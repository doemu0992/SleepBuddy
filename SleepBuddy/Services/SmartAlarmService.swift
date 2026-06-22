import AVFoundation
import UserNotifications
import Observation

@Observable
final class SmartAlarmService {

    private enum Keys {
        static let isEnabled      = "smartAlarm.isEnabled"
        static let earliestHour   = "smartAlarm.earliestHour"
        static let earliestMinute = "smartAlarm.earliestMinute"
        static let latestHour     = "smartAlarm.latestHour"
        static let latestMinute   = "smartAlarm.latestMinute"
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

    private(set) var alarmFired = false
    private(set) var alarmFiredDate: Date?
    private(set) var hasNotificationPermission = false

    private var audioPlayer: AVAudioPlayer?
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
        guard let url = Bundle.main.url(forResource: "alarm", withExtension: "caf")
                     ?? Bundle.main.url(forResource: "alarm", withExtension: "mp3") else { return }
        audioPlayer = try? AVAudioPlayer(contentsOf: url)
        audioPlayer?.numberOfLoops = -1   // loop until user taps "Aufwachen"
        audioPlayer?.play()
    }

    func stopAlarm() {
        audioPlayer?.stop()
        audioPlayer = nil
    }

    // MARK: - Failsafe notification

    private func scheduleFailsafeNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Zeit aufzuwachen"
        content.body = "Dein Smart Alarm meldet sich."
        content.sound = .defaultCritical

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
