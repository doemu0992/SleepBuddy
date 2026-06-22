import AVFoundation
import Observation

/// Captures audio via AVAudioEngine and extracts acoustic features.
/// Raw audio buffers are never persisted — only derived feature vectors are kept in memory.
@Observable
final class AudioAnalysisService {
    private(set) var isRunning = false
    private(set) var currentAmplitude: Float = 0
    private(set) var currentSpectralCentroid: Float = 0

    var onFeaturesUpdated: ((AudioFeatures) -> Void)?

    private let engine = AVAudioEngine()
    private let analysisQueue = DispatchQueue(label: "com.sleepbuddy.audio", qos: .utility)

    // Feature update interval
    private let featureWindowDuration: TimeInterval = 30

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .allowBluetooth])
        try session.setActive(true)

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.analysisQueue.async {
                self?.processBuffer(buffer)
            }
        }

        try engine.start()
        isRunning = true
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        isRunning = false
    }

    private var amplitudeAccumulator: Float = 0
    private var bufferCount: Int = 0

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)

        // RMS amplitude — raw samples discarded immediately
        var rms: Float = 0
        for i in 0..<frameCount {
            rms += channelData[i] * channelData[i]
        }
        rms = sqrt(rms / Float(frameCount))

        amplitudeAccumulator += rms
        bufferCount += 1

        let sampleRate = buffer.format.sampleRate
        let framesPerWindow = Int(featureWindowDuration * sampleRate) / 4096

        if bufferCount >= framesPerWindow {
            let avgAmplitude = amplitudeAccumulator / Float(bufferCount)
            let features = AudioFeatures(
                averageAmplitude: avgAmplitude,
                spectralCentroid: estimateSpectralCentroid(channelData, count: frameCount),
                timestamp: Date()
            )
            amplitudeAccumulator = 0
            bufferCount = 0

            DispatchQueue.main.async { [weak self] in
                self?.currentAmplitude = features.averageAmplitude
                self?.onFeaturesUpdated?(features)
            }
        }
    }

    private func estimateSpectralCentroid(_ data: UnsafePointer<Float>, count: Int) -> Float {
        // Simplified: use zero-crossing rate as proxy for spectral centroid
        var crossings = 0
        for i in 1..<count {
            if (data[i] >= 0) != (data[i - 1] >= 0) { crossings += 1 }
        }
        return Float(crossings) / Float(count)
    }
}

struct AudioFeatures {
    let averageAmplitude: Float
    let spectralCentroid: Float
    let timestamp: Date
}
