import SwiftUI
import SwiftData
import AVFoundation

// Starts building the container the moment the module loads — before any SwiftUI body runs.
private let _earlyContainerTask = Task.detached(priority: .userInitiated) {
    SleepBuddyApp.makeContainer()
}

@main
struct SleepBuddyApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("onboarding_complete") private var onboardingComplete = false

    @State private var modelContainer: ModelContainer?

    private static let containerID = "iCloud.DG-Software-Solution.PainDiary"

    var body: some Scene {
        WindowGroup {
            if let container = modelContainer {
                Group {
                    if onboardingComplete {
                        ContentView()
                            .onAppear { ICloudSettingsSync.shared.start() }
                    } else {
                        OnboardingView { onboardingComplete = true }
                    }
                }
                .modelContainer(container)
            } else {
                Color(.systemBackground)
                    .ignoresSafeArea()
                    .task {
                        modelContainer = await _earlyContainerTask.value
                    }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, !SleepBuddyApp.isTrackingActive {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    // MARK: - Container build (nonisolated so Task.detached can call it)

    nonisolated static func makeContainer() -> ModelContainer {
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

        // Fallback without CloudKit — data stays accessible, sync resumes on next success
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
