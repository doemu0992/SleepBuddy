import Foundation

/// Tracks user corrections on detected sound events and adjusts per-type confidence
/// thresholds so the classifier improves with each corrected night.
///
/// Persists stats in UserDefaults (one entry per SoundEventType):
///   "soundFeedback.<rawValue>.confirmed" — times user said "correct"
///   "soundFeedback.<rawValue>.rejected"  — times user reassigned away from this type
///   "soundFeedback.<rawValue>.missed"    — times user assigned TO this type from something else
final class SoundFeedbackService {

    static let shared = SoundFeedbackService()
    private init() {}

    private let defaults = UserDefaults.standard

    // MARK: - Record feedback

    /// Call when user marks an event as correct (no type change).
    func recordConfirmed(type: SoundEventType) {
        increment(key: confirmedKey(type))
    }

    /// Call when user reassigns an event from `original` to `corrected`.
    func recordCorrection(from original: SoundEventType, to corrected: SoundEventType) {
        increment(key: rejectedKey(original))   // original type was wrong
        increment(key: missedKey(corrected))    // corrected type was missed
    }

    // MARK: - Adjusted threshold

    /// Returns an adjusted minimum confidence for a given type based on past feedback.
    /// - False positives (many rejections) → raise threshold (fewer false alarms)
    /// - Missed detections (many misses)   → lower threshold (catch more)
    func adjustedThreshold(for type: SoundEventType, base: Double) -> Double {
        let confirmed = count(key: confirmedKey(type))
        let rejected  = count(key: rejectedKey(type))
        let missed    = count(key: missedKey(type))
        let total     = confirmed + rejected + missed
        guard total >= 5 else { return base }   // not enough data yet

        // False-positive rate: how often this type was wrongly triggered
        let fpr = Double(rejected) / Double(confirmed + rejected)
        // Miss rate: how often this type was not detected
        let mr  = Double(missed)   / Double(confirmed + missed)

        // Nudge threshold: +0.10 max for false positives, -0.10 max for misses
        let adjustment = (fpr - mr) * 0.10
        return min(0.90, max(0.20, base + adjustment))
    }

    // MARK: - Stats for display

    struct TypeStats {
        let type: SoundEventType
        let confirmed: Int
        let rejected: Int
        let missed: Int
        var accuracy: Double {
            let total = confirmed + rejected
            guard total > 0 else { return 0 }
            return Double(confirmed) / Double(total)
        }
    }

    func stats(for type: SoundEventType) -> TypeStats {
        TypeStats(
            type: type,
            confirmed: count(key: confirmedKey(type)),
            rejected:  count(key: rejectedKey(type)),
            missed:    count(key: missedKey(type))
        )
    }

    func allStats() -> [TypeStats] {
        SoundEventType.allCases.map { stats(for: $0) }.filter {
            $0.confirmed + $0.rejected + $0.missed > 0
        }
    }

    func resetAllStats() {
        for type in SoundEventType.allCases {
            defaults.removeObject(forKey: confirmedKey(type))
            defaults.removeObject(forKey: rejectedKey(type))
            defaults.removeObject(forKey: missedKey(type))
        }
    }

    // MARK: - Private helpers

    private func confirmedKey(_ t: SoundEventType) -> String { "soundFeedback.\(t.rawValue).confirmed" }
    private func rejectedKey (_ t: SoundEventType) -> String { "soundFeedback.\(t.rawValue).rejected" }
    private func missedKey   (_ t: SoundEventType) -> String { "soundFeedback.\(t.rawValue).missed" }

    private func increment(key: String) {
        defaults.set(defaults.integer(forKey: key) + 1, forKey: key)
    }

    private func count(key: String) -> Int {
        defaults.integer(forKey: key)
    }
}
