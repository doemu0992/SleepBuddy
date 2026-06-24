import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SleepSession.startDate, order: .reverse) private var sessions: [SleepSession]

    @State private var selectedTab = 0
    @State private var trackingViewModel = SleepTrackingViewModel()
    @State private var showTracking = false

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { StatistikView() }
                .tabItem { Label("Statistik", systemImage: "chart.bar.fill") }
                .tag(0)

            Color.clear
                .tabItem { Label(" ", systemImage: "moon.stars.fill") }
                .tag(1)

            NavigationStack { ProfilView() }
                .tabItem { Label("Profil", systemImage: "person.fill") }
                .tag(2)
        }
        .tint(.indigo)
        .overlay(alignment: .bottom) {
            Button { showTracking = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: trackingViewModel.isTracking ? "waveform" : "moon.stars.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text(trackingViewModel.isTracking ? "Läuft…" : "Tracker starten")
                        .font(.subheadline.bold())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: trackingViewModel.isTracking ? [.purple, .indigo] : [.indigo, .purple],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .shadow(color: .indigo.opacity(0.4), radius: 10, x: 0, y: 4)
                )
            }
            .padding(.bottom, 52)
        }
        .fullScreenCover(isPresented: $showTracking) {
            SleepTrackingView(viewModel: trackingViewModel)
        }
        .onAppear {
            trackingViewModel.configure(modelContext: modelContext)
        }
        .task {
            await trackingViewModel.requestAlarmPermission()
            await trackingViewModel.requestHealthKitAccess()
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == 1 {
                showTracking = true
                selectedTab = 0
            }
        }
        .onChange(of: sessions.count) { _, count in
            guard count > 0 else { return }
            autoSyncPainDiaryIfNeeded()
        }
        .task {
            try? await Task.sleep(for: .seconds(3))
            autoSyncPainDiaryIfNeeded()
        }
    }

    // MARK: - PainDiary sync

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
