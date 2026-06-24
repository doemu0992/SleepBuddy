import Foundation
import FoundationModels

/// Generates natural language sleep insights using Apple's on-device Foundation Model.
/// Requires iOS 26+; silently skips on older OS versions.
@Observable
final class SleepInsightService {
    private(set) var isGenerating = false
    private(set) var summary: String?
    private(set) var recommendations: [String] = []
    private(set) var error: String?

    @available(iOS 26.0, *)
    private var session: LanguageModelSession? {
        get { _session as? LanguageModelSession }
        set { _session = newValue }
    }
    private var _session: AnyObject?

    // MARK: - Public API

    func generateInsights(for sleepSession: SleepSession) async {
        guard #available(iOS 26.0, *) else {
            error = "Apple Intelligence erfordert iOS 26."
            return
        }
        guard SystemLanguageModel.default.isAvailable else {
            error = "Apple Intelligence ist auf diesem Gerät nicht verfügbar."
            return
        }

        isGenerating = true
        error = nil
        summary = nil
        recommendations = []

        do {
            let newSession = LanguageModelSession()
            self.session = newSession
            let prompt = buildPrompt(for: sleepSession)
            let response = try await newSession.respond(to: prompt)
            parse(response: response.content, session: sleepSession)
        } catch {
            self.error = "Analyse konnte nicht erstellt werden."
        }

        isGenerating = false
    }

    func reset() {
        cancel()
        summary = nil
        recommendations = []
        error = nil
    }

    func cancel() {
        if #available(iOS 26.0, *) { session = nil }
        isGenerating = false
    }

    // MARK: - Prompt construction

    private func buildPrompt(for session: SleepSession) -> String {
        let duration = formatDuration(session.totalDuration)
        let deep = formatDuration(session.deepSleepDuration)
        let rem = formatDuration(session.remSleepDuration)
        let light = formatDuration(session.lightSleepDuration)
        let awake = formatDuration(session.awakeDuration)
        let quality = Int(session.computedQualityScore)
        let bedtime = session.startDate.formatted(date: .omitted, time: .shortened)
        let wakeTime = session.endDate?.formatted(date: .omitted, time: .shortened) ?? "unbekannt"
        let cycles = Dictionary(grouping: session.phasesArray, by: \.phaseType)[.deep]?.count ?? 0

        return """
        Du bist ein Schlaf-Experte. Analysiere diese Schlafdaten und antworte auf Deutsch in folgendem Format:

        ZUSAMMENFASSUNG: (2-3 Sätze über die Schlafqualität, was gut war, was nicht)
        EMPFEHLUNG_1: (konkrete, personalisierte Empfehlung)
        EMPFEHLUNG_2: (konkrete, personalisierte Empfehlung)
        EMPFEHLUNG_3: (konkrete, personalisierte Empfehlung)

        Schlafdaten:
        - Zubettgehzeit: \(bedtime)
        - Aufstehzeit: \(wakeTime)
        - Gesamtschlafdauer: \(duration)
        - Qualitätsscore: \(quality)/100
        - Tiefschlaf: \(deep)
        - REM-Schlaf: \(rem)
        - Leichtschlaf: \(light)
        - Wachphasen: \(awake)
        - Schlafzyklen: \(cycles)

        Normwerte: Tiefschlaf 15-25%, REM 20-25%, Einschlafzeit idealerweise unter 20 Min.
        Halte die Antwort kurz. Keine Überschriften außer ZUSAMMENFASSUNG und EMPFEHLUNG_X.
        """
    }

    // MARK: - Response parsing

    private func parse(response: String, session: SleepSession) {
        var summaryText = ""
        var recs: [String] = []

        for line in response.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("ZUSAMMENFASSUNG:") {
                summaryText = t.replacingOccurrences(of: "ZUSAMMENFASSUNG:", with: "").trimmingCharacters(in: .whitespaces)
            } else if t.hasPrefix("EMPFEHLUNG_1:") {
                recs.append(t.replacingOccurrences(of: "EMPFEHLUNG_1:", with: "").trimmingCharacters(in: .whitespaces))
            } else if t.hasPrefix("EMPFEHLUNG_2:") {
                recs.append(t.replacingOccurrences(of: "EMPFEHLUNG_2:", with: "").trimmingCharacters(in: .whitespaces))
            } else if t.hasPrefix("EMPFEHLUNG_3:") {
                recs.append(t.replacingOccurrences(of: "EMPFEHLUNG_3:", with: "").trimmingCharacters(in: .whitespaces))
            } else if !summaryText.isEmpty && !t.isEmpty && !t.hasPrefix("EMPFEHLUNG") && recs.isEmpty {
                summaryText += " " + t
            }
        }

        if summaryText.isEmpty {
            summaryText = response.components(separatedBy: "\n").first ?? response
        }

        self.summary = summaryText.isEmpty ? nil : summaryText
        self.recommendations = recs
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let h = Int(interval) / 3600
        let m = (Int(interval) % 3600) / 60
        if h > 0 { return "\(h)h \(m)min" }
        return "\(m)min"
    }
}
