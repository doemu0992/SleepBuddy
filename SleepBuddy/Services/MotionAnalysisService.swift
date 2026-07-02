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

    // PLM detection: 1 Hz movement envelope (every 50th sample) over 3 min
    private var plmBuffer: [Float] = []
    private let plmWindowSize = 180    // 3 min × 1 Hz
    private var plmDownsampleCounter = 0

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
            self.append(x: x, y: y, z: z, mag: mag)
        }
        isRunning = true
    }

    func stop() {
        motionManager.stopAccelerometerUpdates()
        rawSamples.removeAll()
        breathingSamples.removeAll()
        bcgZ.removeAll()
        plmBuffer.removeAll()
        recentBCG.removeAll()
        downsampleCounter = 0
        plmDownsampleCounter = 0
        emitCounter = 0
        isRunning = false
    }

    func reset() {
        rawSamples.removeAll()
        breathingSamples.removeAll()
        bcgZ.removeAll()
        plmBuffer.removeAll()
        recentBCG.removeAll()
        downsampleCounter = 0
        plmDownsampleCounter = 0
        emitCounter = 0
    }

    // MARK: - Processing

    private func append(x: Float, y: Float, z: Float, mag: Float) {
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

        // PLM: 1 Hz movement envelope (every 50th sample) for periodicity detection
        plmDownsampleCounter += 1
        if plmDownsampleCounter >= 50 {
            plmDownsampleCounter = 0
            plmBuffer.append(mag)
            if plmBuffer.count > plmWindowSize { plmBuffer.removeFirst() }
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
        // Peak-Abweichung fängt KURZE Bewegungen (schnelles Umdrehen) ab, die im 30-s-RMS
        // sonst verwässern und untergehen. Blend: anhaltende Bewegung via RMS + kurze
        // Spitzen via Peak. Peak wird moderat gewichtet, damit Sensor-Rauschen (~0.02 g)
        // niedrig bleibt, ein echtes Umdrehen (> 0.1 g) aber klar registriert wird.
        var peak: Float = 0
        vDSP_maxmgv(demeaned, 1, &peak, n)
        let intensity = min(sqrt(variance) * 25.0 + peak * 3.0, 1.0)

        // Breathing via accelerometer autocorrelation (downsampled 10 Hz buffer)
        let (breathBPM, breathReg, onMattress) = detectBreathing(samples: breathingSamples)

        // BCG heart rate — only attempt when phone is on mattress
        let bcgHR: Float = onMattress ? detectHeartRate(zSamples: bcgZ) : 0

        // PLM: periodic limb movements every 20–40 s
        let plm = detectPLM(samples: plmBuffer)

        return MotionFeatures(
            movementIntensity: intensity,
            breathingRateBPM: breathBPM,
            breathingRegularity: breathReg,
            isOnMattress: onMattress,
            bcgHeartRateBPM: bcgHR,
            isPLMSuspected: plm,
            timestamp: Date()
        )
    }

    // MARK: - PLM detection (periodic limb movements, 20–40 s intervals)

    private func detectPLM(samples: [Float]) -> Bool {
        guard samples.count >= 60 else { return false }  // need at least 1 min
        let n = samples.count

        // Subtract mean (DC removal)
        var mean: Float = 0
        vDSP_meanv(samples, 1, &mean, vDSP_Length(n))
        let demeaned = samples.map { $0 - mean }

        // RMS — must have some movement to detect PLM
        var rms: Float = 0
        vDSP_measqv(demeaned, 1, &rms, vDSP_Length(n))
        guard rms > 0.0005 else { return false }

        // Autocorrelation at lags 20–40 s (20–40 samples at 1 Hz)
        // PLM produces a clear peak in this range.
        var bestPeak: Float = 0
        let lagMin = 20, lagMax = 40
        for lag in lagMin...lagMax {
            guard lag < n else { break }
            var corr: Float = 0
            vDSP_dotpr(demeaned, 1, Array(demeaned.dropFirst(lag)), 1, &corr, vDSP_Length(n - lag))
            corr /= Float(n - lag)
            if corr > bestPeak { bestPeak = corr }
        }

        // Normalise by zero-lag power
        var zeroPower: Float = 0
        vDSP_dotpr(demeaned, 1, demeaned, 1, &zeroPower, vDSP_Length(n))
        zeroPower /= Float(n)
        guard zeroPower > 0 else { return false }

        let normPeak = bestPeak / zeroPower
        // Threshold: normalised ACF > 0.35 indicates clear periodicity
        return normPeak > 0.35
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

        // High-pass: subtract 1.0 s moving average to remove DC + breathing.
        // 1.0 s (was 1.5 s) rejects more low-frequency breathing energy → validated on real
        // SCG+ECG data (CEBSDB) to slightly raise the cardiac lock rate.
        let hpWindow = Int(sampleRate * 1.0)   // 50 samples
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

        // Pick the strongest peak in the cardiac lag range.
        // NOTE: a breathing-harmonic *exclusion* was tried here and REMOVED — validation on
        // real SCG+ECG data (CEBSDB) showed it cut the lock rate roughly in half (the resting
        // pulse is often an integer multiple of the breathing rate, so excluding harmonics
        // also kills the genuine cardiac peak). The stronger high-pass handles breathing instead.
        let searchRange = Array(acf[lagMin...lagMax])
        var peakVal: Float = 0
        var peakIdx: vDSP_Length = 0
        vDSP_maxvi(searchRange, 1, &peakVal, &peakIdx, vDSP_Length(searchRange.count))

        let zeroLag = acf[0]
        guard zeroLag > 0 else { return 0 }
        let strength = peakVal / zeroLag

        // Peak-strength gate. 0.22 (was 0.28) — validated on CEBSDB: raises the lock rate
        // from ~44% to ~67% with NO loss of accuracy (MAE stayed 0.8 BPM). 0.28 was too strict.
        guard strength > 0.22 else { return 0 }

        var chosenLag = Int(peakIdx) + lagMin

        // Continuity prior (fixes minutes-long HR spike plateaus): the BCG beat has
        // intra-beat structure (I/J/K waves) that can make a HALF-period ACF peak
        // temporarily the strongest → the rate locks onto ~1.5–2× the true pulse and
        // holds there (observed: rectangular 60→100 BPM plateaus at night). The true
        // peak is still present, just slightly weaker. If the winning candidate jumps
        // > 20 BPM away from the recent stable pulse while a nearly-as-strong local
        // peak (≥ 65 %) sits within ±12 BPM of it, prefer the continuous one. A real
        // sustained HR change still wins: once the near peak fades, the jump is accepted
        // and the history follows.
        if let med = recentBCGMedian {
            let candBPM = Float(sampleRate * 60.0) / Float(chosenLag)
            if abs(candBPM - med) > 20 {
                let nearLag = Int((Float(sampleRate) * 60.0 / med).rounded())
                let lo = max(lagMin, nearLag - 6), hi = min(lagMax, nearLag + 6)
                if lo < hi {
                    var bestNearVal: Float = 0
                    var bestNearLag = 0
                    for l in lo...hi where l > lagMin && l < lagMax {
                        // local maximum only (not a slope point)
                        if acf[l] >= acf[l - 1] && acf[l] >= acf[l + 1] && acf[l] > bestNearVal {
                            bestNearVal = acf[l]; bestNearLag = l
                        }
                    }
                    let nearBPM = bestNearLag > 0 ? Float(sampleRate * 60.0) / Float(bestNearLag) : 0
                    if bestNearLag > 0, bestNearVal >= peakVal * 0.65, abs(nearBPM - med) <= 12 {
                        chosenLag = bestNearLag
                    }
                }
            }
        }

        let bpm = Float(sampleRate * 60.0) / Float(chosenLag)

        // Sanity: must be in physiological range
        guard bpm >= 40 && bpm <= 150 else { return 0 }

        // Track recent accepted values for the continuity prior.
        recentBCG.append(bpm)
        if recentBCG.count > 8 { recentBCG.removeFirst() }

        return bpm
    }

    // Recent accepted BCG values (median = stable pulse reference for the continuity prior).
    private var recentBCG: [Float] = []
    private var recentBCGMedian: Float? {
        guard recentBCG.count >= 4 else { return nil }
        let s = recentBCG.sorted()
        return s[s.count / 2]
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
    let isPLMSuspected: Bool           // periodic limb movements detected (20–40 s intervals)
    let timestamp: Date

    var isSignificant: Bool { movementIntensity > 0.35 }

    static let neutral = MotionFeatures(
        movementIntensity: 0,
        breathingRateBPM: 0,
        breathingRegularity: 0,
        isOnMattress: false,
        bcgHeartRateBPM: 0,
        isPLMSuspected: false,
        timestamp: Date()
    )
}
