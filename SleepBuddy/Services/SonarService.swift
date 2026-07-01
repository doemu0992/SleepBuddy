import AVFoundation
import Accelerate
import Observation

/// Ergebnis einer Sonar-Analyse (pro ~30-s-Fenster emittiert).
struct SonarFeatures {
    let breathingRateBPM: Float     // Atemfrequenz aus der Reflexion (0 = kein Signal)
    let breathingRegularity: Float  // 0…1, ACF-Peak-Stärke
    let movementIntensity: Float    // 0 = still, 1 = deutliche Körperbewegung
    let signalPresent: Bool         // true wenn ein plausibles Reflexionssignal vorliegt

    static let neutral = SonarFeatures(breathingRateBPM: 0, breathingRegularity: 0,
                                       movementIntensity: 0, signalPresent: false)
}

/// Aktives Sonar (Sleep-Cycle-Stil): sendet einen (nahezu) unhörbaren ~19 kHz-Ton über den
/// Lautsprecher und analysiert die vom Körper reflektierte, atem-/bewegungsmodulierte Welle
/// im Mikrofon. Liefert Atemfrequenz, Atem-Regularität und Bewegungsintensität — robust auch
/// vom **Nachttisch** und weitgehend unabhängig von Umgebungslärm (das Nutzsignal liegt im
/// Ultraschallband weit über Alltagsgeräuschen).
///
/// **Eigenständige Engine** (Ton-Ausgabe + Mikrofon-Tap in EINEM `AVAudioEngine`) — läuft nur
/// wenn explizit gestartet (Live-Test / später opt-in im Tracking), damit die bestehende
/// Aufnahme-Pipeline unberührt bleibt.
@Observable
final class SonarService {

    var onFeaturesUpdated: ((SonarFeatures) -> Void)?
    /// Kurzer Ausschnitt des Basisband-Atemsignals (für eine Live-Wellenform im Test-UI).
    private(set) var waveform: [Float] = []
    private(set) var isRunning = false
    private(set) var latest: SonarFeatures = .neutral

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let carrier: Double = 19_000        // Trägerfrequenz (Hz), nahe Ultraschall
    private let toneAmplitude: Float = 0.12     // leise (großteils unhörbar), Lautsprecher-schonend

    private var outputSampleRate: Double = 48_000
    private var inputSampleRate: Double = 48_000

    // Demodulations-Zustand (durchlaufender Trägerphasen-Index über Buffergrenzen hinweg)
    private var sampleIndex: Int = 0
    private let processQueue = DispatchQueue(label: "sonar.dsp")

    // Basisband (dezimiert auf ~50 Hz): I/Q + abgeleitete Phase & Magnitude
    private let basebandRate: Double = 50
    private var decim = 960                      // fs / basebandRate (bei 48 kHz)
    private var iBB: [Float] = []
    private var qBB: [Float] = []
    private let bbCapacity = 3000                // ~60 s @ 50 Hz
    private var newSinceEmit = 0
    private let emitEverySamples = 1500          // ~30 s @ 50 Hz

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        // playAndRecord + measurement: Ton raus UND Mikro rein, ohne Voice-Processing/AGC
        // (das Echo/den Ton wollen wir bewusst mitschneiden), Lautsprecher erzwungen.
        try? session.setCategory(.playAndRecord, mode: .measurement,
                                 options: [.defaultToSpeaker, .mixWithOthers, .allowBluetoothHFP])
        try? session.setActive(true, options: .notifyOthersOnDeactivation)

