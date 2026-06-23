import SwiftUI
import SwiftData
import AVFoundation

@main
struct SleepBuddyApp: App {
    @Environment(\.scenePhase) private var scenePhase

    static let sharedModelContainer: ModelContainer = {
        let allTypes: [any PersistentModel.Type] = [SleepSession.self, SleepPhase.self, SleepSoundEvent.self, TrainingSample.self]

        // 1. CloudKit + separate local store for ML data
        let cloudConfig = ModelConfiguration(
            "SleepData",
            schema: Schema([SleepSession.self, SleepPhase.self, SleepSoundEvent.self]),
            cloudKitDatabase: .automatic
        )
        let localConfig = ModelConfiguration(
            "MLData",
            schema: Schema([TrainingSample.self]),
            cloudKitDatabase: .none
        )
        if let container = try? ModelContainer(
            for: SleepSession.self, SleepPhase.self, SleepSoundEvent.self, TrainingSample.self,
            configurations: cloudConfig, localConfig
        ) { return container }

        // 2. Single local store without CloudKit (e.g. simulator / no iCloud account)
        let localOnlyConfig = ModelConfiguration(
            "SleepDataLocal",
            schema: Schema(allTypes),
            cloudKitDatabase: .none
        )
        if let container = try? ModelContainer(
            for: SleepSession.self, SleepPhase.self, SleepSoundEvent.self, TrainingSample.self,
            configurations: localOnlyConfig
        ) { return container }

        // 3. Default container — SwiftData picks path automatically
        if let container = try? ModelContainer(
            for: SleepSession.self, SleepPhase.self, SleepSoundEvent.self, TrainingSample.self
        ) { return container }

        // 4. In-memory last resort so the app never crashes on launch
        let memConfig = ModelConfiguration(schema: Schema(allTypes), isStoredInMemoryOnly: true)
        return try! ModelContainer(
            for: SleepSession.self, SleepPhase.self, SleepSoundEvent.self, TrainingSample.self,
            configurations: memConfig
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
