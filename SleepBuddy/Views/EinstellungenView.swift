import SwiftUI
import SwiftData
import AVFoundation
import Accelerate
import SoundAnalysis
import CoreMedia
import Observation

struct EinstellungenView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SleepSession.startDate, order: .reverse) private var alleSessions: [SleepSession]

    private let healthKit = HealthKitService()

    @AppStorage("soundEvents_enabled") private var soundEventsAktiv = false
    @AppStorage("partnerModus_aktiv") private var partnerModusAktiv = false
    @AppStorage("partnerModus_stufe") private var partnerModusStufe = 1

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
                VStack(alignment: .leading, spacing: 2) {
                    Label("Geräusche aufzeichnen", systemImage: "waveform.badge.mic")
                    Text("Schlaf- & Umgebungsgeräusche mit 30s-Clip")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(.indigo)

            Toggle(isOn: $partnerModusAktiv) {
                Label("Partnermodus", systemImage: "person.2.fill")
            }
            .tint(.indigo)
            .onChange(of: partnerModusAktiv) { _, on in
                if on && partnerModusStufe < 1 { partnerModusStufe = 1 }   // Alt-Wert 0 normalisieren
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
                    Text("Wie nah liegt dein Partner?")
                        .font(.subheadline)

                    Picker("Abstand", selection: $partnerModusStufe) {
                        Text("Normaler Abstand").tag(1)
                        Text("Direkt daneben").tag(2)
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

            NavigationLink(destination: DatenschutzView()) {
                Label("Datenschutz", systemImage: "lock.shield.fill")
            }

            NavigationLink(destination: EntwickleroptionenView()) {
                Label("Entwickleroptionen", systemImage: "hammer.fill")
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
        case 2: return "Partner liegt direkt neben dir — nur klar nähere/lautere Signale (deine) werden gewertet. Funktioniert auf Matratze und Nachttisch."
        default: return "Partner in normalem Abstand — Bewegungen und leisere Geräusche des Partners werden herausgefiltert."
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

// MARK: - MikrofonTest Classifier (kein Schwellenwert-Filter, jeden Buffer analysieren)

import SoundAnalysis
import CoreMedia
import Observation

@available(iOS 15, *)
private final class MikrofonTestKlassifikator: NSObject, SNResultsObserving {
    var onResults: (([TestErkennung]) -> Void)?
    private var analyzer: SNAudioStreamAnalyzer?
    private let queue = DispatchQueue(label: "com.sleepbuddy.miktest", qos: .userInitiated)

    // Alle relevanten Apple-ML-Identifier → Anzeigename + Icon + Farbe
    static let mappings: [(id: String, name: String, icon: String, farbe: Color)] = [
        ("snoring",            "Schnarchen",     "waveform",                    .orange),
        ("speech",             "Sprechen",        "bubble.left.fill",            .blue),
        ("cough",              "Husten",          "lungs.fill",                  .teal),
        ("coughing",           "Husten",          "lungs.fill",                  .teal),
        ("teeth_chattering",   "Zähneknirschen",  "mouth.fill",                  .pink),
        ("teeth_grinding",     "Zähneknirschen",  "mouth.fill",                  .pink),
        ("clapping",           "Klatschen",       "hands.clap.fill",             .indigo),
        ("whistling",          "Pfeifen",         "mouth.fill",                  .cyan),
        ("laughing",           "Lachen",          "face.smiling.fill",           .yellow),
        ("crying",             "Weinen",          "drop.fill",                   .blue),
        ("baby_cry",           "Babyweinen",      "figure.and.child.holdinghands", .mint),
        ("infant_cry",         "Babyweinen",      "figure.and.child.holdinghands", .mint),
        ("dog",                "Hundebellen",     "pawprint.fill",               .brown),
        ("dog_barking",        "Hundebellen",     "pawprint.fill",               .brown),
        ("music",              "Musik",           "music.note",                  .indigo),
        ("alarm_clock",        "Alarm/Wecker",    "bell.fill",                   .red),
        ("siren",              "Sirene",          "light.beacon.max.fill",       .red),
        ("car_horn",           "Hupen",           "car.fill",                    .gray),
        ("vehicle",            "Fahrzeug",        "car.fill",                    .gray),
        ("glass_breaking",     "Glasbruch",       "sparkles",                    .red),
        ("door_knock",         "Klopfen",         "hand.raised.fill",            .secondary),
        ("knock",              "Klopfen",         "hand.raised.fill",            .secondary),
        ("sneezing",           "Niesen",          "wind",                        .teal),
        ("breathing",          "Atmen",           "lungs",                       .green),
        ("snoring_breathing",  "Schnarchen/Atmen","waveform",                    .orange),
    ]

    func start(format: AVAudioFormat) {
        do {
            analyzer = SNAudioStreamAnalyzer(format: format)
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            // Kurzes Fenster für schnellere Reaktion im Test
            request.windowDuration = CMTimeMakeWithSeconds(1.0, preferredTimescale: 44100)
            request.overlapFactor = 0.75
            try analyzer?.add(request, withObserver: self)
        } catch {
            analyzer = nil
        }
    }

    func analyze(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        // Jeden Buffer analysieren — kein Skip wie im Nacht-Modus
        queue.async { [weak self] in
            self?.analyzer?.analyze(buffer, atAudioFramePosition: time.sampleTime)
        }
    }

    func stop() {
        analyzer = nil
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let res = result as? SNClassificationResult else { return }
        // Top-5 Erkennungen ab 5% Konfidenz zeigen
        let top = Self.mappings.compactMap { m -> TestErkennung? in
            guard let c = res.classification(forIdentifier: m.id), c.confidence >= 0.05 else { return nil }
            return TestErkennung(id: m.id, name: m.name, icon: m.icon, farbe: m.farbe, konfidenz: c.confidence)
        }
        .sorted { $0.konfidenz > $1.konfidenz }
        // Deduplizieren nach Name (z.B. "cough" + "coughing" → einmal)
        var seen = Set<String>()
        let dedup = top.filter { seen.insert($0.name).inserted }
        let result5 = Array(dedup.prefix(5))
        DispatchQueue.main.async { [weak self] in
            self?.onResults?(result5)
        }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {}
}

struct TestErkennung: Identifiable {
    let id: String
    let name: String
    let icon: String
    let farbe: Color
    let konfidenz: Double
}

// MARK: - MikrofonTestView

struct MikrofonTestView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var db: Double = 0
    @State private var isRunning = false
    @State private var keineBerechtigung = false
    @State private var barHeights: [CGFloat] = Array(repeating: 0.05, count: 30)
    @State private var topErkennungen: [TestErkennung] = []
    @State private var letzteErkennungen: [(name: String, icon: String, farbe: Color, konfidenz: Double, zeit: Date)] = []

    private let engine = AVAudioEngine()
    private let barCount = 30

    @State private var klassifikator: AnyObject? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {

                    // Visualizer
                    VStack(spacing: 10) {
                        HStack(alignment: .bottom, spacing: 4) {
                            ForEach(0..<barCount, id: \.self) { i in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(barColor)
                                    .frame(width: 7, height: max(4, barHeights[i] * 130))
                                    .animation(.easeOut(duration: 0.08), value: barHeights[i])
                            }
                        }
                        .frame(height: 130)

                        HStack {
                            Text(isRunning ? "\(Int(db)) dB" : "–")
                                .font(.system(size: 40, weight: .thin, design: .rounded))
                                .foregroundStyle(barColor)
                                .contentTransition(.numericText())
                                .animation(.easeOut(duration: 0.1), value: db)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(pegelLabel).font(.subheadline.weight(.semibold)).foregroundStyle(barColor)
                                Text("Lautstärke").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)

                    // Live ML-Erkennungen: Top 5 mit Konfidenz-Balken
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Live-Erkennung (Apple ML)", systemImage: "waveform.badge.magnifyingglass")
                            .font(.headline)

                        if topErkennungen.isEmpty {
                            HStack {
                                Image(systemName: "mic.fill").foregroundStyle(.secondary)
                                Text(isRunning ? "Mach ein Geräusch — schnarche, huste, klatsche…"
                                              : "Test starten")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        } else {
                            ForEach(topErkennungen) { e in
                                VStack(spacing: 4) {
                                    HStack(spacing: 10) {
                                        Image(systemName: e.icon)
                                            .foregroundStyle(e.farbe)
                                            .frame(width: 22)
                                        Text(e.name)
                                            .font(.subheadline)
                                        Spacer()
                                        Text("\(Int(e.konfidenz * 100))%")
                                            .font(.caption.monospacedDigit().weight(.semibold))
                                            .foregroundStyle(e.konfidenz >= 0.4 ? e.farbe : .secondary)
                                    }
                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            RoundedRectangle(cornerRadius: 3)
                                                .fill(e.farbe.opacity(0.12))
                                                .frame(height: 6)
                                            RoundedRectangle(cornerRadius: 3)
                                                .fill(e.farbe.opacity(e.konfidenz >= 0.4 ? 0.85 : 0.35))
                                                .frame(width: geo.size.width * e.konfidenz, height: 6)
                                                .animation(.easeOut(duration: 0.15), value: e.konfidenz)
                                        }
                                    }
                                    .frame(height: 6)
                                }
                            }
                        }

                        if !letzteErkennungen.isEmpty {
                            Divider()
                            Text("Zuletzt sicher erkannt (≥ 40%)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(letzteErkennungen.suffix(6).reversed(), id: \.zeit) { e in
                                HStack(spacing: 10) {
                                    Image(systemName: e.icon).foregroundStyle(e.farbe).frame(width: 18)
                                    Text(e.name).font(.caption)
                                    Spacer()
                                    Text("\(Int(e.konfidenz * 100))%")
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    Text(e.zeit, style: .time)
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
                    .animation(.spring(response: 0.35, dampingFraction: 0.75), value: topErkennungen.map(\.id).joined())

                    if keineBerechtigung {
                        Label("Kein Mikrofonzugriff — Bitte in den iOS-Einstellungen erlauben.",
                              systemImage: "mic.slash.fill")
                            .font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                    }

                    Button {
                        if isRunning { stoppen() } else { starten() }
                    } label: {
                        Label(isRunning ? "Stoppen" : "Test starten",
                              systemImage: isRunning ? "stop.circle.fill" : "mic.fill")
                            .font(.headline).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .background(isRunning ? Color.red : Color.indigo,
                                        in: RoundedRectangle(cornerRadius: 16))
                    }

                    Text("Schnarche, huste, pfeife oder klatsche — alle Geräusche die SleepBuddy in der Nacht erkennt werden hier mit Konfidenz angezeigt. Balken grau = unter Erkennungsschwelle, farbig = wird nachts erfasst.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
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
                guard #available(iOS 15, *) else { return }
                let klass = MikrofonTestKlassifikator()
                klass.onResults = { erkennungen in
                    topErkennungen = erkennungen
                    // Nur Erkennungen ≥ 40% in die Historie
                    if let beste = erkennungen.first, beste.konfidenz >= 0.4 {
                        let neu = (name: beste.name, icon: beste.icon,
                                   farbe: beste.farbe, konfidenz: beste.konfidenz, zeit: Date())
                        // Kein Duplikat innerhalb 2s
                        if let letzter = letzteErkennungen.last,
                           letzter.name == neu.name,
                           Date().timeIntervalSince(letzter.zeit) < 2 { return }
                        letzteErkennungen.append(neu)
                    }
                }
                klassifikator = klass
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.record, mode: .measurement,
                                           options: [.mixWithOthers, .allowBluetoothHFP])
                    try session.setActive(true)
                    let input = engine.inputNode
                    let format = input.outputFormat(forBus: 0)
                    klass.start(format: format)
                    input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
                        if let data = buffer.floatChannelData?[0] {
                            var rms: Float = 0
                            vDSP_rmsqv(data, 1, &rms, vDSP_Length(Int(buffer.frameLength)))
                            let dbVal = max(0, min(120, Double(20 * log10(max(rms, 1e-6))) + 90))
                            let norm = CGFloat(max(0.05, min(1.0, (dbVal - 20) / 80)))
                            DispatchQueue.main.async {
                                db = dbVal
                                var bars = barHeights; bars.removeFirst(); bars.append(norm)
                                barHeights = bars
                            }
                        }
                        klass.analyze(buffer: buffer, time: time)
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
        if #available(iOS 15, *) { (klassifikator as? MikrofonTestKlassifikator)?.stop() }
        klassifikator = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRunning = false
        barHeights = Array(repeating: 0.05, count: barCount)
        db = 0
        topErkennungen = []
    }
}

// MARK: - ICloudAudioTestView

struct ICloudAudioTestView: View {
    @Environment(\.dismiss) private var dismiss

    enum TestStatus {
        case bereit, aufnahme, speichern, erfolg(String), fehler(String)

        var beschreibung: String {
            switch self {
            case .bereit:           return "Bereit zum Testen"
            case .aufnahme:         return "Nimmt 3 Sekunden auf…"
            case .speichern:        return "Speichert in iCloud…"
            case .erfolg(let pfad): return "✅ Gespeichert:\n\(pfad)"
            case .fehler(let msg):  return "❌ Fehler:\n\(msg)"
            }
        }

        var farbe: Color {
            switch self {
            case .erfolg: return .green
            case .fehler: return .red
            default:      return .secondary
            }
        }
    }

    @State private var status: TestStatus = .bereit
    @State private var countdown = 3
    @State private var laeuft = false
    private let engine = AVAudioEngine()
    private static let iCloudID = "iCloud.DG-Software-Solution.PainDiary"

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                Image(systemName: iconName)
                    .font(.system(size: 56))
                    .foregroundStyle(status.farbe)
                    .symbolEffect(.pulse, isActive: laeuft)

                VStack(spacing: 8) {
                    if case .aufnahme = status {
                        Text("\(countdown)")
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .foregroundStyle(.indigo)
                    }
                    Text(status.beschreibung)
                        .font(.subheadline)
                        .foregroundStyle(status.farbe)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                iCloudStatusRow

                Button {
                    startTest()
                } label: {
                    Label("Test starten", systemImage: "play.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(laeuft ? Color.secondary : Color.indigo,
                                    in: RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 32)
                .disabled(laeuft)

                Spacer()
            }
            .navigationTitle("iCloud-Test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }

    private var iconName: String {
        switch status {
        case .bereit:    return "icloud.and.arrow.up"
        case .aufnahme:  return "mic.fill"
        case .speichern: return "arrow.up.to.line.circle"
        case .erfolg:    return "checkmark.icloud.fill"
        case .fehler:    return "exclamationmark.icloud.fill"
        }
    }

    @ViewBuilder
    private var iCloudStatusRow: some View {
        let url = FileManager.default.url(
            forUbiquityContainerIdentifier: Self.iCloudID)
        VStack(spacing: 4) {
            if let url {
                Label("iCloud verfügbar", systemImage: "icloud.fill")
                    .font(.caption).foregroundStyle(.green)
                Text(url.path)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2).multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else {
                Label("iCloud nicht erreichbar", systemImage: "icloud.slash")
                    .font(.caption).foregroundStyle(.orange)
                Text("Lokal gespeichert (Documents/SleepSounds/)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 24)
    }

    private func startTest() {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                guard granted else {
                    status = .fehler("Mikrofon-Berechtigung fehlt")
                    return
                }
                aufnehmenUndSpeichern()
            }
        }
    }

    private func aufnehmenUndSpeichern() {
        laeuft = true
        status = .aufnahme
        countdown = 3

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .measurement,
                                  options: [.mixWithOthers, .allowBluetoothHFP])
        try? session.setActive(true)

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        let sampleRate = format.sampleRate
        var samples: [Float] = []

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buf, _ in
            guard let data = buf.floatChannelData?[0] else { return }
            samples.append(contentsOf: Array(UnsafeBufferPointer(start: data, count: Int(buf.frameLength))))
        }

        try? engine.start()

        // Countdown
        var tick = 0
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            tick += 1
            countdown = 3 - tick
            if tick >= 3 {
                timer.invalidate()
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
                DispatchQueue.main.async {
                    status = .speichern
                    speichern(samples: samples, sampleRate: sampleRate)
                }
            }
        }
    }

    private func speichern(samples: [Float], sampleRate: Double) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let fileName = "icloudtest_\(formatter.string(from: Date())).m4a"

        guard let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: sampleRate,
                                             channels: 1, interleaved: false) else {
            status = .fehler("Audio-Format konnte nicht erstellt werden")
            laeuft = false
            return
        }

        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ]
            let file = try AVAudioFile(forWriting: tmpURL, settings: settings)
            let count = AVAudioFrameCount(samples.count)
            guard let buf = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: count) else {
                throw NSError(domain: "ICloudTest", code: 1)
            }
            buf.frameLength = count
            samples.withUnsafeBufferPointer { ptr in
                buf.floatChannelData?[0].update(from: ptr.baseAddress!, count: samples.count)
            }
            try file.write(from: buf)
        } catch {
            DispatchQueue.main.async {
                status = .fehler("Aufnahme fehlgeschlagen: \(error.localizedDescription)")
                laeuft = false
            }
            return
        }

        // iCloud versuchen, lokal als Fallback
        let destURL: URL
        var ziel = "iCloud"

        if let icloudBase = FileManager.default.url(
            forUbiquityContainerIdentifier: Self.iCloudID)?
            .appendingPathComponent("Documents/SleepSounds/") {
            try? FileManager.default.createDirectory(at: icloudBase, withIntermediateDirectories: true)
            destURL = icloudBase.appendingPathComponent(fileName)
        } else {
            let local = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SleepSounds/")
            try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            destURL = local.appendingPathComponent(fileName)
            ziel = "Lokal (kein iCloud)"
        }

        do {
            try FileManager.default.copyItem(at: tmpURL, to: destURL)
            try? FileManager.default.removeItem(at: tmpURL)
            DispatchQueue.main.async {
                status = .erfolg("\(ziel)\n\(destURL.lastPathComponent)\n\(Int(samples.count / Int(sampleRate)))s · \(Int(sampleRate/1000))kHz")
                laeuft = false
            }
        } catch {
            DispatchQueue.main.async {
                status = .fehler("Speichern fehlgeschlagen: \(error.localizedDescription)")
                laeuft = false
            }
        }
    }
}

// MARK: - Sound taxonomy audit report

/// Shows the Apple sound-taxonomy audit (dead identifiers + full class list) with a
/// copy button so the report can be shared for correcting the mappings.
struct SoundAuditView: View {
    // Optional übergebener Text; wird sonst selbst berechnet (verhindert leere Seite durch
    // SwiftUI-State-Timing beim gleichzeitigen Setzen von Text + Sheet-Flag).
    var report: String = ""
    @Environment(\.dismiss) private var dismiss
    @State private var kopiert = false
    @State private var text = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text.isEmpty ? "Lade Klassen…" : text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .onAppear {
                if !report.isEmpty { text = report; return }
                if #available(iOS 15, *) { text = SoundClassificationService.auditText() }
                else { text = "Erfordert iOS 15 oder neuer." }
            }
            .navigationTitle("Geräusch-Klassen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = text
                        kopiert = true
                    } label: {
                        Label(kopiert ? "Kopiert ✓" : "Kopieren",
                              systemImage: kopiert ? "checkmark" : "doc.on.doc")
                    }
                }
            }
        }
    }
}

