import SwiftUI
import SwiftData
import HealthKit

struct ProfilView: View {
    @AppStorage("profil_vorname") private var vorname: String = ""
    @AppStorage("profil_schlafziel") private var schlafZielStunden: Double = 8.0
    @AppStorage("profil_einschlafzeit_h") private var einschlafzeitH: Int = 23
    @AppStorage("profil_einschlafzeit_m") private var einschlafzeitM: Int = 0
    @AppStorage("profil_paindiary_verknuepft") private var painDiaryVerknuepft: Bool = false
    @AppStorage("profil_healthkit_aktiv") private var healthKitAktiv: Bool = false

    @State private var healthKitStatus: String = "Unbekannt"
    @State private var painDiaryLetzteSync: Date? = nil
    @State private var zeigeHealthKitInfo = false

    var body: some View {
        NavigationStack {
            List {
                schlafzielSektion
                painDiarySektion
                gesundheitSektion
                infoSektion
            }
            .navigationTitle("Profil")
            .navigationBarTitleDisplayMode(.large)
            .onAppear { pruefeHealthKit(); ladePainDiarySync() }
            .sheet(isPresented: $zeigeHealthKitInfo) { healthKitInfoSheet }
        }
    }

    // MARK: - Schlafziel

    private var schlafzielSektion: some View {
        Section("Schlafziel") {
            HStack {
                Label("Ziel-Schlafdauer", systemImage: "moon.stars.fill")
                    .foregroundStyle(.indigo)
                Spacer()
                Text(schlafZielFormatiert)
                    .foregroundStyle(.secondary)
            }
            Slider(value: $schlafZielStunden, in: 5...10, step: 0.5)
                .tint(.indigo)
                .padding(.vertical, 2)

            HStack {
                Label("Einschlafzeit", systemImage: "bed.double.fill")
                    .foregroundStyle(.indigo)
                Spacer()
                Picker("", selection: $einschlafzeitH) {
                    ForEach([18, 19, 20, 21, 22, 23, 0, 1, 2, 3], id: \.self) { h in
                        Text(String(format: "%02d", h)).tag(h)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                Text(":")
                Picker("", selection: $einschlafzeitM) {
                    ForEach([0, 15, 30, 45], id: \.self) { m in
                        Text(String(format: "%02d", m)).tag(m)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }

    private var schlafZielFormatiert: String {
        let h = Int(schlafZielStunden)
        let m = Int((schlafZielStunden - Double(h)) * 60)
        return m == 0 ? "\(h) Std." : "\(h) Std. \(m) Min."
    }

    // MARK: - PainDiary-Verknüpfung

    private var painDiarySektion: some View {
        Section {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(painDiaryVerknuepft ? Color.indigo.opacity(0.15) : Color.secondary.opacity(0.1))
                        .frame(width: 44, height: 44)
                    Image(systemName: painDiaryVerknuepft ? "link.circle.fill" : "link.circle")
                        .font(.title3)
                        .foregroundStyle(painDiaryVerknuepft ? .indigo : .secondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("PainDiary verbinden")
                        .font(.subheadline.bold())
                    if painDiaryVerknuepft {
                        Text(syncStatusText)
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Schlafqualität in PainDiary nutzen")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle("", isOn: $painDiaryVerknuepft)
                    .labelsHidden()
                    .tint(.indigo)
                    .onChange(of: painDiaryVerknuepft) { _, aktiv in
                        if aktiv { schreibePainDiaryDaten() }
                    }
            }

            if painDiaryVerknuepft {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(.indigo).font(.caption)
                    Text("SleepBuddy schreibt nach jeder Nacht die Schlafqualität (0–100) in eine geteilte App Group. PainDiary liest diesen Wert und zeigt die Schmerz-Schlaf-Korrelation.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("PainDiary-Verknüpfung")
        } footer: {
            if !painDiaryVerknuepft {
                Text("Voraussetzung: PainDiary muss auf demselben Gerät installiert sein.")
            }
        }
    }

    private var syncStatusText: String {
        guard let datum = painDiaryLetzteSync else { return "Noch keine Daten übertragen" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Zuletzt synchronisiert: \(formatter.localizedString(for: datum, relativeTo: Date()))"
    }

    // MARK: - Gesundheit (HealthKit)

    private var gesundheitSektion: some View {
        Section("Apple Health") {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(healthKitAktiv ? Color.pink.opacity(0.15) : Color.secondary.opacity(0.1))
                        .frame(width: 44, height: 44)
                    Image(systemName: "heart.fill")
                        .font(.title3)
                        .foregroundStyle(healthKitAktiv ? .pink : .secondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Schlafdaten in Health")
                        .font(.subheadline.bold())
                    Text(healthKitStatus)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    zeigeHealthKitInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Info

    private var infoSektion: some View {
        Section("Über SleepBuddy") {
            LabeledContent("Version") {
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Build") {
                Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–")
                    .foregroundStyle(.secondary)
            }
            Link(destination: URL(string: "https://github.com/doemu0992/SleepBuddy")!) {
                Label("Quellcode auf GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
            }
        }
    }

    // MARK: - HealthKit Info Sheet

    private var healthKitInfoSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(spacing: 8) {
                        Image(systemName: "heart.text.square.fill")
                            .font(.system(size: 40)).foregroundStyle(.pink)
                        Text("Apple Health Integration")
                            .font(.title3.bold())
                        Text("SleepBuddy schreibt deine Schlafdaten nach jeder aufgezeichneten Nacht in Apple Health.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 8)

                    VStack(alignment: .leading, spacing: 12) {
                        infoZeile(symbol: "moon.fill", text: "Schlafphasen (Tief, REM, Leicht, Wach)", farbe: .indigo)
                        infoZeile(symbol: "clock.fill", text: "Gesamtschlafdauer pro Nacht", farbe: .blue)
                        infoZeile(symbol: "mic.slash.fill", text: "Kein Audio wird gespeichert — nur Klassifikationen", farbe: .orange)
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal).padding(.vertical, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Apple Health")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { zeigeHealthKitInfo = false }
                }
            }
        }
    }

    private func infoZeile(symbol: String, text: String, farbe: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(farbe).frame(width: 20)
            Text(text).font(.subheadline)
        }
    }

    // MARK: - Logik

    private func pruefeHealthKit() {
        let store = HKHealthStore()
        guard HKHealthStore.isHealthDataAvailable() else {
            healthKitStatus = "Nicht verfügbar auf diesem Gerät"
            return
        }
        let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
        let status = store.authorizationStatus(for: type)
        switch status {
        case .sharingAuthorized:
            healthKitAktiv = true
            healthKitStatus = "Zugriff erteilt"
        case .sharingDenied:
            healthKitAktiv = false
            healthKitStatus = "Zugriff verweigert — in Einstellungen ändern"
        default:
            healthKitAktiv = false
            healthKitStatus = "Berechtigung noch nicht angefragt"
        }
    }

    private func ladePainDiarySync() {
        let defaults = UserDefaults(suiteName: "group.com.doemu0992.sleepbuddy")
        if let ts = defaults?.double(forKey: "lastNightSleepQualityTimestamp"), ts > 0 {
            painDiaryLetzteSync = Date(timeIntervalSince1970: ts)
        }
    }

    private func schreibePainDiaryDaten() {
        // Schreibt aktuell keine neuen Daten — passiert nach Schlafende.
        // Diese Funktion dient als Hook für zukünftige sofortige Sync-Logik.
    }
}
