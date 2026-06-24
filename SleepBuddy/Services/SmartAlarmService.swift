import AVFoundation
import AudioToolbox
import UserNotifications
import Observation

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

    // Pulse pattern in Hz for the generated tone
    var frequencyHz: Double {
        switch self {
        case .sanft:     return 440.0
        case .natur:     return 528.0
        case .klassisch: return 523.0
        case .signal:    return 880.0
        case .digital:   return 660.0
        }
    }

    var notificationSound: UNNotificationSound {
        .defaultCritical
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
    private(set) var hasNotificationPermission = false

    private let notificationID = "com.sleepbuddy.smartalarm"

    // Tone generation via AVAudioEngine
    private var toneEngine: AVAudioEngine?
    private var toneNode: AVAudioPlayerNode?
    private var toneLoopTask: Task<Void, Never>?

    // MARK: - Permission

    func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge, .criticalAlert])) ?? false
        await MainActor.run { hasNotificationPermission = granted }
    }

    // MARK: - Arm / Disarm

    func arm() {
        guard isEnabled else { return }
        alarmFired = false
        alarmFiredDate = nil
        scheduleFailsafeNotification()
    }

    func disarm() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationID])
        stopAlarm()
    }

    // MARK: - Phase monitoring

    @discardableResult
    func checkPhase(_ phase: SleepPhaseType) -> Bool {
        guard isEnabled, !alarmFired else { return false }
        let now = Date()
        guard isInsideWindow(now) else { return false }
        guard phase == .light || phase == .awake else { return false }

        triggerAlarm(at: now)
        return true
    }

    // MARK: - Trigger

    private func triggerAlarm(at date: Date) {
        alarmFired = true
        alarmFiredDate = date
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationID])
        playAlarmTone()
    }

    private func playAlarmTone() {
        let session = AVAudioSession.sharedInstance()
        // duckOthers: alarm gets full priority over all other audio (including recording output).
        // The microphone INPUT is unaffected — recording continues for phase detection.
        // overrideOutputAudioPort forces the loud speaker even when earphones are connected.
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .duckOthers, .allowBluetoothHFP])
        try? session.overrideOutputAudioPort(.speaker)
        try? session.setActive(true, options: .notifyOthersOnDeactivation)

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        let sampleRate = 44100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1.0
        player.volume = lautstaerke

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

        scheduleNextPulse(player: player, engine: engine, sampleRate: sampleRate)
    }

    private func scheduleNextPulse(player: AVAudioPlayerNode, engine: AVAudioEngine, sampleRate: Double) {
        guard alarmFired else { return }
        let buffer = makeToneBuffer(frequency: alarmTon.frequencyHz, sampleRate: sampleRate, duration: 0.8)
        let silence = makeSilenceBuffer(sampleRate: sampleRate, duration: 1.0)

        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self, self.alarmFired else { return }
            self.toneNode?.scheduleBuffer(silence, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self, self.alarmFired else { return }
                self.scheduleNextPulse(player: player, engine: engine, sampleRate: sampleRate)
            }
            self.toneNode?.play()
        }
        player.play()
    }

    private func makeToneBuffer(frequency: Double, sampleRate: Double, duration: Double) -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            let envelope = min(t / 0.02, 1.0) * min((duration - t) / 0.02, 1.0)
            data[i] = Float(sin(2.0 * .pi * frequency * t) * envelope)
        }
        return buffer
    }

    private func makeSilenceBuffer(sampleRate: Double, duration: Double) -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        return buffer
    }

    func vorschauSpielen() {
        AudioServicesPlaySystemSound(alarmTon.systemSoundID)
    }

    func stopAlarm() {
        toneLoopTask?.cancel()
        toneLoopTask = nil
        toneNode?.stop()
        toneEngine?.stop()
        toneNode = nil
        toneEngine = nil
        // Restore recording session: mixWithOthers + remove forced speaker override
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .allowBluetoothHFP])
        try? session.overrideOutputAudioPort(.none)
        try? session.setActive(true)
    }

    // MARK: - Failsafe notification

    private func scheduleFailsafeNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Zeit aufzuwachen"
        content.body = "Dein Smart Alarm meldet sich."
        content.sound = alarmTon.notificationSound
        content.interruptionLevel = .timeSensitive

        let components = Calendar.current.dateComponents([.hour, .minute], from: latestWakeTime)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        let request = UNNotificationRequest(identifier: notificationID, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Helpers

    private func isInsideWindow(_ date: Date) -> Bool {
        let cal = Calendar.current
        let earliest = cal.date(bySettingHour: cal.component(.hour, from: earliestWakeTime),
                                minute: cal.component(.minute, from: earliestWakeTime),
                                second: 0, of: date) ?? earliestWakeTime
        let latest = cal.date(bySettingHour: cal.component(.hour, from: latestWakeTime),
                              minute: cal.component(.minute, from: latestWakeTime),
                              second: 0, of: date) ?? latestWakeTime
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
