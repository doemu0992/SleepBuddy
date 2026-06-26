import Foundation
import SwiftData

/// Automatically adjusts the sleep phase classifier based on accumulated morning feedback.
///
/// Three stages activate automatically based on the number of rated nights:
///   Stage 1 (< 10 nights): collect only — no changes
///   Stage 2 (10–20 nights): calibrate awake/REM thresholds per user
///   Stage 3 (20+ nights):  correct k-NN labels based on specific feedback bits
///
/// Called from MorgenBewertungCard after each save.
final class FeedbackCalibrationService {

    static let shared = FeedbackCalibrationService()

    // MARK: - UserDefaults keys written by this service

    enum CalKey: String {
        case awakeMotionOffset   = "calibration.awakeMotionOffset"
        case awakeAmplOffset     = "calibration.awakeAmplitudeOffset"
        case remConfBoost        = "calibration.remConfBoost"
        case ratedNightCount     = "calibration.ratedNightCount"
        case stage               = "calibration.stage"
    }

    private let ud = UserDefaults.standard

    // MARK: - Public

    var currentStage: Int { ud.integer(forKey: CalKey.stage.rawValue) }

    func calibrate(context: ModelContext) {
        let sessions = fetchRatedSessions(context: context)
        let ratedCount = sessions.count
        ud.set(ratedCount, forKey: CalKey.ratedNightCount.rawValue)

        let stage = stageFor(ratedCount)
        ud.set(stage, forKey: CalKey.stage.rawValue)

        switch stage {
        case 1:
            break // only collect
        case 2:
            applyStage2(sessions: sessions)
        default:
            applyStage2(sessions: sessions)
            applyStage3(sessions: sessions, context: context)
        }
    }

    // MARK: - Stage logic

    private func stageFor(_ ratedCount: Int) -> Int {
        switch ratedCount {
        case 0..<10:  return 1
        case 10..<20: return 2
        default:      return 3
        }
    }

    // MARK: - Stage 2: threshold calibration

    private func applyStage2(sessions: [SleepSession]) {
        // Use the last 20 rated nights with "Ungenau" feedback
        let inaccurate = sessions
            .filter { $0.recordingQuality == 1 }
            .suffix(20)
        guard !inaccurate.isEmpty else { return }

        let total = Double(inaccurate.count)

        // Bit 1: öfter wach — reduce awake thresholds
        let wachFraction = inaccurate.filter { $0.recordingFeedbackMask & 1 != 0 }.count
        let wachRatio = Double(wachFraction) / total
        // Max reduction: -0.10 for motion, -0.010 for amplitude
        let motionOffset = -wachRatio * 0.10
        let amplOffset   = -wachRatio * 0.010
        ud.set(motionOffset, forKey: CalKey.awakeMotionOffset.rawValue)
        ud.set(amplOffset,   forKey: CalKey.awakeAmplOffset.rawValue)

        // Bit 2: REM missed — boost REM confidence
        let remFraction = inaccurate.filter { $0.recordingFeedbackMask & 2 != 0 }.count
        let remRatio = Double(remFraction) / total
        let remBoost = remRatio * 0.08   // max +0.08 confidence boost in REM windows
        ud.set(remBoost, forKey: CalKey.remConfBoost.rawValue)
    }

    // MARK: - Stage 3: k-NN label correction

    private func applyStage3(sessions: [SleepSession], context: ModelContext) {
        // Only process newly rated sessions (recordingQuality == 1, has feedback)
        let toCorrect = sessions.filter {
            $0.recordingQuality == 1 && $0.recordingFeedbackMask != 0
        }
        guard !toCorrect.isEmpty else { return }

        var didChange = false

        for session in toCorrect {
            let mask = session.recordingFeedbackMask
            let start = session.startDate
            let end   = session.endDate ?? Date()

            let samples = fetchSamples(in: start...end, context: context)
            guard !samples.isEmpty else { continue }

            // Bit 1: öfter wach → samples with high movement labeled as non-awake → .awake
            if mask & 1 != 0 {
                for s in samples where s.phase != .awake && s.movementIntensity > 0.12 {
                    s.label = SleepPhaseType.awake.rawValue
                    s.isUserCorrected = true
                    didChange = true
                }
            }

            // Bit 2: REM missed → samples in REM windows labeled .light with irregular breathing → .rem
            if mask & 2 != 0 {
                for s in samples where s.phase == .light {
                    let cyclePos = s.elapsedMinutesSinceOnset.truncatingRemainder(dividingBy: 90)
                    let inREMWindow = cyclePos >= 60
                    if inREMWindow && s.breathingRegularity < 0.50 {
                        s.label = SleepPhaseType.rem.rawValue
                        s.isUserCorrected = true
                        didChange = true
                    }
                }
            }
        }

        if didChange {
            try? context.save()
        }
    }

    // MARK: - Fetch helpers

    private func fetchRatedSessions(context: ModelContext) -> [SleepSession] {
        let desc = FetchDescriptor<SleepSession>(
            predicate: #Predicate { $0.recordingQuality > 0 },
            sortBy: [SortDescriptor(\.startDate)]
        )
        return (try? context.fetch(desc)) ?? []
    }

    private func fetchSamples(in range: ClosedRange<Date>, context: ModelContext) -> [TrainingSample] {
        let start = range.lowerBound
        let end   = range.upperBound
        let desc = FetchDescriptor<TrainingSample>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp <= end }
        )
        return (try? context.fetch(desc)) ?? []
    }
}
