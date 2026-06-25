import SwiftUI
import SwiftData
import AVFoundation

@main
struct SleepBuddyApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("onboarding_complete") private var onboardingComplete = false

    // Container starts nil — built async so main thread is never blocked at launch.
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
                // Splash while container initialises in background (~0.3–2 s)
                splashView
                    .task { await buildContainer() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, !SleepBuddyApp.isTrackingActive {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    // MARK: - Splash

    private var splashView: some View {
        ZStack {
            Color(red: 0.04, green: 0.06, blue: 0.16).ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.indigo)
                ProgressView()
                    .tint(.indigo.opacity(0.6))
            }
        }
    }

    // MARK: - Async container build (background thread, never blocks main)

    @MainActor
    private func buildContainer() async {
        let container = await Task.detached(priority: .userInitiated) {
            Self.makeContainer()
        }.value
        modelContainer = container
    }

    private static func makeContainer() -> ModelContainer {
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
