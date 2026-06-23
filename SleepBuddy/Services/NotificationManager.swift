import UserNotifications

final class NotificationManager {
    static let shared = NotificationManager()
    private init() {}

    private let schlafErinnerungID = "sleepbuddy.schlaf.erinnerung"

    func berechtigungAnfordern() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .authorized { return true }
        return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func planeSchlafErinnerung(stunde: Int, minute: Int) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [schlafErinnerungID])

        let content = UNMutableNotificationContent()
        content.title = "Zeit zum Schlafen 🌙"
        content.body = "Starte SleepBuddy für deine Schlafaufzeichnung."
        content.sound = .default

        var dc = DateComponents()
        dc.hour = stunde
        dc.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: dc, repeats: true)
        let request = UNNotificationRequest(identifier: schlafErinnerungID, content: content, trigger: trigger)
        center.add(request)
    }

    func loescheSchlafErinnerung() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [schlafErinnerungID])
    }
}
