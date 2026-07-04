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
    @AppStorage("sonar_enabled") private var sonarAktiv = false

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

            Toggle(isOn: $sonarAktiv) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Sonar (experimentell)", systemImage: "dot.radiowaves.left.and.right")
                    Text("Atmung/Bewegung via Ultraschall — auch vom Nachttisch")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .tint(.indigo)
        } header: {
            Text("Aufzeichnung")
        } footer: {
            if sonarAktiv {
                Text("Experimentell: Sendet nachts einen fast unhörbaren ~19 kHz-Ton und misst die reflektierte Atem-/Bewegungswelle. Wird nach der ersten Nacht feingetunt — bei Problemen einfach wieder ausschalten.")
            } else if soundEventsAktiv {
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
    @State private var zeigeSonarNacht = false
    @State private var normalisiereLaeuft = false
    @State private var normalisiereErgebnis: String?
    @State private var phasenLaeuft = false
    @State private var phasenErgebnis: String?
    @State private var zeigeTestdatenLoeschen = false
    @AppStorage("hmm_enabled") private var hmmAktiv = false
    @State private var zeigeFeatureLogs = false
    @State private var watchVergleichLaeuft = false
    @State private var watchVergleichErgebnis: String?

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

                Button { zeigeSonarNacht = true } label: {
                    Label("Sonar-Nachtlog (letzte Nacht)", systemImage: "moon.zzz.fill").foregroundStyle(.indigo)
                }
                .sheet(isPresented: $zeigeSonarNacht) { SonarNightLogView() }
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
                Toggle(isOn: $hmmAktiv) {
                    Label { VStack(alignment: .leading, spacing: 2) {
                        Text("HMM-Glätter (Beta)")
                        Text("Probabilistisches Gesamtnacht-Modell als letzter Pass — wirkt beim nächsten Tracking/Neuberechnen")
                            .font(.caption2).foregroundStyle(.secondary)
                    } } icon: { Image(systemName: "waveform.path.badge.plus").foregroundStyle(.indigo) }
                }

                Button { zeigeFeatureLogs = true } label: {
                    Label("Feature-Logs teilen (\(FeatureNightLog.allLogs().count) Nächte)", systemImage: "square.and.arrow.up")
                        .foregroundStyle(.indigo)
                }
                .disabled(FeatureNightLog.allLogs().isEmpty)
                .sheet(isPresented: $zeigeFeatureLogs) { ShareSheet(items: FeatureNightLog.allLogs()) }

                Button { watchVergleichStarten() } label: {
                    HStack {
                        Label("Mit Apple-Watch-Schlaf vergleichen", systemImage: "applewatch")
                            .foregroundStyle(.indigo)
                        if watchVergleichLaeuft { Spacer(); ProgressView() }
                    }
                }
                .disabled(watchVergleichLaeuft)
            } header: {
                Text("Analyse-Labor")
            } footer: {
                Text("Feature-Logs enthalten pro Minute alle Sensorwerte (kein Audio) — Grundlage, um Algorithmus-Änderungen offline gegen echte Nächte zu testen. Der Watch-Vergleich misst die Übereinstimmung der letzten Nacht mit Apples Schlafphasen.")
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
        .alert("Watch-Vergleich", isPresented: Binding(
            get: { watchVergleichErgebnis != nil }, set: { if !$0 { watchVergleichErgebnis = nil } }
        )) {
            Button("Kopieren") { UIPasteboard.general.string = watchVergleichErgebnis; watchVergleichErgebnis = nil }
            Button("OK", role: .cancel) { watchVergleichErgebnis = nil }
        } message: { Text(watchVergleichErgebnis ?? "") }
    }

    /// Ground-Truth-Vergleich: unsere Phasen der letzten Nacht vs. Apples (Watch-)Staging.
    private func watchVergleichStarten() {
        watchVergleichLaeuft = true
        Task { @MainActor in
            defer { watchVergleichLaeuft = false }
            var desc = FetchDescriptor<SleepSession>(
                predicate: #Predicate { $0.endDate != nil },
                sortBy: [SortDescriptor(\.startDate, order: .reverse)]
            )
            desc.fetchLimit = 1
            guard let session = try? modelContext.fetch(desc).first, let sEnd = session.endDate else {
                watchVergleichErgebnis = "Keine abgeschlossene Nacht gefunden."
                return
            }
            let hk = HealthKitService()
            await hk.requestAuthorization()
            let segments = await hk.readAppleWatchSleepPhases(from: session.startDate, to: sEnd)
            guard !segments.isEmpty else {
                watchVergleichErgebnis = "Keine Apple-Schlafphasen im Zeitraum gefunden. Wurde die Watch getragen und ist Schlaf-Tracking (Apple) aktiv? HealthKit-Leserecht erteilt?"
                return
            }
            let ours = session.phasesArray.sorted { $0.startDate < $1.startDate }
            func ourPhase(_ t: Date) -> SleepPhaseType? {
                ours.first(where: { $0.startDate <= t && t < $0.endDate })?.phaseType
            }
            func watchPhase(_ t: Date) -> SleepPhaseType? {
                segments.first(where: { $0.start <= t && t < $0.end })?.phase
            }
            var total = 0, both = 0, stageAgree = 0, wsAgree = 0
            var confusion: [String: Int] = [:]
            var t = session.startDate
            while t < sEnd {
                total += 1
                if let o = ourPhase(t), let w = watchPhase(t) {
                    both += 1
                    if o == w { stageAgree += 1 }
                    if (o == .awake) == (w == .awake) { wsAgree += 1 }
                    if o != w { confusion["\(w.rawValue)→\(o.rawValue)", default: 0] += 1 }
                }
                t = t.addingTimeInterval(60)
            }
            guard both > 0 else {
                watchVergleichErgebnis = "Keine überlappenden Minuten gefunden."
                return
            }
            let topConf = confusion.sorted { $0.value > $1.value }.prefix(3)
                .map { "\($0.key): \($0.value)m" }.joined(separator: ", ")
            watchVergleichErgebnis = """
            Überlappung: \(both)/\(total) Minuten
            Wach/Schlaf-Übereinstimmung: \(100 * wsAgree / both) %
            Phasen-Übereinstimmung: \(100 * stageAgree / both) %
            Häufigste Abweichungen (Watch→App): \(topConf)
            """
        }
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
    // Identischer Pfad wie in der realen Nacht (bindend): der Test läuft über die
    // GETEILTE AudioAnalysisService-Engine (Ton-Player, Format-Handling, Notch+Lowpass,
    // feedExternal) — nicht über die frühere Sonar-eigene Test-Engine. So testet man
    // vorab exakt das, was nachts passiert (der Nacht-Bug „Pegel 0" war nur im
    // geteilten Pfad und im alten Test unsichtbar).
    @State private var audio = AudioAnalysisService()
    @State private var laeuft = false
    @State private var feat = SonarFeatures.neutral
    @State private var kopiert = false

    private func startTest() {
        audio.sonar = sonar
        audio.sonarForced = true
        do {
            try audio.start()
            laeuft = true
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            audio.sonar = nil
        }
    }

    private func stopTest() {
        guard laeuft else { return }
        audio.stop()
        audio.sonar = nil
        laeuft = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

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
                        // Bildschirm wachhalten — sonst sperrt iOS und suspendiert den Test
                        // (nur der Test; nachts läuft es via Background-Audio weiter).
                        if laeuft { stopTest() } else { startTest() }
                    } label: {
                        Label(laeuft ? "Stoppen" : "Sonar starten (realer Nacht-Pfad)",
                              systemImage: laeuft ? "stop.fill" : "play.fill")
                            .font(.headline).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding()
                            .background(laeuft ? Color.red : Color.indigo, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)

                    Button {
                        UIPasteboard.general.string = sonar.logText()
                        kopiert = true
                    } label: {
                        Label(kopiert ? "Kopiert ✓ — hier einfügen" : "Verlauf kopieren (\(sonar.log.count) Zeilen)",
                              systemImage: kopiert ? "checkmark" : "doc.on.doc")
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(sonar.log.isEmpty)

                    Text("Sendet einen fast unhörbaren ~19 kHz-Ton und misst die von Brustkorb/Körper reflektierte Welle. Lege das iPhone wie zum Schlafen ab (Matratze oder Nachttisch) und atme ruhig — die Atemfrequenz sollte sich einpendeln, Bewegung schlägt bei Wälzen aus.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Sonar-Test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") {
                        stopTest()
                        dismiss()
                    }
                }
            }
            .onDisappear { stopTest() }
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

// MARK: - Feature-Nachtlog (Replay-Grundlage, bewusst in dieser in-Target-Datei)

/// Schreibt pro Nacht eine CSV mit ALLEN Sensor-Features pro Minute (kein Audio).
/// Zweck: Algorithmus-Änderungen offline gegen echte Nächte durchrechnen (Replay),
/// statt jede Änderung mit einer Schlafnacht zu bezahlen. Behält die letzten 14 Nächte.
final class FeatureNightLog {
    static let shared = FeatureNightLog()
    private var active = false
    private var url: URL?
    private var lastRow = Date.distantPast
    private init() {}

    static var logDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    static func allLogs() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("FeatureLog-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
    }

    func begin() {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmm"
        let file = FeatureNightLog.logDirectory.appendingPathComponent("FeatureLog-\(f.string(from: Date())).csv")
        let header = "# SLEEPBUDDY FEATURELOG — Start \(Date())\n"
            + "zeit,amp,ampVar,atem_best,reg_best,atem_audio,atem_accel,reg_accel,bewegung,onMattress,"
            + "sonar_atem,sonar_reg,sonar_bew,sonar_pegel,sonar_signal,sonar_puls,bcg_hr,watch_hr,phase\n"
        try? header.write(to: file, atomically: true, encoding: .utf8)
        url = file
        active = true
        lastRow = .distantPast
        // Rotation: nur die letzten 14 Nächte behalten.
        let logs = FeatureNightLog.allLogs()
        if logs.count > 14 { for old in logs.dropFirst(14) { try? FileManager.default.removeItem(at: old) } }
    }

    func end() { active = false; url = nil }

    /// Eine Zeile pro Minute (intern gedrosselt) — Aufruf aus handleFeatures ist billig.
    func append(audio: AudioFeatures, motion: MotionFeatures, sonar: SonarFeatures,
                sonarLevel: Float, bcgHR: Int, watchHR: Double, phase: SleepPhaseType) {
        guard active, let url, Date().timeIntervalSince(lastRow) >= 60 else { return }
        lastRow = Date()
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        let bestBreath = motion.breathingRateBPM > 0 ? motion.breathingRateBPM : audio.breathingRateBPM
        let bestReg = motion.breathingRateBPM > 0 ? motion.breathingRegularity : audio.breathingRegularity
        let line = String(format: "%@,%.5f,%.6f,%.1f,%.2f,%.1f,%.1f,%.2f,%.3f,%d,%.1f,%.2f,%.2f,%.5f,%d,%d,%d,%.0f,%@\n",
                          f.string(from: Date()),
                          audio.averageAmplitude, audio.amplitudeVariance,
                          bestBreath, bestReg,
                          audio.breathingRateBPM, motion.breathingRateBPM, motion.breathingRegularity,
                          motion.movementIntensity, motion.isOnMattress ? 1 : 0,
                          sonar.breathingRateBPM, sonar.breathingRegularity, sonar.movementIntensity,
                          sonarLevel, sonar.signalPresent ? 1 : 0, Int(sonar.heartRateBPM),
                          bcgHR, watchHR, phase.rawValue)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            if let d = line.data(using: .utf8) { h.write(d) }
            try? h.close()
        }
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
    var heartRateBPM: Float = 0     // EXPERIMENTELL: Puls aus der Reflexion (0 = kein Lock)

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
    /// Protokoll der emittierten Fenster (für Copy/Paste-Diagnose).
    private(set) var log: [String] = []
    private var logStart = Date()

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

    // Stabilitäts-Historie des Sonar-Pulses (Gate für die Fusion).
    private var recentSonarHR: [Float] = []

    // Nacht-Statistik: Anteil der Fenster mit Atem-Lock (Geräteprofil-Grundlage).
    private(set) var emitCount = 0
    private(set) var lockCount = 0
    var nightLockRate: Double { emitCount > 0 ? Double(lockCount) / Double(emitCount) : 0 }

    // Halten des letzten guten Atemwerts über kurze Lücken (bei Ruhe).
    private var lastGoodBpm: Float = 0
    private var lastGoodReg: Float = 0
    private var lastGoodAt = Date.distantPast

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

    // MARK: - Externer Betrieb (Tracking): keine eigene Engine/Ton — der AudioAnalysisService
    // spielt den Ton und liefert die Roh-Buffer. Nur Demodulation + Feature-Emit.

    /// Für das Tracking: Zustand zurücksetzen, ohne eine eigene Engine zu starten.
    func resetForTracking() { reset() }

    // MARK: - Nacht-Log (Datei, für Analyse über die ganze Nacht)

    private var nightLogActive = false
    static var nightLogURL: URL {
        (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("SonarNightLog.csv")
    }

    func beginNightLog() {
        let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy HH:mm"
        let header = "# SLEEPBUDDY SONAR-NACHTLOG — Start \(f.string(from: Date()))\n# zeit,atem_bpm,reg_pct,bew_pct,pegel,signal,puls_bpm\n"
        try? header.write(to: Self.nightLogURL, atomically: true, encoding: .utf8)
        nightLogActive = true
    }

    func endNightLog() { nightLogActive = false }

    private func appendNightLine(bpm: Float, reg: Float, mov: Float, pegel: Float, present: Bool, hr: Float = 0) {
        guard nightLogActive else { return }
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        // puls_bpm als LETZTE Spalte angehängt — bestehende Spalten-Indizes (Summary-Parser)
        // bleiben unverändert gültig.
        let line = "\(f.string(from: Date())),\(Int(bpm)),\(Int(reg*100)),\(Int(mov*100)),\(String(format: "%.4f", pegel)),\(present ? 1 : 0),\(Int(hr))\n"
        if let h = try? FileHandle(forWritingTo: Self.nightLogURL) {
            h.seekToEndOfFile()
            if let d = line.data(using: .utf8) { h.write(d) }
            try? h.close()
        }
    }

    /// Roh-Mikrofon-Buffer von außen einspeisen (enthält den vom AudioAnalysisService
    /// gespielten 19-kHz-Ton + Reflexion).
    func feedExternal(_ buffer: AVAudioPCMBuffer) {
        processQueue.async { [weak self] in self?.process(buffer: buffer) }
    }

    private func reset() {
        carrierPhase = 0
        emitCount = 0
        lockCount = 0
        recentSonarHR.removeAll()
        lastGoodBpm = 0; lastGoodReg = 0; lastGoodAt = .distantPast
        log.removeAll()
        logStart = Date()
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

        // I/Q glätten (Ein-Pol-Tiefpass ~3 Hz @ 50 Hz) → weniger Demod-Rauschen.
        let iS = lowpass(iBB, alpha: 0.30)
        let qS = lowpass(qBB, alpha: 0.30)

        // CLUTTER-REMOVAL (bindend): Der statische Reflexionsanteil (Wände, Decke, Bettgestell)
        // dominiert I/Q und „friert" die Rohphase ein → das kleine Atem-Signal geht unter.
        // Deshalb den DC (Mittelwert = statischer Anteil) abziehen; übrig bleibt die
        // BEWEGTE Komponente (Atmung/Körper).
        var mi: Float = 0, mq: Float = 0
        vDSP_meanv(iS, 1, &mi, vDSP_Length(count))
        vDSP_meanv(qS, 1, &mq, vDSP_Length(count))
        var ir = [Float](repeating: 0, count: count)
        var qr = [Float](repeating: 0, count: count)
        for k in 0..<count { ir[k] = iS[k] - mi; qr[k] = qS[k] - mq }

        // Hauptbewegungsachse (2D-PCA) → 1D-Signal, das im Atemtakt schwingt.
        var sii: Float = 0, sqq: Float = 0, siq: Float = 0
        vDSP_measqv(ir, 1, &sii, vDSP_Length(count))
        vDSP_measqv(qr, 1, &sqq, vDSP_Length(count))
        vDSP_dotpr(ir, 1, qr, 1, &siq, vDSP_Length(count)); siq /= Float(count)
        let theta = 0.5 * atan2(2*siq, sii - sqq)
        let ct = cos(theta), st = sin(theta)
        var motionSig = [Float](repeating: 0, count: count)
        for k in 0..<count { motionSig[k] = ir[k]*ct + qr[k]*st }
        // Kopie VOR Detrend/Atem-Glättung sichern — Quelle für das Herz-Band (0,7–1,8 Hz).
        let heartSrc = motionSig

        // Signalpräsenz = Stärke des STATISCHEN Reflexionsanteils (Ton reflektiert überhaupt).
        let meanMag = sqrt(mi*mi + mq*mq)
        signalLevel = meanMag
        let present = meanMag > 1e-4

        detrend(&motionSig)
        motionSig = lowpass(motionSig, alpha: 0.5)   // Atemband glätten
        // Atmung aus der clutter-bereinigten Bewegungskomponente (das war der Fix).
        var (bpm, reg) = breathing(from: motionSig, rate: basebandRate)

        // Bewegung aus der Rohphase (guter absoluter Maßstab: still = klein, Wälzen = groß).
        var phase = [Float](repeating: 0, count: count)
        for k in 0..<count { phase[k] = atan2(qS[k], iS[k]) }
        unwrap(&phase)
        detrend(&phase)
        let movement = movementLevel(phase: phase, rate: basebandRate)

        // EXPERIMENTELL: Puls aus der Sonar-Reflexion. Nur bei ruhigem Liegen versucht
        // (Bewegung zerstört das winzige Herz-Signal). Die CSV loggt den ROHWERT
        // (Diagnose); in die Fusion (SonarFeatures.heartRateBPM) geht nur ein
        // STABILER Wert: mindestens 2 der letzten 3 Messungen innerhalb ±8 BPM —
        // einzelne Flacker-Locks (94 → 42 → 0) erreichen die Puls-Reihe so nie.
        let sonarHR: Float = (present && movement < 0.3) ? heartRate(from: heartSrc, rate: basebandRate) : 0
        var gatedHR: Float = 0
        if sonarHR > 0 {
            let near = recentSonarHR.suffix(3).filter { abs($0 - sonarHR) <= 8 }
            if near.count >= 2 { gatedHR = sonarHR }
        }
        recentSonarHR.append(sonarHR)
        if recentSonarHR.count > 6 { recentSonarHR.removeFirst() }

        // Kontinuität: letzten guten Atemwert über kurze Lücken halten, solange ruhig
        // (kein starkes Wälzen) und der letzte Lock < 25 s her ist. Regularität wird dabei
        // abgewertet (gehaltener Wert = geringere Konfidenz).
        let nowT = Date()
        if bpm > 0 {
            lastGoodBpm = bpm; lastGoodReg = reg; lastGoodAt = nowT
        } else if movement < 0.4, lastGoodBpm > 0, nowT.timeIntervalSince(lastGoodAt) < 25 {
            bpm = lastGoodBpm
            reg = lastGoodReg * 0.6
        }

        emitCount += 1
        if present && bpm > 0 { lockCount += 1 }
        let feat = SonarFeatures(
            breathingRateBPM: present ? bpm : 0,
            breathingRegularity: present ? reg : 0,
            movementIntensity: movement,
            signalPresent: present,
            heartRateBPM: gatedHR
        )
        // Letzte ~6 s der Atem-Bewegungskomponente als Wellenform fürs UI
        let tail = Array(motionSig.suffix(Int(basebandRate * 6)))
        let elapsed = Date().timeIntervalSince(logStart)
        let line = String(format: "%5.0fs  Atem %2.0f/min  Reg %3.0f%%  Bew %3.0f%%  Puls %3.0f  Pegel %.5f  %@",
                          elapsed, bpm, reg * 100, movement * 100, sonarHR, meanMag,
                          present ? "OK" : "-")
        appendNightLine(bpm: bpm, reg: reg, mov: movement, pegel: meanMag, present: present, hr: sonarHR)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.latest = feat
            self.waveform = tail
            self.log.append(line)
            if self.log.count > 400 { self.log.removeFirst() }
            self.onFeaturesUpdated?(feat)
        }
    }

    /// Vollständiger, kopierbarer Diagnose-Text (Geräte-Infos + Verlauf).
    func logText() -> String {
        var s = "SLEEPBUDDY SONAR-DIAGNOSE\n"
        s += String(format: "Träger %.0f Hz · Ton-Amp %.2f · Input %.0f Hz · Output %.0f Hz · Dezim %d\n",
                    carrier, toneAmplitude, inputSampleRate, outputSampleRate, decim)
        s += "Spalten: Zeit · Atemfrequenz · Regelmäßigkeit · Bewegung · Puls (experimentell) · Reflexions-Pegel · Signal\n"
        s += "— — —\n"
        s += log.joined(separator: "\n")
        return s
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

    /// Atemfrequenz via Autokorrelation im **8–22 BPM-Band** (Ruhe-/Schlafatmung) + Peak-Stärke
    /// als Regularität. Rastet der Peak am Bandrand oder ist er zu schwach ausgeprägt, wird
    /// (0, 0) zurückgegeben statt eines unplausiblen Werts (kein „Latching" auf 22/8).
    private func breathing(from signal: [Float], rate: Double) -> (bpm: Float, reg: Float) {
        let n = signal.count
        guard n > Int(rate * 6) else { return (0, 0) }
        var energy: Float = 0
        vDSP_measqv(signal, 1, &energy, vDSP_Length(n))     // mittlere Leistung
        guard energy > 1e-12 else { return (0, 0) }

        let minLag = Int(rate * 60.0 / 22.0)   // 22 BPM
        let maxLag = min(Int(rate * 60.0 / 8.0), n - 1)   // 8 BPM
        guard maxLag > minLag + 2 else { return (0, 0) }

        var acf = [Float](repeating: 0, count: maxLag + 1)
        signal.withUnsafeBufferPointer { buf in
            let base = buf.baseAddress!
            for lag in minLag...maxLag {
                var dot: Float = 0
                vDSP_dotpr(base, 1, base + lag, 1, &dot, vDSP_Length(n - lag))
                acf[lag] = dot / (energy * Float(n - lag))
            }
        }
        // Bestes lokales Maximum im Band (kein Rand-Latch).
        var bestLag = -1
        var bestVal: Float = -.greatestFiniteMagnitude
        var mean: Float = 0
        for lag in (minLag+1)...(maxLag-1) {
            mean += acf[lag]
            if acf[lag] > acf[lag-1] && acf[lag] >= acf[lag+1] && acf[lag] > bestVal {
                bestVal = acf[lag]; bestLag = lag
            }
        }
        mean /= Float(maxLag - minLag - 1)
        // Prominenz-Gate: der Peak muss über dem ACF-Mittel liegen und positiv sein.
        // Moderat (nicht zu streng) — echte Atmung lockt so durchgängiger, ohne dass
        // Rauschen an den Bandrändern durchrutscht (Rand-Latch ist separat ausgeschlossen).
        guard bestLag > 0, bestVal > 0.08, bestVal > mean + 0.05 else { return (0, 0) }
        let bpm = Float(rate * 60.0 / Double(bestLag))
        let reg = min(max(bestVal, 0), 1)
        return (bpm, reg)
    }

    /// EXPERIMENTELL: Puls (40–110 BPM) aus der clutter-bereinigten Bewegungskomponente.
    /// Der Herzschlag bewegt die Brustwand nur ~0,2–0,5 mm — eine Größenordnung schwächer
    /// als die Atmung, daher strengere Gates (nur bei Ruhe, höhere Prominenz-Schwelle).
    /// Hochpass (1,2-s-MA) entfernt das Atemband; Autokorrelation wie bei der Atmung.
    private func heartRate(from signal: [Float], rate: Double) -> Float {
        let n = signal.count
        let win = min(n, Int(rate * 20))                 // letzte ~20 s
        guard win > Int(rate * 10) else { return 0 }
        let src = Array(signal.suffix(win))
        // Bandpass 0,5–2,5 Hz aus zwei EIN-POL-Filtern (kein Moving Average!):
        // Der frühere MA-Hochpass (1,2-s-Fenster) erzeugte selbst ein ACF-Artefakt
        // bei der HALBEN Fensterlänge (~30 Samples ≙ ~96 BPM) — real beobachtet:
        // 2034/2165 Nacht-Locks klebten bei 93–100 BPM, stundenlang konstant ~96,
        // während der echte Puls (BCG) bei 55–70 lag. Ein-Pol-IIR-Filter haben
        // keine solche Lag-Signatur.
        var lpSlow = [Float](repeating: 0, count: win)   // ~0.5 Hz (Atmung/Drift)
        var acc: Float = src.first ?? 0
        let aSlow: Float = 0.059                          // dt/(RC+dt), fc≈0.5 Hz @ 50 Hz
        for i in 0..<win { acc += aSlow * (src[i] - acc); lpSlow[i] = acc }
        var seg = [Float](repeating: 0, count: win)
        var smooth: Float = 0
        let aFast: Float = 0.24                           // fc≈2.5 Hz @ 50 Hz
        for i in 0..<win {
            let hp = src[i] - lpSlow[i]                   // Atemband raus
            smooth += aFast * (hp - smooth)               // Rauschen > 2.5 Hz raus
            seg[i] = smooth
        }
        var energy: Float = 0
        vDSP_measqv(seg, 1, &energy, vDSP_Length(win))
        guard energy > 1e-14 else { return 0 }
        let minLag = Int(rate * 60.0 / 110.0)            // 110 BPM
        let maxLag = min(Int(rate * 60.0 / 40.0), win - 2) // 40 BPM
        guard maxLag > minLag + 2 else { return 0 }
        var acf = [Float](repeating: 0, count: maxLag + 1)
        seg.withUnsafeBufferPointer { buf in
            let base = buf.baseAddress!
            for lag in minLag...maxLag {
                var dot: Float = 0
                vDSP_dotpr(base, 1, base + lag, 1, &dot, vDSP_Length(win - lag))
                acf[lag] = dot / (energy * Float(win - lag))
            }
        }
        var bestLag = -1
        var bestVal: Float = -.greatestFiniteMagnitude
        var mean: Float = 0
        for lag in (minLag+1)...(maxLag-1) {
            mean += acf[lag]
            if acf[lag] > acf[lag-1] && acf[lag] >= acf[lag+1] && acf[lag] > bestVal {
                bestVal = acf[lag]; bestLag = lag
            }
        }
        mean /= Float(maxLag - minLag - 1)
        // Strenger als Atmung (0.15/0.08): das Herz-Signal ist winzig — lieber 0 als Müll.
        guard bestLag > 0, bestVal > 0.15, bestVal > mean + 0.08 else { return 0 }
        return Float(rate * 60.0 / Double(bestLag))
    }

    /// Bewegungsintensität: kurzfristige Energie schneller Phasenänderungen (Körperbewegung
    /// erzeugt große, schnelle Ausschläge; ruhiges Atmen nur kleine, langsame). Gain moderat,
    /// damit ruhiges Liegen nicht sättigt.
    private func movementLevel(phase: [Float], rate: Double) -> Float {
        let n = phase.count
        let win = min(n, Int(rate * 5))    // letzte ~5 s
        guard win > 2 else { return 0 }
        let seg = Array(phase.suffix(win))
        var diffs = [Float](repeating: 0, count: win - 1)
        for k in 1..<win { diffs[k-1] = seg[k] - seg[k-1] }
        var rms: Float = 0
        vDSP_rmsqv(diffs, 1, &rms, vDSP_Length(win - 1))
        // kleiner Rausch-Sockel abgezogen, dann skaliert
        return min(max(rms - 0.02, 0) * 3.0, 1.0)
    }

    /// Einfacher Ein-Pol-Tiefpass (Glättung) über ein Array.
    private func lowpass(_ x: [Float], alpha: Float) -> [Float] {
        guard !x.isEmpty else { return x }
        var out = x
        for k in 1..<x.count { out[k] = out[k-1] + alpha * (x[k] - out[k-1]) }
        return out
    }
}

// MARK: - SonarNightLogView (kompakte Zusammenfassung der Nacht + Datei teilen)

struct SonarNightLogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var summary = "Lade…"
    @State private var kopiert = false
    @State private var zeigeShare = false

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(summary)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Sonar-Nachtlog")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = summary
                        kopiert = true
                    } label: {
                        Label(kopiert ? "Kopiert ✓" : "Kopieren", systemImage: kopiert ? "checkmark" : "doc.on.doc")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    zeigeShare = true
                } label: {
                    Label("Volle Datei teilen (CSV)", systemImage: "square.and.arrow.up")
                        .font(.subheadline.bold()).frame(maxWidth: .infinity).padding()
                        .background(Color.indigo, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.white)
                }
                .buttonStyle(.plain).padding()
                .sheet(isPresented: $zeigeShare) { ShareSheet(items: [SonarService.nightLogURL]) }
            }
            .onAppear { summary = Self.buildSummary() }
        }
    }

    /// Parst die CSV-Nachtdatei und baut eine kurze, pastebare Zusammenfassung.
    static func buildSummary() -> String {
        guard let text = try? String(contentsOf: SonarService.nightLogURL, encoding: .utf8) else {
            return "Noch kein Nachtlog vorhanden.\nSonar in den Einstellungen aktivieren und eine Nacht tracken."
        }
        var bpms: [Int] = []
        var movHigh = 0, presentCnt = 0, total = 0
        var firstT = "", lastT = ""
        for raw in text.split(separator: "\n") {
            if raw.hasPrefix("#") { continue }
            let c = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard c.count >= 6 else { continue }
            total += 1
            if firstT.isEmpty { firstT = c[0] }
            lastT = c[0]
            if let b = Int(c[1]), b > 0 { bpms.append(b) }
            if let m = Int(c[3]), m >= 30 { movHigh += 1 }
            if c[5] == "1" { presentCnt += 1 }
        }
        guard total > 0 else { return "Nachtlog ist leer (keine Sonar-Daten aufgezeichnet)." }
        let sorted = bpms.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count/2]
        let lo = sorted.first ?? 0, hi = sorted.last ?? 0
        let breathPct = Int(Double(bpms.count) / Double(total) * 100)
        let movPct = Int(Double(movHigh) / Double(total) * 100)
        let presPct = Int(Double(presentCnt) / Double(total) * 100)
        var s = "SONAR-NACHT — ZUSAMMENFASSUNG\n"
        s += "Zeitraum: \(firstT) – \(lastT)\n"
        s += "Fenster gesamt: \(total) (à ~5 s)\n"
        s += "Signal vorhanden: \(presPct)%\n"
        s += "Atem erkannt: \(breathPct)% der Zeit\n"
        s += "Atemrate: Median \(median)/min (Bereich \(lo)–\(hi))\n"
        s += "Bewegung ≥30%: \(movPct)% der Zeit\n"
        return s
    }
}
