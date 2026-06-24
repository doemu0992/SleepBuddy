import SwiftUI
import SwiftData
import HealthKit

struct EinstellungenView: View {
    @AppStorage("einst_erinnerung_aktiv") private var erinnerungAktiv = false
    @AppStorage("einst_erinnerung_zeit") private var erinnerungZeitSek = 79200.0 // 22:00

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SleepSession.startDate, order: .reverse) private var alleSessions: [SleepSession]

    private let notif = NotificationManager.shared
    private let healthKit = HealthKitService()

    @State private var exportLaeuft = false
    @State private var exportErgebnis: String?

    private var erinnerungZeit: Binding<Date> {
        Binding(
            get: { Date(timeIntervalSinceReferenceDate: erinnerungZeitSek) },
            set: { erinnerungZeitSek = $0.timeIntervalSinceReferenceDate }
        )
    }

    @AppStorage("soundEvents_enabled") private var soundEventsAktiv = false
    @AppStorage("partnerModus_aktiv") private var partnerModusAktiv = false
    @AppStorage("partnerModus_stufe") private var partnerModusStufe = 0
    @AppStorage("schlafZielStunden") private var schlafZielStunden = 8.0

    var body: some View {
        List {
            erinnerungSektion
            schlafzielSektion
            schlafgeraeuschSektion
            partnerModusSektion
            syncSektion
            appSektion
            versionSektion
        }
        .navigationTitle("Einstellungen")
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: - Erinnerungen

    private var erinnerungSektion: some View {
        Section {
            Toggle("Schlafenszeit-Erinnerung", isOn: $erinnerungAktiv)
                .tint(.indigo)
                .onChange(of: erinnerungAktiv) { _, aktiv in
                    if aktiv {
                        Task {
                            let granted = await notif.berechtigungAnfordern()
                            if granted {
                                planeErinnerung()
                            } else {
                                erinnerungAktiv = false
                            }
                        }
                    } else {
                        notif.loescheSchlafErinnerung()
                    }
                }

            if erinnerungAktiv {
                DatePicker("Uhrzeit", selection: erinnerungZeit, displayedComponents: .hourAndMinute)
                    .onChange(of: erinnerungZeit.wrappedValue) { _, _ in planeErinnerung() }
            }
        } header: {
            Text("Erinnerungen")
        } footer: {
            if erinnerungAktiv {
                Text("Du erhältst täglich eine Erinnerung, SleepBuddy zu starten.")
            }
        }
    }

    // MARK: - Schlafziel

    private var schlafzielSektion: some View {
        Section {
            NavigationLink(destination: SchlafzielView()) {
                HStack {
                    Label("Schlafdauer-Ziel", systemImage: "moon.stars.fill")
                        .font(.subheadline)
                    Spacer()
                    Text(String(format: "%.1f Std.", schlafZielStunden))
                        .font(.subheadline.bold())
                        .foregroundStyle(.indigo)
                }
            }
        } header: {
            Text("Schlafziel")
        } footer: {
            Text("Dein Ziel wird im Verlauf und im Schlafindex berücksichtigt.")
        }
    }

    // MARK: - Schlafgeräusche

    private var schlafgeraeuschSektion: some View {
        Section {
            Toggle("Schlafgeräusche aufzeichnen", isOn: $soundEventsAktiv)
                .tint(.indigo)
        } header: {
            Text("Schlafgeräusche")
        } footer: {
            Text("Wenn aktiviert, werden kurze Audioclips beim Erkennen von Schnarchen, Sprechen oder anderen Geräuschen aufgezeichnet und in iCloud gespeichert. Audio wird nur bei Geräuschereignissen gespeichert.")
        }
    }


    // MARK: - Partner-Modus

    private var partnerModusSektion: some View {
        Section {
            Toggle("Zwei Personen im Bett", isOn: $partnerModusAktiv)
                .tint(.indigo)

            if partnerModusAktiv {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Position des Telefons")
                        .font(.subheadline)
                        .foregroundStyle(.primary)

                    Picker("Position", selection: $partnerModusStufe) {
                        Label("Auf meiner Seite", systemImage: "iphone").tag(0)
                        Label("In der Mitte", systemImage: "arrow.left.and.right").tag(1)
                        Label("Näher am Partner", systemImage: "person.2.fill").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    HStack(spacing: 6) {
                        Image(systemName: positionSymbol)
                            .foregroundStyle(.indigo)
                            .font(.caption)
                        Text(partnerModusHinweis)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Partnermodus")
        } footer: {
            if partnerModusAktiv {
                Text("SleepBuddy filtert Geräusche des Partners heraus. Je näher das Telefon an dir liegt, desto besser funktioniert die Trennung.")
            } else {
                Text("Aktiviere den Partnermodus, wenn eine weitere Person im selben Bett schläft.")
            }
        }
    }

    private var positionSymbol: String {
        switch partnerModusStufe {
        case 0: return "iphone"
        case 1: return "arrow.left.and.right"
        case 2: return "person.2.fill"
        default: return "iphone"
        }
    }

    private var partnerModusHinweis: String {
        switch partnerModusStufe {
        case 0: return "Optimal: Telefon liegt auf deinem Nachttisch. Deine Geräusche sind lauter."
        case 1: return "Mittel: Geräusche beider Personen werden teilweise gefiltert."
        case 2: return "Stark: Nur sehr laute Geräusche nah am Telefon werden erkannt."
        default: return ""
        }
    }

    // MARK: - Synchronisation

    private var syncSektion: some View {
        Section {
            Button {
                exportiereAlleSessionsNachtraglich()
            } label: {
                HStack {
                    Label("Jetzt synchronisieren", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(exportLaeuft ? Color.secondary : Color.indigo)
                    Spacer()
                    if exportLaeuft {
                        ProgressView().tint(.indigo)
                    }
                }
            }
            .disabled(exportLaeuft)

            if let ergebnis = exportErgebnis {
                Text(ergebnis)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Nachträgliche Synchronisation")
        } footer: {
            Text("Überträgt alle gespeicherten Schlafdaten erneut nach PainDiary und Apple Health.")
        }
    }

    // MARK: - App

    private var appSektion: some View {
        Section("App") {
            Button("Onboarding erneut anzeigen") {
                UserDefaults.standard.set(false, forKey: "onboarding_complete")
            }
            .foregroundStyle(.orange)

            Button("Alle Schlafklassifikationen zurücksetzen") {
                // TODO: ML-Samples löschen
            }
            .foregroundStyle(.red)
        }
    }

    // MARK: - Version & Info

    private var versionSektion: some View {
        Section("Über SleepBuddy") {
            LabeledContent("Version") {
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Build") {
                Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–")
                    .foregroundStyle(.secondary)
            }

            NavigationLink(destination: VersionsverlaufView()) {
                Label("Versionsverlauf", systemImage: "clock.arrow.circlepath")
            }

            Link(destination: URL(string: "https://github.com/doemu0992/SleepBuddy")!) {
                Label("Quellcode auf GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
            }
        }
    }

    // MARK: - Logik

    private func planeErinnerung() {
        let dc = Calendar.current.dateComponents([.hour, .minute], from: erinnerungZeit.wrappedValue)
        notif.planeSchlafErinnerung(stunde: dc.hour ?? 22, minute: dc.minute ?? 0)
    }

    private func exportiereAlleSessionsNachtraglich() {
        exportLaeuft = true
        exportErgebnis = nil
        Task {
            var painDiaryCount = 0
            var healthCount = 0

            // PainDiary export
            let verknuepft = UserDefaults.standard.bool(forKey: "profil_paindiary_verknuepft")
            if verknuepft {
                for session in alleSessions where session.endDate != nil {
                    PainDiaryVerknuepfungView.exportiereSession(session)
                    painDiaryCount += 1
                }
            }

            // HealthKit export
            await healthKit.requestAuthorization()
            if healthKit.isAuthorized {
                for session in alleSessions where session.endDate != nil {
                    try? await healthKit.saveSleepSession(session)
                    healthCount += 1
                }
            }

            await MainActor.run {
                exportLaeuft = false
                var teile: [String] = []
                if verknuepft { teile.append("\(painDiaryCount) Nächte → PainDiary") }
                if healthKit.isAuthorized { teile.append("\(healthCount) Nächte → Apple Health") }
                exportErgebnis = teile.isEmpty
                    ? "Keine Verbindung aktiv (PainDiary oder HealthKit prüfen)"
                    : "✓ " + teile.joined(separator: ", ")
            }
        }
    }
}

// MARK: - Versionsverlauf

struct VersionsverlaufView: View {
    private let versionen: [(version: String, datum: String, aenderungen: [String])] = [
        ("1.0", "Juni 2026", [
            "Automatische Schlafphasen-Erkennung via Mikrofon",
            "Smart Alarm im Leichtschlaf",
            "HealthKit-Integration",
            "PainDiary-Verknüpfung via App Group",
            "KI-Schlafanalyse (iOS 26)"
        ])
    ]

    var body: some View {
        List {
            ForEach(versionen, id: \.version) { v in
                Section {
                    ForEach(v.aenderungen, id: \.self) { aenderung in
                        Label(aenderung, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.primary)
                            .labelStyle(versionLabelStyle())
                    }
                } header: {
                    HStack {
                        Text("Version \(v.version)")
                            .font(.headline).textCase(nil)
                        Spacer()
                        Text(v.datum)
                            .font(.caption).foregroundStyle(.secondary).textCase(nil)
                    }
                }
            }
        }
        .navigationTitle("Versionsverlauf")
        .navigationBarTitleDisplayMode(.large)
    }
}

private struct versionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top, spacing: 10) {
            configuration.icon.foregroundStyle(.indigo).font(.caption)
            configuration.title.font(.subheadline)
        }
    }
}
