import SwiftUI
import AVFoundation

struct SleepTrackingView: View {
    @Bindable var viewModel: SleepTrackingViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showStopConfirmation = false
    @State private var showMicDeniedAlert = false
    @State private var elapsed: TimeInterval = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if viewModel.alarmFired {
                alarmRingingContent
            } else if viewModel.isTracking {
                trackingContent
            } else {
                startContent
            }
        }
        .onReceive(timer) { _ in
            if viewModel.isTracking { elapsed = viewModel.currentSession?.totalDuration ?? 0 }
        }
        .alert("Aufzeichnung beenden?", isPresented: $showStopConfirmation) {
            Button("Beenden", role: .destructive) {
                Task { await viewModel.stopTracking(); dismiss() }
            }
            Button("Weiter schlafen", role: .cancel) {}
        }
        .alert("Mikrofon-Zugriff verweigert", isPresented: $showMicDeniedAlert) {
            Button("Einstellungen öffnen") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("SleepBuddy benötigt Mikrofon-Zugriff. Bitte in den Einstellungen erlauben.")
        }
        .alert("Fehler", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.clearError() } }
        )) {
            Button("OK", role: .cancel) { viewModel.clearError() }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .task { await viewModel.requestHealthKitAccess() }
    }

    // MARK: - Start screen

    private var startContent: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "moon.stars.fill")
                .font(.system(size: 80))
                .foregroundStyle(.indigo)

            VStack(spacing: 8) {
                Text("Bereit zum Schlafen?")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                Text("Lege dein iPhone in der Nähe ab.\nKein Audio wird gespeichert.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.7))
                if viewModel.smartAlarm.isEnabled {
                    Label(alarmLabel, systemImage: "alarm.fill")
                        .font(.subheadline)
                        .foregroundStyle(.indigo)
                        .padding(.top, 4)
                }
            }

            Spacer()

            Button { requestMicAndStart() } label: {
                Text("Jetzt schlafen")
                    .font(.title3.bold()).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding()
                    .background(.indigo)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .padding(.horizontal, 32)

            Button("Abbrechen") { dismiss() }
                .foregroundStyle(.white.opacity(0.5))
                .padding(.bottom, 32)
        }
    }

    // MARK: - Active tracking screen

    private var trackingContent: some View {
        VStack(spacing: 0) {
            // Status bar indicators
            HStack(spacing: 10) {
                sleepOnsetBadge
                Spacer()
                heartRateBadge
                if viewModel.isSnoring {
                    Label("Schnarchen", systemImage: "waveform")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.orange.opacity(0.15))
                        .clipShape(Capsule())
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 56)
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: viewModel.isSnoring)
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: viewModel.liveHeartRateBPM)
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: viewModel.liveBCGHeartRateBPM)

            Spacer()

            // Phase circle
            ZStack {
                Circle()
                    .fill(viewModel.currentPhase.color.opacity(0.15))
                    .frame(width: 220, height: 220)
                Circle()
                    .fill(viewModel.currentPhase.color.opacity(0.30))
                    .frame(width: 165, height: 165)
                VStack(spacing: 8) {
                    Image(systemName: viewModel.currentPhase.icon)
                        .font(.system(size: 38))
                        .foregroundStyle(viewModel.currentPhase.color)
                    Text(viewModel.currentPhase.rawValue)
                        .font(.headline).foregroundStyle(.white)
                    Text(String(format: "%.0f%%", viewModel.currentConfidence * 100))
                        .font(.caption).foregroundStyle(.white.opacity(0.5))
                }
            }
            .animation(.spring(response: 0.6, dampingFraction: 0.7), value: viewModel.currentPhase)

            Spacer()

            // Timer
            Text(elapsed.formattedDuration)
                .font(.system(size: 52, weight: .thin, design: .monospaced))
                .foregroundStyle(.white)

            Text(viewModel.isSleepOnsetDetected ? "Schläfst seit \(sleepOnsetLabel)" : "Warte auf Einschlafen…")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
                .padding(.top, 4)

            Spacer()

            // Stop button
            Button { showStopConfirmation = true } label: {
                Label("Aufwachen", systemImage: "sun.horizon.fill")
                    .font(.title3.bold()).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding()
                    .background(.indigo.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
    }

    // MARK: - Smart alarm ringing

    private var alarmRingingContent: some View {
        VStack(spacing: 32) {
            Spacer()

            ZStack {
                ForEach(0..<3) { i in
                    Circle()
                        .stroke(Color.indigo.opacity(0.3 - Double(i) * 0.1), lineWidth: 2)
                        .frame(width: CGFloat(160 + i * 50), height: CGFloat(160 + i * 50))
                        .scaleEffect(1.0)
                        .animation(.easeInOut(duration: 1.5).repeatForever().delay(Double(i) * 0.4), value: viewModel.alarmFired)
                }
                Image(systemName: "alarm.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.indigo)
            }

            VStack(spacing: 8) {
                Text("Guten Morgen!")
                    .font(.largeTitle.bold()).foregroundStyle(.white)
                Text("Du bist gerade in einer Leichtschlafphase —\nder ideale Moment zum Aufwachen.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.7))
            }

            Spacer()

            Button {
                Task { await viewModel.dismissAlarm(); dismiss() }
            } label: {
                Text("Aufwachen")
                    .font(.title2.bold()).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding()
                    .background(.indigo)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
    }

    // MARK: - Helpers

    @ViewBuilder private var heartRateBadge: some View {
        if viewModel.liveHeartRateBPM > 0 {
            Label("\(Int(viewModel.liveHeartRateBPM)) BPM", systemImage: "heart.fill")
                .font(.caption.bold())
                .foregroundStyle(.pink)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.pink.opacity(0.15))
                .clipShape(Capsule())
                .transition(.scale.combined(with: .opacity))
        } else if viewModel.liveBCGHeartRateBPM > 0 {
            Label("\(Int(viewModel.liveBCGHeartRateBPM)) BPM", systemImage: "waveform.path.ecg")
                .font(.caption.bold())
                .foregroundStyle(.pink.opacity(0.7))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.pink.opacity(0.10))
                .clipShape(Capsule())
                .transition(.scale.combined(with: .opacity))
        }
    }

    private var sleepOnsetBadge: some View {
        Group {
            if viewModel.isSleepOnsetDetected {
                Label("Eingeschlafen", systemImage: "zzz")
                    .font(.caption.bold())
                    .foregroundStyle(.indigo)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.indigo.opacity(0.15))
                    .clipShape(Capsule())
            } else {
                Label("Warte auf Einschlafen", systemImage: "ellipsis")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
    }

    private var sleepOnsetLabel: String {
        guard let onset = viewModel.currentSession?.sleepOnsetDate else { return "–" }
        return onset.formatted(date: .omitted, time: .shortened)
    }

    private var alarmLabel: String {
        let alarm = viewModel.smartAlarm
        let fmt = DateFormatter(); fmt.timeStyle = .short
        return "Smart Alarm \(fmt.string(from: alarm.earliestWakeTime))–\(fmt.string(from: alarm.latestWakeTime))"
    }

    private func requestMicAndStart() {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                if granted { viewModel.startTracking() }
                else { showMicDeniedAlert = true }
            }
        }
    }
}
