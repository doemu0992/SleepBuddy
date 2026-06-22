import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SleepSession.startDate, order: .reverse) private var sessions: [SleepSession]

    @State private var viewModel = HomeViewModel()
    @State private var trackingViewModel = SleepTrackingViewModel()

    private var lastSession: SleepSession? { sessions.first(where: { !$0.isActive }) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    sleepButton
                    if let session = lastSession {
                        lastNightCard(session)
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("SleepBuddy")
            .fullScreenCover(isPresented: $viewModel.showTrackingSheet) {
                SleepTrackingView(viewModel: trackingViewModel)
            }
            .onAppear {
                trackingViewModel.configure(modelContext: modelContext)
            }
        }
    }

    private var sleepButton: some View {
        Button {
            viewModel.startSleep()
        } label: {
            VStack(spacing: 12) {
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.white)
                Text("Schlafen starten")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text("Schlafphasen werden automatisch erkannt")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(32)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(
                    colors: [.indigo, .purple],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 24))
        }
        .buttonStyle(.plain)
    }

    private func lastNightCard(_ session: SleepSession) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Letzte Nacht")
                .font(.headline)
                .foregroundStyle(.secondary)

            HStack(spacing: 20) {
                statView(
                    icon: "clock.fill",
                    value: session.totalDuration.formattedDuration,
                    label: "Schlafdauer",
                    color: .indigo
                )
                Divider()
                statView(
                    icon: "star.fill",
                    value: "\(Int(session.computedQualityScore))%",
                    label: "Qualität",
                    color: .purple
                )
                Divider()
                statView(
                    icon: "moon.fill",
                    value: session.deepSleepDuration.formattedDuration,
                    label: "Tiefschlaf",
                    color: .blue
                )
            }

            if !session.phases.isEmpty {
                SleepPhaseBarView(phases: session.phases, totalDuration: session.totalDuration)
                    .frame(height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func statView(icon: String, value: String, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(color)
            Text(value).font(.title3.bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
