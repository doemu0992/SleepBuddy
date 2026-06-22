import CoreMotion
import Accelerate
import Observation

/// Reads accelerometer data to detect bed movement.
/// When the iPhone lies on the mattress, body movement causes measurable vibrations.
/// This is the same principle Sleep Cycle uses.
@Observable
final class MotionAnalysisService {
    private(set) var isRunning = false
    private(set) var isAvailable: Bool

    var onFeaturesUpdated: ((MotionFeatures) -> Void)?

    private let motionManager = CMMotionManager()
    private let queue = OperationQueue()
    private var samples: [Float] = []

    private let sampleRate = 10.0           // Hz
    private let windowSeconds = 30.0
    private var windowSize: Int { Int(windowSeconds * sampleRate) }

    init() {
        isAvailable = CMMotionManager().isAccelerometerAvailable
    }

    func start() {
        guard motionManager.isAccelerometerAvailable else { return }
        queue.maxConcurrentOperationCount = 1
        motionManager.accelerometerUpdateInterval = 1.0 / sampleRate
        motionManager.startAccelerometerUpdates(to: queue) { [weak self] data, _ in
            guard let data, let self else { return }
            // Magnitude of acceleration vector (gravity-inclusive)
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
        isRunning = false
    }

    func reset() { samples.removeAll() }

    // MARK: - Processing

    private func append(_ value: Float) {
        samples.append(value)
        if samples.count > windowSize { samples.removeFirst() }

        if samples.count == windowSize {
            let features = extract(from: samples)
            DispatchQueue.main.async { [weak self] in
                self?.onFeaturesUpdated?(features)
            }
        }
    }

    private func extract(from samples: [Float]) -> MotionFeatures {
        let n = vDSP_Length(samples.count)

        // Mean ≈ gravity (≈1g). Variance of residuals = actual movement.
        var mean: Float = 0
        vDSP_meanv(samples, 1, &mean, n)

        let demeaned = samples.map { $0 - mean }
        var variance: Float = 0
        vDSP_measqv(demeaned, 1, &variance, n)

        // Scale so normal sleep ≈ 0.0–0.2, significant movement > 0.5
        let intensity = min(sqrt(variance) * 25.0, 1.0)
        return MotionFeatures(movementIntensity: intensity, timestamp: Date())
    }
}

struct MotionFeatures {
    let movementIntensity: Float   // 0 = still, 1 = awake/moving
    let timestamp: Date

    var isSignificant: Bool { movementIntensity > 0.35 }

    static let neutral = MotionFeatures(movementIntensity: 0, timestamp: Date())
}
