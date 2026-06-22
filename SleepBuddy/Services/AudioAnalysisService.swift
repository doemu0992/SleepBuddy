import AVFoundation
import Observation
import Accelerate

/// Captures audio and extracts breathing-related acoustic features.
/// Raw audio buffers are never stored — only derived feature vectors.
@Observable
final class AudioAnalysisService {
    private(set) var isRunning = false
    var onFeaturesUpdated: ((AudioFeatures) -> Void)?

    private let engine = AVAudioEngine()
    private let analysisQueue = DispatchQueue(label: "com.sleepbuddy.audio", qos: .utility)

    // Amplitude envelope sampled at ~8 Hz for breathing rate detection
    private var envelopeBuffer: [Float] = []
    private let envelopeSampleRate: Double = 8.0
    private let analysisWindowSeconds: Double = 30.0
    private var envelopeWindowSize: Int { Int(envelopeSampleRate * analysisWindowSeconds) }

    // Sub-buffer for computing amplitude per chunk
    private var chunkSamples: [Float] = []
    private var audioSampleRate: Double = 44100
    private var samplesPerEnvelopeTick: Int { Int(audioSampleRate / envelopeSampleRate) }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .allowBluetoothHFP])
        try session.setActive(true)

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        audioSampleRate = format.sampleRate

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
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
        envelopeBuffer.removeAll()
        chunkSamples.removeAll()
        isRunning = false
    }

    // MARK: - Buffer processing

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)

        // Accumulate samples into chunk
        for i in 0..<count {
            chunkSamples.append(channelData[i])

            if chunkSamples.count >= samplesPerEnvelopeTick {
                let rms = computeRMS(chunkSamples)
                chunkSamples.removeAll(keepingCapacity: true)
                appendEnvelopeSample(rms)
            }
        }
    }

    private func computeRMS(_ samples: [Float]) -> Float {
        var rms: Float = 0
        vDSP_measqv(samples, 1, &rms, vDSP_Length(samples.count))
        return sqrt(rms)
    }

    private func appendEnvelopeSample(_ value: Float) {
        envelopeBuffer.append(value)
        if envelopeBuffer.count > envelopeWindowSize {
            envelopeBuffer.removeFirst()
        }

        // Emit features every 30 seconds (full window filled)
        if envelopeBuffer.count == envelopeWindowSize {
            let features = extractFeatures(from: envelopeBuffer)
            DispatchQueue.main.async { [weak self] in
                self?.onFeaturesUpdated?(features)
            }
        }
    }

    // MARK: - Feature extraction

    private func extractFeatures(from envelope: [Float]) -> AudioFeatures {
        let n = envelope.count

        // Average amplitude
        var mean: Float = 0
        vDSP_meanv(envelope, 1, &mean, vDSP_Length(n))

        // Amplitude variance (movement indicator)
        let demeaned = envelope.map { $0 - mean }
        var variance: Float = 0
        vDSP_measqv(demeaned, 1, &variance, vDSP_Length(n))

        // Breathing rate via autocorrelation on the amplitude envelope
        let breathingRate = estimateBreathingRate(envelope: demeaned, sampleRate: envelopeSampleRate)

        // Regularity: ratio of peak autocorrelation to variance
        let regularity = computeRegularity(envelope: demeaned)

        return AudioFeatures(
            averageAmplitude: mean,
            amplitudeVariance: variance,
            breathingRateBPM: breathingRate,
            breathingRegularity: regularity,
            timestamp: Date()
        )
    }

    /// Autocorrelation-based breathing rate estimation.
    /// Breathing range: 8–30 breaths/min → periods of 2s–7.5s at 8 Hz = 16–60 samples.
    private func estimateBreathingRate(envelope: [Float], sampleRate: Double) -> Float {
        let n = envelope.count
        let minPeriodSamples = Int(sampleRate * 2.0)   // 30 bpm max
        let maxPeriodSamples = Int(sampleRate * 7.5)   // 8 bpm min

        guard minPeriodSamples < maxPeriodSamples, maxPeriodSamples < n else { return 0 }

        var bestLag = 0
        var bestCorr: Float = -1

        for lag in minPeriodSamples...maxPeriodSamples {
            var corr: Float = 0
            let overlap = n - lag
            vDSP_dotpr(envelope, 1, Array(envelope[lag...]), 1, &corr, vDSP_Length(overlap))
            corr /= Float(overlap)
            if corr > bestCorr {
                bestCorr = corr
                bestLag = lag
            }
        }

        guard bestLag > 0 && bestCorr > 0 else { return 0 }

        let periodSeconds = Float(bestLag) / Float(sampleRate)
        return 60.0 / periodSeconds
    }

    /// Normalized regularity: 0 = chaotic, 1 = perfectly periodic
    private func computeRegularity(envelope: [Float]) -> Float {
        let n = envelope.count
        guard n > 1 else { return 0 }

        // Variance of consecutive differences (lower = more regular)
        var diffs: [Float] = []
        for i in 1..<n { diffs.append(abs(envelope[i] - envelope[i-1])) }

        var diffMean: Float = 0
        vDSP_meanv(diffs, 1, &diffMean, vDSP_Length(diffs.count))

        var diffVar: Float = 0
        let demeanedDiffs = diffs.map { $0 - diffMean }
        vDSP_measqv(demeanedDiffs, 1, &diffVar, vDSP_Length(demeanedDiffs.count))

        // Normalize: low variance of diffs = high regularity
        let regularity = 1.0 / (1.0 + diffVar * 1000)
        return min(max(regularity, 0), 1)
    }
}

struct AudioFeatures {
    let averageAmplitude: Float
    let amplitudeVariance: Float
    let breathingRateBPM: Float       // 0 if not detectable
    let breathingRegularity: Float    // 0–1, 1 = perfectly regular
    let timestamp: Date
}
