import AVFoundation
import Observation
import Accelerate

/// Captures audio and extracts breathing + snoring features.
/// Raw audio buffers are never stored — only derived feature vectors.
@Observable
final class AudioAnalysisService {
    private(set) var isRunning = false
    var onFeaturesUpdated: ((AudioFeatures) -> Void)?

    private let engine = AVAudioEngine()
    private let analysisQueue = DispatchQueue(label: "com.sleepbuddy.audio", qos: .utility)

    // Amplitude envelope at 8 Hz for breathing rate detection
    private var envelopeBuffer: [Float] = []
    private let envelopeSampleRate: Double = 8.0
    private let analysisWindowSeconds: Double = 30.0
    private var envelopeWindowSize: Int { Int(envelopeSampleRate * analysisWindowSeconds) }

    // Raw sample accumulator for FFT-based snoring detection
    private var rawSampleBuffer: [Float] = []
    private let fftSize = 4096
    private var audioSampleRate: Double = 44100
    private var rawBufferMaxSize: Int { fftSize * 4 }   // keep last ~0.4s at 44.1kHz

    // Chunk accumulator for envelope tick
    private var chunkSamples: [Float] = []
    private var samplesPerEnvelopeTick: Int { Int(audioSampleRate / envelopeSampleRate) }

    // FFT setup (created once, reused)
    private var fftSetup: FFTSetup?

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .allowBluetoothHFP])
        try session.setActive(true)

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        audioSampleRate = format.sampleRate

        let log2n = vDSP_Length(log2(Float(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(FFT_RADIX2))

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.analysisQueue.async { self?.processBuffer(buffer) }
        }

        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let setup = fftSetup { vDSP_destroy_fftsetup(setup); fftSetup = nil }
        try? AVAudioSession.sharedInstance().setActive(false)
        envelopeBuffer.removeAll()
        chunkSamples.removeAll()
        rawSampleBuffer.removeAll()
        isRunning = false
    }

    // MARK: - Buffer processing

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)

        // Accumulate raw samples for FFT (ring-buffer capped at rawBufferMaxSize)
        for i in 0..<count { rawSampleBuffer.append(channelData[i]) }
        if rawSampleBuffer.count > rawBufferMaxSize {
            rawSampleBuffer.removeFirst(rawSampleBuffer.count - rawBufferMaxSize)
        }

        // Build amplitude envelope at envelopeSampleRate
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
        if envelopeBuffer.count > envelopeWindowSize { envelopeBuffer.removeFirst() }

        if envelopeBuffer.count == envelopeWindowSize {
            let features = extractFeatures()
            DispatchQueue.main.async { [weak self] in
                self?.onFeaturesUpdated?(features)
            }
        }
    }

    // MARK: - Feature extraction

    private func extractFeatures() -> AudioFeatures {
        let n = envelopeBuffer.count

        var mean: Float = 0
        vDSP_meanv(envelopeBuffer, 1, &mean, vDSP_Length(n))

        let demeaned = envelopeBuffer.map { $0 - mean }
        var variance: Float = 0
        vDSP_measqv(demeaned, 1, &variance, vDSP_Length(n))

        let breathingRate = estimateBreathingRate(envelope: demeaned, sampleRate: envelopeSampleRate)
        let regularity = computeRegularity(envelope: demeaned)
        let snoring = snoringIntensity(rawSamples: rawSampleBuffer, sampleRate: audioSampleRate)

        return AudioFeatures(
            averageAmplitude: mean,
            amplitudeVariance: variance,
            breathingRateBPM: breathingRate,
            breathingRegularity: regularity,
            snoringIntensity: snoring,
            timestamp: Date()
        )
    }

    // MARK: - Breathing rate (autocorrelation)

    private func estimateBreathingRate(envelope: [Float], sampleRate: Double) -> Float {
        let n = envelope.count
        let minPeriodSamples = Int(sampleRate * 2.0)    // 30 bpm max
        let maxPeriodSamples = Int(sampleRate * 7.5)    // 8 bpm min

        guard minPeriodSamples < maxPeriodSamples, maxPeriodSamples < n else { return 0 }

        var bestLag = 0
        var bestCorr: Float = -1

        for lag in minPeriodSamples...maxPeriodSamples {
            var corr: Float = 0
            let overlap = n - lag
            vDSP_dotpr(envelope, 1, Array(envelope[lag...]), 1, &corr, vDSP_Length(overlap))
            corr /= Float(overlap)
            if corr > bestCorr { bestCorr = corr; bestLag = lag }
        }

        guard bestLag > 0, bestCorr > 0 else { return 0 }
        return 60.0 / (Float(bestLag) / Float(sampleRate))
    }

    // MARK: - Breathing regularity

    private func computeRegularity(envelope: [Float]) -> Float {
        guard envelope.count > 1 else { return 0 }
        var diffs: [Float] = []
        for i in 1..<envelope.count { diffs.append(abs(envelope[i] - envelope[i-1])) }
        var diffMean: Float = 0
        vDSP_meanv(diffs, 1, &diffMean, vDSP_Length(diffs.count))
        let demDiffs = diffs.map { $0 - diffMean }
        var diffVar: Float = 0
        vDSP_measqv(demDiffs, 1, &diffVar, vDSP_Length(demDiffs.count))
        return min(max(1.0 / (1.0 + diffVar * 1000), 0), 1)
    }

    // MARK: - Snoring detection (FFT spectral analysis)
    // Snoring: dominant energy in 80–500 Hz, above background noise floor.

    private func snoringIntensity(rawSamples: [Float], sampleRate: Double) -> Float {
        guard let setup = fftSetup, rawSamples.count >= fftSize else { return 0 }

        let recent = Array(rawSamples.suffix(fftSize))

        // Apply Hann window
        var windowed = [Float](repeating: 0, count: fftSize)
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        vDSP_vmul(recent, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        // FFT
        var realPart = [Float](repeating: 0, count: fftSize / 2)
        var imagPart = [Float](repeating: 0, count: fftSize / 2)

        windowed.withUnsafeBufferPointer { ptr in
            var splitComplex = DSPSplitComplex(realp: &realPart, imagp: &imagPart)
            ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { cPtr in
                vDSP_ctoz(cPtr, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
            }
            let log2n = vDSP_Length(log2(Float(fftSize)))
            vDSP_fft_zrip(setup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
        }

        // Power spectrum
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        for i in 0..<fftSize/2 {
            magnitudes[i] = realPart[i]*realPart[i] + imagPart[i]*imagPart[i]
        }

        let hzPerBin = sampleRate / Double(fftSize)
        let lowBin  = max(1, Int(80.0  / hzPerBin))
        let highBin = min(fftSize / 2 - 1, Int(500.0 / hzPerBin))

        var bandEnergy: Float = 0
        var totalEnergy: Float = 0
        vDSP_sve(Array(magnitudes[lowBin...highBin]), 1, &bandEnergy, vDSP_Length(highBin - lowBin + 1))
        vDSP_sve(magnitudes, 1, &totalEnergy, vDSP_Length(fftSize / 2))

        guard totalEnergy > 1e-10 else { return 0 }

        // Snoring: high band ratio + sufficient amplitude (avoids false positives from ambient noise)
        let ratio = bandEnergy / totalEnergy
        let rmsAll = sqrt(totalEnergy / Float(fftSize / 2))
        guard rmsAll > 0.005 else { return 0 }   // minimum volume floor

        // Snoring band ratio typically > 0.4 during real snoring
        return min(max((ratio - 0.3) / 0.4, 0), 1.0)
    }
}

struct AudioFeatures {
    let averageAmplitude: Float
    let amplitudeVariance: Float
    let breathingRateBPM: Float        // 0 if not detectable
    let breathingRegularity: Float     // 0–1, 1 = perfectly regular
    let snoringIntensity: Float        // 0–1, 0 = keine Schnarchen
    let timestamp: Date
}
