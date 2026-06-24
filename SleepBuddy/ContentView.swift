import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SleepSession.startDate, order: .reverse) private var sessions: [SleepSession]

    @State private var selectedTab: Tab = .statistik
    @State private var trackingViewModel = SleepTrackingViewModel()
    @State private var showTracking = false

    enum Tab { case statistik, profil }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch selectedTab {
                case .statistik:
                    StatistikView()
                case .profil:
                    ProfilView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            customTabBar
        }
        .ignoresSafeArea(.keyboard)
        .tint(.indigo)
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
        .onChange(of: sessions.count) { _, count in
            guard count > 0 else { return }
            autoSyncPainDiaryIfNeeded()
        }
        .task {
            try? await Task.sleep(for: .seconds(3))
            autoSyncPainDiaryIfNeeded()
        }
    }

    // MARK: - Custom Tab Bar

    private var customTabBar: some View {
        HStack(spacing: 0) {
            tabButton(icon: "chart.bar.fill", label: "Statistik", tab: .statistik)

            // Center: Tracker starten
            Button {
                showTracking = true
            } label: {
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
            .offset(y: -8)
            .frame(maxWidth: .infinity)

            tabButton(icon: "person.fill", label: "Profil", tab: .profil)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea(edges: .bottom)
                .shadow(color: Color.primary.opacity(0.08), radius: 20, x: 0, y: -4)
        )
    }

    private func tabButton(icon: String, label: String, tab: Tab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(selectedTab == tab ? .indigo : .secondary)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(selectedTab == tab ? .indigo : .secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
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
