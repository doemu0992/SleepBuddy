import SwiftUI
import HealthKit

struct ProfilView: View {
    @State private var profil = SharedProfil.shared
    @AppStorage("profil_paindiary_verknuepft") private var painDiaryVerknuepft: Bool = false
    @AppStorage("einst_erinnerung_aktiv") private var erinnerungAktiv = false
    @AppStorage("einst_erinnerung_zeit") private var erinnerungZeitSek = 79200.0

    private let notif = NotificationManager.shared

    private var erinnerungZeit: Binding<Date> {
        Binding(
            get: { Date(timeIntervalSinceReferenceDate: erinnerungZeitSek) },
            set: { erinnerungZeitSek = $0.timeIntervalSinceReferenceDate }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                profilKarte
                schlafSektion
                verknuepfungSektion
                gesundheitSektion
                einstellungenSektion
            }
            .navigationTitle("Profil")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    // MARK: - Profilkarte

    private var profilKarte: some View {
        Section {
            NavigationLink(destination: ProfilBearbeitenView()) {
                HStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(Color.indigo.opacity(0.15))
                            .frame(width: 64, height: 64)
                        Image(systemName: "moon.stars.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.indigo)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        let name = profil.anzeigeName
                        Text(name.isEmpty ? "Dein Name" : name)
                            .font(.title3.bold())
                            .foregroundStyle(name.isEmpty ? .secondary : .primary)
                        if let geb = profil.geburtsdatum {
                            let alter = Calendar.current.dateComponents([.year], from: geb, to: Date()).year ?? 0
                            Text("\(alter) Jahre · SleepBuddy-Profil")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("SleepBuddy-Profil")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Schlaf-Sektion

    private var schlafSektion: some View {
        Section("Schlaf") {
            NavigationLink(destination: SchlafzielView()) {
                Label("Schlafziel", systemImage: "moon.fill")
            }
            NavigationLink(destination: AlarmEinstellungenView()) {
                Label("Smart Alarm", systemImage: "alarm.fill")
            }
            Toggle(isOn: $erinnerungAktiv) {
                Label("Schlafenszeit-Erinnerung", systemImage: "bell.fill")
            }
            .tint(.indigo)
            .onChange(of: erinnerungAktiv) { _, aktiv in
                if aktiv {
                    Task {
                        let granted = await notif.berechtigungAnfordern()
                        if granted { planeErinnerung() } else { erinnerungAktiv = false }
                    }
                } else {
                    notif.loescheSchlafErinnerung()
                }
            }
            if erinnerungAktiv {
                DatePicker("Uhrzeit", selection: erinnerungZeit, displayedComponents: .hourAndMinute)
                    .onChange(of: erinnerungZeit.wrappedValue) { _, _ in planeErinnerung() }
            }
        }
    }

    private func planeErinnerung() {
        let dc = Calendar.current.dateComponents([.hour, .minute], from: erinnerungZeit.wrappedValue)
        notif.planeSchlafErinnerung(stunde: dc.hour ?? 22, minute: dc.minute ?? 0)
    }

    // MARK: - Verknüpfungen

    private var verknuepfungSektion: some View {
        Section("Verknüpfungen") {
            NavigationLink(destination: PainDiaryVerknuepfungView()) {
                HStack {
                    Label("PainDiary verbinden", systemImage: "link.circle.fill")
                    Spacer()
                    if painDiaryVerknuepft {
                        Text("Aktiv")
                            .font(.caption.bold())
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.indigo.opacity(0.15))
                            .foregroundStyle(.indigo)
                            .clipShape(Capsule())
                    }
                }
            }
            NavigationLink(destination: HealthKitView()) {
                Label("Apple Health", systemImage: "heart.fill")
            }
        }
    }

    // MARK: - Einstellungen

    private var einstellungenSektion: some View {
        Section("App") {
            NavigationLink(destination: EinstellungenView()) {
                Label("App-Einstellungen", systemImage: "gearshape.fill")
            }
        }
    }

    // MARK: - Gesundheit (Platzhalter für spätere Daten)

    private var gesundheitSektion: some View {
        EmptyView()
    }
}

// MARK: - Profil bearbeiten

struct ProfilBearbeitenView: View {
    @State private var profil = SharedProfil.shared
    @Environment(\.dismiss) private var dismiss

    @State private var vorname: String = ""
    @State private var nachname: String = ""
    @State private var geburtsdatum: Date = Date()
    @State private var hatGeburtsdatum: Bool = false
    @State private var geschlecht: String = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 0) {
                    HStack {
                        Text("Vorname")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        TextField("Vorname", text: $vorname)
                            .multilineTextAlignment(.trailing)
                            .font(.subheadline)
                    }
                    .padding(16)
                    Divider().padding(.leading, 16)
                    HStack {
                        Text("Nachname")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        TextField("Nachname", text: $nachname)
                            .multilineTextAlignment(.trailing)
                            .font(.subheadline)
                    }
                    .padding(16)
                    Divider().padding(.leading, 16)
                    Toggle("Geburtsdatum angeben", isOn: $hatGeburtsdatum)
                        .tint(.indigo)
                        .font(.subheadline)
                        .padding(16)
                    if hatGeburtsdatum {
                        Divider().padding(.leading, 16)
                        DatePicker("Geburtsdatum", selection: $geburtsdatum, displayedComponents: .date)
                            .font(.subheadline)
                            .padding(16)
                    }
                    Divider().padding(.leading, 16)
                    HStack {
                        Text("Geschlecht")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: $geschlecht) {
                            Text("Keine Angabe").tag("")
                            Text("Weiblich").tag("Weiblich")
                            Text("Männlich").tag("Männlich")
                            Text("Divers").tag("Divers")
                        }
                        .labelsHidden()
                    }
                    .padding(16)
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))

                Text("Diese Daten werden mit PainDiary geteilt, wenn die Verknüpfung aktiv ist.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal)
            .padding(.vertical, 24)
        }
        .background(Color(.systemGroupedBackground))
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Profil bearbeiten")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Fertig") { speichern() }
            }
        }
        .onAppear { laden() }
    }

    private func laden() {
        vorname = profil.vorname
        nachname = profil.nachname
        geschlecht = profil.geschlecht
        if let geb = profil.geburtsdatum {
            geburtsdatum = geb
            hatGeburtsdatum = true
        }
    }

    private func speichern() {
        profil.vorname = vorname
        profil.nachname = nachname
        profil.geschlecht = geschlecht
        profil.geburtsdatum = hatGeburtsdatum ? geburtsdatum : nil
        dismiss()
    }
}

