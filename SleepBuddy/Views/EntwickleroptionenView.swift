import SwiftUI
import SwiftData

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
    @State private var zeigeDebugPaket = false
    @State private var debugPaketDateien: [URL] = []

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

                Button { debugPaketErstellen() } label: {
                    Label("Debug-Paket teilen (alles)", systemImage: "shippingbox.fill")
                        .foregroundStyle(.indigo)
                }
                .sheet(isPresented: $zeigeDebugPaket) {
                    ShareSheet(items: debugPaketDateien)
                }
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


    /// Ein Button, alles drin: Einstellungen/Parameter, Korrektur-Protokoll, Phasen der
    /// letzten Nacht (JSON), Feature-Log, Sonar-Log, ML-Log, Watch-Referenz.
    private func debugPaketErstellen() {
        let dir = FeatureNightLog.logDirectory
        let ud = UserDefaults.standard
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let hb = ud.double(forKey: "tracking.heartbeat")
        let hbText = hb > 0 ? "\(Date(timeIntervalSince1970: hb))" : "nie"

        var info = """
        SLEEPBUDDY DEBUG-PAKET — \(Date())
        Version: \(version) (\(build))
        Sonar: \(ud.bool(forKey: "sonar_enabled")) | Ton aktuell: \(ud.double(forKey: "debug.sonarAmpCurrent")) | Sweet-Spot: \(ud.double(forKey: "device.sonarGoodAmp"))
        Partner: \(ud.bool(forKey: "partnerModus_aktiv")) Stufe \(ud.integer(forKey: "partnerModus_stufe")) | Sounds: \(ud.bool(forKey: "soundEvents_enabled")) | HMM: \(ud.bool(forKey: "hmm_enabled"))
        Letzter Tracking-Heartbeat: \(hbText)

        """
        info += PassAudit.text

        // Phasen der letzten Nacht als JSON
        var desc = FetchDescriptor<SleepSession>(
            predicate: #Predicate { $0.endDate != nil },
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        desc.fetchLimit = 1
        if let session = try? modelContext.fetch(desc).first {
            var phasen = "[\n"
            for ph in session.phasesArray.sorted(by: { $0.startDate < $1.startDate }) {
                phasen += "  {\"phase\": \"\(ph.phaseType.rawValue)\", \"von\": \"\(ph.startDate)\", \"bis\": \"\(ph.endDate)\"},\n"
            }
            phasen += "]"
            let phasenURL = dir.appendingPathComponent("Phasen.json")
            try? phasen.write(to: phasenURL, atomically: true, encoding: .utf8)

            // TrainingSamples.csv — die maßgebliche Eingabe ALLER Korrektur-Pässe
            // (Bewegung/Atem/Regularität pro 30 s). Ohne sie rechnet das Offline-
            // Replay mit anderen Daten als das Gerät (real passiert: 50 % → 42 %).
            let sStart = session.startDate
            let sEnd = session.endDate ?? Date()
            let tsDesc = FetchDescriptor<TrainingSample>(
                predicate: #Predicate { $0.timestamp >= sStart && $0.timestamp <= sEnd },
                sortBy: [SortDescriptor(\.timestamp)]
            )
            if let samples = try? modelContext.fetch(tsDesc), !samples.isEmpty {
                let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"
                var csv = "timestamp,amp,ampVar,atem_bpm,atem_reg,bewegung,schnarchen,label,korrigiert\n"
                for s in samples {
                    csv += "\(df.string(from: s.timestamp)),\(s.averageAmplitude),\(s.amplitudeVariance),\(s.breathingRateBPM),\(s.breathingRegularity),\(s.movementIntensity),\(s.snoringIntensity),\(s.label),\(s.isUserCorrected)\n"
                }
                try? csv.write(to: dir.appendingPathComponent("TrainingSamples.csv"), atomically: true, encoding: .utf8)
            }

            // SessionState.json — alles, was die Pässe außerhalb der Samples lesen:
            // Session-Zeiten, Onset, Wecker, gespeicherte Puls-Reihe (inkl. Watch-
            // Backfill) und die über Nächte gelernten persönlichen Baselines.
            let df2 = DateFormatter(); df2.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let hrList = session.heartRateSamples.map { String(format: "%.1f", $0) }.joined(separator: ",")
            let noiseList = session.noiseSamples.map { String(format: "%.1f", $0) }.joined(separator: ",")
            func d(_ date: Date?) -> String { date.map { "\"\(df2.string(from: $0))\"" } ?? "null" }
            let state = """
            {
              "startDate": \(d(session.startDate)),
              "endDate": \(d(session.endDate)),
              "sleepOnsetDate": \(d(session.sleepOnsetDate)),
              "alarmFiredDate": \(d(session.alarmFiredDate)),
              "heartRateSamples": [\(hrList)],
              "noiseSamples": [\(noiseList)],
              "cal_hrMedian": \(ud.double(forKey: "cal_hrMedian")),
              "cal_hrDeepFloor": \(ud.double(forKey: "cal_hrDeepFloor")),
              "cal_brSlowRate": \(ud.double(forKey: "cal_brSlowRate")),
              "cal_brRegHigh": \(ud.double(forKey: "cal_brRegHigh")),
              "cal_brRegLow": \(ud.double(forKey: "cal_brRegLow")),
              "cal_quietAmplitude": \(ud.double(forKey: "cal_quietAmplitude")),
              "cal_nightCount": \(ud.integer(forKey: "cal_nightCount"))
            }
            """
            try? state.write(to: dir.appendingPathComponent("SessionState.json"), atomically: true, encoding: .utf8)
        }

        let infoURL = dir.appendingPathComponent("DebugInfo.txt")
        try? info.write(to: infoURL, atomically: true, encoding: .utf8)

        var items: [URL] = [infoURL]
        for name in ["Phasen.json", "TrainingSamples.csv", "SessionState.json", "SonarNightLog.csv", "MLLog.csv", "WatchRef.csv"] {
            let u = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: u.path) { items.append(u) }
        }
        if let latestFeature = FeatureNightLog.allLogs().first { items.append(latestFeature) }

        // ALLES in EIN Zip packen (Upload-Limits: 8 Einzeldateien sind zu viele).
        // NSFileCoordinator mit .forUploading zippt einen Ordner ohne Fremdbibliothek.
        let fm = FileManager.default
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmm"
        let bundleDir = fm.temporaryDirectory.appendingPathComponent("DebugPaket-\(df.string(from: Date()))")
        try? fm.removeItem(at: bundleDir)
        try? fm.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        for u in items {
            try? fm.copyItem(at: u, to: bundleDir.appendingPathComponent(u.lastPathComponent))
        }
        var zipURL: URL?
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        coordinator.coordinate(readingItemAt: bundleDir, options: .forUploading, error: &coordError) { tempZip in
            // tempZip lebt nur innerhalb des Blocks — an einen stabilen Ort kopieren.
            let dest = dir.appendingPathComponent(bundleDir.lastPathComponent + ".zip")
            try? fm.removeItem(at: dest)
            if (try? fm.copyItem(at: tempZip, to: dest)) != nil { zipURL = dest }
        }
        // Fallback: Zippen fehlgeschlagen → Einzeldateien wie bisher teilen.
        debugPaketDateien = zipURL.map { [$0] } ?? items
        zeigeDebugPaket = true
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
            // Ground-Truth-CSV für Replay/Tuning: Apples Phase pro Minute neben unserer,
            // plus echter Watch-Puls (welche Puls-Signatur haben die ECHTEN Phasen —
            // und wo weicht unsere gespeicherte BCG/Sonar-Reihe vom echten Puls ab?)
            // und unsere gespeicherte HR-Reihe zum direkten Vergleich.
            // Watch-Ground-Truth-Serien: Puls, Atemfrequenz, SpO₂, HRV. Alles pro
            // Minute neben die Phasen — Basis für Signatur-Analysen und HMM-Training.
            func byMinute(_ series: [(date: Date, value: Double)]) -> [Int: Double] {
                var out: [Int: Double] = [:]
                for (d, v) in series {
                    out[Int(d.timeIntervalSince(session.startDate) / 60)] = v
                }
                return out
            }
            let hrByMin = byMinute(await hk.readHeartRateSeries(from: session.startDate, to: sEnd)
                .map { (date: $0.date, value: $0.bpm) })
            let atemByMin = byMinute(await hk.readRespiratorySeries(from: session.startDate, to: sEnd))
            let spo2ByMin = byMinute(await hk.readSpO2Series(from: session.startDate, to: sEnd))
            let hrvByMin = byMinute(await hk.readHRVSeries(from: session.startDate, to: sEnd))
            func fmt(_ v: Double?, _ format: String = "%.0f") -> String {
                v.map { String(format: format, $0) } ?? "-"
            }
            var refCSV = "# WATCH-REFERENZ \(session.startDate)\nminute,watch,app,watch_hr,app_hr,watch_atem,watch_spo2,watch_hrv\n"
            var tt = session.startDate; var mi = 0
            while tt < sEnd {
                let ahr = mi < session.heartRateSamples.count && session.heartRateSamples[mi] > 0
                    ? String(format: "%.0f", session.heartRateSamples[mi]) : "-"
                refCSV += "\(mi),\(watchPhase(tt)?.rawValue ?? "-"),\(ourPhase(tt)?.rawValue ?? "-"),"
                refCSV += "\(fmt(hrByMin[mi])),\(ahr),\(fmt(atemByMin[mi], "%.1f")),\(fmt(spo2ByMin[mi])),\(fmt(hrvByMin[mi]))\n"
                tt = tt.addingTimeInterval(60); mi += 1
            }
            let refURL = FeatureNightLog.logDirectory.appendingPathComponent("WatchRef.csv")
            try? refCSV.write(to: refURL, atomically: true, encoding: .utf8)

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

