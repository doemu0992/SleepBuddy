import Foundation
import SwiftData

@Model
final class SleepSession {
    var startDate: Date
    var endDate: Date?
    var phases: [SleepPhase]
    var sleepQualityScore: Double?
    var healthKitSampleID: String?

    init(startDate: Date = .now) {
        self.startDate = startDate
        self.phases = []
    }

    var totalDuration: TimeInterval {
        guard let end = endDate else { return Date.now.timeIntervalSince(startDate) }
        return end.timeIntervalSince(startDate)
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

    // Simple quality score: 0-100 based on deep + rem ratio
    var computedQualityScore: Double {
        let total = totalDuration
        guard total > 0 else { return 0 }
        let restorative = deepSleepDuration + remSleepDuration
        return min((restorative / total) * 200, 100)
    }
}
