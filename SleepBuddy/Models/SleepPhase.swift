import Foundation
import SwiftData

@Model
final class SleepPhase {
    // CloudKit: all non-optional attributes need defaults
    var startDate: Date = Date()
    var endDate: Date = Date()
    var phaseTypeRaw: String = SleepPhaseType.awake.rawValue
    var confidence: Double = 1.0

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