// MARK: - Entwickleroptionen (Test-/Debug-Werkzeuge, aus den Einstellungen ausgelagert)
// Bewusst in dieser Datei (kein eigenes File) — neue Swift-Dateien müssten manuell
// zum Xcode-Build-Target hinzugefügt werden.

struct EntwickleroptionenView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var zeigeMikrofonTest = false
    @State private var zeigeICloudTest = false
    @State private var zeigeSoundAudit = false
    @State private var zeigeSonarTest = false
    @State private var normalisiereLaeuft = false
    @State private var normalisiereErgebnis: String?
    @State private var phasenLaeuft = false
    @State private var phasenErgebnis: String?
    @State private var zeigeTestdatenLoeschen = false

    var body: some View {
        List {
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
                    zeigeSoundAudit = true
                } label: {
                    Label("Geräusch-Klassen prüfen", systemImage: "checklist").foregroundStyle(.indigo)
                }
                .sheet(isPresented: $zeigeSoundAudit) { SoundAuditView() }

                Button { zeigeSonarTest = true } label: {
                    Label("Sonar testen (Atmung/Bewegung)", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.indigo)
                }
                .sheet(isPresented: $zeigeSonarTest) { SonarTestView() }
            } header: {
                Text("Tests")
            }

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

// MARK: - DatenschutzView

