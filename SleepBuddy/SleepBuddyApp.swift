import SwiftUI
import SwiftData
import AVFoundation

@main
struct SleepBuddyApp: App {
    @Environment(\.scenePhase) private var scenePhase

    static let sharedModelContainer: ModelContainer = {
        // iCloud-synced models (SleepSession, SleepPhase, SleepSoundEvent)
        let cloudConfig = ModelConfiguration(
            "SleepData",
            schema: Schema([SleepSession.self, SleepPhase.self, SleepSoundEvent.self]),
            cloudKitDatabase: .automatic
        )
        // Local-only (TrainingSamples are large and ML-only, no cloud needed)
        let localConfig = ModelConfiguration(
            "MLData",
            schema: Schema([TrainingSample.self]),
            cloudKitDatabase: .none
        )
        do {
            return try ModelContainer(for: SleepSession.self, SleepPhase.self, SleepSoundEvent.self, TrainingSample.self,
                                      configurations: cloudConfig, localConfig)
        } catch {
            // Fallback to local-only if CloudKit is unavailable
            let fallback = try! ModelContainer(for: SleepSession.self, SleepPhase.self, SleepSoundEvent.self, TrainingSample.self)
            return fallback
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(SleepBuddyApp.sharedModelContainer)
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
