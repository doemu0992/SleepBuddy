import SwiftUI
import SwiftData
import AVFoundation

@main
struct SleepBuddyApp: App {
    @Environment(\.scenePhase) private var scenePhase

    static let sharedModelContainer: ModelContainer = {
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

        if let container = try? ModelContainer(
            for: SleepSession.self, SleepPhase.self, SleepSoundEvent.self, TrainingSample.self,
            configurations: cloudConfig, localConfig
        ) { return container }

        // Fallback: same store name without CloudKit — data stays accessible, CloudKit re-syncs on next success
        let sleepFallback = ModelConfiguration(
            "SleepData",
            schema: Schema([SleepSession.self, SleepPhase.self, SleepSoundEvent.self]),
            cloudKitDatabase: .none
        )
        return try! ModelContainer(
            for: SleepSession.self, SleepPhase.self, SleepSoundEvent.self, TrainingSample.self,
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
                if !SleepBuddyApp.isTrackingActive {
                    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                }
            }
        }
    }

    static var isTrackingActive = false
}
