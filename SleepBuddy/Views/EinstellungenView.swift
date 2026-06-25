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
    @State private var db: Double = 0
    @State private var isRunning = false
    @State private var keineBerechtigung = false
    @State private var barHeights: [CGFloat] = Array(repeating: 0.05, count: 30)
    @State private var erkannterTyp: SoundEventType? = nil
    @State private var erkannteKonfidenz: Double = 0
    @State private var letzteErkennungen: [(type: SoundEventType, konfidenz: Double, zeit: Date)] = []

    private let engine = AVAudioEngine()
    private let classifier = SoundClassificationService()
    private let barCount = 30

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {

                    // Visualizer
                    VStack(spacing: 12) {
                        HStack(alignment: .bottom, spacing: 4) {
                            ForEach(0..<barCount, id: \.self) { i in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(barColor)
                                    .frame(width: 7, height: max(4, barHeights[i] * 140))
                                    .animation(.easeOut(duration: 0.08), value: barHeights[i])
                            }
                        }
                        .frame(height: 140)

                        HStack(spacing: 4) {
                            Text(isRunning ? "\(Int(db)) dB" : "–")
                                .font(.system(size: 44, weight: .thin, design: .rounded))
                                .foregroundStyle(barColor)
                                .contentTransition(.numericText())
                                .animation(.easeOut(duration: 0.1), value: db)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(pegelLabel)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(barColor)
                                Text("Lautstärke")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)

                    // ML-Erkennung: aktuelle Erkennung
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Geräuscherkennung (ML)", systemImage: "waveform.badge.magnifyingglass")
                            .font(.headline)

                        if let typ = erkannterTyp {
                            HStack(spacing: 12) {
                                Image(systemName: typ.icon)
                                    .font(.title2)
                                    .foregroundStyle(typ.color)
                                    .frame(width: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(typ.rawValue)
                                        .font(.subheadline.weight(.semibold))
                                    Text("Konfidenz: \(Int(erkannteKonfidenz * 100))%")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Circle()
                                    .fill(typ.color.opacity(0.2))
                                    .frame(width: 10, height: 10)
                                    .overlay(Circle().fill(typ.color).frame(width: 6, height: 6))
                            }
                            .padding()
                            .background(erkannterTyp?.color.opacity(0.08) ?? Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .transition(.scale(scale: 0.95).combined(with: .opacity))
                        } else {
                            HStack {
                                Image(systemName: "waveform")
                                    .foregroundStyle(.secondary)
                                Text(isRunning ? "Kein Geräusch erkannt — mach ein Geräusch!" : "Test starten um ML-Erkennung zu prüfen")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding()
                        }

                        // Letzte Erkennungen
                        if !letzteErkennungen.isEmpty {
                            Divider()
                            Text("Letzte Erkennungen")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(letzteErkennungen.suffix(5).reversed(), id: \.zeit) { e in
                                HStack(spacing: 10) {
                                    Image(systemName: e.type.icon)
                                        .foregroundStyle(e.type.color)
                                        .frame(width: 20)
                                    Text(e.type.rawValue)
                                        .font(.caption)
                                    Spacer()
                                    Text("\(Int(e.konfidenz * 100))%")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    Text(e.zeit, style: .time)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: erkannterTyp?.rawValue)

                    if keineBerechtigung {
                        Label("Kein Mikrofonzugriff — Bitte in den iOS-Einstellungen erlauben.", systemImage: "mic.slash.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
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

                    Text("Schnarche, sprich, huste oder klatsche — SleepBuddy zeigt genau was erkannt wird. So siehst du ob die Geräuscherkennung für die Nacht bereit ist.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Mikrofon & Erkennung testen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { stoppen(); dismiss() }
                }
            }
            .onDisappear { stoppen() }
        }
        .presentationDetents([.large])
    }

    private var barColor: Color {
        if db < 35 { return .green }
        if db < 55 { return .orange }
        return .red
    }

    private var pegelLabel: String {
        guard isRunning else { return "Gestoppt" }
        if db < 35 { return "Still" }
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

                    classifier.onSoundDetected = { type, confidence in
                        DispatchQueue.main.async {
                            withAnimation {
                                erkannterTyp = type
                                erkannteKonfidenz = confidence
                            }
                            letzteErkennungen.append((type: type, konfidenz: confidence, zeit: Date()))
                            // Auto-clear nach 3s
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                if erkannterTyp == type { withAnimation { erkannterTyp = nil } }
                            }
                        }
                    }
                    classifier.start(format: format)

                    input.installTap(onBus: 0, bufferSize: 1024, format: format) { [self] buffer, time in
                        // Amplitude für Balken
                        if let data = buffer.floatChannelData?[0] {
                            let count = Int(buffer.frameLength)
                            var rms: Float = 0
                            vDSP_rmsqv(data, 1, &rms, vDSP_Length(count))
                            let dbVal = max(0, min(120, Double(20 * log10(max(rms, 1e-6))) + 90))
                            let norm = CGFloat(max(0.05, min(1.0, (dbVal - 20) / 80)))
                            DispatchQueue.main.async {
                                db = dbVal
                                var newBars = barHeights
                                newBars.removeFirst()
                                newBars.append(norm)
                                barHeights = newBars
                            }
                        }
                        // ML-Klassifikation
                        classifier.analyze(buffer: buffer, time: time)
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
        classifier.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRunning = false
        barHeights = Array(repeating: 0.05, count: barCount)
        db = 0
        erkannterTyp = nil
    }
}
