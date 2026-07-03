import AVFoundation
import Observation
import Accelerate
import MediaPlayer
import UIKit

/// Captures audio and extracts breathing + snoring features.
/// Raw audio buffers are never stored for analysis. Opt-in audio clip saving
/// is handled separately by SoundEventService.
@Observable
final class AudioAnalysisService {
    private(set) var isRunning = false
    private(set) var currentFormat: AVAudioFormat?
    var onFeaturesUpdated: ((AudioFeatures) -> Void)?

    /// Called on the analysis queue with raw samples, sample rate, and snoring score
    /// so SoundEventService can maintain its own circular buffer.
    var onRawChunk: (([Float], Double, Float) -> Void)?

    /// Called with each raw buffer for ML classification.
    var onBufferReady: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?

    private let engine = AVAudioEngine()
    private let analysisQueue = DispatchQueue(label: "com.sleepbuddy.audio", qos: .utility)

    // MARK: - Sonar (experimentell, opt-in)
    /// Wenn gesetzt (und `sonar_enabled`), spielt die Engine zusätzlich einen 19-kHz-Ton und
    /// leitet jeden Roh-Buffer an das Sonar weiter. Der Ton wird für die restliche Analyse per
    /// Notch-Filter entfernt (sonst würde er Lautstärke-/Geräuschmessung verfälschen).
    weak var sonar: SonarService?
    // Test-Modus (SonarTestView): Sonar-Pfad unabhängig vom "sonar_enabled"-Toggle erzwingen,
    // damit der Test EXAKT den realen Nacht-Pfad fährt (geteilte Engine, Notch+Lowpass).
    var sonarForced = false
    private var sonarActive = false
    private let sonarTonePlayer = AVAudioPlayerNode()
    private let sonarCarrier: Double = 19_000
    private let sonarToneAmp: Float = 0.35
    @ObservationIgnored private var sonarToneFormat: AVAudioFormat?
    // Notch-Biquad-Koeffizienten (bei start berechnet) + Zustand (Direct Form 1).
    // Je eine Zeile: @Observable verträgt keine Mehrfach-Deklaration pro Zeile.
    @ObservationIgnored private var nb0: Float = 1
    @ObservationIgnored private var nb1: Float = 0
    @ObservationIgnored private var nb2: Float = 0
    @ObservationIgnored private var na1: Float = 0
    @ObservationIgnored private var na2: Float = 0
    @ObservationIgnored private var nx1: Float = 0
    @ObservationIgnored private var nx2: Float = 0
    @ObservationIgnored private var ny1: Float = 0
    @ObservationIgnored private var ny2: Float = 0
    // 11-kHz-Lowpass-Biquad (kaskadiert hinter dem Notch) — siehe configureLowpass.
    @ObservationIgnored private var lb0: Float = 1
    @ObservationIgnored private var lb1: Float = 0
    @ObservationIgnored private var lb2: Float = 0
    @ObservationIgnored private var la1: Float = 0
    @ObservationIgnored private var la2: Float = 0
    @ObservationIgnored private var lx1: Float = 0
    @ObservationIgnored private var lx2: Float = 0
    @ObservationIgnored private var ly1: Float = 0
    @ObservationIgnored private var ly2: Float = 0

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

    // Most recent instantaneous RMS (single 125 ms window) — used by SoundEventService
    // for event detection. The 30s average in AudioFeatures is too smoothed for burst detection.
    private(set) var lastInstantRMS: Float = 0

    // FFT setup for raw-audio snoring/speech (4096-point, created once)
    private var fftSetup: FFTSetup?
    // Separate FFT setup for envelope breathing rate (256-point)
    private var envelopeFftSetup: FFTSetup?
    private let envelopeFftSize = 256