struct DatenschutzView: View {
    @Environment(\.openURL) private var openURL

    private let supportMail = "doemugerber@gmail.com"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                abschnitt(
                    icon: "mic.fill",
                    titel: "Audio bleibt auf dem Gerät",
                    text: "Die Geräusch- und Atemanalyse läuft vollständig auf deinem iPhone. Rohaudio verlässt niemals das Gerät — es werden nur anonyme Merkmale (z. B. Lautstärke, Frequenzbänder) ausgewertet."
                )

                abschnitt(
                    icon: "icloud.fill",
                    titel: "Deine iCloud, deine Daten",
                    text: "Schlafdaten werden über deine private iCloud (CloudKit) zwischen deinen Geräten synchronisiert. Optionale Geräusch-Aufnahmen (Clips) werden — wenn aktiviert — ausschließlich in deinem eigenen iCloud-Ordner gespeichert. Niemand außer dir hat Zugriff."
                )

                abschnitt(
                    icon: "heart.fill",
                    titel: "Gesundheitsdaten (HealthKit)",
                    text: "Wenn du es erlaubst, liest SleepBuddy deine Herzfrequenz aus Apple Health und schreibt deine Schlafanalyse zurück. Diese Daten bleiben auf deinem Gerät bzw. in deiner iCloud und werden nicht an Dritte weitergegeben."
                )

