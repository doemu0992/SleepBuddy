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

    // Starts as a fast in-memory container so the UI renders at T=0.
    // Replaced with the real persistent container once it's ready.
    @State private var modelContainer: ModelContainer = SleepBuddyApp.makeInMemoryContainer()
    @State private var isReady = false

    var body: some Scene {
        WindowGroup {
            Group {
                if onboardingComplete {
                    ContentView()
                } else {
                    OnboardingView { onboardingComplete = true }
                }
            }
            .modelContainer(modelContainer)
            .opacity(isReady ? 1 : 0)
            .task {
                let persistent = await _persistentContainerTask.value
                modelContainer = persistent
                withAnimation(.easeIn(duration: 0.15)) { isReady = true }
                ICloudSettingsSync.shared.start()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, !SleepBuddyApp.isTrackingActive {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    // MARK: - In-memory container (instant, ~1 ms)

    nonisolated static func makeInMemoryContainer() -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return (try? ModelContainer(
            for: SleepSession.self, SleepPhase.self, SleepSoundEvent.self, TrainingSample.self,
            configurations: config
        )) ?? try! ModelContainer(for: SleepSession.self, configurations: config)
    }

    // MARK: - Persistent container with CloudKit (runs off main thread)

    nonisolated static func makePersistentContainer() -> ModelContainer {
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

        let sleepFallback = ModelConfiguration(
            "SleepData",
            schema: Schema([SleepSession.self, SleepPhase.self, SleepSoundEvent.self]),
            cloudKitDatabase: .none
        )
        return try! ModelContainer(
            for: SleepSession.self, SleepPhase.self, SleepSoundEvent.self, TrainingSample.self,
            configurations: sleepFallback, localConfig
        )
    }

    static var isTrackingActive = false
}
