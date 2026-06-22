import SwiftUI
import SwiftData
import AVFoundation

@main
struct SleepBuddyApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [SleepSession.self, SleepPhase.self, TrainingSample.self])
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                // Deactivate audio session when not tracking.
                // SleepTrackingViewModel reactivates it in startTracking().
                if !SleepBuddyApp.isTrackingActive {
                    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                }
            }
        }
    }

    // Set to true by SleepTrackingViewModel during active sleep tracking.
    static var isTrackingActive = false
}
