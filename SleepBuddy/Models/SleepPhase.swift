import Foundation
import SwiftData

@Model
final class SleepPhase {
    var startDate: Date
    var endDate: Date
    var phaseTypeRaw: String
    var confidence: Double

    @Relationship(inverse: \SleepSession.phases)
    var session: SleepSession?

    init(startDate: Date, endDate: Date, phaseType: SleepPhaseType, confidence: Double = 1.0) {
        self.startDate = startDate
        self.endDate = endDate
        self.phaseTypeRaw = phaseType.rawValue
        self.confidence = confidence
    }

    var phaseType: SleepPhaseType {
        get { SleepPhaseType(rawValue: phaseTypeRaw) ?? .awake }
        set { phaseTypeRaw = newValue.rawValue }
    }

    var duration: TimeInterval {
        endDate.timeIntervalSince(startDate)
    }
}
