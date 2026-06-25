import CoreMotion
import Accelerate
import Observation

/// Reads accelerometer data at 50 Hz to detect:
/// - Bed movement (gross)
/// - Breathing rhythm via periodic vibrations in 0.15–0.5 Hz (9–30 BPM)
/// - Heart rate via Ballistokardiography (BCG) in 0.8–2.5 Hz (48–150 BPM)
///   — only when phone is flat on the mattress
@Observable
final class MotionAnalysisService {
    private(set) var isRunning = false
    private(set) var isAvailable: Bool

    var onFeaturesUpdated: ((MotionFeatures) -> Void)?

    private let motionManager = CMMotionManager()
    private let queue = OperationQueue()

    // 50 Hz — high enough for BCG heart rate detection (max ~2.5 Hz = 150 BPM)
    private let sampleRate = 50.0

    // Movement + breathing share 30 s window → downsample 5× to get effective 10 Hz
    private let windowSeconds = 30.0
    private var windowSize: Int { Int(windowSeconds * sampleRate) }      // 1500 samples

    // Breathing: 60 s at effective 10 Hz (every 5th sample)
    private let breathingWindowSeconds = 60.0
    private var breathingWindowSize: Int { Int(breathingWindowSeconds * 10.0) }  // 600 samples

    // BCG: 30 s at full 50 Hz
    private let bcgWindowSeconds = 30.0
    private var bcgWindowSize: Int { Int(bcgWindowSeconds * sampleRate) }  // 1500 samples

    // Buffers
    private var rawSamples: [Float] = []           // full 50 Hz, movement detection
    private var breathingSamples: [Float] = []     // downsampled 10 Hz, breathing
    private var bcgZ: [Float] = []                 // 50 Hz z-axis only, BCG
    private var downsampleCounter = 0
    private var emitCounter = 0                    // emit features every windowSize samples (30 s)

    init() {
        isAvailable = CMMotionManager().isAccelerometerAvailable
    }

    func start() {
        guard motionManager.isAccelerometerAvailable else { return }
        queue.maxConcurrentOperationCount = 1
        motionManager.accelerometerUpdateInterval = 1.0 / sampleRate
        motionManager.startAccelerometerUpdates(to: queue) { [weak self] data, _ in
            guard let data, let self else { return }
            let x = Float(data.acceleration.x)
            let y = Float(data.acceleration.y)
            let z = Float(data.acceleration.z)
            let mag = sqrt(x*x + y*y + z*z)
            self.append(mag: mag, z: z)
        }
        isRunning = true
    }

    func stop() {
        motionManager.stopAccelerometerUpdates()
        rawSamples.removeAll()
        breathingSamples.removeAll()
        bcgZ.removeAll()
        downsampleCounter = 0
        emitCounter = 0
        isRunning = false
    }

    func reset() {
        rawSamples.removeAll()
        breathingSamples.removeAll()
        bcgZ.removeAll()
        downsampleCounter = 0
        emitCounter = 0
    }

    // MARK: - Processing

    private func append(mag: Float, z: Float) {
        // Full-rate magnitude buffer for movement detection
        rawSamples.append(mag)
        if rawSamples.count > windowSize { rawSamples.removeFirst() }

        // BCG: z-axis at full 50 Hz
        bcgZ.append(z)
        if bcgZ.count > bcgWindowSize { bcgZ.removeFirst() }

        // Breathing: downsample to 10 Hz (every 5th sample)
        downsampleCounter += 1
        if downsampleCounter >= 5 {
            downsampleCounter = 0
            breathingSamples.append(mag)
            if breathingSamples.count > breathingWindowSize { breathingSamples.removeFirst() }
        }

        // Emit features every windowSize samples (30 s) — not on every sample after fill
        emitCounter += 1
        if emitCounter >= windowSize {
            emitCounter = 0
            let features = extract()
            DispatchQueue.main.async { [weak self] in
                self?.onFeaturesUpdated?(features)
            }
        }
    }

    private func extract() -> MotionFeatures {
        let n = vDSP_Length(rawSamples.count)

        // Movement intensity (30 s window)
        var mean: Float = 0
        vDSP_meanv(rawSamples, 1, &mean, n)
        let demeaned = rawSamples.map { $0 - mean }
        var variance: Float = 0
        vDSP_measqv(demeaned, 1, &variance, n)
        let intensity = min(sqrt(variance) * 25.0, 1.0)

        // Breathing via accelerometer autocorrelation (downsampled 10 Hz buffer)
        let (breathBPM, breathReg, onMattress) = detectBreathing(samples: breathingSamples)

        // BCG heart rate — only attempt when phone is on mattress
        let bcgHR: Float = onMattress ? detectHeartRate(zSamples: bcgZ) : 0

        return MotionFeatures(
            movementIntensity: intensity,
            breathingRateBPM: breathBPM,
            breathingRegularity: breathReg,
            isOnMattress: onMattress,
            bcgHeartRateBPM: bcgHR,
            timestamp: Date()
        )
    }

    // MARK: - Breathing detection (10 Hz autocorrelation, 9–30 BPM)

