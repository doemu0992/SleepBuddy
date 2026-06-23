import SwiftUI
import HealthKit

struct ProfilView: View {
    @AppStorage("profil_vorname") private var vorname: String = ""
    @AppStorage("profil_schlafziel") private var schlafZielStunden: Double = 8.0
    @AppStorage("profil_einschlafzeit_h") private var einschlafzeitH: Int = 23
    @AppStorage("profil_einschlafzeit_m") private var einschlafzeitM: Int = 0
    @AppStorage("profil_paindiary_verknuepft") private var painDiaryVerknuepft: Bool = false

    @State private var healthKitStatus: String = "Unbekannt"
    @State private var healthKitAktiv: Bool = false
    @State private var painDiaryLetzteSync: Date? = nil

    var body: some View {
        NavigationStack {
            List {
                profilHeader
                schlafzielSektion
                painDiarySektion
                gesundheitSektion
                infoSektion
            }
            .navigationTitle("Profil")
            .navigationBarTitleDisplayMode(.large)
            .onAppear { pruefeHealthKit(); ladePainDiarySync() }
        }
    }

    // MARK: - Profil Header

    private var profilHeader: some View {
        Section {
            HStack {
                Spacer()
                VStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Color.indigo.opacity(0.15))
                            .frame(width: 88, height: 88)
                        Image(systemName: "moon.stars.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.indigo)
                    }
                    if !vorname.isEmpty {
                        Text(vorname)
                            .font(.title3.bold())
                    }
                }
                Spacer()
            }
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)

            LabeledContent("Name") {
                TextField("Dein Name", text: $vorname)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    // MARK: - Schlafziel

    private var schlafzielSektion: some View {
        Section("Schlafziel") {
            LabeledContent("Ziel-Schlafdauer") {
                Text(schlafZielFormatiert)
                    .foregroundStyle(.secondary)
            }
            Slider(value: $schlafZielStunden, in: 5...10, step: 0.5)
                .tint(.indigo)

            HStack {
                Label("Einschlafzeit", systemImage: "bed.double.fill")
                Spacer()
                Picker("", selection: $einschlafzeitH) {
                    ForEach([18, 19, 20, 21, 22, 23, 0, 1, 2, 3], id: \.self) { h in
                        Text(String(format: "%02d", h)).tag(h)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                Text(":")
                    .foregroundStyle(.secondary)
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
            Toggle(isOn: $painDiaryVerknuepft) {
                Label("PainDiary verbinden", systemImage: "link.circle.fill")
            }
            .tint(.indigo)
            .onChange(of: painDiaryVerknuepft) { _, aktiv in
                if aktiv { schreibePainDiaryDaten() }
            }

            if painDiaryVerknuepft {
                LabeledContent("Letzte Sync") {
                    Text(syncStatusText)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
        } header: {
            Text("PainDiary-Verknüpfung")
        } footer: {
            if painDiaryVerknuepft {
                Text("SleepBuddy schreibt nach jeder Nacht die Schlafqualität (0–100) in eine geteilte App Group. PainDiary liest diesen Wert für die Schmerz-Schlaf-Korrelation.")
            } else {
                Text("Voraussetzung: PainDiary muss auf demselben Gerät installiert sein.")
            }
        }
    }

    private var syncStatusText: String {
        guard let datum = painDiaryLetzteSync else { return "Noch keine Daten" }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: datum, relativeTo: Date())
    }

    // MARK: - Apple Health

    private var gesundheitSektion: some View {
        Section("Apple Health") {
            HStack {
                Label("Schlafdaten in Health", systemImage: "heart.fill")
                Spacer()
                Text(healthKitStatus)
                    .foregroundStyle(healthKitAktiv ? .green : .secondary)
                    .font(.caption)
            }

            if !healthKitAktiv {
                Button {
                    anfragenHealthKit()
                } label: {
                    Label("Zugriff anfragen", systemImage: "arrow.right.circle")
                        .foregroundStyle(.indigo)
                }
            }
        } footer: {
            Text("SleepBuddy schreibt Schlafphasen in Apple Health. Kein Audio wird gespeichert.")
        }
    }

    // MARK: - Über SleepBuddy

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

    // MARK: - Logik

    private func pruefeHealthKit() {
        guard HKHealthStore.isHealthDataAvailable() else {
            healthKitStatus = "Nicht verfügbar"
            return
        }
        let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
        let status = HKHealthStore().authorizationStatus(for: type)
        switch status {
        case .sharingAuthorized:
            healthKitAktiv = true
            healthKitStatus = "Zugriff erteilt"
        case .sharingDenied:
            healthKitAktiv = false
            healthKitStatus = "Verweigert — Einstellungen öffnen"
        default:
            healthKitAktiv = false
            healthKitStatus = "Noch nicht angefragt"
        }
    }

    private func anfragenHealthKit() {
        let store = HKHealthStore()
        let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
        store.requestAuthorization(toShare: [type], read: []) { success, _ in
            DispatchQueue.main.async { pruefeHealthKit() }
        }
    }

    private func ladePainDiarySync() {
        let defaults = UserDefaults(suiteName: "group.com.doemu0992.sleepbuddy")
        if let ts = defaults?.double(forKey: "lastNightSleepQualityTimestamp"), ts > 0 {
            painDiaryLetzteSync = Date(timeIntervalSince1970: ts)
        }
    }

    private func schreibePainDiaryDaten() {
        // Hook — Daten werden nach Schlafende geschrieben
    }
}