        let input = engine.inputNode
        inputSampleRate = input.inputFormat(forBus: 0).sampleRate
        let outFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        outputSampleRate = outFormat.sampleRate
        decim = max(1, Int((inputSampleRate / basebandRate).rounded()))

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outFormat)

        // Mikrofon-Tap: demoduliert jeden Buffer
        input.installTap(onBus: 0, bufferSize: 4096, format: input.inputFormat(forBus: 0)) { [weak self] buf, _ in
            self?.processQueue.async { self?.process(buffer: buf) }
        }

        reset()
        do {
            try engine.start()
            player.scheduleBuffer(makeToneBuffer(format: outFormat), at: nil, options: .loops)
            player.play()
            isRunning = true
        } catch {
            input.removeTap(onBus: 0)
        }
    }

    func stop() {
        guard isRunning else { return }
        player.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func reset() {
        sampleIndex = 0
        iBB.removeAll(keepingCapacity: true)
        qBB.removeAll(keepingCapacity: true)
        newSinceEmit = 0
        waveform = []
        latest = .neutral
    }

    // MARK: - Tone generation

    /// 1-Sekunden-Trägerbuffer; bei ganzzahliger Zyklenzahl klickfrei loopbar.
    private func makeToneBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer {
        let fs = format.sampleRate
        let frames = AVAudioFrameCount(fs)                 // exakt 1 s
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        let ch = Int(format.channelCount)
        for c in 0..<ch {
            guard let p = buf.floatChannelData?[c] else { continue }
            for i in 0..<Int(frames) {
                p[i] = toneAmplitude * Float(sin(2.0 * .pi * carrier * Double(i) / fs))
            }
        }
        return buf
    }

    // MARK: - Demodulation

    private func process(buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        let fs = inputSampleRate
        let w = 2.0 * .pi * carrier / fs

        // I/Q-Demodulation + Blockmittelung (grober Tiefpass) auf ~50 Hz
        var accI: Float = 0, accQ: Float = 0, cnt = 0
        for k in 0..<n {
            let idx = sampleIndex + k
            let ph = w * Double(idx)
            let x = ch[k]
            accI += x * Float(cos(ph))
            accQ += x * Float(sin(ph))
            cnt += 1
            if cnt >= decim {
                let inv = 1.0 / Float(cnt)
                appendBaseband(i: accI * inv, q: accQ * inv)
                accI = 0; accQ = 0; cnt = 0
            }
        }
        sampleIndex += n

        if newSinceEmit >= emitEverySamples { emitFeatures() }
    }

    private func appendBaseband(i: Float, q: Float) {
        iBB.append(i); qBB.append(q)
        if iBB.count > bbCapacity { iBB.removeFirst(); qBB.removeFirst() }
        newSinceEmit += 1
    }

    private func emitFeatures() {
        newSinceEmit = 0
        let count = iBB.count
        guard count >= Int(basebandRate * 8) else { return }   // ≥ 8 s Daten

        // Phase (Mikro-Bewegung der Brust) + Magnitude (grobe Reflexionsstärke)
        var phase = [Float](repeating: 0, count: count)
        var mag = [Float](repeating: 0, count: count)
        for k in 0..<count {
            phase[k] = atan2(qBB[k], iBB[k])
            mag[k] = sqrt(iBB[k]*iBB[k] + qBB[k]*qBB[k])
        }
        unwrap(&phase)
        // Detrend Phase (linearer Drift raus) → reines Atem-/Bewegungssignal
        detrend(&phase)

        let (bpm, reg) = breathing(from: phase, rate: basebandRate)
        let movement = movementLevel(phase: phase, rate: basebandRate)
        let present = mag.reduce(0, +) / Float(count) > 1e-5

        let feat = SonarFeatures(
            breathingRateBPM: present ? bpm : 0,
            breathingRegularity: present ? reg : 0,
            movementIntensity: movement,
            signalPresent: present
        )
        // Letzte ~6 s als Wellenform fürs UI
        let tail = Array(phase.suffix(Int(basebandRate * 6)))
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.latest = feat
            self.waveform = tail
            self.onFeaturesUpdated?(feat)
        }
    }

    // MARK: - DSP-Helfer

    private func unwrap(_ p: inout [Float]) {
        guard p.count > 1 else { return }
        var offset: Float = 0
        for k in 1..<p.count {
            let d = p[k] + offset - p[k-1]
            if d > .pi { offset -= 2 * .pi }
            else if d < -.pi { offset += 2 * .pi }
            p[k] += offset
        }
    }

    private func detrend(_ x: inout [Float]) {
        let n = x.count
        guard n > 2 else { return }
        // lineare Regression y = a + b·t abziehen
        let tf = (0..<n).map { Float($0) }
        var meanT: Float = 0, meanX: Float = 0
        vDSP_meanv(tf, 1, &meanT, vDSP_Length(n))
        vDSP_meanv(x, 1, &meanX, vDSP_Length(n))
        var num: Float = 0, den: Float = 0
        for i in 0..<n {
            num += (tf[i]-meanT) * (x[i]-meanX)
            den += (tf[i]-meanT) * (tf[i]-meanT)
        }
        let b = den > 0 ? num/den : 0
        let a = meanX - b*meanT
        for i in 0..<n { x[i] -= (a + b*tf[i]) }
    }

    /// Atemfrequenz via Autokorrelation im 6–30 BPM-Band + Peak-Stärke als Regularität.
    private func breathing(from signal: [Float], rate: Double) -> (bpm: Float, reg: Float) {
        let n = signal.count
        guard n > Int(rate * 4) else { return (0, 0) }
        var energy: Float = 0
        vDSP_measqv(signal, 1, &energy, vDSP_Length(n))     // mittlere Leistung
        guard energy > 1e-9 else { return (0, 0) }

        let minLag = Int(rate * 60.0 / 30.0)   // 30 BPM
        let maxLag = min(Int(rate * 60.0 / 6.0), n - 1)   // 6 BPM
        guard maxLag > minLag else { return (0, 0) }

        var bestLag = -1
        var bestVal: Float = 0
        signal.withUnsafeBufferPointer { buf in
            let base = buf.baseAddress!
            for lag in minLag...maxLag {
                var dot: Float = 0
                vDSP_dotpr(base, 1, base + lag, 1, &dot, vDSP_Length(n - lag))
                let norm = dot / (energy * Float(n - lag))
                if norm > bestVal { bestVal = norm; bestLag = lag }
            }
        }
        guard bestLag > 0 else { return (0, 0) }
        let bpm = Float(rate * 60.0 / Double(bestLag))
        let reg = min(max(bestVal, 0), 1)
        return (bpm, reg)
    }

    /// Bewegungsintensität: kurzfristige Energie schneller Phasenänderungen (Körperbewegung
    /// erzeugt große, schnelle Ausschläge; ruhiges Atmen nur kleine, langsame).
    private func movementLevel(phase: [Float], rate: Double) -> Float {
        let n = phase.count
        let win = min(n, Int(rate * 5))    // letzte ~5 s
        guard win > 2 else { return 0 }
        let seg = Array(phase.suffix(win))
        var diffs = [Float](repeating: 0, count: win - 1)
        for k in 1..<win { diffs[k-1] = seg[k] - seg[k-1] }
        var rms: Float = 0
        vDSP_rmsqv(diffs, 1, &rms, vDSP_Length(win - 1))
        return min(rms * 6.0, 1.0)
    }
}
