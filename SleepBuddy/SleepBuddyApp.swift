import SwiftUI
import SwiftData
import AVFoundation

// Starts container build before SwiftUI loads — maximum head start.
private let _containerTask = Task.detached(priority: .userInitiated) {
    SleepBuddyApp.makeContainer()
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
                        modelContainer = await _containerTask.value
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

    nonisolated static func makeContainer() -> ModelContainer {
        let schema = Schema([
            SleepSession.self, SleepPhase.self, SleepSoundEvent.self, TrainingSample.self
        ])

        guard let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return try! ModelContainer(for: schema, configurations: [
                ModelConfiguration("sleepdata", schema: schema,
                                   isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            ])
        }

        let url = dir.appendingPathComponent("sleepdata.store")

        // Attempt 1: CloudKit sync
        let cloud = ModelConfiguration("sleepdata", schema: schema, url: url, cloudKitDatabase: .automatic)
        if let c = try? ModelContainer(for: schema, configurations: [cloud]) { return c }

        // Attempt 2: Local only
        let local = ModelConfiguration("sleepdata", schema: schema, url: url, cloudKitDatabase: .none)
        if let c = try? ModelContainer(for: schema, configurations: [local]) { return c }

        // Attempt 3: Delete corrupt store, retry
        for name in ["sleepdata.store", "sleepdata.store-shm", "sleepdata.store-wal"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        if let c = try? ModelContainer(for: schema, configurations: [cloud]) { return c }
        if let c = try? ModelContainer(for: schema, configurations: [local]) { return c }

        // Last resort: in-memory (app always starts)
        return try! ModelContainer(for: schema, configurations: [
            ModelConfiguration("sleepdata", schema: schema,
                               isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
    }

    static var isTrackingActive = false
}