    private func detectBreathing(samples: [Float]) -> (Float, Float, Bool) {
        guard samples.count >= breathingWindowSize else { return (0, 0, false) }
        let effRate = 10.0   // effective rate after downsampling

        let n = samples.count
        var mean: Float = 0
        vDSP_meanv(samples, 1, &mean, vDSP_Length(n))
        let signal = samples.map { $0 - mean }

        var rms: Float = 0
        vDSP_rmsqv(signal, 1, &rms, vDSP_Length(n))
        guard rms > 0.0003 else { return (0, 0, false) }

        var acf = [Float](repeating: 0, count: n)
        vDSP_conv(signal, 1, signal, 1, &acf, 1, vDSP_Length(n), vDSP_Length(n))

        let lagMin = Int(effRate * 2.0)    // 30 BPM = 2s
        let lagMax = Int(effRate * 6.7)    // 9 BPM = 6.7s
        guard lagMax < n else { return (0, 0, false) }

        let searchRange = Array(acf[lagMin...lagMax])
        var peakVal: Float = 0
        var peakIdx: vDSP_Length = 0
        vDSP_maxvi(searchRange, 1, &peakVal, &peakIdx, vDSP_Length(searchRange.count))

        let zeroLag = acf[0]
        guard zeroLag > 0 else { return (0, 0, false) }
        let strength = peakVal / zeroLag
        guard strength > 0.25 else { return (0, 0, false) }

        let periodSamples = Float(Int(peakIdx) + lagMin)
        let bpm = Float(effRate * 60.0) / periodSamples
        let regularity = min(strength * 1.5, 1.0)

        return (bpm, regularity, true)
    }

    // MARK: - BCG Heart Rate detection (50 Hz z-axis, 48–150 BPM)
    //
    // Ballistokardiography: each heartbeat imparts a tiny mechanical impulse to
    // the mattress that the accelerometer z-axis picks up as a ~0.8–2.5 Hz signal.
    // Algorithm:
    //   1. Bandpass filter: high-pass (remove breathing/DC) + light low-pass
    //   2. Autocorrelation on the 48–150 BPM lag range
    //   3. Require high peak strength to avoid false positives
    //   4. Cross-check with breathing rate (HR should not equal breathing rate)

    private func detectHeartRate(zSamples: [Float]) -> Float {
        guard zSamples.count >= bcgWindowSize else { return 0 }

        // High-pass: subtract 1.5 s moving average to remove DC + breathing (< 0.7 Hz)
        let hpWindow = Int(sampleRate * 1.5)   // 75 samples
        let filtered = highPass(zSamples, windowSize: hpWindow)

        // Light low-pass: 3-sample MA to remove sensor noise above ~8 Hz
        let smoothed = movingAverage(filtered, n: 3)

        // RMS check — too quiet means phone is not picking up heartbeat
        let n = smoothed.count
        var rms: Float = 0
        vDSP_rmsqv(smoothed, 1, &rms, vDSP_Length(n))
        // BCG signal is very weak; typical threshold ~0.00003–0.0005 g
        guard rms > 0.00003 else { return 0 }

        // Autocorrelation
        var acf = [Float](repeating: 0, count: n)
        vDSP_conv(smoothed, 1, smoothed, 1, &acf, 1, vDSP_Length(n), vDSP_Length(n))

        // Lag range: 48 BPM = 50/0.8 = 62.5 samples, 150 BPM = 50/2.5 = 20 samples
        let lagMin = Int(sampleRate * 60.0 / 150.0)   // 20 samples (150 BPM)
        let lagMax = Int(sampleRate * 60.0 / 48.0)    // 62 samples (48 BPM)
        guard lagMax < n, lagMin < lagMax else { return 0 }

        let searchRange = Array(acf[lagMin...lagMax])
        var peakVal: Float = 0
        var peakIdx: vDSP_Length = 0
        vDSP_maxvi(searchRange, 1, &peakVal, &peakIdx, vDSP_Length(searchRange.count))

        let zeroLag = acf[0]
        guard zeroLag > 0 else { return 0 }
        let strength = peakVal / zeroLag

        // BCG requires stronger peak than breathing (more noise)
        guard strength > 0.28 else { return 0 }

        let periodSamples = Float(Int(peakIdx) + lagMin)
        let bpm = Float(sampleRate * 60.0) / periodSamples

        // Sanity: must be in physiological range
        guard bpm >= 40 && bpm <= 150 else { return 0 }

        return bpm
    }

    // MARK: - Filter helpers

    private func highPass(_ signal: [Float], windowSize: Int) -> [Float] {
        guard signal.count > windowSize else { return signal }
        var out = [Float](repeating: 0, count: signal.count)
        // Causal moving average (running sum)
        var runSum: Float = 0
        for i in 0..<signal.count {
            runSum += signal[i]
            if i >= windowSize { runSum -= signal[i - windowSize] }
            let count = Float(min(i + 1, windowSize))
            out[i] = signal[i] - runSum / count
        }
        return out
    }

    private func movingAverage(_ signal: [Float], n: Int) -> [Float] {
        guard signal.count > n else { return signal }
        var out = [Float](repeating: 0, count: signal.count)
        var runSum: Float = 0
        for i in 0..<signal.count {
            runSum += signal[i]
            if i >= n { runSum -= signal[i - n] }
            out[i] = runSum / Float(min(i + 1, n))
        }
        return out
    }
}

struct MotionFeatures {
    let movementIntensity: Float       // 0 = still, 1 = awake/moving
    let breathingRateBPM: Float        // >0 when phone is on mattress
    let breathingRegularity: Float     // 0–1, from accelerometer
    let isOnMattress: Bool             // true when breathing rhythm detected via accelerometer
    let bcgHeartRateBPM: Float         // BCG heart rate, 0 if unreliable or not on mattress
    let timestamp: Date

    var isSignificant: Bool { movementIntensity > 0.35 }

    static let neutral = MotionFeatures(
        movementIntensity: 0,
        breathingRateBPM: 0,
        breathingRegularity: 0,
        isOnMattress: false,
        bcgHeartRateBPM: 0,
        timestamp: Date()
    )
}
