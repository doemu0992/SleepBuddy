import SwiftUI
import SwiftData
import AVFoundation

@main
struct SleepBuddyApp: App {
    @Environment(\.scenePhase) private var scenePhase

    static let sharedModelContainer: ModelContainer = {
        let allTypes: [any PersistentModel.Type] = [SleepSession.self, SleepPhase.self, SleepSoundEvent.self, TrainingSample.self]
        let containerID = "iCloud.DG-Software-Solution.PainDiary"

        let cloudConfig = ModelConfiguration(
            "SleepData",
            schema: Schema([SleepSession.self, SleepPhase.self, SleepSoundEvent.self]),
            cloudKitDatabase: .private(containerID)
        )
        let localConfig = ModelConfiguration(
            "MLData",
            schema: Schema([TrainingSample.self]),
            cloudKitDatabase: .none
        )
        // With migration plan: handles V1→V2 schema upgrade (added inverse relationships)
        if let container = try? ModelContainer(
            for: SleepSession.self, SleepPhase.self, SleepSoundEvent.self, TrainingSample.self,
            migrationPlan: SleepMigrationPlan.self,
            configurations: cloudConfig, localConfig
        ) { return container }

        // Fallback: same store name "SleepData" without CloudKit — keeps existing local data accessible
        let sleepFallback = ModelConfiguration(
            "SleepData",
            schema: Schema([SleepSession.self, SleepPhase.self, SleepSoundEvent.self]),
            cloudKitDatabase: .none
        )
        return try! ModelContainer(
            for: SleepSession.self, SleepPhase.self, SleepSoundEvent.self, TrainingSample.self,
            migrationPlan: SleepMigrationPlan.self,
            configurations: sleepFallback, localConfig
        )
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
