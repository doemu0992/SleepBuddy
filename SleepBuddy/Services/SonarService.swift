import Foundation
import AVFoundation
import Accelerate
import MediaPlayer
import Observation

// MARK: - SonarService & SonarFeatures (bewusst in dieser in-Target-Datei — neue Swift-Dateien
// müssten sonst manuell zum Xcode-Build-Target hinzugefügt werden)

/// Ergebnis einer Sonar-Analyse (pro ~30-s-Fenster emittiert).
struct SonarFeatures {
    let breathingRateBPM: Float     // Atemfrequenz aus der Reflexion (0 = kein Signal)
    let breathingRegularity: Float  // 0…1, ACF-Peak-Stärke
    let movementIntensity: Float    // 0 = still, 1 = deutliche Körperbewegung
    let signalPresent: Bool         // true wenn ein plausibles Reflexionssignal vorliegt
    var heartRateBPM: Float = 0     // EXPERIMENTELL: Puls aus der Reflexion (0 = kein Lock)

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
    private let toneAmplitude: Float = 0.45     // kräftiger, damit die Reflexion klar messbar ist
    /// Diagnose: mittlere Basisband-Magnitude des letzten Fensters (0 = Ton kommt nicht am Mikro an).
    private(set) var signalLevel: Float = 0
    /// Protokoll der emittierten Fenster (für Copy/Paste-Diagnose).
    private(set) var log: [String] = []
    private var logStart = Date()

    private var outputSampleRate: Double = 48_000
    private var inputSampleRate: Double = 48_000

    // Demodulations-Zustand: laufende Trägerphase (mod 2π) über Buffergrenzen hinweg —
    // bounded, daher kein Präzisionsverlust über Stunden, aber phasenkontinuierlich.
    private var carrierPhase: Double = 0
    // Demod-Blockmittelungs-Akku — MUSS über Buffergrenzen persistieren (siehe process()).
    private var demodAccI: Float = 0
    private var demodAccQ: Float = 0
    private var demodCnt = 0
    private let processQueue = DispatchQueue(label: "sonar.dsp")

    // Basisband (dezimiert auf ~50 Hz): I/Q + abgeleitete Phase & Magnitude
    private let basebandRate: Double = 50
    private var decim = 960                      // fs / basebandRate (bei 48 kHz)
    private var iBB: [Float] = []
    private var qBB: [Float] = []
    private let bbCapacity = 3000                // ~60 s @ 50 Hz
    private var newSinceEmit = 0
    private let emitEverySamples = 250           // ~5 s @ 50 Hz (schnelles Test-Feedback)

    // Stabilitäts-Historie des Sonar-Pulses (Gate für die Fusion).
    private var recentSonarHR: [Float] = []
    /// Zähler für das Atem-Artefakt-Band (20.3–21.4/min) — Veto ab 5 Treffern.
    private var recentArtifactBand = 0

    // Nacht-Statistik: Anteil der Fenster mit Atem-Lock (Geräteprofil-Grundlage).
    private(set) var emitCount = 0
    private(set) var lockCount = 0
    var nightLockRate: Double { emitCount > 0 ? Double(lockCount) / Double(emitCount) : 0 }

    // Halten des letzten guten Atemwerts über kurze Lücken (bei Ruhe).
    private var lastGoodBpm: Float = 0
    private var lastGoodReg: Float = 0
    private var lastGoodAt = Date.distantPast

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        // playAndRecord + measurement: Ton raus UND Mikro rein, ohne Voice-Processing/AGC
        // (das Echo/den Ton wollen wir bewusst mitschneiden), Lautsprecher erzwungen.
        // KEIN Bluetooth-HFP: das würde die Route auf 8/16 kHz zwingen → 19 kHz wäre weg.
        // Hohe Samplerate erzwingen, damit 19 kHz (< Nyquist) sicher erhalten bleibt.
        try? session.setCategory(.playAndRecord, mode: .measurement,
                                 options: [.defaultToSpeaker, .mixWithOthers])
        try? session.setPreferredSampleRate(48_000)
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

    // MARK: - Externer Betrieb (Tracking): keine eigene Engine/Ton — der AudioAnalysisService
    // spielt den Ton und liefert die Roh-Buffer. Nur Demodulation + Feature-Emit.

    /// Für das Tracking: Zustand zurücksetzen, ohne eine eigene Engine zu starten.
    func resetForTracking() { reset() }

    // MARK: - Nacht-Log (Datei, für Analyse über die ganze Nacht)

