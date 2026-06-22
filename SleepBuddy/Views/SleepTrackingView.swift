import SwiftUI

struct SleepTrackingView: View {
    @Bindable var viewModel: SleepTrackingViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showStopConfirmation = false
    @State private var elapsed: TimeInterval = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if viewModel.isTracking {
                trackingContent
            } else {
                startContent
            }
        }
        .onReceive(timer) { _ in
            if viewModel.isTracking {
                elapsed = viewModel.currentSession?.totalDuration ?? 0
            }
        }
        .alert("Aufzeichnung beenden?", isPresented: $showStopConfirmation) {
            Button("Beenden", role: .destructive) {
                Task { await stopAndDismiss() }
            }
            Button("Weiter schlafen", role: .cancel) {}
        }
        .task {
            await viewModel.requestHealthKitAccess()
        }
    }

    private var startContent: some View {
        VStack(spacing: 32) {
            Spacer()
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 80))
                .foregroundStyle(.indigo)

            Text("Bereit zum Schlafen?")
                .font(.largeTitle.bold())
                .foregroundStyle(.white)

            Text("Lege dein iPhone in der Nähe ab.\nKein Audio wird gespeichert.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.7))

            Spacer()

            Button {
                viewModel.startTracking()
            } label: {
                Text("Jetzt schlafen")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.indigo)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .padding(.horizontal, 32)

            Button("Abbrechen") { dismiss() }
                .foregroundStyle(.white.opacity(0.5))
                .padding(.bottom, 32)
        }
    }

    private var trackingContent: some View {
        VStack(spacing: 32) {
            Spacer()

            // Pulsing phase indicator
            ZStack {
                Circle()
                    .fill(viewModel.currentPhase.color.opacity(0.2))
                    .frame(width: 200, height: 200)

                Circle()
                    .fill(viewModel.currentPhase.color.opacity(0.4))
                    .frame(width: 150, height: 150)

                VStack(spacing: 8) {
                    Image(systemName: viewModel.currentPhase.icon)
                        .font(.system(size: 36))
                        .foregroundStyle(viewModel.currentPhase.color)
                    Text(viewModel.currentPhase.rawValue)
                        .font(.headline)
                        .foregroundStyle(.white)
                }
            }
            .animation(.spring(response: 0.6, dampingFraction: 0.7), value: viewModel.currentPhase)

            Text(elapsed.formattedDuration)
                .font(.system(size: 48, weight: .thin, design: .monospaced))
                .foregroundStyle(.white)

            Text("Aufzeichnung läuft...")
                .foregroundStyle(.white.opacity(0.5))

            Spacer()

            Button {
                showStopConfirmation = true
            } label: {
                Label("Aufwachen", systemImage: "sun.horizon.fill")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.indigo.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
    }

    private func stopAndDismiss() async {
        await viewModel.stopTracking()
        dismiss()
    }
}
