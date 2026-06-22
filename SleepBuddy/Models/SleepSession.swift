import Foundation
import SwiftData

@Model
final class SleepSession {
    var startDate: Date
    var endDate: Date?
    var phases: [SleepPhase]
    var sleepQualityScore: Double?
    var healthKitSampleID: String?

    // Sleep onset (auto-detected)
    var sleepOnsetDate: Date?

    // Snoring
    var snoringEventCount: Int = 0

    // Smart alarm
    var alarmEarliestTime: Date?
    var alarmLatestTime: Date?
    var alarmFiredDate: Date?

    // Sound events (opt-in iCloud audio clips)
    var soundEvents: [SleepSoundEvent] = []

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

    var deepSleepDuration: TimeInterval {
        phases.filter { $0.phaseType == .deep }.reduce(0) { $0 + $1.duration }
    }
    var remSleepDuration: TimeInterval {
        phases.filter { $0.phaseType == .rem }.reduce(0) { $0 + $1.duration }
    }
    var lightSleepDuration: TimeInterval {
        phases.filter { $0.phaseType == .light }.reduce(0) { $0 + $1.duration }
    }
    var awakeDuration: TimeInterval {
        phases.filter { $0.phaseType == .awake }.reduce(0) { $0 + $1.duration }
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

        return max(score, 0)
    }
}
