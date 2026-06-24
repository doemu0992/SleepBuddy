import SwiftUI
import SwiftData

struct EinstellungenView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SleepSession.startDate, order: .reverse) private var alleSessions: [SleepSession]

    private let healthKit = HealthKitService()

    @AppStorage("soundEvents_enabled") private var soundEventsAktiv = false
    @AppStorage("partnerModus_aktiv") private var partnerModusAktiv = false
    @AppStorage("partnerModus_stufe") private var partnerModusStufe = 0

    @State private var exportLaeuft = false
    @State private var exportErgebnis: String?
    @State private var zeigeLoeschenBestaetigung = false

    var body: some View {
        List {
            aufzeichnungSektion
            partnerModusSektion
            datenSektion
            appSektion
        }
        .navigationTitle("Einstellungen")
        .navigationBarTitleDisplayMode(.large)
        .confirmationDialog(
            "Alle Schlafdaten löschen?",
            isPresented: $zeigeLoeschenBestaetigung,
            titleVisibility: .visible
        ) {
            Button("Löschen", role: .destructive) { alleDatenLoeschen() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Alle Schlafnächte und Phasen werden permanent gelöscht. Dieser Vorgang kann nicht rückgängig gemacht werden.")
        }
    }

    // MARK: - Aufzeichnung

    private var aufzeichnungSektion: some View {
        Section {
            Toggle(isOn: $soundEventsAktiv) {
                Label("Schlafgeräusche aufzeichnen", systemImage: "waveform.badge.mic")
            }
            .tint(.indigo)

            Toggle(isOn: $partnerModusAktiv) {
                Label("Partnermodus", systemImage: "person.2.fill")
            }
            .tint(.indigo)
        } header: {
            Text("Aufzeichnung")
        } footer: {
            if soundEventsAktiv {
                Text("Kurze Audioclips werden bei Schnarchen oder Geräuschen in iCloud gespeichert.")
            } else if partnerModusAktiv {
                Text("SleepBuddy filtert Geräusche einer zweiten Person im Bett heraus.")
            }
        }
    }

    // MARK: - Partnermodus-Position

    @ViewBuilder
    private var partnerModusSektion: some View {
        if partnerModusAktiv {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Position des Telefons")
                        .font(.subheadline)

                    Picker("Position", selection: $partnerModusStufe) {
                        Label("Meine Seite", systemImage: "iphone").tag(0)
                        Label("Mitte", systemImage: "arrow.left.and.right").tag(1)
                        Label("Partner", systemImage: "person.2.fill").tag(2)
                    }
                    .pickerStyle(.segmented)

                    Text(partnerModusHinweis)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Partnermodus")
            }
        }
    }

    // MARK: - Daten

    private var datenSektion: some View {
        Section {
            Button {
                exportiereAlleSessionsNachtraglich()
            } label: {
                HStack {
                    Label("Mit PainDiary & Health synchronisieren", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(exportLaeuft ? .secondary : .indigo)
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

            Button(role: .destructive) {
                zeigeLoeschenBestaetigung = true
            } label: {
                Label("Alle Schlafdaten löschen", systemImage: "trash")
            }
        } header: {
            Text("Daten")
        } footer: {
            Text("Überträgt alle Schlafnächte nachträglich nach PainDiary und Apple Health.")
        }
    }

    // MARK: - App

    private var appSektion: some View {
        Section("App") {
            NavigationLink(destination: VersionsverlaufView()) {
                Label("Versionsverlauf", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
            }

            Button {
                UserDefaults.standard.set(false, forKey: "onboarding_complete")
            } label: {
                Label("Onboarding erneut anzeigen", systemImage: "arrow.counterclockwise")
                    .foregroundStyle(.orange)
            }

            LabeledContent("Version") {
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private var partnerModusHinweis: String {
        switch partnerModusStufe {
        case 0: return "Telefon liegt auf deinem Nachttisch — deine Geräusche sind am lautesten."
        case 1: return "Telefon liegt in der Mitte — Geräusche beider Personen werden gefiltert."
        case 2: return "Telefon liegt näher am Partner — nur sehr laute Geräusche werden erkannt."
        default: return ""
        }
    }

    private func exportiereAlleSessionsNachtraglich() {
        exportLaeuft = true
        exportErgebnis = nil
        Task {
            var painDiaryCount = 0
            var healthCount = 0

            let verknuepft = UserDefaults.standard.bool(forKey: "profil_paindiary_verknuepft")
            if verknuepft {
                for session in alleSessions where session.endDate != nil {
                    PainDiaryVerknuepfungView.exportiereSession(session)
                    painDiaryCount += 1
                }
            }

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

    private func alleDatenLoeschen() {
        for session in alleSessions {
            modelContext.delete(session)
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
                            .labelStyle(VersionLabelStyle())
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

private struct VersionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top, spacing: 10) {
            configuration.icon.foregroundStyle(.indigo).font(.caption)
            configuration.title.font(.subheadline)
        }
    }
}
