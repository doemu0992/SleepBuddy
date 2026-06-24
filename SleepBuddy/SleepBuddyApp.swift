import SwiftUI
import SwiftData
import AVFoundation

@main
struct SleepBuddyApp: App {
    @Environment(\.scenePhase) private var scenePhase

    static let sharedModelContainer: ModelContainer = {
        let allTypes: [any PersistentModel.Type] = [SleepSession.self, SleepPhase.self, SleepSoundEvent.self, TrainingSample.self]

        // Store lives in the App Group so PainDiary can read shared UserDefaults
        // alongside it. CloudKit sync is disabled — the schema doesn't satisfy
        // CloudKit's "all attributes optional" requirement without a migration.
        let groupURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.doemu0992.sleepbuddy")?
            .appendingPathComponent("SleepData.store")

        if let url = groupURL {
            let config = ModelConfiguration(
                "SleepData",
                schema: Schema(allTypes),
                url: url,
                cloudKitDatabase: .none
            )
            if let container = try? ModelContainer(for: SleepSession.self, SleepPhase.self, SleepSoundEvent.self, TrainingSample.self, configurations: config) {
                return container
            }
        }

        // Fallback: default local path, no CloudKit
        let localConfig = ModelConfiguration("SleepDataLocal", schema: Schema(allTypes), cloudKitDatabase: .none)
        if let container = try? ModelContainer(for: SleepSession.self, SleepPhase.self, SleepSoundEvent.self, TrainingSample.self, configurations: localConfig) {
            return container
        }

        // Last resort: in-memory (app never crashes on launch)
        let memConfig = ModelConfiguration(schema: Schema(allTypes), isStoredInMemoryOnly: true)
        return try! ModelContainer(for: SleepSession.self, SleepPhase.self, SleepSoundEvent.self, TrainingSample.self, configurations: memConfig)
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
