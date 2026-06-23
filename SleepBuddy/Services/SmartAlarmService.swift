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

    /// SystemSoundID used for in-app preview and fallback playback
    var systemSoundID: SystemSoundID {
        switch self {
        case .sanft:     return 1013   // Tri-tone
        case .natur:     return 1020   // Fanfare
        case .klassisch: return 1016   // Anticipate
        case .signal:    return 1057   // Radar
        case .digital:   return 1022   // Minuet
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

    /// UNNotificationSoundName for background notification fallback
    var notificationSound: UNNotificationSound {
        switch self {
        case .sanft:     return .defaultCritical
        case .natur:     return .defaultCriticalSound(withAudioVolume: 0.7)
        case .klassisch: return .defaultCritical
        case .signal:    return .defaultCritical
        case .digital:   return .defaultCritical
        }
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
            audioPlayer?.volume = lautstaerke
        }
    }

    private(set) var alarmFired = false
    private(set) var alarmFiredDate: Date?
    private(set) var hasNotificationPermission = false

    private var audioPlayer: AVAudioPlayer?
    private var loopTask: Task<Void, Never>?
    private let notificationID = "com.sleepbuddy.smartalarm"

    // MARK: - Permission

    func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await MainActor.run { hasNotificationPermission = granted }
    }

    // MARK: - Arm / Disarm

    /// Call when sleep tracking starts. Schedules the failsafe notification.
    func arm() {
        guard isEnabled else { return }
        alarmFired = false
        alarmFiredDate = nil
        scheduleFailsafeNotification()
    }

    /// Call when tracking stops without the alarm having fired.
    func disarm() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationID])
        audioPlayer?.stop()
    }

    // MARK: - Phase monitoring (called every 30s from ViewModel)

    /// Returns true if the smart alarm was just triggered.
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
        playAlarmSound()
    }

    private func playAlarmSound() {
        // Try bundle audio file first
        if let url = Bundle.main.url(forResource: "alarm", withExtension: "caf")
                  ?? Bundle.main.url(forResource: "alarm", withExtension: "mp3"),
           let player = try? AVAudioPlayer(contentsOf: url) {
            player.numberOfLoops = -1
            player.volume = lautstaerke
            player.play()
            audioPlayer = player
        } else {
            // Fallback: loop system sound via repeating task
            loopTask = Task { @MainActor in
                while !Task.isCancelled {
                    AudioServicesPlaySystemSound(alarmTon.systemSoundID)
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    func vorschauSpielen() {
        AudioServicesPlaySystemSound(alarmTon.systemSoundID)
    }

    func stopAlarm() {
        loopTask?.cancel()
        loopTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
    }

    // MARK: - Failsafe notification

    private func scheduleFailsafeNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Zeit aufzuwachen"
        content.body = "Dein Smart Alarm meldet sich."
        content.sound = alarmTon.notificationSound

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
