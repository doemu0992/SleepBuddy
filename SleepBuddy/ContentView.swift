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
            NavigationStack { HomeView() }
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(0)

            NavigationStack { StatistikView() }
                .tabItem { Label("Statistik", systemImage: "chart.bar.fill") }
                .tag(1)

            Color.clear
                .tabItem { Label(" ", systemImage: "moon.stars.fill") }
                .tag(2)

            NavigationStack { ProfilView() }
                .tabItem { Label("Profil", systemImage: "person.fill") }
                .tag(3)
        }
        .tint(.indigo)
        .overlay(alignment: .bottom) {
            Button { showTracking = true } label: {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: trackingViewModel.isTracking ? [.purple, .indigo] : [.indigo, .purple],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 54, height: 54)
                        .shadow(color: .indigo.opacity(0.5), radius: 8, x: 0, y: 4)
                    Image(systemName: trackingViewModel.isTracking ? "waveform" : "moon.stars.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.bottom, 4)
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
            if tab == 2 {
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