    private var nightLogActive = false
    static var nightLogURL: URL {
        (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("SonarNightLog.csv")
    }

    func beginNightLog() {
        let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy HH:mm"
        let header = "# SLEEPBUDDY SONAR-NACHTLOG — Start \(f.string(from: Date()))\n# zeit,atem_bpm,reg_pct,bew_pct,pegel,signal,puls_bpm\n"
        try? header.write(to: Self.nightLogURL, atomically: true, encoding: .utf8)
        nightLogActive = true
    }

    func endNightLog() { nightLogActive = false }

    private func appendNightLine(bpm: Float, reg: Float, mov: Float, pegel: Float, present: Bool, hr: Float = 0) {
        guard nightLogActive else { return }
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        // puls_bpm als LETZTE Spalte angehängt — bestehende Spalten-Indizes (Summary-Parser)
        // bleiben unverändert gültig.
        let line = "\(f.string(from: Date())),\(Int(bpm)),\(Int(reg*100)),\(Int(mov*100)),\(String(format: "%.4f", pegel)),\(present ? 1 : 0),\(Int(hr))\n"
        if let h = try? FileHandle(forWritingTo: Self.nightLogURL) {
            h.seekToEndOfFile()
            if let d = line.data(using: .utf8) { h.write(d) }
            try? h.close()
        }
    }

    /// Roh-Mikrofon-Buffer von außen einspeisen (enthält den vom AudioAnalysisService
    /// gespielten 19-kHz-Ton + Reflexion).
    func feedExternal(_ buffer: AVAudioPCMBuffer) {
        processQueue.async { [weak self] in self?.process(buffer: buffer) }
    }

    private func reset() {
        recentArtifactBand = 0
        carrierPhase = 0
        demodAccI = 0; demodAccQ = 0; demodCnt = 0
        emitCount = 0
        lockCount = 0
        recentSonarHR.removeAll()
        lastGoodBpm = 0; lastGoodReg = 0; lastGoodAt = .distantPast
        log.removeAll()
        logStart = Date()
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
        // Authoritative Samplerate aus dem Buffer (nicht die evtl. veraltete Annahme).
        let fs = buffer.format.sampleRate
        let dec = max(1, Int((fs / basebandRate).rounded()))
        let w = 2.0 * .pi * carrier / fs

        // I/Q-Demodulation + Blockmittelung (grober Tiefpass) auf ~50 Hz.
        // KRITISCH: Der Mittelungs-Akku läuft ÜBER Buffergrenzen weiter (Instanz-State).
        // Früher war er buffer-lokal und der unvollständige Restblock (1024 % 960 = 64
        // Samples) wurde bei JEDEM Buffer verworfen — periodisch alle 15 Buffer (0,32 s)
        // → künstliche Basisband-Schwingung bei 3,125 Hz mit Subharmonischer bei
        // 1,5625 Hz ≙ 93,75 BPM. DARAUF lockte der Puls-Detektor (nachtbelegt auf zwei
        // Geräten: 89 % der Locks bei konstant 93–96), unabhängig vom Filtertyp.
        var phase = carrierPhase
        let twoPi = 2.0 * Double.pi
        for k in 0..<n {
            let x = ch[k]
            demodAccI += x * Float(cos(phase))
            demodAccQ += x * Float(sin(phase))
            phase += w
            if phase >= twoPi { phase -= twoPi }
            demodCnt += 1
            if demodCnt >= dec {
                let inv = 1.0 / Float(demodCnt)
                appendBaseband(i: demodAccI * inv, q: demodAccQ * inv)
                demodAccI = 0; demodAccQ = 0; demodCnt = 0
            }
        }
        carrierPhase = phase

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

        // I/Q glätten (Ein-Pol-Tiefpass ~3 Hz @ 50 Hz) → weniger Demod-Rauschen.
        let iS = lowpass(iBB, alpha: 0.30)
        let qS = lowpass(qBB, alpha: 0.30)

        // CLUTTER-REMOVAL (bindend): Der statische Reflexionsanteil (Wände, Decke, Bettgestell)
        // dominiert I/Q und „friert" die Rohphase ein → das kleine Atem-Signal geht unter.
        // Deshalb den DC (Mittelwert = statischer Anteil) abziehen; übrig bleibt die
        // BEWEGTE Komponente (Atmung/Körper).
        var mi: Float = 0, mq: Float = 0
        vDSP_meanv(iS, 1, &mi, vDSP_Length(count))
        vDSP_meanv(qS, 1, &mq, vDSP_Length(count))
        var ir = [Float](repeating: 0, count: count)
        var qr = [Float](repeating: 0, count: count)
        for k in 0..<count { ir[k] = iS[k] - mi; qr[k] = qS[k] - mq }

        // Hauptbewegungsachse (2D-PCA) → 1D-Signal, das im Atemtakt schwingt.
        var sii: Float = 0, sqq: Float = 0, siq: Float = 0
        vDSP_measqv(ir, 1, &sii, vDSP_Length(count))
        vDSP_measqv(qr, 1, &sqq, vDSP_Length(count))
        vDSP_dotpr(ir, 1, qr, 1, &siq, vDSP_Length(count)); siq /= Float(count)
        let theta = 0.5 * atan2(2*siq, sii - sqq)
        let ct = cos(theta), st = sin(theta)
        var motionSig = [Float](repeating: 0, count: count)
        for k in 0..<count { motionSig[k] = ir[k]*ct + qr[k]*st }
        // Kopie VOR Detrend/Atem-Glättung sichern — Quelle für das Herz-Band (0,7–1,8 Hz).
        let heartSrc = motionSig

        // Signalpräsenz = Stärke des STATISCHEN Reflexionsanteils (Ton reflektiert überhaupt).
        let meanMag = sqrt(mi*mi + mq*mq)
        signalLevel = meanMag
        let present = meanMag > 1e-4

        detrend(&motionSig)
        motionSig = lowpass(motionSig, alpha: 0.5)   // Atemband glätten
        // Atmung aus der clutter-bereinigten Bewegungskomponente (das war der Fix).
        var (bpm, reg) = breathing(from: motionSig, rate: basebandRate)

        // Bewegung aus der Rohphase (guter absoluter Maßstab: still = klein, Wälzen = groß).
        var phase = [Float](repeating: 0, count: count)
        for k in 0..<count { phase[k] = atan2(qS[k], iS[k]) }
        unwrap(&phase)
        detrend(&phase)
        let movement = movementLevel(phase: phase, rate: basebandRate)

        // EXPERIMENTELL: Puls aus der Sonar-Reflexion. Nur bei ruhigem Liegen versucht
        // (Bewegung zerstört das winzige Herz-Signal). Die CSV loggt den ROHWERT
        // (Diagnose); in die Fusion (SonarFeatures.heartRateBPM) geht nur ein
        // STABILER Wert: mindestens 2 der letzten 3 Messungen innerhalb ±8 BPM —
        // einzelne Flacker-Locks (94 → 42 → 0) erreichen die Puls-Reihe so nie.
        let sonarHR: Float = (present && movement < 0.3) ? heartRate(from: heartSrc, rate: basebandRate) : 0
        var gatedHR: Float = 0
        if sonarHR > 0 {
            let near = recentSonarHR.suffix(3).filter { abs($0 - sonarHR) <= 8 }
            if near.count >= 2 { gatedHR = sonarHR }
        }
        recentSonarHR.append(sonarHR)
        if recentSonarHR.count > 6 { recentSonarHR.removeFirst() }

        // ARTEFAKT-VETO (bindend, 2 Geräte × 2 Nächte belegt): Ohne starkes Körper-
        // Signal (Nachttisch) lockt die Atem-ACF auf eine INTERNE Störperiode von
        // ~2.86–2.88 s → konstant 20.8–21.1 „Atemzüge"/min die GANZE Nacht, auf
        // beiden Geräten identisch (real: 15–16/min laut Watch). Ein konstanter
        // Wert in genau diesem schmalen Band über viele Fenster ist physiologisch
        // ausgeschlossen — echte Atmung variiert. Deshalb: Lockt die Rate wiederholt
        // (≥ 5 der letzten 6 Fenster) ins Band 20.3–21.4, gilt die Messung als
        // Artefakt → kein Atem-Lock (Accelerometer/Audio übernehmen).
        if bpm >= 20.3 && bpm <= 21.4 {
            recentArtifactBand += 1
        } else if bpm > 0 {
            recentArtifactBand = max(0, recentArtifactBand - 2)
        }
        if bpm >= 20.3 && bpm <= 21.4 && recentArtifactBand >= 5 {
            bpm = 0; reg = 0
        }

        // Kontinuität: letzten guten Atemwert über kurze Lücken halten, solange ruhig
        // (kein starkes Wälzen) und der letzte Lock < 25 s her ist. Regularität wird dabei
        // abgewertet (gehaltener Wert = geringere Konfidenz).
        let nowT = Date()
        if bpm > 0 {
            lastGoodBpm = bpm; lastGoodReg = reg; lastGoodAt = nowT
        } else if movement < 0.4, lastGoodBpm > 0, nowT.timeIntervalSince(lastGoodAt) < 25 {
            bpm = lastGoodBpm
            reg = lastGoodReg * 0.6
        }

        emitCount += 1
        if present && bpm > 0 { lockCount += 1 }
        let feat = SonarFeatures(
            breathingRateBPM: present ? bpm : 0,
            breathingRegularity: present ? reg : 0,
            movementIntensity: movement,
            signalPresent: present,
            heartRateBPM: gatedHR
        )
        // Letzte ~6 s der Atem-Bewegungskomponente als Wellenform fürs UI
        let tail = Array(motionSig.suffix(Int(basebandRate * 6)))
        let elapsed = Date().timeIntervalSince(logStart)
        let line = String(format: "%5.0fs  Atem %2.0f/min  Reg %3.0f%%  Bew %3.0f%%  Puls %3.0f  Pegel %.5f  %@",
                          elapsed, bpm, reg * 100, movement * 100, sonarHR, meanMag,
                          present ? "OK" : "-")
        appendNightLine(bpm: bpm, reg: reg, mov: movement, pegel: meanMag, present: present, hr: sonarHR)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.latest = feat
            self.waveform = tail
            self.log.append(line)
            if self.log.count > 400 { self.log.removeFirst() }
            self.onFeaturesUpdated?(feat)
        }
    }

