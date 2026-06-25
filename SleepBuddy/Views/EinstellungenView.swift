import SwiftUI
import SwiftData
import AVFoundation
import Accelerate

struct EinstellungenView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SleepSession.startDate, order: .reverse) private var alleSessions: [SleepSession]

    private let healthKit = HealthKitService()

    @AppStorage("soundEvents_enabled") private var soundEventsAktiv = false
    @AppStorage("partnerModus_aktiv") private var partnerModusAktiv = false
    @AppStorage("partnerModus_stufe") private var partnerModusStufe = 0

    @State private var zeigeMikrofonTest = false
    @State private var exportLaeuft = false
    @State private var exportErgebnis: String?
    @State private var zeigeLoeschenBestaetigung = false
    @State private var csvShareItem: URL?
    @State private var zeigeCSVShare = false

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

            Button {
                zeigeMikrofonTest = true
            } label: {
                Label("Mikrofon testen", systemImage: "mic.badge.waveform.fill")
                    .foregroundStyle(.indigo)
            }
            .sheet(isPresented: $zeigeMikrofonTest) {
                MikrofonTestView()
            }
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

            Button {
                exportiereCSV()
            } label: {
                Label("Schlafdaten als CSV exportieren", systemImage: "tablecells")
                    .foregroundStyle(.indigo)
            }
            .sheet(isPresented: $zeigeCSVShare) {
                if let url = csvShareItem {
                    ShareSheet(items: [url])
                }
            }

            Button {
                SampleDataService.insertSampleNight(into: modelContext)
            } label: {
                Label("Beispielnacht hinzufügen", systemImage: "moon.stars.fill")
                    .foregroundStyle(.indigo)
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

    private func exportiereCSV() {
        let header = "Datum,Start,Ende,Dauer (h),Tiefschlaf (min),REM (min),Leichtschlaf (min),Wach (min),Einschlafen (min),Schnarchen,Qualität\n"
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"

        let rows = alleSessions
            .filter { !$0.isActive }
            .sorted { $0.startDate < $1.startDate }
            .map { s -> String in
                let date = fmt.string(from: s.startDate)
                let start = timeFmt.string(from: s.startDate)
                let end = s.endDate.map { timeFmt.string(from: $0) } ?? ""
                let dur = String(format: "%.2f", s.totalDuration / 3600)
                let deep = Int(s.deepSleepDuration / 60)
                let rem = Int(s.remSleepDuration / 60)
                let light = Int(s.lightSleepDuration / 60)
                let awake = Int(s.awakeDuration / 60)
                let latency = s.sleepOnsetLatency.map { Int($0 / 60) }.map { String($0) } ?? ""
                let snoring = s.snoringEventCount
                let quality = s.subjectiveQuality
                return "\(date),\(start),\(end),\(dur),\(deep),\(rem),\(light),\(awake),\(latency),\(snoring),\(quality)"
            }

        let csv = header + rows.joined(separator: "\n")
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("SleepBuddy-Export.csv")
        try? csv.write(to: tmpURL, atomically: true, encoding: .utf8)
        csvShareItem = tmpURL
        zeigeCSVShare = true
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

// MARK: - ShareSheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uvc: UIActivityViewController, context: Context) {}
}

// MARK: - MikrofonTestView

struct MikrofonTestView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var amplitude: Float = 0
    @State private var db: Double = 0
    @State private var isRunning = false
    @State private var keineBerechtigung = false
    @State private var barHeights: [CGFloat] = Array(repeating: 0.05, count: 30)

    private let engine = AVAudioEngine()
    private let barCount = 30

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                // Visualizer
                VStack(spacing: 16) {
                    HStack(alignment: .bottom, spacing: 4) {
                        ForEach(0..<barCount, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(barColor)
                                .frame(width: 6, height: max(4, barHeights[i] * 160))
                                .animation(.easeOut(duration: 0.08), value: barHeights[i])
                        }
                    }
                    .frame(height: 160)
                    .padding(.horizontal)

                    Text(isRunning ? "\(Int(db)) dB" : "–")
                        .font(.system(size: 48, weight: .thin, design: .rounded))
                        .foregroundStyle(barColor)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.1), value: db)

                    Text(pegelLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if keineBerechtigung {
                    Label("Kein Mikrofonzugriff — Bitte in den iOS-Einstellungen erlauben.", systemImage: "mic.slash.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                // Start / Stop
                Button {
                    if isRunning { stoppen() } else { starten() }
                } label: {
                    Label(isRunning ? "Stoppen" : "Test starten", systemImage: isRunning ? "stop.circle.fill" : "mic.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(isRunning ? Color.red : Color.indigo, in: RoundedRectangle(cornerRadius: 16))
                }
                .padding(.horizontal)

                Spacer()

                Text("Sprich oder klatsche — du siehst sofort ob das Mikrofon reagiert.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .padding(.bottom)
            }
            .navigationTitle("Mikrofon testen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { stoppen(); dismiss() }
                }
            }
            .onDisappear { stoppen() }
        }
        .presentationDetents([.medium, .large])
    }

    private var barColor: Color {
        if db < 35 { return .green }
        if db < 55 { return .orange }
        return .red
    }

    private var pegelLabel: String {
        guard isRunning else { return "Tippe auf «Test starten»" }
        if db < 35 { return "Still / Ruhig" }
        if db < 55 { return "Normal" }
        if db < 70 { return "Laut" }
        return "Sehr laut"
    }

    private func starten() {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                guard granted else { keineBerechtigung = true; return }
                keineBerechtigung = false
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.record, mode: .measurement, options: [.mixWithOthers, .allowBluetoothHFP])
                    try session.setActive(true)

                    let input = engine.inputNode
                    let format = input.outputFormat(forBus: 0)
                    input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                        guard let data = buffer.floatChannelData?[0] else { return }
                        let count = Int(buffer.frameLength)
                        var rms: Float = 0
                        vDSP_rmsqv(data, 1, &rms, vDSP_Length(count))
                        let dbVal = max(0, min(120, Double(20 * log10(max(rms, 1e-6))) + 90))
                        let norm = CGFloat(max(0.05, min(1.0, (dbVal - 20) / 80)))

                        DispatchQueue.main.async {
                            amplitude = rms
                            db = dbVal
                            // Shift bars left, append new value
                            var newBars = barHeights
                            newBars.removeFirst()
                            newBars.append(norm)
                            barHeights = newBars
                        }
                    }
                    try engine.start()
                    isRunning = true
                } catch {
                    keineBerechtigung = true
                }
            }
        }
    }

    private func stoppen() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRunning = false
        barHeights = Array(repeating: 0.05, count: barCount)
        db = 0
    }
}
