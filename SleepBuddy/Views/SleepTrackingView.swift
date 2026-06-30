import SwiftUI
import AVFoundation

struct SleepTrackingView: View {
    @Bindable var viewModel: SleepTrackingViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showStopConfirmation = false
    @State private var showMicDeniedAlert = false
    @State private var elapsed: TimeInterval = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let navy = Color(red: 0.04, green: 0.06, blue: 0.16)

    /// Sanfter Nacht-Verlauf (oben etwas indigoer) statt flachem Navy.
    private var nightGradient: LinearGradient {
        LinearGradient(colors: [Color(red: 0.09, green: 0.10, blue: 0.26), navy],
                       startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        ZStack {
            nightGradient.ignoresSafeArea()

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
                Task { await viewModel.stopTracking() }
            }
            Button("Weiter schlafen", role: .cancel) {}
        }
        .onChange(of: viewModel.isTracking) { _, isTracking in
            if !isTracking { dismiss() }
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
    }

    // MARK: - Start screen

    private var startContent: some View {
        VStack(spacing: 32) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.indigo.opacity(0.25))
                    .frame(width: 190, height: 190)
                    .blur(radius: 65)
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            }

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
                Label("Jetzt schlafen", systemImage: "moon.stars.fill")
                    .font(.title3.bold()).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding()
                    .background(
                        LinearGradient(colors: [.indigo, .purple], startPoint: .leading, endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: 16)
                    )
                    .shadow(color: .indigo.opacity(0.45), radius: 14, x: 0, y: 8)
            }
            .padding(.horizontal, 32)

            Button("Abbrechen") { dismiss() }
                .foregroundStyle(.white.opacity(0.5))
                .padding(.bottom, 32)
        }
    }

    // MARK: - Active tracking screen (atmospheric, dark navy)

    private var trackingContent: some View {
        ZStack {
            // Ambient glow behind phase
            Circle()
                .fill(viewModel.currentPhase.color.opacity(0.08))
                .frame(width: 400, height: 400)
                .blur(radius: 80)
                .animation(.easeInOut(duration: 2), value: viewModel.currentPhase)

            VStack(spacing: 0) {
                // Top badges — only shown when there's something to display
                HStack(spacing: 10) {
                    if viewModel.isSleepOnsetDetected {
                        sleepOnsetBadge
                    }
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
                .padding(.top, 60)
                .animation(.spring(response: 0.4, dampingFraction: 0.7), value: viewModel.isSnoring)
                .animation(.spring(response: 0.4, dampingFraction: 0.7), value: viewModel.isSleepOnsetDetected)

                Spacer()

                // Large time display
                Text(Date(), style: .time)
                    .font(.system(size: 72, weight: .thin, design: .monospaced))
                    .foregroundStyle(.white)
                    .monospacedDigit()

                // Alarm subtitle
                if viewModel.smartAlarm.isEnabled {
                    HStack(spacing: 6) {
                        Image(systemName: "alarm.fill")
                            .font(.caption)
                        Text("Weckt um \(alarmLabel)")
                            .font(.subheadline)
                    }
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 6)
                }

                Spacer()

                // Phase capsule
                HStack(spacing: 8) {
                    Image(systemName: viewModel.currentPhase.icon)
                        .font(.caption.bold())
                    Text(viewModel.currentPhase.rawValue)
                        .font(.caption.bold())
                    Text("·")
                        .foregroundStyle(.white.opacity(0.3))
                    Text(elapsed.formattedDuration)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .foregroundStyle(viewModel.currentPhase.color)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(viewModel.currentPhase.color.opacity(0.12), in: Capsule())
                .overlay(Capsule().strokeBorder(viewModel.currentPhase.color.opacity(0.25), lineWidth: 1))
                .animation(.spring(response: 0.6, dampingFraction: 0.7), value: viewModel.currentPhase)

                Spacer()

                // Beenden button
                Button { showStopConfirmation = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sun.horizon.fill")
                            .font(.body.bold())
                        Text("Aufwachen")
                            .font(.title3.bold())
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(
                        LinearGradient(
                            colors: [.indigo.opacity(0.6), .purple.opacity(0.5)],
                            startPoint: .leading, endPoint: .trailing
                        ),
                        in: RoundedRectangle(cornerRadius: 20)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                    )
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 52)
            }
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
                if viewModel.smartAlarm.snoozeCount > 0 {
                    Text("Snooze \(viewModel.smartAlarm.snoozeCount)×")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }

            Spacer()

            VStack(spacing: 12) {
                Button {
                    Task { await viewModel.dismissAlarm() }
                } label: {
                    Label("Aufwachen", systemImage: "sun.horizon.fill")
                        .font(.title2.bold()).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding()
                        .background(
                            LinearGradient(colors: [.indigo, .purple], startPoint: .leading, endPoint: .trailing),
                            in: RoundedRectangle(cornerRadius: 16)
                        )
                        .shadow(color: .indigo.opacity(0.45), radius: 14, x: 0, y: 8)
                }

                if viewModel.smartAlarm.snoozeCount < 3 {
                    Button {
                        viewModel.snoozeAlarm()
                    } label: {
                        Label("5 Min Snooze", systemImage: "moon.zzz.fill")
                            .font(.subheadline.bold())
                            .foregroundStyle(.indigo)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(.indigo.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }
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
        let fmt = DateFormatter(); fmt.timeStyle = .short
        return fmt.string(from: viewModel.smartAlarm.latestWakeTime)
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
