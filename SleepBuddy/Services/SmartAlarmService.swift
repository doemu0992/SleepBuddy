import AVFoundation
import UserNotifications
import Observation

/// Wakes the user during a light sleep phase within a set time window.
/// Strategy:
///   1. Schedule a failsafe local notification at latestWakeTime
///   2. During background audio, monitor phase + time
///   3. If phase is light/awake inside the window → trigger alarm immediately
///   4. Cancel failsafe notification once alarm fires
@Observable
final class SmartAlarmService {

    var isEnabled = false
    var earliestWakeTime: Date = defaultEarliestTime()
    var latestWakeTime: Date = defaultLatestTime()

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

    private static func defaultEarliestTime() -> Date {
        Calendar.current.date(bySettingHour: 6, minute: 30, second: 0, of: Date()) ?? Date()
    }

    private static func defaultLatestTime() -> Date {
        Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date()) ?? Date()
    }
}
