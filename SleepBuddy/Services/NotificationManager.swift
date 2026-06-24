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

    /// Calculates average bedtime from recent start dates and schedules a reminder 15 minutes before.
    /// Falls back to the stored fixed time if fewer than 3 dates are provided.
    func planeAdaptiveErinnerung(startDaten: [Date], fallbackStunde: Int, fallbackMinute: Int) {
        guard startDaten.count >= 3 else {
            planeSchlafErinnerung(stunde: fallbackStunde, minute: fallbackMinute)
            return
        }

        let cal = Calendar.current
        let minutesSinceMidnight = startDaten.map { date -> Double in
            let comps = cal.dateComponents([.hour, .minute], from: date)
            let h = comps.hour ?? 22
            let m = comps.minute ?? 0
            var mins = Double(h * 60 + m)
            if mins < 12 * 60 { mins += 24 * 60 }
            return mins
        }

        let avg = minutesSinceMidnight.reduce(0, +) / Double(minutesSinceMidnight.count)
        let reminderMins = avg - 15
        let totalMins = Int(reminderMins) % (24 * 60)
        let stunde = (totalMins / 60) % 24
        let minute = totalMins % 60
        planeSchlafErinnerung(stunde: stunde, minute: minute)
    }
}
