import SwiftUI
import SwiftData
#if canImport(FoundationModels)
import FoundationModels
#endif

struct MorgenBerichtCard: View {
    let session: SleepSession
    @Query(sort: \SleepSession.startDate, order: .reverse) private var alleSessions: [SleepSession]

    @State private var bericht: String? = nil
    @State private var isGenerating = false
    @State private var hasGenerated = false

    // Previous sessions for comparison (excluding current)
    private var vorherige: [SleepSession] {
        alleSessions.filter { !$0.isActive && $0.startDate < session.startDate }
    }

    private var gestern: SleepSession? { vorherige.first }

    private var wochenSchnittQual: Int? {
        let letzte7 = vorherige.prefix(7)
        guard letzte7.count >= 2 else { return nil }
        return letzte7.map { SchlafindexView.score(for: $0) }.reduce(0, +) / letzte7.count
    }

    private var wochenSchnittDauer: Double? {
        let letzte7 = vorherige.prefix(7)
        guard letzte7.count >= 2 else { return nil }
        return letzte7.map { $0.totalDuration / 3600 }.reduce(0, +) / Double(letzte7.count)
    }

    private var currentScore: Int { SchlafindexView.score(for: session) }
    private var gesternScore: Int? { gestern.map { SchlafindexView.score(for: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Morgen-Report", systemImage: "sun.horizon.fill")
                    .font(.headline).foregroundStyle(.indigo)
                Spacer()
                if hasGenerated {
                    Button {
                        bericht = nil
                        hasGenerated = false
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption).foregroundStyle(.indigo)
                    }
                    .buttonStyle(.plain)
                }
            }

            if isGenerating {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Report wird erstellt…").font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else if let text = bericht {
                Text(text)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button {
                    Task { await generate() }
                } label: {
                    Label("Report generieren", systemImage: "sparkles")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.indigo, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
    }

    // MARK: - Generation

    private func generate() async {
        isGenerating = true
        if #available(iOS 26, *) {
            await generateWithFoundationModels()
        } else {
            bericht = templateReport()
        }
        hasGenerated = true
        isGenerating = false
    }

    @available(iOS 26, *)
    private func generateWithFoundationModels() async {
        do {
            let lmSession = LanguageModelSession()
            let response = try await lmSession.respond(to: buildPrompt())
            bericht = response.content
        } catch {
            bericht = templateReport()
        }
    }

    private func buildPrompt() -> String {
        let qualityInt = currentScore
        let totalHours = String(format: "%.1f", session.totalDuration / 3600)
        let deepMin = Int(session.deepSleepDuration / 60)
        let remMin = Int(session.remSleepDuration / 60)
        let snoring = session.snoringEventCount
        let bruxism = session.bruxismEventCount
        let coughing = session.coughingEventCount

        var vergleichsText = ""
        if let gs = gesternScore {
            vergleichsText += "\n- Vortag Qualität: \(gs)%"
        }
        if let wq = wochenSchnittQual, let wd = wochenSchnittDauer {
            vergleichsText += "\n- 7-Tage-Schnitt Qualität: \(wq)%, Dauer: \(String(format: "%.1f", wd))h"
        }

        return """
        Schlaf-Analyse für diese Nacht:
        - Schlafqualität: \(qualityInt)%
        - Gesamtschlafdauer: \(totalHours) Stunden
        - Tiefschlaf: \(deepMin) Minuten
        - REM-Schlaf: \(remMin) Minuten
        - Schnarchen: \(snoring)× erkannt
        - Zähneknirschen: \(bruxism)× erkannt
        - Husten: \(coughing)× erkannt\(vergleichsText)

        Erstelle einen kurzen, freundlichen Morgen-Report auf Deutsch (3–4 Sätze). Vergleiche diese Nacht mit dem Vortag und dem Wochendurchschnitt wenn vorhanden. Keine Diagnosen, nur Beobachtungen und einen Tipp für den Tag.
        """
    }

    private func templateReport() -> String {
        let quality = currentScore
        let totalHours = session.totalDuration / 3600
        let deepMin = Int(session.deepSleepDuration / 60)
        let remMin = Int(session.remSleepDuration / 60)
        let snoring = session.snoringEventCount
        let bruxism = session.bruxismEventCount

        var lines: [String] = []

        let qualityLabel: String
        if quality >= 75 { qualityLabel = "sehr gute" }
        else if quality >= 55 { qualityLabel = "gute" }
        else if quality >= 35 { qualityLabel = "mäßige" }
        else { qualityLabel = "schlechte" }

        lines.append(String(format: "Du hattest eine %@ Nacht mit %.1f Stunden Schlaf und einer Qualität von %d%%.", qualityLabel, totalHours, quality))

        // Vortag-Vergleich
        if let gs = gesternScore {
            let diff = quality - gs
            if diff > 5 {
                lines.append("Im Vergleich zu gestern (\(gs)%) hast du dich deutlich verbessert.")
            } else if diff < -5 {
                lines.append("Gestern (\(gs)%) war dein Schlaf etwas erholsamer.")
            }
        }

        // Wochentrend
        if let wq = wochenSchnittQual {
            if quality > wq + 8 {
                lines.append("Diese Nacht lag deutlich über deinem 7-Tage-Schnitt von \(wq)%.")
            } else if quality < wq - 8 {
                lines.append("Diese Nacht war etwas schlechter als dein 7-Tage-Schnitt (\(wq)%).")
            }
        }

        if deepMin > 0 || remMin > 0 {
            lines.append("Dein Tiefschlaf betrug \(deepMin) Minuten und dein REM-Schlaf \(remMin) Minuten.")
        }

        if snoring > 0 {
            lines.append("Es wurden \(snoring) Schnarch-Ereignisse erkannt.")
        }
        if bruxism > 0 {
            lines.append("Zähneknirschen wurde \(bruxism)× festgestellt – ein entspanntes Einschlafritual könnte helfen.")
        }

        if quality >= 75 {
            lines.append("Starte erholt in den Tag!")
        } else if quality >= 50 {
            lines.append("Sorge heute für ausreichend Bewegung und einen frühen Schlafbeginn.")
        } else {
            lines.append("Achte heute besonders auf Ruhepausen und versuche früher ins Bett zu gehen.")
        }

        return lines.joined(separator: " ")
    }
}
