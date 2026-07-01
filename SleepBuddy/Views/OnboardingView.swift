import SwiftUI
import AVFoundation
import HealthKit
import UserNotifications

struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var step = 0
    @State private var sleepGoalHours: Double = 8.0
    @State private var micGranted = false
    @State private var healthGranted = false
    @State private var notifGranted = false
    @State private var requestingMic = false
    @State private var requestingHealth = false
    @State private var requestingNotif = false
    @State private var partnerModusAktiv = false
    @AppStorage("partnerModus_aktiv") private var partnerModusGespeichert = false
    @AppStorage("partnerModus_stufe") private var partnerModusStufe = 1

    private let navy = Color(red: 0.04, green: 0.06, blue: 0.16)
    private let totalSteps = 8

    /// Sanfter Nacht-Verlauf (oben indigoer → navy) — identisch zum Tracking-Screen.
    private var nightGradient: LinearGradient {
        LinearGradient(colors: [Color(red: 0.09, green: 0.10, blue: 0.26), navy],
                       startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        ZStack {
            nightGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                // Progress dots
                HStack(spacing: 8) {
                    ForEach(0..<totalSteps, id: \.self) { i in
                        Capsule()
                            .fill(i == step ? Color.white : Color.white.opacity(0.25))
                            .frame(width: i == step ? 24 : 8, height: 8)
                            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: step)
                    }
                }
                .padding(.top, 60)
                .padding(.bottom, 8)

                // Skip button (only for permission/optional steps)
                HStack {
                    Spacer()
                    if [3, 4, 5, 6].contains(step) {
                        Button("Überspringen") { advance() }
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.trailing, 24)
                    }
                }
                .frame(height: 32)

                Spacer()

                stepContent
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                    .id(step)

                Spacer()

                nextButton
                    .padding(.horizontal, 32)
                    .padding(.bottom, 52)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Step content

    @ViewBuilder private var stepContent: some View {
        switch step {
        case 0: welcomeStep
        case 1: placementStep
        case 2: featuresStep
        case 3: micStep
        case 4: healthStep
        case 5: notifStep
        case 6: partnerModusStep
        case 7: goalStep
        default: EmptyView()
        }
    }

    // Step 0: Welcome
    private var welcomeStep: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.indigo.opacity(0.25))
                    .frame(width: 190, height: 190)
                    .blur(radius: 65)
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .padding(.bottom, 8)

            Text("Willkommen bei\nSleepBuddy")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)

            Text("Automatische Schlafphasen-Erkennung — ohne Apple Watch. Nur dein iPhone und ein paar Sekunden Setup.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 16)
        }
        .padding(.horizontal, 24)
    }

    // Step 1: Placement guide
    private var placementStep: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle().fill(Color.indigo.opacity(0.25)).frame(width: 150, height: 150).blur(radius: 55)
                Image(systemName: "bed.double.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            }

            Text("Handy richtig platzieren")
                .font(.title.bold())
                .foregroundStyle(.white)

            VStack(spacing: 12) {
                // Wichtigster Punkt — hervorgehoben.
                placementRow(icon: "bed.double.fill",
                             text: "Lege dein iPhone auf die Matratze, nahe am Kopfkissen — so erkennt es deine Bewegungen am besten",
                             highlight: true)
                placementRow(icon: "speaker.wave.2.fill", text: "Display/Lautsprecher nach oben")
                placementRow(icon: "cable.connector", text: "Angeschlossen lassen — Tracking läuft die ganze Nacht")
                placementRow(icon: "wifi", text: "WLAN aktiv lassen für optimale Synchronisation")
            }
        }
        .padding(.horizontal, 24)
    }

    private func placementRow(icon: String, text: String, highlight: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(highlight ? AnyShapeStyle(LinearGradient(colors: [.indigo, .purple], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Color.indigo))
                .frame(width: 28)
            Text(text)
                .font(highlight ? .subheadline.bold() : .subheadline)
                .foregroundStyle(highlight ? .white : .white.opacity(0.8))
                .multilineTextAlignment(.leading)
            Spacer()
        }
        .padding(14)
        .background(
            (highlight ? Color.indigo.opacity(0.18) : Color.white.opacity(0.05)),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(highlight ? Color.indigo.opacity(0.5) : Color.clear, lineWidth: 1)
        )
    }

    // Step 2: Features
    private var featuresStep: some View {
        VStack(spacing: 28) {
            Text("Was SleepBuddy misst")
                .font(.title.bold())
                .foregroundStyle(.white)

            VStack(spacing: 16) {
                featureRow(icon: "waveform.path.ecg", color: .indigo,
                           title: "Schlafphasen", sub: "Tief-, REM-, Leicht- & Wachphasen automatisch erkannt")
                featureRow(icon: "alarm.fill", color: .purple,
                           title: "Smart Alarm", sub: "Weckt dich sanft in der Leichtschlafphase")
                featureRow(icon: "waveform", color: .orange,
                           title: "Schnarchen erkennen", sub: "Schnarchigereignisse werden gezählt")
                featureRow(icon: "heart.fill", color: .pink,
                           title: "Herzrate (BCG)", sub: "Herzrate aus Bett-Bewegungen ohne Watch")
                featureRow(icon: "chart.bar.fill", color: .cyan,
                           title: "Schlafindex", sub: "Gesamtbewertung deiner Nacht")
            }
        }
        .padding(.horizontal, 24)
    }

    private func featureRow(icon: String, color: Color, title: String, sub: String) -> some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(color.opacity(0.18)).frame(width: 44, height: 44)
                Image(systemName: icon).foregroundStyle(color).font(.body)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold()).foregroundStyle(.white)
                Text(sub).font(.caption).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
        }
    }

    /// Hero-Icon mit weichem Glow (Blur-Kreis + Symbol-Schatten) — neues Nacht-Design.
    private func glowIcon(_ systemName: String, color: Color, granted: Bool) -> some View {
        let c = granted ? Color.green : color
        return ZStack {
            Circle().fill(c.opacity(0.35)).frame(width: 150, height: 150).blur(radius: 55)
            Image(systemName: granted ? "checkmark.circle.fill" : systemName)
                .font(.system(size: 60))
                .foregroundStyle(c)
                .shadow(color: c.opacity(0.6), radius: 14)
        }
    }

    // Step 3: Microphone
    private var micStep: some View {
        VStack(spacing: 28) {
            glowIcon("mic.fill", color: .orange, granted: micGranted)

            Text("Mikrofon-Zugriff")
                .font(.title.bold()).foregroundStyle(.white)

            Text("SleepBuddy analysiert deine Atemgeräusche lokal auf deinem Gerät — kein Audio wird gespeichert oder übertragen.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 8)

            if micGranted {
                Label("Zugriff erteilt", systemImage: "checkmark")
                    .font(.subheadline.bold())
                    .foregroundStyle(.green)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(.green.opacity(0.12), in: Capsule())
            } else {
                Button {
                    requestMic()
                } label: {
                    Label(requestingMic ? "Warte…" : "Mikrofon erlauben", systemImage: "mic.fill")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.orange, in: RoundedRectangle(cornerRadius: 12))
                }
                .disabled(requestingMic)
            }
        }
        .padding(.horizontal, 24)
    }

    // Step 4: HealthKit
    private var healthStep: some View {
        VStack(spacing: 28) {
            glowIcon("heart.fill", color: .pink, granted: healthGranted)

            Text("Apple Health")
                .font(.title.bold()).foregroundStyle(.white)

            Text("Deine Schlafdaten werden in Apple Health gespeichert. So hast du alle Gesundheitsdaten an einem Ort.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 8)

            if healthGranted {
                Label("Zugriff erteilt", systemImage: "checkmark")
                    .font(.subheadline.bold())
                    .foregroundStyle(.green)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(.green.opacity(0.12), in: Capsule())
            } else {
                Button {
                    requestHealth()
                } label: {
                    Label(requestingHealth ? "Warte…" : "Health verbinden", systemImage: "heart.fill")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.pink, in: RoundedRectangle(cornerRadius: 12))
                }
                .disabled(requestingHealth)
            }
        }
        .padding(.horizontal, 24)
    }

    // Step 5: Notifications
    private var notifStep: some View {
        VStack(spacing: 28) {
            glowIcon("bell.fill", color: .yellow, granted: notifGranted)

            Text("Benachrichtigungen")
                .font(.title.bold()).foregroundStyle(.white)

            Text("Erhalte tägliche Schlaferinnerungen und Alarm-Benachrichtigungen für deinen Smart Alarm.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 8)

            if notifGranted {
                Label("Zugriff erteilt", systemImage: "checkmark")
                    .font(.subheadline.bold())
                    .foregroundStyle(.green)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(.green.opacity(0.12), in: Capsule())
            } else {
                Button {
                    requestNotifications()
                } label: {
                    Label(requestingNotif ? "Warte…" : "Benachrichtigungen erlauben", systemImage: "bell.fill")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.yellow.opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
                }
                .disabled(requestingNotif)
            }
        }
        .padding(.horizontal, 24)
    }

    // Step 6: Partnermodus
    private var partnerModusStep: some View {
        VStack(spacing: 28) {
            glowIcon("person.2.fill", color: .purple, granted: false)

            Text("Partnermodus")
                .font(.title.bold()).foregroundStyle(.white)

            Text("Schläfst du nicht alleine? Dann passe die Mikrofon-Empfindlichkeit an, damit SleepBuddy nur dich aufzeichnet.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 8)

            VStack(spacing: 12) {
                Toggle(isOn: $partnerModusAktiv) {
                    Label("Partnermodus aktivieren", systemImage: "person.2.fill")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                }
                .tint(.purple)
                .padding()
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))

                if partnerModusAktiv {
                    VStack(spacing: 8) {
                        partnerStufeButton(stufe: 1, icon: "iphone.and.arrow.forward", title: "Stufe 1 – Nebeneinander", sub: "iPhone liegt zwischen euch oder sehr nah am eigenen Kissen")
                        partnerStufeButton(stufe: 2, icon: "person.2.wave.2.fill", title: "Stufe 2 – Wenig Abstand", sub: "Partner liegt direkt daneben, iPhone am eigenen Kissen")
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .onChange(of: partnerModusAktiv) { _, val in
            partnerModusGespeichert = val
        }
        .onChange(of: partnerModusStufe) { _, _ in }
    }

    private func partnerStufeButton(stufe: Int, icon: String, title: String, sub: String) -> some View {
        let selected = partnerModusStufe == stufe
        return Button { partnerModusStufe = stufe } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .foregroundStyle(selected ? .purple : .white.opacity(0.5))
                    .frame(width: 28)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.bold())
                        .foregroundStyle(selected ? .white : .white.opacity(0.6))
                    Text(sub)
                        .font(.caption)
                        .foregroundStyle(selected ? .white.opacity(0.8) : .white.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.purple)
                        .padding(.top, 2)
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(selected ? Color.purple.opacity(0.2) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? Color.purple.opacity(0.6) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // Step 7: Sleep goal
    private var goalStep: some View {
        VStack(spacing: 28) {
            ZStack {
                Circle().fill(Color.indigo.opacity(0.3)).frame(width: 150, height: 150).blur(radius: 55)
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            }

            Text("Dein Schlafdauer-Ziel")
                .font(.title.bold()).foregroundStyle(.white)

            Text("Wie viele Stunden Schlaf möchtest du pro Nacht erreichen?")
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 8)

            VStack(spacing: 12) {
                Text(String(format: "%.1f Stunden", sleepGoalHours))
                    .font(.system(size: 48, weight: .thin, design: .rounded))
                    .foregroundStyle(.white)

                Slider(value: $sleepGoalHours, in: 4...12, step: 0.5)
                    .tint(.indigo)
                    .padding(.horizontal, 8)

                HStack {
                    Text("4 h").font(.caption).foregroundStyle(.white.opacity(0.4))
                    Spacer()
                    Text("12 h").font(.caption).foregroundStyle(.white.opacity(0.4))
                }
                .padding(.horizontal, 8)
            }
            .padding()
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Next button

    private var nextButton: some View {
        Button {
            if step == totalSteps - 1 {
                UserDefaults.standard.set(sleepGoalHours, forKey: "schlafZielStunden")
                partnerModusGespeichert = partnerModusAktiv
                onComplete()
            } else {
                advance()
            }
        } label: {
            Text(step == totalSteps - 1 ? "Los geht's!" : "Weiter")
                .font(.title3.bold())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(
                    LinearGradient(colors: [.indigo, .purple], startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: 16)
                )
                .shadow(color: .indigo.opacity(0.4), radius: 12, x: 0, y: 4)
        }
    }

    // MARK: - Helpers

    private func advance() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            step = min(step + 1, totalSteps - 1)
        }
    }

    private func requestMic() {
        requestingMic = true
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                micGranted = granted
                requestingMic = false
                if granted { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { advance() } }
            }
        }
    }

    private func requestHealth() {
        requestingHealth = true
        let hk = HKHealthStore()
        guard HKHealthStore.isHealthDataAvailable() else {
            requestingHealth = false
            healthGranted = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { advance() }
            return
        }
        let writeTypes: Set<HKSampleType> = [
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
        ]
        let readTypes: Set<HKObjectType> = [
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!,
            HKObjectType.quantityType(forIdentifier: .heartRate)!,
            HKObjectType.quantityType(forIdentifier: .oxygenSaturation)!,
            HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!
        ]
        hk.requestAuthorization(toShare: writeTypes, read: readTypes) { success, _ in
            DispatchQueue.main.async {
                healthGranted = success
                requestingHealth = false
                if success { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { advance() } }
            }
        }
    }

    private func requestNotifications() {
        requestingNotif = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                notifGranted = granted
                requestingNotif = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { advance() }
            }
        }
    }
}
