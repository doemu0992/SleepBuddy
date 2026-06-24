import CoreMotion
import Accelerate
import Observation

/// Reads accelerometer data to detect bed movement and — when phone is on the mattress —
/// breathing rhythm via periodic vibrations in the 0.15–0.5 Hz range (9–30 BPM).
@Observable
final class MotionAnalysisService {
    private(set) var isRunning = false
    private(set) var isAvailable: Bool

    var onFeaturesUpdated: ((MotionFeatures) -> Void)?

    private let motionManager = CMMotionManager()
    private let queue = OperationQueue()

    // Movement detection: 10 Hz, 30s window
    private let sampleRate = 10.0
    private let windowSeconds = 30.0
    private var windowSize: Int { Int(windowSeconds * sampleRate) }
    private var samples: [Float] = []

    // Breathing detection: same buffer but analysed over 60s for better frequency resolution
    private let breathingWindowSeconds = 60.0
    private var breathingWindowSize: Int { Int(breathingWindowSeconds * sampleRate) }
    private var breathingSamples: [Float] = []

    init() {
        isAvailable = CMMotionManager().isAccelerometerAvailable
    }

    func start() {
        guard motionManager.isAccelerometerAvailable else { return }
        queue.maxConcurrentOperationCount = 1
        motionManager.accelerometerUpdateInterval = 1.0 / sampleRate
        motionManager.startAccelerometerUpdates(to: queue) { [weak self] data, _ in
            guard let data, let self else { return }
            let mag = Float(sqrt(data.acceleration.x * data.acceleration.x
                               + data.acceleration.y * data.acceleration.y
                               + data.acceleration.z * data.acceleration.z))
            self.append(mag)
        }
        isRunning = true
    }

    func stop() {
        motionManager.stopAccelerometerUpdates()
        samples.removeAll()
        breathingSamples.removeAll()
        isRunning = false
    }

    func reset() {
        samples.removeAll()
        breathingSamples.removeAll()
    }

    // MARK: - Processing

    private func append(_ value: Float) {
        samples.append(value)
        if samples.count > windowSize { samples.removeFirst() }

        breathingSamples.append(value)
        if breathingSamples.count > breathingWindowSize { breathingSamples.removeFirst() }

        if samples.count == windowSize {
            let features = extract(movement: samples, breathing: breathingSamples)
            DispatchQueue.main.async { [weak self] in
                self?.onFeaturesUpdated?(features)
            }
        }
    }

    private func extract(movement: [Float], breathing: [Float]) -> MotionFeatures {
        let n = vDSP_Length(movement.count)

        // Movement intensity
        var mean: Float = 0
        vDSP_meanv(movement, 1, &mean, n)
        let demeaned = movement.map { $0 - mean }
        var variance: Float = 0
        vDSP_measqv(demeaned, 1, &variance, n)
        let intensity = min(sqrt(variance) * 25.0, 1.0)

        // Breathing detection via autocorrelation on longer window
        let (bpm, regularity, onMattress) = detectBreathing(samples: breathing)

        return MotionFeatures(
            movementIntensity: intensity,
            breathingRateBPM: bpm,
            breathingRegularity: regularity,
            isOnMattress: onMattress,
            timestamp: Date()
        )
    }

    // MARK: - Accelerometer breathing detection

    /// Looks for a dominant periodic component in the 9–30 BPM (0.15–0.5 Hz) band.
    /// Returns (BPM, regularity 0–1, onMattress).
    /// On a nightstand the signal is too weak to detect; on a mattress it's clearly visible.
    private func detectBreathing(samples: [Float]) -> (Float, Float, Bool) {
        guard samples.count >= breathingWindowSize else { return (0, 0, false) }

        let n = samples.count
        let nF = vDSP_Length(n)

        // Remove gravity (mean) to isolate movement
        var mean: Float = 0
        vDSP_meanv(samples, 1, &mean, nF)
        let signal = samples.map { $0 - mean }

        // RMS of signal — on a nightstand this is near 0
        var rms: Float = 0
        vDSP_rmsqv(signal, 1, &rms, nF)
        // Threshold: if signal is barely moving, phone is on nightstand
        guard rms > 0.0008 else { return (0, 0, false) }

        // Autocorrelation to find dominant period
        var acf = [Float](repeating: 0, count: n)
        vDSP_conv(signal, 1, signal, 1, &acf, 1, vDSP_Length(n), vDSP_Length(n))

        // Search for peak in lag range corresponding to 9–30 BPM
        let lagMin = Int(sampleRate * 2.0)   // 30 BPM = 2s period
        let lagMax = Int(sampleRate * 6.7)   // 9 BPM = 6.67s period
        guard lagMax < n else { return (0, 0, false) }

        let searchRange = Array(acf[lagMin...lagMax])
        var peakVal: Float = 0
        var peakIdx: vDSP_Length = 0
        vDSP_maxvi(searchRange, 1, &peakVal, &peakIdx, vDSP_Length(searchRange.count))

        // Normalised peak strength (compared to zero-lag)
        let zeroLag = acf[0]
        guard zeroLag > 0 else { return (0, 0, false) }
        let strength = peakVal / zeroLag   // 0–1

        // Only count as breathing if the periodic component is strong enough
        guard strength > 0.25 else { return (0, 0, false) }

        let periodSamples = Float(Int(peakIdx) + lagMin)
        let bpm = (sampleRate * 60.0) / Double(periodSamples)
        let regularity = min(strength * 1.5, 1.0)  // scale to 0–1

        return (Float(bpm), regularity, true)
    }
}

struct MotionFeatures {
    let movementIntensity: Float      // 0 = still, 1 = awake/moving
    let breathingRateBPM: Float       // >0 when phone is on mattress
    let breathingRegularity: Float    // 0–1, from accelerometer
    let isOnMattress: Bool            // true when breathing rhythm detected via accelerometer
    let timestamp: Date

    var isSignificant: Bool { movementIntensity > 0.35 }

    static let neutral = MotionFeatures(
        movementIntensity: 0,
        breathingRateBPM: 0,
        breathingRegularity: 0,
        isOnMattress: false,
        timestamp: Date()
    )
}