// MARK: - Schlafziel

struct SchlafzielView: View {
    @AppStorage("schlafZielStunden") private var schlafZielStunden: Double = 8.0
    @AppStorage("profil_einschlafzeit_h") private var einschlafzeitH: Int = 23
    @AppStorage("profil_einschlafzeit_m") private var einschlafzeitM: Int = 0

    var body: some View {
        List {
            Section {
                LabeledContent("Ziel-Schlafdauer") {
                    Text(schlafZielFormatiert).foregroundStyle(.secondary)
                }
                Slider(value: $schlafZielStunden, in: 5...10, step: 0.5)
                    .tint(.indigo)
            } header: {
                Text("Schlafdauer")
            } footer: {
                Text("Empfehlung für Erwachsene: 7–9 Stunden.")
            }

            Section("Einschlafzeit") {
                HStack {
                    Text("Uhrzeit")
                    Spacer()
                    Picker("", selection: $einschlafzeitH) {
                        ForEach([18, 19, 20, 21, 22, 23, 0, 1, 2, 3], id: \.self) { h in
                            Text(String(format: "%02d", h)).tag(h)
                        }
                    }
                    .pickerStyle(.menu).labelsHidden()
                    Text(":").foregroundStyle(.secondary)
                    Picker("", selection: $einschlafzeitM) {
                        ForEach([0, 15, 30, 45], id: \.self) { m in
                            Text(String(format: "%02d", m)).tag(m)
                        }
                    }
                    .pickerStyle(.menu).labelsHidden()
                }
            }
        }
        .navigationTitle("Schlafziel")
        .navigationBarTitleDisplayMode(.large)
    }