    func start() throws {
        sonarActive = (sonar != nil) && (sonarForced || UserDefaults.standard.bool(forKey: "sonar_enabled"))

        let session = AVAudioSession.sharedInstance()
        if sonarActive {
            // Ton raus UND Mikro rein; kein BluetoothHFP (würde 19 kHz auf 8/16 kHz-Route killen).
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.defaultToSpeaker, .mixWithOthers])
            try? session.setPreferredSampleRate(48_000)
        } else {
            try session.setCategory(.record, mode: .measurement, options: [.mixWithOthers, .allowBluetoothHFP])
        }
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        audioSampleRate = format.sampleRate
        currentFormat = format

        let log2n = vDSP_Length(log2(Float(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(FFT_RADIX2))
        let log2env = vDSP_Length(log2(Float(envelopeFftSize)))
        envelopeFftSetup = vDSP_create_fftsetup(log2env, FFTRadix(FFT_RADIX2))

        if sonarActive {
            configureNotch(fs: audioSampleRate, f0: sonarCarrier, q: 8)
            configureLowpass(fs: audioSampleRate, f0: 11_000)
            sonar?.resetForTracking()
            // EIN konsistentes Format für Verbindung UND Ton-Buffer — sonst wird der
            // Buffer bei Format-Abweichung (SR vor/nach engine.start()) still verworfen → Pegel 0.
            let toneFormat = AVAudioFormat(standardFormatWithSampleRate: audioSampleRate, channels: 1)
                ?? engine.mainMixerNode.outputFormat(forBus: 0)
            sonarToneFormat = toneFormat
            engine.attach(sonarTonePlayer)
            engine.connect(sonarTonePlayer, to: engine.mainMixerNode, format: toneFormat)
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            guard let self else { return }
            if self.sonarActive {
                self.sonar?.feedExternal(buffer)          // Roh (mit Ton) → Sonar
                let clean = self.notchedCopy(buffer)       // Ton entfernt → restliche Analyse
                self.onBufferReady?(clean, time)
                self.analysisQueue.async { self.processBuffer(clean) }
            } else {
                self.onBufferReady?(buffer, time)
                self.analysisQueue.async { self.processBuffer(buffer) }
            }
        }

        try engine.start()
        if sonarActive, let toneFormat = sonarToneFormat {
            sonarTonePlayer.scheduleBuffer(makeSonarTone(format: toneFormat), at: nil, options: .loops)
            sonarTonePlayer.play()
            // Lautstärke-Floor (bindend, gerätebelegt): Der Sonar-Ton läuft über die
            // Medien-Wiedergabe. Steht die Medienlautstärke auf 0/leise (real beobachtet:
            // ganze Nacht Pegel 0.0000 auf einem Zweitgerät), ist der Ton stumm und das
            // Sonar blind. Nur ANHEBEN auf mindestens 0.6 — nie absenken.
            ensureSonarVolume()
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        if sonarActive {
            sonarTonePlayer.stop()
            sonarActive = false
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let setup = fftSetup { vDSP_destroy_fftsetup(setup); fftSetup = nil }
        if let setup = envelopeFftSetup { vDSP_destroy_fftsetup(setup); envelopeFftSetup = nil }
        try? AVAudioSession.sharedInstance().setActive(false)
        envelopeBuffer.removeAll()
        chunkSamples.removeAll()
        rawSampleBuffer.removeAll()
        currentFormat = nil
        isRunning = false
    }

    // MARK: - Sonar tone + notch helpers

    /// RBJ-Notch-Biquad-Koeffizienten für f0 (Ton) berechnen.
    private func configureNotch(fs: Double, f0: Double, q: Double) {
        let w0 = 2.0 * Double.pi * f0 / fs
        let alpha = sin(w0) / (2.0 * q)
        let cosw = cos(w0)
        let a0 = 1.0 + alpha
        nb0 = Float((1.0) / a0)
        nb1 = Float((-2.0 * cosw) / a0)
        nb2 = Float((1.0) / a0)
        na1 = Float((-2.0 * cosw) / a0)
        na2 = Float((1.0 - alpha) / a0)
        nx1 = 0; nx2 = 0; ny1 = 0; ny2 = 0
    }

    /// RBJ-Lowpass-Biquad (f0, Q=0.707) — kaskadiert hinter dem Notch. Der Notch allein
    /// ist zu schmal: Rest-Ton, Lautsprecher-Verzerrungen (Intermodulation bei lautem
    /// 19-kHz-Ton) und Reflexionen liegen knapp daneben und hoben real den gemessenen
    /// Pegel an (~45 dB die ganze Nacht, alles als „Geräusch", ML fand nichts).
    /// Schlafgeräusche liegen < 8 kHz — alles darüber ist für die Analyse Müll.
    private func configureLowpass(fs: Double, f0: Double) {
        let w0 = 2.0 * Double.pi * f0 / fs
        let alpha = sin(w0) / (2.0 * 0.7071)
        let cosw = cos(w0)
        let a0 = 1.0 + alpha
        lb0 = Float(((1.0 - cosw) / 2.0) / a0)
        lb1 = Float((1.0 - cosw) / a0)
        lb2 = Float(((1.0 - cosw) / 2.0) / a0)
        la1 = Float((-2.0 * cosw) / a0)
        la2 = Float((1.0 - alpha) / a0)
        lx1 = 0; lx2 = 0; ly1 = 0; ly2 = 0
    }

    /// Kopie des Buffers mit entferntem 19-kHz-Ton: Notch + 11-kHz-Lowpass (nur Kanal 0).
    private func notchedCopy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard let inCh = buffer.floatChannelData?[0],
              let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity),
              let outCh = out.floatChannelData?[0] else { return buffer }
        out.frameLength = buffer.frameLength
        let n = Int(buffer.frameLength)
        for i in 0..<n {
            let x = inCh[i]
            let y = nb0*x + nb1*nx1 + nb2*nx2 - na1*ny1 - na2*ny2
            nx2 = nx1; nx1 = x
            ny2 = ny1; ny1 = y
            let z = lb0*y + lb1*lx1 + lb2*lx2 - la1*ly1 - la2*ly2
            lx2 = lx1; lx1 = y
            ly2 = ly1; ly1 = z
            outCh[i] = z
        }
        // weitere Kanäle unverändert kopieren (falls vorhanden)
        let ch = Int(buffer.format.channelCount)
        if ch > 1, let ic = buffer.floatChannelData, let oc = out.floatChannelData {
            for c in 1..<ch { for i in 0..<n { oc[c][i] = ic[c][i] } }
        }
        return out
    }

    /// Hebt die System-Medienlautstärke auf mindestens 0.6 an (MPVolumeView-Slider,
    /// gleiche Technik wie der Wecker). Der ~19-kHz-Ton ist dabei für Menschen
    /// praktisch unhörbar — aber ohne Lautstärke ist das Sonar blind.
    private func ensureSonarVolume() {
        let session = AVAudioSession.sharedInstance()
        guard session.outputVolume < 0.55 else { return }
        DispatchQueue.main.async {
            let volumeView = MPVolumeView(frame: .zero)
            if let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first {
                // Kurze Verzögerung: der Slider braucht einen Runloop-Tick, bis er
                // mit der System-Lautstärke verbunden ist.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    slider.value = 0.6
                    slider.sendActions(for: .valueChanged)
                }
            }
        }
    }

    /// 1-Sekunden-Sonar-Trägerbuffer (klickfrei loopbar).
    private func makeSonarTone(format: AVAudioFormat) -> AVAudioPCMBuffer {
        let fs = format.sampleRate
        let frames = AVAudioFrameCount(fs)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        for c in 0..<Int(format.channelCount) {
            guard let p = buf.floatChannelData?[c] else { continue }
            for i in 0..<Int(frames) {
                p[i] = sonarToneAmp * Float(sin(2.0 * .pi * sonarCarrier * Double(i) / fs))
            }
        }
        return buf
    }

    // MARK: - Buffer processing

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)

        // Copy samples for raw chunk callback (SoundEventService ring buffer)
        let chunkCopy = Array(UnsafeBufferPointer(start: channelData, count: count))
        let currentSnoringScore = snoringIntensity(rawSamples: rawSampleBuffer, sampleRate: audioSampleRate)
        onRawChunk?(chunkCopy, audioSampleRate, currentSnoringScore)

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
        lastInstantRMS = value   // always track the per-125ms RMS for burst detection
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

        let breathingRate = fusedBreathingRate(envelope: demeaned)
        let regularity = computeRegularity(envelope: demeaned)
        let snoring = snoringIntensity(rawSamples: rawSampleBuffer, sampleRate: audioSampleRate)
        let speech = speechLikelihood(rawSamples: rawSampleBuffer, sampleRate: audioSampleRate)

        return AudioFeatures(
            averageAmplitude: mean,
            instantAmplitude: lastInstantRMS,
            amplitudeVariance: variance,
            breathingRateBPM: breathingRate,
            breathingRegularity: regularity,
            snoringIntensity: snoring,
            speechLikelihood: speech,
            timestamp: Date()
        )
    }

    // MARK: - Breathing rate (dual method: autocorrelation + FFT peak, fused)

    /// Fuses autocorrelation and FFT-peak estimates for more robust breathing rate detection.
    /// If both agree (within 2 BPM), average them. If only one is valid, use it.
    private func fusedBreathingRate(envelope: [Float]) -> Float {
        let acf = estimateBreathingRate(envelope: envelope, sampleRate: envelopeSampleRate)
        let fft = estimateBreathingRateFFT(envelope: envelope)

        switch (acf > 0, fft > 0) {
        case (false, false): return 0
        case (true, false):  return acf
        case (false, true):  return fft
        case (true, true):
            // Both valid — agree within 2 BPM → weighted average (autocorrelation slightly favoured)
            if abs(acf - fft) <= 2.0 { return acf * 0.6 + fft * 0.4 }
            // Disagreement — trust autocorrelation (longer window, more robust for slow rhythms)
            return acf
        }
    }

    /// FFT-peak breathing rate: dominant spectral peak in 9–30 BPM range of the 30s envelope.
    private func estimateBreathingRateFFT(envelope: [Float]) -> Float {
        guard let setup = envelopeFftSetup, envelope.count >= envelopeFftSize / 2 else { return 0 }

        let n = envelopeFftSize
        var padded = [Float](repeating: 0, count: n)
        let copyLen = min(envelope.count, n)
        padded.replaceSubrange(0..<copyLen, with: envelope.prefix(copyLen))

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(padded, 1, window, 1, &windowed, 1, vDSP_Length(n))

        var realPart = [Float](repeating: 0, count: n / 2)
        var imagPart = [Float](repeating: 0, count: n / 2)
        realPart.withUnsafeMutableBufferPointer { rp in
            imagPart.withUnsafeMutableBufferPointer { ip in
                var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { cp in
                        vDSP_ctoz(cp, 2, &sc, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &sc, 1, vDSP_Length(log2(Float(n))), FFTDirection(FFT_FORWARD))
            }
        }

        var magnitudes = [Float](repeating: 0, count: n / 2)
        for i in 0..<n / 2 { magnitudes[i] = realPart[i] * realPart[i] + imagPart[i] * imagPart[i] }

        // Breathing range: 9–30 BPM = 0.15–0.5 Hz
        let hzPerBin = envelopeSampleRate / Double(n)
        let minBin = max(1, Int(0.15 / hzPerBin))
        let maxBin = min(n / 2 - 1, Int(0.5 / hzPerBin))
        guard minBin < maxBin else { return 0 }

        var bestBin = minBin
        var bestMag: Float = 0
        for i in minBin...maxBin where magnitudes[i] > bestMag {
            bestMag = magnitudes[i]; bestBin = i
        }

        // Require the peak to stand out above noise floor
        var totalMag: Float = 0
        vDSP_sve(magnitudes, 1, &totalMag, vDSP_Length(n / 2))
        let meanMag = totalMag / Float(n / 2)
        guard bestMag > meanMag * 3.0 else { return 0 }   // peak must be 3× above average

        let hz = Double(bestBin) * hzPerBin
        return Float(hz * 60.0)
    }

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

        realPart.withUnsafeMutableBufferPointer { realPtr in
            imagPart.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { ptr in
                    ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { cPtr in
                        vDSP_ctoz(cPtr, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                    }
                }
                let log2n = vDSP_Length(log2(Float(fftSize)))
                vDSP_fft_zrip(setup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
            }
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

        // Snoring: high band ratio + sufficient amplitude
        let ratio = bandEnergy / totalEnergy
        let rmsAll = sqrt(totalEnergy / Float(fftSize / 2))
        guard rmsAll > 0.002 else { return 0 }   // was 0.005 — catch quieter snoring

        // Snoring band ratio typically > 0.35 during real snoring (was 0.3 threshold)
        return min(max((ratio - 0.25) / 0.4, 0), 1.0)
    }

    // MARK: - Speech detection (300–3500 Hz band with high amplitude variation)

    private func speechLikelihood(rawSamples: [Float], sampleRate: Double) -> Float {
        guard let setup = fftSetup, rawSamples.count >= fftSize else { return 0 }

        let recent = Array(rawSamples.suffix(fftSize))
        var windowed = [Float](repeating: 0, count: fftSize)
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        vDSP_vmul(recent, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        var realPart = [Float](repeating: 0, count: fftSize / 2)
        var imagPart = [Float](repeating: 0, count: fftSize / 2)
        realPart.withUnsafeMutableBufferPointer { realPtr in
            imagPart.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { ptr in
                    ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { cPtr in
                        vDSP_ctoz(cPtr, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(setup, &splitComplex, 1, vDSP_Length(log2(Float(fftSize))), FFTDirection(FFT_FORWARD))
            }
        }

        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        for i in 0..<fftSize/2 { magnitudes[i] = realPart[i]*realPart[i] + imagPart[i]*imagPart[i] }

        let hzPerBin = sampleRate / Double(fftSize)
        let speechLow  = max(1, Int(300.0  / hzPerBin))
        let speechHigh = min(fftSize / 2 - 1, Int(3500.0 / hzPerBin))
        let snoringLow = max(1, Int(80.0   / hzPerBin))
        let snoringHigh = min(fftSize / 2 - 1, Int(500.0  / hzPerBin))

        var speechEnergy: Float = 0
        var snoringEnergy: Float = 0
        var totalEnergy: Float = 0
        vDSP_sve(Array(magnitudes[speechLow...speechHigh]), 1, &speechEnergy, vDSP_Length(speechHigh - speechLow + 1))
        vDSP_sve(Array(magnitudes[snoringLow...snoringHigh]), 1, &snoringEnergy, vDSP_Length(snoringHigh - snoringLow + 1))
        vDSP_sve(magnitudes, 1, &totalEnergy, vDSP_Length(fftSize / 2))

        guard totalEnergy > 1e-10 else { return 0 }

        // Speech: high energy in 300–3500 Hz that is NOT dominated by low snoring band
        let speechRatio = speechEnergy / totalEnergy
        let snoringRatio = snoringEnergy / totalEnergy
        let rms = sqrt(totalEnergy / Float(fftSize / 2))
        guard rms > 0.008 else { return 0 }

        // Speech has high speech-band ratio but snoring does not dominate
        let likelihood = speechRatio * (1.0 - min(snoringRatio, 1.0))
        return min(max((likelihood - 0.25) / 0.4, 0), 1.0)
    }
}

struct AudioFeatures {
    let averageAmplitude: Float     // 30 s rolling mean — for breathing analysis
    let instantAmplitude: Float     // latest 125 ms RMS — for sound-event detection
    let amplitudeVariance: Float
    let breathingRateBPM: Float        // 0 if not detectable
    let breathingRegularity: Float     // 0–1, 1 = perfectly regular
    let snoringIntensity: Float        // 0–1, 0 = kein Schnarchen
    let speechLikelihood: Float        // 0–1, heuristic for voice-like sounds
    let timestamp: Date

    static var neutral: AudioFeatures {
        AudioFeatures(averageAmplitude: 0, instantAmplitude: 0, amplitudeVariance: 0,
                      breathingRateBPM: 0, breathingRegularity: 0,
                      snoringIntensity: 0, speechLikelihood: 0, timestamp: Date())
    }
}
