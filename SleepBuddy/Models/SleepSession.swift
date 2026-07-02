import Foundation
import SwiftData

@Model
final class SleepSession {
    // CloudKit: all attributes must be optional or have defaults
    var startDate: Date = Date()
    var endDate: Date?
    @Relationship(deleteRule: .cascade, inverse: \SleepPhase.session)
    var phases: [SleepPhase]? = []
    var sleepQualityScore: Double?
    var healthKitSampleID: String?

    // Sleep onset (auto-detected)
    var sleepOnsetDate: Date?

    // Smart alarm
    var alarmEarliestTime: Date?
    var alarmLatestTime: Date?
    var alarmFiredDate: Date?

    // Sound events — inverse required for CloudKit
    @Relationship(deleteRule: .cascade, inverse: \SleepSoundEvent.session)
    var soundEvents: [SleepSoundEvent]? = []

    // Ambient noise samples: one dB value per minute throughout the night
    var noiseSamples: [Double] = []

    // BCG heart rate samples: one value per minute (0 = no data for that minute)
    var heartRateSamples: [Double] = []

    // Subjective morning rating: 0 = not rated yet, 1–5 (1=terrible … 5=great)
    var subjectiveQuality: Int = 0

    // Recording quality rating: 0 = not rated, 1 = inaccurate, 2 = ok, 3 = accurate
    var recordingQuality: Int = 0

    // Inaccuracy feedback bitmask (only relevant when recordingQuality == 1):
    // bit 0 (1) = öfter wach als angezeigt
    // bit 1 (2) = lebhafte Träume aber kein REM markiert
    // bit 2 (4) = Einschlafzeit falsch
    // bit 3 (8) = Aufwachzeit falsch
    var recordingFeedbackMask: Int = 0


    init(startDate: Date = .now) {
        self.startDate = startDate
        self.phases = []
        self.soundEvents = []
    }

    // MARK: - Derived

    var totalDuration: TimeInterval {
        guard let end = endDate else { return Date.now.timeIntervalSince(startDate) }
        return end.timeIntervalSince(startDate)
    }

    /// Time from lying down to actual sleep onset.
    var sleepOnsetLatency: TimeInterval? {
        guard let onset = sleepOnsetDate else { return nil }
        return onset.timeIntervalSince(startDate)
    }

    var isActive: Bool { endDate == nil }

    // Non-optional convenience accessors (CloudKit stores these as optional arrays)
    var phasesArray: [SleepPhase] { phases ?? [] }
    var soundEventsArray: [SleepSoundEvent] { soundEvents ?? [] }

    var snoringEventCount: Int { soundEventsArray.filter { $0.type == .snoring }.count }
    var bruxismEventCount: Int { soundEventsArray.filter { $0.type == .bruxism }.count }
    var coughingEventCount: Int { soundEventsArray.filter { $0.type == .coughing }.count }

    var deepSleepDuration: TimeInterval {
        phasesArray.filter { $0.phaseType == .deep }.reduce(0) { $0 + $1.duration }
    }
    var remSleepDuration: TimeInterval {
        phasesArray.filter { $0.phaseType == .rem }.reduce(0) { $0 + $1.duration }
    }
    var lightSleepDuration: TimeInterval {
        phasesArray.filter { $0.phaseType == .light }.reduce(0) { $0 + $1.duration }
    }
    var awakeDuration: TimeInterval {
        phasesArray.filter { $0.phaseType == .awake }.reduce(0) { $0 + $1.duration }
    }

    /// Tatsächliche Schlafdauer = Zeit im Bett (totalDuration) minus Wachphasen —
    /// Apple-Stil: „Zeit im Bett 6h 56m, Schlafdauer 6h 34m". Ohne erkannte Phasen
    /// (alte/leere Sessions) fällt der Wert auf die Zeit im Bett zurück.
    var sleepDuration: TimeInterval {
        guard !phasesArray.isEmpty else { return totalDuration }
        return max(0, totalDuration - awakeDuration)
    }

    /// Quality 0–100: restorative sleep ratio + onset latency penalty + snoring penalty
    var computedQualityScore: Double {
        let total = totalDuration
        guard total > 0 else { return 0 }
        let restorative = deepSleepDuration + remSleepDuration
        var score = min((restorative / total) * 200, 100)

        // Penalize long sleep onset (>20 min loses up to 10 pts)
        if let latency = sleepOnsetLatency {
            let latencyMin = latency / 60
            score -= min(max(latencyMin - 20, 0) * 0.5, 10)
        }

        // Snoring penalty (each event = -0.5 pts, max -15)
        score -= min(Double(snoringEventCount) * 0.5, 15)

        // Bruxism penalty (each event = -0.3 pts, max -5)
        score -= min(Double(bruxismEventCount) * 0.3, 5)

        return max(score, 0)
    }
}