    private var schlafZielFormatiert: String {
        let h = Int(schlafZielStunden)
        let m = Int((schlafZielStunden - Double(h)) * 60)
        return m == 0 ? "\(h) Std." : "\(h) Std. \(m) Min."
    }
}

// MARK: - Alarm-Einstellungen (Wrapper)

struct AlarmEinstellungenView: View {
    @State private var alarm = SmartAlarmService()

    var body: some View {
        List {
            Section {
                Toggle("Smart Alarm aktivieren", isOn: Bindable(alarm).isEnabled)
                    .tint(.indigo)
            } footer: {
                Text("SleepBuddy weckt dich im optimalen Leichtschlafmoment innerhalb deines Zeitfensters.")
            }

            if alarm.isEnabled {
                Section("Aufwachfenster") {
                    DatePicker("Frühestens", selection: Bindable(alarm).earliestWakeTime, displayedComponents: .hourAndMinute)
                    DatePicker("Spätestens", selection: Bindable(alarm).latestWakeTime, displayedComponents: .hourAndMinute)
                }

                Section {
                    ForEach(AlarmTon.allCases, id: \.self) { ton in
                        Button {
                            alarm.alarmTon = ton
                            alarm.vorschauSpielen()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: ton.symbol)
                                    .foregroundStyle(.indigo)
                                    .frame(width: 24)
                                Text(ton.rawValue)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if alarm.alarmTon == ton {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.indigo)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Weckton")
                } footer: {
                    Text("Tippe auf einen Ton, um ihn als Vorschau abzuspielen.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Lautstärke")
                            Spacer()
                            Text("\(Int(alarm.lautstaerke * 100)) %")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        HStack(spacing: 10) {
                            Image(systemName: "speaker.fill")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            Slider(value: Bindable(alarm).lautstaerke, in: 0.1...1.0, step: 0.05)
                                .tint(.indigo)
                            Image(systemName: "speaker.wave.3.fill")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                    .padding(.vertical, 4)
                } footer: {
                    Text("Gilt für den Weckton bei aktiver Schlafaufzeichnung.")
                }
            }
        }
        .navigationTitle("Smart Alarm")
        .navigationBarTitleDisplayMode(.large)
    }
}

// MARK: - PainDiary-Verknüpfung

struct PainDiaryVerknuepfungView: View {
    @AppStorage("profil_paindiary_verknuepft") private var painDiaryVerknuepft: Bool = false
    @State private var letzteSync: Date? = nil

    var body: some View {
        List {
            Section {
                Toggle("PainDiary verbinden", isOn: $painDiaryVerknuepft)
                    .tint(.indigo)
                    .onChange(of: painDiaryVerknuepft) { _, aktiv in
                        if aktiv { schreibePainDiaryDaten() }
                    }

                if painDiaryVerknuepft, let datum = letzteSync {
                    LabeledContent("Letzte Sync") {
                        Text(datum, style: .relative)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            } header: {
                Text("Verbindung")
            } footer: {
                Text(painDiaryVerknuepft
                    ? "Schlafqualität wird nach jeder Nacht automatisch an PainDiary übertragen."
                    : "Voraussetzung: PainDiary muss auf demselben Gerät installiert sein.")
            }

            Section("Wie funktioniert es?") {
                Label("SleepBuddy berechnet eine Schlafqualität (0–100)", systemImage: "moon.fill")
                Label("Der Wert wird in einer geteilten App Group gespeichert", systemImage: "internaldrive")
                Label("PainDiary liest den Wert und zeigt die Schmerz-Schlaf-Korrelation", systemImage: "chart.line.uptrend.xyaxis")
            }
            .foregroundStyle(.secondary)
            .font(.subheadline)
        }
        .navigationTitle("PainDiary")
        .navigationBarTitleDisplayMode(.large)
        .onAppear { ladeSyncDatum() }
    }

    private func ladeSyncDatum() {
        let defaults = UserDefaults(suiteName: "group.com.doemu0992.sleepbuddy")
        if let ts = defaults?.double(forKey: "lastNightSleepQualityTimestamp"), ts > 0 {
            letzteSync = Date(timeIntervalSince1970: ts)
        }
    }

    private func schreibePainDiaryDaten() {
        // Called manually from toggle — also called automatically from SleepTrackingViewModel
        letzteSync = Date()
        UserDefaults(suiteName: "group.com.doemu0992.sleepbuddy")?
            .set(letzteSync!.timeIntervalSince1970, forKey: "lastNightSleepQualityTimestamp")
    }

    static func exportiereSession(_ session: SleepSession) {
        guard UserDefaults.standard.bool(forKey: "profil_paindiary_verknuepft") else { return }
        let total = session.totalDuration
        guard total >= 1800 else { return }  // Mindestens 30 Minuten
        let summary = SleepNightSummary(
            datum: session.startDate.timeIntervalSince1970,
            qualitaet: Double(SchlafindexView.score(for: session)),
            dauerSek: total,
            tiefPct: session.deepSleepDuration / total,
            remPct: session.remSleepDuration / total,
            leichtPct: session.lightSleepDuration / total,
            wachPct: session.awakeDuration / total,
            schnarchenAnzahl: session.soundEventsArray.filter { $0.type == .snoring }.count,
            sprechenAnzahl: session.soundEventsArray.filter { $0.type == .talking }.count,
            geraeuschAnzahl: session.soundEventsArray.filter { $0.type == .other }.count
        )
        var alle = SleepNightSummary.laden()
        // Replace if same night already exists (same day)
        let cal = Calendar.current
        alle.removeAll { cal.isDate(Date(timeIntervalSince1970: $0.datum), inSameDayAs: session.startDate) }
        alle.append(summary)
        // Keep last 90 nights
        let sorted = alle.sorted { $0.datum > $1.datum }
        SleepNightSummary.speichern(Array(sorted.prefix(90)))
    }
}

// MARK: - Apple Health

struct HealthKitView: View {
    @State private var status: String = "Prüfe…"
    @State private var aktiv: Bool = false

    var body: some View {
        List {
            Section {
                HStack {
                    Label("Schlafdaten in Health", systemImage: "heart.fill")
                    Spacer()
                    Text(status)
                        .foregroundStyle(aktiv ? .green : .secondary)
                        .font(.caption)
                }

                if !aktiv {
                    Button {
                        anfragen()
                    } label: {
                        Label("Zugriff anfragen", systemImage: "arrow.right.circle")
                            .foregroundStyle(.indigo)
                    }
                }
            } footer: {
                Text("SleepBuddy schreibt Schlafphasen (Tief, REM, Leicht, Wach) in Apple Health. Audio wird nie gespeichert.")
            }
        }
        .navigationTitle("Apple Health")
        .navigationBarTitleDisplayMode(.large)
        .onAppear { pruefen() }
    }

    private func pruefen() {
        guard HKHealthStore.isHealthDataAvailable() else {
            status = "Nicht verfügbar"; return
        }
        let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
        switch HKHealthStore().authorizationStatus(for: type) {
        case .sharingAuthorized: aktiv = true; status = "Zugriff erteilt"
        case .sharingDenied:     aktiv = false; status = "Verweigert"
        default:                 aktiv = false; status = "Nicht angefragt"
        }
    }

    private func anfragen() {
        let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
        HKHealthStore().requestAuthorization(toShare: [type], read: []) { _, _ in
            DispatchQueue.main.async { pruefen() }
        }
    }
}
