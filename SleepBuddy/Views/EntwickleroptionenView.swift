import SwiftUI
import SwiftData

/// Entwickler-/Test-Werkzeuge — aus den normalen Einstellungen ausgelagert,
/// damit die Nutzer-Einstellungen sauber bleiben.
struct EntwickleroptionenView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var zeigeMikrofonTest = false
    @State private var zeigeICloudTest = false
    @State private var zeigeSoundAudit = false
    @State private var soundAuditText = ""
    @State private var normalisiereLaeuft = false
    @State private var normalisiereErgebnis: String?
    @State private var phasenLaeuft = false
    @State private var phasenErgebnis: String?
    @State private var zeigeTestdatenLoeschen = false

    var body: some View {
        List {
            // MARK: Tests
            Section {
                Button { zeigeMikrofonTest = true } label: {
                    Label("Mikrofon testen", systemImage: "mic.fill").foregroundStyle(.indigo)
                }
                .sheet(isPresented: $zeigeMikrofonTest) { MikrofonTestView() }

                Button { zeigeICloudTest = true } label: {
                    Label("iCloud-Speicher testen", systemImage: "icloud.and.arrow.up").foregroundStyle(.indigo)
                }
                .sheet(isPresented: $zeigeICloudTest) { ICloudAudioTestView() }

                Button {
                    if #available(iOS 15, *) { soundAuditText = SoundClassificationService.auditText() }
                    else { soundAuditText = "Erfordert iOS 15 oder neuer." }
                    zeigeSoundAudit = true
                } label: {
                    Label("Geräusch-Klassen prüfen", systemImage: "checklist").foregroundStyle(.indigo)
                }
                .sheet(isPresented: $zeigeSoundAudit) { SoundAuditView(report: soundAuditText) }
            } header: {
                Text("Tests")
            }

            // MARK: Wartung
            Section {
                Button { normalisiereAufnahmen() } label: {
                    HStack {
                        Label("Aufnahmen lauter machen", systemImage: "speaker.wave.3.fill").foregroundStyle(.indigo)
                        if normalisiereLaeuft { Spacer(); ProgressView() }
                    }
                }
                .disabled(normalisiereLaeuft)

                Button { korrigierePhasen() } label: {
                    HStack {
                        Label("Schlafphasen neu berechnen", systemImage: "wand.and.stars").foregroundStyle(.indigo)
                        if phasenLaeuft { Spacer(); ProgressView() }
                    }
                }
                .disabled(phasenLaeuft)
            } header: {
                Text("Wartung")
            }

            // MARK: Testdaten
            Section {
                Button {
                    SampleDataService.insertSampleNight(into: modelContext)
                } label: {
                    Label("Beispielnacht hinzufügen", systemImage: "moon.stars.fill").foregroundStyle(.indigo)
                }
                Button {
                    for _ in 0..<3 { SampleDataService.insertSampleNight(into: modelContext) }
                } label: {
                    Label("Alle 3 Beispielnächte hinzufügen", systemImage: "moon.stars.fill").foregroundStyle(.indigo)
                }
                Button {
                    SampleDataService.insertSampleHistory(into: modelContext)
                } label: {
                    Label("Langzeitverlauf-Testdaten (6 Monate)", systemImage: "calendar").foregroundStyle(.indigo)
                }
                Button(role: .destructive) {
                    zeigeTestdatenLoeschen = true
                } label: {
                    Label("Alle Testdaten löschen", systemImage: "trash.slash")
                }
                .confirmationDialog("Alle Testdaten löschen?", isPresented: $zeigeTestdatenLoeschen, titleVisibility: .visible) {
                    Button("Löschen", role: .destructive) { testdatenLoeschen() }
                    Button("Abbrechen", role: .cancel) {}
                } message: {
                    Text("Alle Schlafnächte werden gelöscht. Dieser Vorgang kann nicht rückgängig gemacht werden.")
                }
            } header: {
                Text("Testdaten")
            } footer: {
                Text("Diese Werkzeuge sind für Entwicklung & Diagnose gedacht.")
            }
        }
        .navigationTitle("Entwickleroptionen")
        .navigationBarTitleDisplayMode(.large)
        .alert("Aufnahmen", isPresented: Binding(
            get: { normalisiereErgebnis != nil }, set: { if !$0 { normalisiereErgebnis = nil } }
        )) { Button("OK", role: .cancel) { normalisiereErgebnis = nil } } message: { Text(normalisiereErgebnis ?? "") }
        .alert("Schlafphasen", isPresented: Binding(
            get: { phasenErgebnis != nil }, set: { if !$0 { phasenErgebnis = nil } }
        )) { Button("OK", role: .cancel) { phasenErgebnis = nil } } message: { Text(phasenErgebnis ?? "") }
    }

    // MARK: - Aktionen

    private func normalisiereAufnahmen() {
        normalisiereLaeuft = true
        Task.detached {
            let count = SoundEventService().normalizeExistingClips()
            await MainActor.run {
                normalisiereLaeuft = false
                normalisiereErgebnis = count > 0
                    ? "\(count) Aufnahme(n) wurden lauter gemacht."
                    : "Keine leisen Aufnahmen gefunden (bereits laut genug oder noch nicht aus iCloud geladen)."
            }
        }
    }

    private func korrigierePhasen() {
        phasenLaeuft = true
        let descriptor = FetchDescriptor<SleepSession>()
        let sessions = (try? modelContext.fetch(descriptor)) ?? []
        let vm = SleepTrackingViewModel()
        let n = vm.reapplyPhaseCorrections(to: sessions, context: modelContext)
        phasenLaeuft = false
        phasenErgebnis = n > 0
            ? "\(n) Nacht/Nächte wurden aus den Rohdaten neu berechnet."
            : "Keine Nächte mit gespeicherten Messdaten gefunden (Testnächte haben keine)."
    }

    private func testdatenLoeschen() {
        let descriptor = FetchDescriptor<SleepSession>()
        let sessions = (try? modelContext.fetch(descriptor)) ?? []
        for s in sessions { modelContext.delete(s) }
        try? modelContext.save()
    }
}