    /// Vollständiger, kopierbarer Diagnose-Text (Geräte-Infos + Verlauf).
    func logText() -> String {
        var s = "SLEEPBUDDY SONAR-DIAGNOSE\n"
        s += String(format: "Träger %.0f Hz · Ton-Amp %.2f · Input %.0f Hz · Output %.0f Hz · Dezim %d\n",
                    carrier, toneAmplitude, inputSampleRate, outputSampleRate, decim)
        s += "Spalten: Zeit · Atemfrequenz · Regelmäßigkeit · Bewegung · Puls (experimentell) · Reflexions-Pegel · Signal\n"
        s += "— — —\n"
        s += log.joined(separator: "\n")
        return s
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

    /// Atemfrequenz via Autokorrelation im **8–22 BPM-Band** (Ruhe-/Schlafatmung) + Peak-Stärke
    /// als Regularität. Rastet der Peak am Bandrand oder ist er zu schwach ausgeprägt, wird
    /// (0, 0) zurückgegeben statt eines unplausiblen Werts (kein „Latching" auf 22/8).
    private func breathing(from signal: [Float], rate: Double) -> (bpm: Float, reg: Float) {
        let n = signal.count
        guard n > Int(rate * 6) else { return (0, 0) }
        var energy: Float = 0
        vDSP_measqv(signal, 1, &energy, vDSP_Length(n))     // mittlere Leistung
        guard energy > 1e-12 else { return (0, 0) }

        let minLag = Int(rate * 60.0 / 22.0)   // 22 BPM
        let maxLag = min(Int(rate * 60.0 / 8.0), n - 1)   // 8 BPM
        guard maxLag > minLag + 2 else { return (0, 0) }

        var acf = [Float](repeating: 0, count: maxLag + 1)
        signal.withUnsafeBufferPointer { buf in
            let base = buf.baseAddress!
            for lag in minLag...maxLag {
                var dot: Float = 0
                vDSP_dotpr(base, 1, base + lag, 1, &dot, vDSP_Length(n - lag))
                acf[lag] = dot / (energy * Float(n - lag))
            }
        }
        // Bestes lokales Maximum im Band (kein Rand-Latch).
        var bestLag = -1
        var bestVal: Float = -.greatestFiniteMagnitude
        var mean: Float = 0
        for lag in (minLag+1)...(maxLag-1) {
            mean += acf[lag]
            if acf[lag] > acf[lag-1] && acf[lag] >= acf[lag+1] && acf[lag] > bestVal {
                bestVal = acf[lag]; bestLag = lag
            }
        }
        mean /= Float(maxLag - minLag - 1)
        // Prominenz-Gate: der Peak muss über dem ACF-Mittel liegen und positiv sein.
        // Moderat (nicht zu streng) — echte Atmung lockt so durchgängiger, ohne dass
        // Rauschen an den Bandrändern durchrutscht (Rand-Latch ist separat ausgeschlossen).
        guard bestLag > 0, bestVal > 0.08, bestVal > mean + 0.05 else { return (0, 0) }
        let bpm = Float(rate * 60.0 / Double(bestLag))
        let reg = min(max(bestVal, 0), 1)
        return (bpm, reg)
    }

    /// EXPERIMENTELL: Puls (40–110 BPM) aus der clutter-bereinigten Bewegungskomponente.
    /// Der Herzschlag bewegt die Brustwand nur ~0,2–0,5 mm — eine Größenordnung schwächer
    /// als die Atmung, daher strengere Gates (nur bei Ruhe, höhere Prominenz-Schwelle).
    /// Hochpass (1,2-s-MA) entfernt das Atemband; Autokorrelation wie bei der Atmung.
    private func heartRate(from signal: [Float], rate: Double) -> Float {
        let n = signal.count
        let win = min(n, Int(rate * 20))                 // letzte ~20 s
        guard win > Int(rate * 10) else { return 0 }
        let src = Array(signal.suffix(win))
        // Bandpass 0,5–2,5 Hz aus zwei EIN-POL-Filtern (kein Moving Average!):
        // Der frühere MA-Hochpass (1,2-s-Fenster) erzeugte selbst ein ACF-Artefakt
        // bei der HALBEN Fensterlänge (~30 Samples ≙ ~96 BPM) — real beobachtet:
        // 2034/2165 Nacht-Locks klebten bei 93–100 BPM, stundenlang konstant ~96,
        // während der echte Puls (BCG) bei 55–70 lag. Ein-Pol-IIR-Filter haben
        // keine solche Lag-Signatur.
        var lpSlow = [Float](repeating: 0, count: win)   // ~0.5 Hz (Atmung/Drift)
        var acc: Float = src.first ?? 0
        let aSlow: Float = 0.059                          // dt/(RC+dt), fc≈0.5 Hz @ 50 Hz
        for i in 0..<win { acc += aSlow * (src[i] - acc); lpSlow[i] = acc }
        var seg = [Float](repeating: 0, count: win)
        var smooth: Float = 0
        let aFast: Float = 0.24                           // fc≈2.5 Hz @ 50 Hz
        for i in 0..<win {
            let hp = src[i] - lpSlow[i]                   // Atemband raus
            smooth += aFast * (hp - smooth)               // Rauschen > 2.5 Hz raus
            seg[i] = smooth
        }
        var energy: Float = 0
        vDSP_measqv(seg, 1, &energy, vDSP_Length(win))
        guard energy > 1e-14 else { return 0 }
        let minLag = Int(rate * 60.0 / 110.0)            // 110 BPM
        let maxLag = min(Int(rate * 60.0 / 40.0), win - 2) // 40 BPM
        guard maxLag > minLag + 2 else { return 0 }
        var acf = [Float](repeating: 0, count: maxLag + 1)
        seg.withUnsafeBufferPointer { buf in
            let base = buf.baseAddress!
            for lag in minLag...maxLag {
                var dot: Float = 0
                vDSP_dotpr(base, 1, base + lag, 1, &dot, vDSP_Length(win - lag))
                acf[lag] = dot / (energy * Float(win - lag))
            }
        }
        var bestLag = -1
        var bestVal: Float = -.greatestFiniteMagnitude
        var mean: Float = 0
        for lag in (minLag+1)...(maxLag-1) {
            mean += acf[lag]
            if acf[lag] > acf[lag-1] && acf[lag] >= acf[lag+1] && acf[lag] > bestVal {
                bestVal = acf[lag]; bestLag = lag
            }
        }
        mean /= Float(maxLag - minLag - 1)
        // Strenger als Atmung (0.15/0.08): das Herz-Signal ist winzig — lieber 0 als Müll.
        guard bestLag > 0, bestVal > 0.15, bestVal > mean + 0.08 else { return 0 }
        return Float(rate * 60.0 / Double(bestLag))
    }

    /// Bewegungsintensität: kurzfristige Energie schneller Phasenänderungen (Körperbewegung
    /// erzeugt große, schnelle Ausschläge; ruhiges Atmen nur kleine, langsame). Gain moderat,
    /// damit ruhiges Liegen nicht sättigt.
    private func movementLevel(phase: [Float], rate: Double) -> Float {
        let n = phase.count
        let win = min(n, Int(rate * 5))    // letzte ~5 s
        guard win > 2 else { return 0 }
        let seg = Array(phase.suffix(win))
        var diffs = [Float](repeating: 0, count: win - 1)
        for k in 1..<win { diffs[k-1] = seg[k] - seg[k-1] }
        var rms: Float = 0
        vDSP_rmsqv(diffs, 1, &rms, vDSP_Length(win - 1))
        // kleiner Rausch-Sockel abgezogen, dann skaliert
        return min(max(rms - 0.02, 0) * 3.0, 1.0)
    }

    /// Einfacher Ein-Pol-Tiefpass (Glättung) über ein Array.
    private func lowpass(_ x: [Float], alpha: Float) -> [Float] {
        guard !x.isEmpty else { return x }
        var out = x
        for k in 1..<x.count { out[k] = out[k-1] + alpha * (x[k] - out[k-1]) }
        return out
    }
}

