import SwiftUI
import SwiftData

@main
struct SleepBuddyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [SleepSession.self, SleepPhase.self])
    }
}