                abschnitt(
                    icon: "arrow.left.arrow.right",
                    titel: "Datenaustausch mit PainDiary",
                    text: "Wenn du die App PainDiary desselben Entwicklers nutzt und die Verknüpfung aktivierst, überträgt SleepBuddy eine Zusammenfassung deiner Nacht (z. B. Schlafdauer und -qualität) an PainDiary. Dieser Austausch findet ausschließlich lokal auf deinem Gerät über eine gemeinsame, geschützte App-Gruppe statt — keine Übertragung an Server oder Dritte. Du kannst die Verknüpfung jederzeit im Profil deaktivieren."
                )

                abschnitt(
                    icon: "hand.raised.fill",
                    titel: "Kein Tracking, keine Werbung",
                    text: "SleepBuddy enthält keine Werbung, kein Analyse-Tracking durch Dritte und verkauft keine Daten. Es gibt keine Nutzerkonten — deine Identität wird nicht erfasst."
                )

                abschnitt(
                    icon: "cross.case.fill",
                    titel: "Kein Medizinprodukt",
                    text: "SleepBuddy dient der Information und dem persönlichen Wohlbefinden. Die App ist kein Medizinprodukt und ersetzt keine ärztliche Diagnose oder Behandlung."
                )

                kontaktKarte

                Text("Stand: \(Date().formatted(.dateTime.month(.wide).year()))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Datenschutz")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 40))
                .foregroundStyle(LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text("Deine Privatsphäre zuerst")
                .font(.title3.bold())
            Text("SleepBuddy ist so gebaut, dass deine sensibelsten Daten — dein Schlaf und deine Geräusche — bei dir bleiben.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func abschnitt(icon: String, titel: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.indigo)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(titel).font(.subheadline.bold())
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
    }

    private var kontaktKarte: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Entwickler & Kontakt")
                .font(.subheadline.bold())

            LabeledContent("Entwickler") {
                Text("Dominik Gerber").foregroundStyle(.secondary)
            }
            Divider()
            Button {
                if let url = URL(string: "mailto:\(supportMail)") { openURL(url) }
            } label: {
                HStack {
                    Text("Support")
                    Spacer()
                    Text(supportMail).foregroundStyle(.indigo)
                    Image(systemName: "envelope.fill").font(.caption).foregroundStyle(.indigo)
                }
            }
            .buttonStyle(.plain)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
    }
}

