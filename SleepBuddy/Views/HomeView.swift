import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SleepSession.startDate, order: .reverse) private var sessions: [SleepSession]

    @State private var viewModel = HomeViewModel()
    @State private var trackingViewModel = SleepTrackingViewModel()
    @State private var showAlarmSetup = false

    private var lastSession: SleepSession? { sessions.first(where: { !$0.isActive }) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    sleepButton
                    smartAlarmCard
                    if let session = lastSession {
                        lastNightCard(session)
                    }
                    if trackingViewModel.classifier.sampleCount > 0 {
                        learningStatusCard
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("SleepBuddy")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(destination: SleepHistoryView()) {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                }
            }
            .fullScreenCover(isPresented: $viewModel.showTrackingSheet) {
                SleepTrackingView(viewModel: trackingViewModel)
            }
            .sheet(isPresented: $showAlarmSetup) {
                AlarmSetupSheet(alarm: trackingViewModel.smartAlarm)
            }
            .onAppear {
                trackingViewModel.configure(modelContext: modelContext)
            }
            .task {
                await trackingViewModel.requestAlarmPermission()
            }
        }
    }

    // MARK: - Sleep button

    private var sleepButton: some View {
        Button { viewModel.startSleep() } label: {
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
                if trackingViewModel.smartAlarm.isEnabled {
                    Label(alarmTimeLabel, systemImage: "alarm.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(.white.opacity(0.2))
                        .clipShape(Capsule())
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity)
            .background(LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: 24))
        }
        .buttonStyle(.plain)
    }

    private var alarmTimeLabel: String {
        let alarm = trackingViewModel.smartAlarm
        let fmt = DateFormatter()
        fmt.timeStyle = .short
        return "Smart Alarm \(fmt.string(from: alarm.earliestWakeTime))–\(fmt.string(from: alarm.latestWakeTime))"
    }

    // MARK: - Smart Alarm card

    private var smartAlarmCard: some View {
        let alarm = trackingViewModel.smartAlarm
        return Button { showAlarmSetup = true } label: {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(alarm.isEnabled ? Color.indigo.opacity(0.15) : Color.secondary.opacity(0.1))
                        .frame(width: 44, height: 44)
                    Image(systemName: alarm.isEnabled ? "alarm.fill" : "alarm")
                        .foregroundStyle(alarm.isEnabled ? .indigo : .secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Smart Alarm")
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                    Text(alarm.isEnabled ? alarmTimeLabel : "Weckt dich in der Leichtschlafphase")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Bindable(alarm).isEnabled)
                    .labelsHidden()
                    .tint(.indigo)
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Last night card

    private func lastNightCard(_ session: SleepSession) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Letzte Nacht", systemImage: "moon.stars.fill")
                .font(.headline).foregroundStyle(.indigo)

            HStack(spacing: 20) {
                statView(icon: "clock.fill", value: session.totalDuration.formattedDuration, label: "Schlafdauer", color: .indigo)
                Divider()
                statView(icon: "star.fill", value: "\(Int(session.computedQualityScore))%", label: "Qualität", color: .purple)
                Divider()
                statView(icon: "moon.fill", value: session.deepSleepDuration.formattedDuration, label: "Tiefschlaf", color: .blue)
            }

            if let latency = session.sleepOnsetLatency {
                HStack {
                    Image(systemName: "zzz").foregroundStyle(.indigo).font(.caption)
                    Text("Einschlafen nach \(formatMinutes(latency))")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if session.snoringEventCount > 0 {
                        Label("\(session.snoringEventCount)× Schnarchen", systemImage: "waveform")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
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
        .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
    }

    // MARK: - Learning status

    private var learningStatusCard: some View {
        let count = trackingViewModel.classifier.sampleCount
        let isML = count >= 40
        return HStack(spacing: 12) {
            Image(systemName: isML ? "brain.fill" : "brain")
                .foregroundStyle(isML ? .indigo : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(isML ? "KI aktiv" : "KI lernt noch")
                    .font(.caption.bold())
                    .foregroundStyle(isML ? .indigo : .secondary)
                Text(isML ? "\(count) Messwerte — Klassifikator personalisiert"
                          : "\(count)/40 Messwerte bis zur KI-Klassifikation")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !isML {
                ProgressView(value: Double(count), total: 40)
                    .tint(.indigo)
                    .frame(width: 60)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.indigo)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
    }

    // MARK: - Helpers

    private func statView(icon: String, value: String, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(color)
            Text(value).font(.title3.bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func formatMinutes(_ interval: TimeInterval) -> String {
        let m = Int(interval / 60)
        return m < 60 ? "\(m) min" : "\(m / 60)h \(m % 60)min"
    }
}

// MARK: - AlarmSetupSheet

struct AlarmSetupSheet: View {
    @Bindable var alarm: SmartAlarmService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 8) {
                        Image(systemName: "alarm.fill")
                            .font(.system(size: 32)).foregroundStyle(.indigo)
                        Text("Smart Alarm")
                            .font(.title3.bold())
                        Text("Weckt dich im optimalen Leichtschlafmoment innerhalb deines Zeitfensters.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.bottom, 4)

                    VStack(spacing: 0) {
                        Toggle("Smart Alarm aktivieren", isOn: $alarm.isEnabled)
                            .tint(.indigo)
                            .font(.subheadline)
                            .padding(16)
                    }
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))

                    if alarm.isEnabled {
                        VStack(spacing: 0) {
                            DatePicker("Frühestens", selection: $alarm.earliestWakeTime, displayedComponents: .hourAndMinute)
                                .font(.subheadline).padding(16)
                            Divider().padding(.leading, 16)
                            DatePicker("Spätestens", selection: $alarm.latestWakeTime, displayedComponents: .hourAndMinute)
                                .font(.subheadline).padding(16)
                        }
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))

                        HStack(spacing: 10) {
                            Image(systemName: "info.circle").foregroundStyle(.indigo)
                            Text("Der Alarm klingt sobald eine Leichtschlafphase im Fenster erkannt wird. Spätestens zum letzten Zeitpunkt wirst du geweckt.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(.horizontal).padding(.vertical, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Smart Alarm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }
}
