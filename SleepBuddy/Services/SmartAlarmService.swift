import AVFoundation
import AudioToolbox
import UserNotifications
import Observation
import MediaPlayer
import SwiftUI

// MARK: - Alarm-Ton

enum AlarmTon: String, CaseIterable, Codable {
    case sanft     = "Sanft"
    case natur     = "Natur"
    case klassisch = "Klassisch"
    case signal    = "Signal"
    case digital   = "Digital"

    var systemSoundID: SystemSoundID {
        switch self {
        case .sanft:     return 1013
        case .natur:     return 1020
        case .klassisch: return 1016
        case .signal:    return 1057
        case .digital:   return 1022
        }
    }

    var symbol: String {
        switch self {
        case .sanft:     return "sun.max.fill"
        case .natur:     return "leaf.fill"
        case .klassisch: return "music.note"
        case .signal:    return "antenna.radiowaves.left.and.right"
        case .digital:   return "waveform"
        }
    }

    var notificationSound: UNNotificationSound {
        // .defaultCritical requires Apple's Critical Alerts entitlement, which the app does
        // not hold — using it makes the notification fall back to SILENT. The plain default
        // sound is guaranteed to play and respects the ringer/volume.
        .default
    }
}

@Observable
final class SmartAlarmService {

    private enum Keys {
        static let isEnabled      = "smartAlarm.isEnabled"
        static let earliestHour   = "smartAlarm.earliestHour"
        static let earliestMinute = "smartAlarm.earliestMinute"
        static let latestHour     = "smartAlarm.latestHour"
        static let latestMinute   = "smartAlarm.latestMinute"
        static let alarmTon       = "smartAlarm.alarmTon"
        static let lautstaerke    = "smartAlarm.lautstaerke"
    }