// MARK: - SonarTestView (Live-Test des aktiven Sonars)

struct SonarTestView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sonar = SonarService()
    @State private var feat = SonarFeatures.neutral

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Live-Wellenform (Atem-/Bewegungssignal aus der Reflexion)
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Reflexionssignal", systemImage: "waveform.path")
                            .font(.headline)
                        GeometryReader { geo in
                            let w = sonar.waveform
                            Path { p in
                                guard w.count > 1 else { return }
                                let maxAbs = max(w.map { abs($0) }.max() ?? 1, 0.0001)
                                let dx = geo.size.width / CGFloat(w.count - 1)
                                let mid = geo.size.height / 2
                                for (i, v) in w.enumerated() {
                                    let x = CGFloat(i) * dx
                                    let y = mid - CGFloat(v / maxAbs) * mid * 0.9
                                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                                    else { p.addLine(to: CGPoint(x: x, y: y)) }
                                }
                            }
                            .stroke(Color.indigo, lineWidth: 2)
                        }
                        .frame(height: 120)
                        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))

                    // Kennzahlen
                    HStack(spacing: 0) {
                        messwert(String(format: "%.0f", feat.breathingRateBPM), "Atem/min",
                                 farbe: feat.breathingRateBPM > 0 ? .indigo : .secondary)
                        Divider().frame(height: 40)
                        messwert(String(format: "%.0f%%", feat.breathingRegularity * 100), "Regelmäßig", farbe: .teal)
                        Divider().frame(height: 40)
                        messwert(String(format: "%.0f%%", feat.movementIntensity * 100), "Bewegung",
                                 farbe: feat.movementIntensity > 0.3 ? .orange : .secondary)
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))

                    VStack(spacing: 4) {
                        Label(feat.signalPresent ? "Signal erkannt" : "Kein Signal — näher/ruhiger legen",
                              systemImage: feat.signalPresent ? "checkmark.circle.fill" : "questionmark.circle")
                            .font(.subheadline)
                            .foregroundStyle(feat.signalPresent ? .green : .secondary)
                        // Diagnose-Pegel: 0 = Ton kommt nicht am Mikro an; > 0.0001 = Reflexion da.
                        Text(String(format: "Pegel: %.5f", sonar.signalLevel))
                            .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }

                    Button {
                        if sonar.isRunning { sonar.stop() } else { sonar.start() }
                    } label: {
                        Label(sonar.isRunning ? "Stoppen" : "Sonar starten",
                              systemImage: sonar.isRunning ? "stop.fill" : "play.fill")
                            .font(.headline).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding()
                            .background(sonar.isRunning ? Color.red : Color.indigo, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)

                    Text("Sendet einen fast unhörbaren ~19 kHz-Ton und misst die von Brustkorb/Körper reflektierte Welle. Lege das iPhone wie zum Schlafen ab (Matratze oder Nachttisch) und atme ruhig — die Atemfrequenz sollte sich einpendeln, Bewegung schlägt bei Wälzen aus.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Sonar-Test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { sonar.stop(); dismiss() }
                }
            }
            .onDisappear { sonar.stop() }
            .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
                feat = sonar.latest
            }
        }
    }

    private func messwert(_ wert: String, _ label: String, farbe: Color) -> some View {
        VStack(spacing: 4) {
            Text(wert).font(.title3.bold()).foregroundStyle(farbe)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - SonarService & SonarFeatures (bewusst in dieser in-Target-Datei — neue Swift-Dateien
// müssten sonst manuell zum Xcode-Build-Target hinzugefügt werden)

/// Ergebnis einer Sonar-Analyse (pro ~30-s-Fenster emittiert).
struct SonarFeatures {
    let breathingRateBPM: Float     // Atemfrequenz aus der Reflexion (0 = kein Signal)
    let breathingRegularity: Float  // 0…1, ACF-Peak-Stärke
    let movementIntensity: Float    // 0 = still, 1 = deutliche Körperbewegung
    let signalPresent: Bool         // true wenn ein plausibles Reflexionssignal vorliegt

    static let neutral = SonarFeatures(breathingRateBPM: 0, breathingRegularity: 0,
                                       movementIntensity: 0, signalPresent: false)
}

/// Aktives Sonar (Sleep-Cycle-Stil): sendet einen (nahezu) unhörbaren ~19 kHz-Ton über den
/// Lautsprecher und analysiert die vom Körper reflektierte, atem-/bewegungsmodulierte Welle
/// im Mikrofon. Liefert Atemfrequenz, Atem-Regularität und Bewegungsintensität — robust auch
/// vom **Nachttisch** und weitgehend unabhängig von Umgebungslärm (das Nutzsignal liegt im
/// Ultraschallband weit über Alltagsgeräuschen).
///
/// **Eigenständige Engine** (Ton-Ausgabe + Mikrofon-Tap in EINEM `AVAudioEngine`) — läuft nur
/// wenn explizit gestartet (Live-Test / später opt-in im Tracking), damit die bestehende
/// Aufnahme-Pipeline unberührt bleibt.
@Observable
final class SonarService {

    var onFeaturesUpdated: ((SonarFeatures) -> Void)?
    /// Kurzer Ausschnitt des Basisband-Atemsignals (für eine Live-Wellenform im Test-UI).
    private(set) var waveform: [Float] = []
    private(set) var isRunning = false
    private(set) var latest: SonarFeatures = .neutral

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let carrier: Double = 19_000        // Trägerfrequenz (Hz), nahe Ultraschall
    private let toneAmplitude: Float = 0.45     // kräftiger, damit die Reflexion klar messbar ist
    /// Diagnose: mittlere Basisband-Magnitude des letzten Fensters (0 = Ton kommt nicht am Mikro an).
    private(set) var signalLevel: Float = 0

    private var outputSampleRate: Double = 48_000
    private var inputSampleRate: Double = 48_000

    // Demodulations-Zustand: laufende Trägerphase (mod 2π) über Buffergrenzen hinweg —
    // bounded, daher kein Präzisionsverlust über Stunden, aber phasenkontinuierlich.
    private var carrierPhase: Double = 0
    private let processQueue = DispatchQueue(label: "sonar.dsp")

    // Basisband (dezimiert auf ~50 Hz): I/Q + abgeleitete Phase & Magnitude
    private let basebandRate: Double = 50
    private var decim = 960                      // fs / basebandRate (bei 48 kHz)
    private var iBB: [Float] = []
    private var qBB: [Float] = []
    private let bbCapacity = 3000                // ~60 s @ 50 Hz
    private var newSinceEmit = 0
    private let emitEverySamples = 250           // ~5 s @ 50 Hz (schnelles Test-Feedback)

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        // playAndRecord + measurement: Ton raus UND Mikro rein, ohne Voice-Processing/AGC
        // (das Echo/den Ton wollen wir bewusst mitschneiden), Lautsprecher erzwungen.
        // KEIN Bluetooth-HFP: das würde die Route auf 8/16 kHz zwingen → 19 kHz wäre weg.
        // Hohe Samplerate erzwingen, damit 19 kHz (< Nyquist) sicher erhalten bleibt.
        try? session.setCategory(.playAndRecord, mode: .measurement,
                                 options: [.defaultToSpeaker, .mixWithOthers])
        try? session.setPreferredSampleRate(48_000)
        try? session.setActive(true, options: .notifyOthersOnDeactivation)

        let input = engine.inputNode
        inputSampleRate = input.inputFormat(forBus: 0).sampleRate
        let outFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        outputSampleRate = outFormat.sampleRate
        decim = max(1, Int((inputSampleRate / basebandRate).rounded()))

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outFormat)

        // Mikrofon-Tap: demoduliert jeden Buffer
        input.installTap(onBus: 0, bufferSize: 4096, format: input.inputFormat(forBus: 0)) { [weak self] buf, _ in
            self?.processQueue.async { self?.process(buffer: buf) }
        }

        reset()
        do {
            try engine.start()
            player.scheduleBuffer(makeToneBuffer(format: outFormat), at: nil, options: .loops)
            player.play()
            isRunning = true
        } catch {
            input.removeTap(onBus: 0)
        }
    }

    func stop() {
        guard isRunning else { return }
        player.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func reset() {
        carrierPhase = 0
        iBB.removeAll(keepingCapacity: true)
        qBB.removeAll(keepingCapacity: true)
        newSinceEmit = 0
        waveform = []
        latest = .neutral
    }

    // MARK: - Tone generation

    /// 1-Sekunden-Trägerbuffer; bei ganzzahliger Zyklenzahl klickfrei loopbar.
    private func makeToneBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer {
        let fs = format.sampleRate
        let frames = AVAudioFrameCount(fs)                 // exakt 1 s
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        let ch = Int(format.channelCount)
        for c in 0..<ch {
            guard let p = buf.floatChannelData?[c] else { continue }
            for i in 0..<Int(frames) {
                p[i] = toneAmplitude * Float(sin(2.0 * .pi * carrier * Double(i) / fs))
            }
        }
        return buf
    }

    // MARK: - Demodulation

    private func process(buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        // Authoritative Samplerate aus dem Buffer (nicht die evtl. veraltete Annahme).
        let fs = buffer.format.sampleRate
        let dec = max(1, Int((fs / basebandRate).rounded()))
        let w = 2.0 * .pi * carrier / fs

        // I/Q-Demodulation + Blockmittelung (grober Tiefpass) auf ~50 Hz.
        var accI: Float = 0, accQ: Float = 0, cnt = 0
        var phase = carrierPhase
        let twoPi = 2.0 * Double.pi
        for k in 0..<n {
            let x = ch[k]
            accI += x * Float(cos(phase))
            accQ += x * Float(sin(phase))
            phase += w
            if phase >= twoPi { phase -= twoPi }
            cnt += 1
            if cnt >= dec {
                let inv = 1.0 / Float(cnt)
                appendBaseband(i: accI * inv, q: accQ * inv)
                accI = 0; accQ = 0; cnt = 0
            }
        }
        carrierPhase = phase

        if newSinceEmit >= emitEverySamples { emitFeatures() }
    }

    private func appendBaseband(i: Float, q: Float) {
        iBB.append(i); qBB.append(q)
        if iBB.count > bbCapacity { iBB.removeFirst(); qBB.removeFirst() }
        newSinceEmit += 1
    }

    private func emitFeatures() {
        newSinceEmit = 0
        let count = iBB.count
        guard count >= Int(basebandRate * 8) else { return }   // ≥ 8 s Daten

        // Phase (Mikro-Bewegung der Brust) + Magnitude (grobe Reflexionsstärke)
        var phase = [Float](repeating: 0, count: count)
        var mag = [Float](repeating: 0, count: count)
        for k in 0..<count {
            phase[k] = atan2(qBB[k], iBB[k])
            mag[k] = sqrt(iBB[k]*iBB[k] + qBB[k]*qBB[k])
        }
        let meanMag = mag.reduce(0, +) / Float(count)
        unwrap(&phase)
        // Detrend Phase (linearer Drift raus) → reines Atem-/Bewegungssignal
        detrend(&phase)

        let (bpm, reg) = breathing(from: phase, rate: basebandRate)
        let movement = movementLevel(phase: phase, rate: basebandRate)
        // Signal gilt als vorhanden, wenn die Reflexion klar über dem Rauschen liegt.
        let present = meanMag > 1e-4
        signalLevel = meanMag

        let feat = SonarFeatures(
            breathingRateBPM: present ? bpm : 0,
            breathingRegularity: present ? reg : 0,
            movementIntensity: movement,
            signalPresent: present
        )
        // Letzte ~6 s als Wellenform fürs UI
        let tail = Array(phase.suffix(Int(basebandRate * 6)))
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.latest = feat
            self.waveform = tail
            self.onFeaturesUpdated?(feat)
        }
    }

    // MARK: - DSP-Helfer

    private func unwrap(_ p: inout [Float]) {
        guard p.count > 1 else { return }
        var offset: Float = 0
        for k in 1..<p.count {
            let d = p[k] + offset - p[k-1]
            if d > .pi { offset -= 2 * .pi }
            else if d < -.pi { offset += 2 * .pi }
            p[k] += offset
        }
    }

    private func detrend(_ x: inout [Float]) {
        let n = x.count
        guard n > 2 else { return }
        // lineare Regression y = a + b·t abziehen
        let tf = (0..<n).map { Float($0) }
        var meanT: Float = 0, meanX: Float = 0
        vDSP_meanv(tf, 1, &meanT, vDSP_Length(n))
        vDSP_meanv(x, 1, &meanX, vDSP_Length(n))
        var num: Float = 0, den: Float = 0
        for i in 0..<n {
            num += (tf[i]-meanT) * (x[i]-meanX)
            den += (tf[i]-meanT) * (tf[i]-meanT)
        }
        let b = den > 0 ? num/den : 0
        let a = meanX - b*meanT
        for i in 0..<n { x[i] -= (a + b*tf[i]) }
    }

    /// Atemfrequenz via Autokorrelation im 6–30 BPM-Band + Peak-Stärke als Regularität.
    private func breathing(from signal: [Float], rate: Double) -> (bpm: Float, reg: Float) {
        let n = signal.count
        guard n > Int(rate * 4) else { return (0, 0) }
        var energy: Float = 0
        vDSP_measqv(signal, 1, &energy, vDSP_Length(n))     // mittlere Leistung
        guard energy > 1e-9 else { return (0, 0) }

        let minLag = Int(rate * 60.0 / 30.0)   // 30 BPM
        let maxLag = min(Int(rate * 60.0 / 6.0), n - 1)   // 6 BPM
        guard maxLag > minLag else { return (0, 0) }

        var bestLag = -1
        var bestVal: Float = 0
        signal.withUnsafeBufferPointer { buf in
            let base = buf.baseAddress!
            for lag in minLag...maxLag {
                var dot: Float = 0
                vDSP_dotpr(base, 1, base + lag, 1, &dot, vDSP_Length(n - lag))
                let norm = dot / (energy * Float(n - lag))
                if norm > bestVal { bestVal = norm; bestLag = lag }
            }
        }
        guard bestLag > 0 else { return (0, 0) }
        let bpm = Float(rate * 60.0 / Double(bestLag))
        let reg = min(max(bestVal, 0), 1)
        return (bpm, reg)
    }

    /// Bewegungsintensität: kurzfristige Energie schneller Phasenänderungen (Körperbewegung
    /// erzeugt große, schnelle Ausschläge; ruhiges Atmen nur kleine, langsame).
    private func movementLevel(phase: [Float], rate: Double) -> Float {
        let n = phase.count
        let win = min(n, Int(rate * 5))    // letzte ~5 s
        guard win > 2 else { return 0 }
        let seg = Array(phase.suffix(win))
        var diffs = [Float](repeating: 0, count: win - 1)
        for k in 1..<win { diffs[k-1] = seg[k] - seg[k-1] }
        var rms: Float = 0
        vDSP_rmsqv(diffs, 1, &rms, vDSP_Length(win - 1))
        return min(rms * 6.0, 1.0)
    }
}
