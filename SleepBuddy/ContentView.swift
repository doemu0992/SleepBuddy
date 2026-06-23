import SwiftUI
import SwiftData

struct ContentView: View {
    @Query(sort: \SleepSession.startDate, order: .reverse) private var sessions: [SleepSession]

    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("Schlafen", systemImage: "moon.fill")
                }
            NavigationStack {
                SleepHistoryView()
            }
            .tabItem {
                Label("Verlauf", systemImage: "chart.bar.fill")
            }
            ProfilView()
                .tabItem {
                    Label("Profil", systemImage: "person.fill")
                }
        }
        .tint(.indigo)
        .onChange(of: sessions.count) { _, count in
            guard count > 0 else { return }
            autoSyncPainDiaryIfNeeded()
        }
        .task {
            // Delay allows CloudKit to deliver restored sessions first
            try? await Task.sleep(for: .seconds(3))
            autoSyncPainDiaryIfNeeded()
        }
    }

    // Re-exports all sessions when App Group data is empty (e.g. new device after reinstall)
    // but SwiftData has recovered sessions from CloudKit.
    private func autoSyncPainDiaryIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "profil_paindiary_verknuepft") else { return }
        let existing = SleepNightSummary.laden()
        let finished = sessions.filter { !$0.isActive && $0.totalDuration >= 1800 }
        guard finished.count > existing.count else { return }
        for session in finished {
            PainDiaryVerknuepfungView.exportiereSession(session)
        }
    }
}