    var isEnabled: Bool = UserDefaults.standard.bool(forKey: Keys.isEnabled) {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.isEnabled) }
    }

    var earliestWakeTime: Date = SmartAlarmService.loadTime(hourKey: Keys.earliestHour, minuteKey: Keys.earliestMinute, defaultHour: 6, defaultMinute: 30) {
        didSet { SmartAlarmService.saveTime(earliestWakeTime, hourKey: Keys.earliestHour, minuteKey: Keys.earliestMinute) }
    }

    var latestWakeTime: Date = SmartAlarmService.loadTime(hourKey: Keys.latestHour, minuteKey: Keys.latestMinute, defaultHour: 7, defaultMinute: 0) {
        didSet { SmartAlarmService.saveTime(latestWakeTime, hourKey: Keys.latestHour, minuteKey: Keys.latestMinute) }
    }

    var alarmTon: AlarmTon = AlarmTon(rawValue: UserDefaults.standard.string(forKey: Keys.alarmTon) ?? "") ?? .sanft {
        didSet { UserDefaults.standard.set(alarmTon.rawValue, forKey: Keys.alarmTon) }
    }

    var lautstaerke: Float = {
        let stored = UserDefaults.standard.float(forKey: Keys.lautstaerke)
        return stored > 0 ? stored : 0.8
    }() {
        didSet {
            UserDefaults.standard.set(lautstaerke, forKey: Keys.lautstaerke)
            toneNode?.volume = lautstaerke
        }
    }

    private(set) var alarmFired = false
    private(set) var alarmFiredDate: Date?
    // Beim Arm auf das NÄCHSTE Vorkommen (ab Tracking-Start) verankerte Weck-Zeitpunkte —
    // robuster als jede Tageszeit-Heuristik: die Weckzeit liegt immer in der Zukunft.
    private var armedEarliest: Date?
    private var armedLatest: Date?
    private(set) var snoozeCount = 0
    private var snoozeTask: Task<Void, Never>?

    /// Standard-Snooze in Minuten (5 min)
    let snoozeDuration: TimeInterval = 5 * 60
    private(set) var hasNotificationPermission = false

    private let notificationID = "com.sleepbuddy.smartalarm"

    // Tone generation via AVAudioEngine
    private var toneEngine: AVAudioEngine?
    private var toneNode: AVAudioPlayerNode?
    private var toneReverb: AVAudioUnitReverb?
    private var toneLoopTask: Task<Void, Never>?
    // Sanftes Crescendo: der Wecker startet leise und wird über die ersten Pulse lauter —
    // ein beruhigendes, allmähliches Aufwecken statt eines abrupten lauten Tons.
    private var pulseIndex = 0

    // Short preview playback (vorschauSpielen)
    private var previewEngine: AVAudioEngine?
    private var previewNode: AVAudioPlayerNode?

    // MARK: - Permission

    func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge, .criticalAlert])) ?? false
        await MainActor.run { hasNotificationPermission = granted }
    }

    // MARK: - Reload

    // Liest alle Werte frisch aus UserDefaults. Nötig, weil die Einstellungen (ProfilView)
    // eine EIGENE SmartAlarmService-Instanz nutzen und nur über UserDefaults persistieren —
    // ohne Reload zeigt der Tracking-Screen veraltete Weckzeiten.
    func reloadFromDefaults() {
        isEnabled = UserDefaults.standard.bool(forKey: Keys.isEnabled)
        earliestWakeTime = SmartAlarmService.loadTime(hourKey: Keys.earliestHour, minuteKey: Keys.earliestMinute, defaultHour: 6, defaultMinute: 30)
        latestWakeTime = SmartAlarmService.loadTime(hourKey: Keys.latestHour, minuteKey: Keys.latestMinute, defaultHour: 7, defaultMinute: 0)
        alarmTon = AlarmTon(rawValue: UserDefaults.standard.string(forKey: Keys.alarmTon) ?? "") ?? .sanft
        let vol = UserDefaults.standard.float(forKey: Keys.lautstaerke)
        lautstaerke = vol > 0 ? vol : 0.8
    }

    // MARK: - Arm / Disarm

    func arm() {
        reloadFromDefaults()
        guard isEnabled else { return }
        alarmFired = false
        alarmFiredDate = nil
        // Weckfenster auf das NÄCHSTE Vorkommen ab jetzt ankern (immer in der Zukunft).
        let now = Date()
        var e = nextOccurrence(of: earliestWakeTime, after: now)
        var l = nextOccurrence(of: latestWakeTime, after: now)
        // Spätestens muss ≥ Frühestens sein (falls latest-Tageszeit < earliest → nächster Tag).
        if l < e { l = Calendar.current.date(byAdding: .day, value: 1, to: l) ?? l }
        armedEarliest = e
        armedLatest = l
        // Make sure notification permission is granted so the failsafe burst can fire even
        // if the app gets suspended; harmless if already authorised.
        Task { await requestPermission() }
        scheduleFailsafeNotification()
    }

    func disarm() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: failsafeIDs)
        armedEarliest = nil
        armedLatest = nil
        snoozeTask?.cancel()
        snoozeTask = nil
        stopAlarm()
    }

    /// Nächstes Vorkommen der Tageszeit von `time` am/nach `ref`.
    private func nextOccurrence(of time: Date, after ref: Date) -> Date {
        let cal = Calendar.current
        let h = cal.component(.hour, from: time)
        let m = cal.component(.minute, from: time)
        var t = cal.date(bySettingHour: h, minute: m, second: 0, of: ref) ?? ref
        if t < ref { t = cal.date(byAdding: .day, value: 1, to: t) ?? t }
        return t
    }

    // MARK: - Snooze

    /// Stops the alarm for `snoozeDuration` then re-triggers.
    func snooze() {
        guard alarmFired, snoozeCount < 3 else { return }
        snoozeCount += 1
        stopAlarm()
        alarmFired = false
        snoozeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(snoozeDuration))
            guard !Task.isCancelled else { return }
            self.triggerAlarm(at: Date())
        }
    }

    // MARK: - Phase monitoring

    @discardableResult
    func checkPhase(_ phase: SleepPhaseType) -> Bool {
        guard isEnabled, !alarmFired else { return false }
        let now = Date()

        // Hard deadline: once the latest wake time is reached, the alarm MUST ring,
        // regardless of the detected phase. This is the safety net that guarantees the
        // user is woken — even if the cycle model never reports light/awake in the window
        // (e.g. a night that goes straight from REM to wake with no light phase).
        if isPastLatest(now) {
            triggerAlarm(at: now)
            return true
        }

        // Smart wake: inside the window, fire at the first light/awake moment.
        guard isInsideWindow(now) else { return false }
        guard phase == .light || phase == .awake else { return false }

        triggerAlarm(at: now)
        return true
    }

    // MARK: - Trigger

    private func triggerAlarm(at date: Date) {
        alarmFired = true
        alarmFiredDate = date
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: failsafeIDs)
        playAlarmTone()
    }

    // Setzt die System-Medienlautstärke auf Maximum (MPVolumeView-Slider). So klingelt der
    // Wecker laut, egal wie der Nutzer das Telefon eingestellt hat. Stummschalter (Ringer)
    // betrifft die Medien-Wiedergabe via AVAudioEngine nicht.
    private func forceSystemVolumeMax() {
        DispatchQueue.main.async {
            let volumeView = MPVolumeView(frame: .zero)
            if let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first {
                slider.value = 1.0
                slider.sendActions(for: .valueChanged)
            }
        }
    }

    private func playAlarmTone() {
        let session = AVAudioSession.sharedInstance()
        // duckOthers: alarm gets full priority over all other audio (including recording output).
        // The microphone INPUT is unaffected — recording continues for phase detection.
        // overrideOutputAudioPort forces the loud speaker even when earphones are connected.
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .duckOthers, .allowBluetoothHFP])
        try? session.overrideOutputAudioPort(.speaker)
        try? session.setActive(true, options: .notifyOthersOnDeactivation)

        // Wecker IMMER auf maximaler Lautstärke — unabhängig von der System-Medienlautstärke.
        forceSystemVolumeMax()

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        // Weicher Hall gibt den synthetisierten Tönen Wärme und Raum (angenehmer, weniger
        // „elektronisch"). player → reverb → mainMixer.
        let reverb = AVAudioUnitReverb()
        reverb.loadFactoryPreset(.largeHall2)
        reverb.wetDryMix = 40
        engine.attach(player)
        engine.attach(reverb)

        let sampleRate = 44100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.connect(player, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1.0
        pulseIndex = 0
        // Crescendo-Start: erster Puls leise; scheduleNextPulse rampt auf 1.0.
        player.volume = 0.35

        do {
            try engine.start()
        } catch {
            // Fallback: vibration + repeating tone via system sound
            toneLoopTask = Task { @MainActor in
                while !Task.isCancelled {
                    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                    AudioServicesPlaySystemSound(alarmTon.systemSoundID)
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            return
        }

        toneEngine = engine
        toneNode = player
        toneReverb = reverb

        scheduleNextPulse(player: player, engine: engine, sampleRate: sampleRate)
    }

    private func scheduleNextPulse(player: AVAudioPlayerNode, engine: AVAudioEngine, sampleRate: Double) {
        guard alarmFired else { return }
        // Sanftes Crescendo über die ersten ~6 Pulse (leise → 100 %), danach voll laut.
        pulseIndex += 1
        player.volume = Float(min(0.35 + 0.11 * Double(pulseIndex), 1.0))
        let (toneBuf, silenceBuf) = makePulseBuffers(for: alarmTon, sampleRate: sampleRate)

        player.scheduleBuffer(toneBuf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self, self.alarmFired else { return }
            self.toneNode?.scheduleBuffer(silenceBuf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self, self.alarmFired else { return }
                self.scheduleNextPulse(player: player, engine: engine, sampleRate: sampleRate)
            }
            self.toneNode?.play()
        }
        player.play()
    }

    // Returns (tone, silence) buffers tailored for each alarm type.
    // Alle Töne sind bewusst weich (sanfte Attack/Release, warme Obertöne, kein Clipping)
    // und werden durch den Hall zusätzlich beruhigend — kein hartes Piepen mehr.
    private func makePulseBuffers(for ton: AlarmTon, sampleRate: Double) -> (AVAudioPCMBuffer, AVAudioPCMBuffer) {
        switch ton {
        case .sanft:
            // Warmer, atmender Dur-Akkord mit sanftem Vibrato, langer 2.2 s Ruhe.
            return (makeSanftBuffer(sampleRate: sampleRate), makeSilenceBuffer(sampleRate: sampleRate, duration: 2.2))
        case .natur:
            // Weiche Vogel-Pfiffe (entschärft), 1.6 s Ruhe.
            return (makeNaturBuffer(sampleRate: sampleRate), makeSilenceBuffer(sampleRate: sampleRate, duration: 1.6))
        case .klassisch:
            // Sanftes Glockenspiel-Arpeggio (C-Dur), weicher Ausklang, 1.2 s Ruhe.
            return (makeKlassischBuffer(sampleRate: sampleRate), makeSilenceBuffer(sampleRate: sampleRate, duration: 1.2))
        case .signal:
            // Zartes Zwei-Ton-Glockenspiel (G5→C6), weicher Mallet-Anschlag, 1.0 s Ruhe.
            return (makeChimeBuffer(sampleRate: sampleRate), makeSilenceBuffer(sampleRate: sampleRate, duration: 1.0))
        case .digital:
            // Weiches Schimmern: drei sanft aufsteigende Glockentöne, 1.0 s Ruhe.
            return (makeShimmerBuffer(sampleRate: sampleRate), makeSilenceBuffer(sampleRate: sampleRate, duration: 1.0))
        }
    }

    // MARK: - Tone synthesisers

    // Sanft: warmer, breathing C-major chord (C4 + E4 + G4 + C5) with gentle vibrato and a
    // long, soft fade in/out — like a distant harmonium easing you awake.
    private func makeSanftBuffer(sampleRate: Double) -> AVAudioPCMBuffer {
        let duration = 2.0
        let buf = allocBuffer(sampleRate: sampleRate, duration: duration)
        let data = buf.floatChannelData![0]
        let freqs = [261.63, 329.63, 392.0, 523.25]     // C4, E4, G4, C5
        let amps  = [0.42,   0.26,   0.24,  0.16]
        for i in 0..<Int(buf.frameLength) {
            let t = Double(i) / sampleRate
            // Smooth bell-shaped envelope: fade in over 0.9 s, hold, fade out over 0.7 s.
            let fadeIn  = min(t / 0.9, 1.0)
            let fadeOut = min(max(duration - t, 0.0) / 0.7, 1.0)
            let env = fadeIn * fadeOut
            // gentle 5 Hz vibrato for a living, calming timbre
            let vib = 1.0 + 0.004 * sin(2.0 * .pi * 5.0 * t)
            var s = 0.0
            for (f, a) in zip(freqs, amps) { s += a * sin(2.0 * .pi * f * vib * t) }
            data[i] = Float(s * env * 0.8)
        }
        return buf
    }

    // Natur: three ascending FM whistles (bird chirp)
    private func makeNaturBuffer(sampleRate: Double) -> AVAudioPCMBuffer {
        let chirpDur = 0.18
        let gap      = 0.07
        let duration = 3.0 * (chirpDur + gap)
        let buf = allocBuffer(sampleRate: sampleRate, duration: duration)
        let data = buf.floatChannelData![0]
        // Lower, softer whistles (less shrill) with a much gentler FM index.
        let startFreqs = [900.0, 1150.0, 1400.0]
        let endFreqs   = [1150.0, 1400.0, 1650.0]
        for i in 0..<Int(buf.frameLength) {
            let t = Double(i) / sampleRate
            var s = 0.0
            for k in 0..<3 {
                let t0 = Double(k) * (chirpDur + gap)
                let t1 = t0 + chirpDur
                guard t >= t0 && t < t1 else { continue }
                let lt = t - t0
                let phase = lt / chirpDur
                let freq = startFreqs[k] + (endFreqs[k] - startFreqs[k]) * phase
                let env = sin(.pi * phase)            // bell-shaped per chirp
                // gentle FM (index 0.6) → warmer, less piercing than before
                let carrier = sin(2.0 * .pi * freq * lt + 0.6 * sin(2.0 * .pi * freq * 2.0 * lt))
                s += carrier * env * 0.55
            }
            data[i] = Float(s)
        }
        return buf
    }

    // Klassisch: C-major arpeggio C5 → E5 → G5 → C6, piano-style decay per note
    private func makeKlassischBuffer(sampleRate: Double) -> AVAudioPCMBuffer {
        let noteLen  = 0.22
        let overlap  = 0.04
        let notes: [Double] = [523.25, 659.25, 783.99, 1046.50]  // C5 E5 G5 C6
        let duration = Double(notes.count) * (noteLen - overlap) + 0.18
        let buf = allocBuffer(sampleRate: sampleRate, duration: duration)
        let data = buf.floatChannelData![0]
        for i in 0..<Int(buf.frameLength) {
            let t = Double(i) / sampleRate
            var s = 0.0
            for (n, freq) in notes.enumerated() {
                let t0 = Double(n) * (noteLen - overlap)
                let lt = t - t0
                guard lt >= 0 else { continue }
                // soft mallet: gentle attack, longer mellow decay
                let env = min(lt / 0.02, 1.0) * exp(-lt * 4.0)
                // fundamental + soft 2nd harmonic (less 3rd) → mellower, bell-like
                s += (sin(2.0 * .pi * freq * lt)
                    + 0.22 * sin(4.0 * .pi * freq * lt)
                    + 0.07 * sin(6.0 * .pi * freq * lt)) * env * 0.6
            }
            data[i] = Float(max(-1.0, min(1.0, s)))
        }
        return buf
    }

    // Chime: two soft mallet bells (G5 → C6), gentle attack + mellow decay, no clipping.
    private func makeChimeBuffer(sampleRate: Double) -> AVAudioPCMBuffer {
        let noteLen = 0.8
        let overlap = 0.25
        let notes: [Double] = [783.99, 1046.50]     // G5, C6
        let duration = Double(notes.count) * (noteLen - overlap) + overlap + 0.3
        let buf = allocBuffer(sampleRate: sampleRate, duration: duration)
        let data = buf.floatChannelData![0]
        for i in 0..<Int(buf.frameLength) {
            let t = Double(i) / sampleRate
            var s = 0.0
            for (n, freq) in notes.enumerated() {
                let t0 = Double(n) * (noteLen - overlap)
                let lt = t - t0
                guard lt >= 0 else { continue }
                let env = min(lt / 0.02, 1.0) * exp(-lt * 3.2)
                s += (sin(2.0 * .pi * freq * lt) + 0.18 * sin(4.0 * .pi * freq * lt)) * env * 0.55
            }
            data[i] = Float(max(-1.0, min(1.0, s)))
        }
        return buf
    }

    // Shimmer: three softly rising bell tones (C5, E5, G5) with slight detune — a calm,
    // dreamy ascent instead of a harsh digital sweep.
    private func makeShimmerBuffer(sampleRate: Double) -> AVAudioPCMBuffer {
        let noteLen = 0.7
        let step    = 0.22
        let notes: [Double] = [523.25, 659.25, 783.99]   // C5, E5, G5
        let duration = Double(notes.count - 1) * step + noteLen + 0.3
        let buf = allocBuffer(sampleRate: sampleRate, duration: duration)
        let data = buf.floatChannelData![0]
        for i in 0..<Int(buf.frameLength) {
            let t = Double(i) / sampleRate
            var s = 0.0
            for (n, freq) in notes.enumerated() {
                let t0 = Double(n) * step
                let lt = t - t0
                guard lt >= 0 else { continue }
                let env = min(lt / 0.03, 1.0) * exp(-lt * 2.8)
                // slight detune (+0.3 %) layered for a shimmering, soft chorus
                s += (sin(2.0 * .pi * freq * lt) + 0.5 * sin(2.0 * .pi * freq * 1.003 * lt)) * env * 0.32
            }
            data[i] = Float(max(-1.0, min(1.0, s)))
        }
        return buf
    }

    private func allocBuffer(sampleRate: Double, duration: Double) -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buf.frameLength = frameCount
        return buf
    }

    private func makeSilenceBuffer(sampleRate: Double, duration: Double) -> AVAudioPCMBuffer {
        let buf = allocBuffer(sampleRate: sampleRate, duration: duration)
        return buf
    }

    func vorschauSpielen() {
        // Stop previous preview engine if still running
        previewEngine?.stop()
        previewNode?.stop()
        previewEngine = nil
        previewNode = nil

        // .playback does not accept .defaultToSpeaker — omit it for preview
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let reverb = AVAudioUnitReverb()
        reverb.loadFactoryPreset(.largeHall2)
        reverb.wetDryMix = 40
        engine.attach(player)
        engine.attach(reverb)
        let sampleRate = 44100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.connect(player, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1.0
        player.volume = max(lautstaerke, 0.6)   // preview always clearly audible

        guard (try? engine.start()) != nil else { return }
        previewEngine = engine
        previewNode = player

        let (toneBuf, _) = makePulseBuffers(for: alarmTon, sampleRate: sampleRate)
        // Completion callback fires on an internal audio thread — dispatch cleanup to main
        player.scheduleBuffer(toneBuf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                self?.previewEngine?.stop()
                self?.previewEngine = nil
                self?.previewNode = nil
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
        player.play()
    }

    /// Fires the alarm immediately for testing — same tone + volume as the real alarm.
    func testAlarm() {
        alarmFired = true
        alarmFiredDate = Date()
        playAlarmTone()
    }

    func stopAlarm() {
        snoozeTask?.cancel()
        snoozeTask = nil
        alarmFired = false
        toneLoopTask?.cancel()
        toneLoopTask = nil
        toneNode?.stop()
        toneEngine?.stop()
        toneNode = nil
        toneEngine = nil
        toneReverb = nil
        // Failsafe-Notification-Burst abbrechen — sonst klingelt der Hintergrund-Wecker
        // (alle 30 s über 5 min) weiter, obwohl der In-App-Ton gestoppt wurde.
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: failsafeIDs)
        center.removeDeliveredNotifications(withIdentifiers: failsafeIDs)
        // Restore recording session: mixWithOthers + remove forced speaker override
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .allowBluetoothHFP])
        try? session.overrideOutputAudioPort(.none)
        try? session.setActive(true)
    }

    // MARK: - Failsafe notification

    private func scheduleFailsafeNotification() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: failsafeIDs)

        // Backup for the case where the app was killed/suspended and the in-app tone can't
        // play. A single local notification plays its sound only briefly and is easy to sleep
        // through — so we schedule a short BURST of notifications around the latest wake time
        // (at the deadline, then every 30 s for 5 minutes). Each plays the default sound.
        let cal = Calendar.current
        guard let baseLatest = cal.nextDate(after: Date(),
                                            matching: cal.dateComponents([.hour, .minute], from: latestWakeTime),
                                            matchingPolicy: .nextTime) else { return }

        for (index, offset) in stride(from: 0, through: 300, by: 30).enumerated() {
            let fireDate = baseLatest.addingTimeInterval(TimeInterval(offset))
            let content = UNMutableNotificationContent()
            content.title = "Zeit aufzuwachen ⏰"
            content.body = "Dein Smart Alarm meldet sich."
            content.sound = alarmTon.notificationSound
            content.interruptionLevel = .timeSensitive

            let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let request = UNNotificationRequest(identifier: "\(notificationID).\(index)",
                                                content: content, trigger: trigger)
            center.add(request)
        }
    }

    /// All failsafe notification identifiers (burst 0…10 → 0 s … 300 s).
    private var failsafeIDs: [String] {
        (0...10).map { "\(notificationID).\($0)" }
    }

    // MARK: - Helpers

    /// True once the latest wake time for "today" has been reached.
    /// Handles the over-midnight case: if the latest time is in the early morning and we
    /// fell asleep before midnight, the relevant latest time is on the *next* calendar day.
    // Normalisiert eine Tageszeit (earliest/latest) auf das Weckfenster, das zur
    // aktuellen Schlafsession gehört. Ein Wecker um 07:00 gehört beim Tracking-Start
    // um 23:29 zum NÄCHSTEN Morgen (über Mitternacht) — sonst gilt 07:00 als bereits
    // vergangen und der Alarm würde sofort feuern.
    private func normalizedWindowTime(_ base: Date, relativeTo date: Date) -> Date {
        let cal = Calendar.current
        var t = cal.date(bySettingHour: cal.component(.hour, from: base),
                         minute: cal.component(.minute, from: base),
                         second: 0, of: date) ?? base
        if date.timeIntervalSince(t) > 12 * 3600 {
            // Mehr als 12 h in der Vergangenheit → gehört zum nächsten Morgen.
            t = cal.date(byAdding: .day, value: 1, to: t) ?? t
        } else if t.timeIntervalSince(date) > 12 * 3600 {
            // Mehr als 12 h in der Zukunft → gehört zum vorigen Tag.
            t = cal.date(byAdding: .day, value: -1, to: t) ?? t
        }
        return t
    }

    private func isPastLatest(_ date: Date) -> Bool {
        // Bevorzugt die beim Arm verankerten Zeitpunkte (immer korrekt in der Zukunft).
        if let l = armedLatest { return date >= l }
        return date >= normalizedWindowTime(latestWakeTime, relativeTo: date)
    }

    private func isInsideWindow(_ date: Date) -> Bool {
        if let e = armedEarliest, let l = armedLatest { return date >= e && date <= l }
        let earliest = normalizedWindowTime(earliestWakeTime, relativeTo: date)
        let latest = normalizedWindowTime(latestWakeTime, relativeTo: date)
        return date >= earliest && date <= latest
    }

    private static func loadTime(hourKey: String, minuteKey: String, defaultHour: Int, defaultMinute: Int) -> Date {
        let hour   = UserDefaults.standard.object(forKey: hourKey)   != nil ? UserDefaults.standard.integer(forKey: hourKey)   : defaultHour
        let minute = UserDefaults.standard.object(forKey: minuteKey) != nil ? UserDefaults.standard.integer(forKey: minuteKey) : defaultMinute
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }

    private static func saveTime(_ date: Date, hourKey: String, minuteKey: String) {
        UserDefaults.standard.set(Calendar.current.component(.hour,   from: date), forKey: hourKey)
        UserDefaults.standard.set(Calendar.current.component(.minute, from: date), forKey: minuteKey)
    }
}
