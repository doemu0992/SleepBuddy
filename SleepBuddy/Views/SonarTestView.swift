import SwiftUI
import AVFoundation

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
