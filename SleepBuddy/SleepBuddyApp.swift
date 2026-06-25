import SwiftUI
import SwiftData
import AVFoundation

// Starts building the persistent container at module-load time — maximum head start.
private let _persistentContainerTask = Task.detached(priority: .userInitiated) {
    SleepBuddyApp.makePersistentContainer()
}

@main
struct SleepBuddyApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("onboarding_complete") private var onboardingComplete = false

    @State private var modelContainer: ModelContainer? = nil

    var body: some Scene {
        WindowGroup {
            if let container = modelContainer {
                Group {
                    if onboardingComplete {
                        ContentView()
                    } else {
                        OnboardingView { onboardingComplete = true }
                    }
                }
                .modelContainer(container)
            } else {
                Color.clear
                    .task {
                        let container = await _persistentContainerTask.value
                        modelContainer = container
                        ICloudSettingsSync.shared.start()
                    }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, !SleepBuddyApp.isTrackingActive {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    // MARK: - Persistent container with CloudKit (runs off main thread)

    nonisolated static func makePersistentContainer() -> ModelContainer {
        // Attempt 1: CloudKit sync
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
        if let c = try? ModelContainer(for: SleepSession.self, SleepPhase.self, SleepSoundEvent.self, TrainingSample.self, configurations: cloudConfig, localConfig) {
            return c
        }

        // Attempt 2: Local only (no CloudKit)
        let sleepLocal = ModelConfiguration(
            "SleepData",
            schema: Schema([SleepSession.self, SleepPhase.self, SleepSoundEvent.self]),
            cloudKitDatabase: .none
        )
        let mlLocal = ModelConfiguration(
            "MLData",
            schema: Schema([TrainingSample.self]),
            cloudKitDatabase: .none
        )
        if let c = try? ModelContainer(for: SleepSession.self, SleepPhase.self, SleepSoundEvent.self, TrainingSample.self, configurations: sleepLocal, mlLocal) {
            return c
        }

        // Attempt 3: Delete corrupt on-disk stores and recreate
        deleteStoreFiles()
        let sleepFresh = ModelConfiguration(
            "SleepData",
            schema: Schema([SleepSession.self, SleepPhase.self, SleepSoundEvent.self]),
            cloudKitDatabase: .none
        )
        let mlFresh = ModelConfiguration(
            "MLData",
            schema: Schema([TrainingSample.self]),
            cloudKitDatabase: .none
        )
        return try! ModelContainer(for: SleepSession.self, SleepPhase.self, SleepSoundEvent.self, TrainingSample.self, configurations: sleepFresh, mlFresh)
    }

    nonisolated private static func deleteStoreFiles() {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let names = ["SleepData.sqlite", "SleepData.sqlite-wal", "SleepData.sqlite-shm",
                     "MLData.sqlite", "MLData.sqlite-wal", "MLData.sqlite-shm"]
        for name in names { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
    }

    static var isTrackingActive = false
}
