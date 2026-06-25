import Foundation

/// Learns user-specific sleep feature baselines from accumulated TrainingSamples.
/// After ≥ 7 nights (≥ 840 samples at 30 s intervals) the generic classifier
/// thresholds are replaced with personal ones stored in UserDefaults.
///
/// Usage: call `updateCalibration(samples:)` at the end of every night.
/// SleepPhaseClassifier reads the personal values automatically via the accessor properties.
final class PersonalCalibrationService {

    static let shared = PersonalCalibrationService()

    private enum Key: String {
        case deepBreathMin  = "cal_deepBreathMin"
        case deepBreathMax  = "cal_deepBreathMax"
        case lightBreathMin = "cal_lightBreathMin"
        case lightBreathMax = "cal_lightBreathMax"
        case remBreathMin   = "cal_remBreathMin"
        case remBreathMax   = "cal_remBreathMax"
        case quietAmplitude = "cal_quietAmplitude"
        case nightCount     = "cal_nightCount"
        case isCalibrated   = "cal_isCalibrated"
    }

    private let ud = UserDefaults.standard
    private let minNights = 7
    private let minSamplesPerClass = 20

    // MARK: - Public state

    var isCalibrated: Bool { ud.bool(forKey: Key.isCalibrated.rawValue) }
    var nightCount: Int    { ud.integer(forKey: Key.nightCount.rawValue) }

    // MARK: - Calibration update

    /// Call at the end of each night with the session's TrainingSamples.
    /// Updates UserDefaults after minNights accumulate.
    func updateCalibration(samples: [TrainingSample]) {
        let nights = ud.integer(forKey: Key.nightCount.rawValue) + 1
        ud.set(nights, forKey: Key.nightCount.rawValue)
        guard nights >= minNights else { return }

        let byPhase = Dictionary(grouping: samples, by: \.phase)

        func bpmPercentileRange(_ phase: SleepPhaseType) -> (Float, Float)? {
            let s = byPhase[phase] ?? []
            let bpms = s.map(\.breathingRateBPM).filter { $0 > 0 }
            guard bpms.count >= minSamplesPerClass else { return nil }
            let sorted = bpms.sorted()
            let lo = sorted[max(0, Int(Double(sorted.count) * 0.10))]
            let hi = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.90))]
            return (lo, hi)
        }

        if let (lo, hi) = bpmPercentileRange(.deep) {
            ud.set(max(6.0, lo - 1.0),  forKey: Key.deepBreathMin.rawValue)
            ud.set(min(18.0, hi + 1.0), forKey: Key.deepBreathMax.rawValue)
        }
        if let (lo, hi) = bpmPercentileRange(.light) {
            ud.set(max(10.0, lo - 1.0), forKey: Key.lightBreathMin.rawValue)
            ud.set(min(26.0, hi + 1.0), forKey: Key.lightBreathMax.rawValue)
        }
        if let (lo, hi) = bpmPercentileRange(.rem) {
            ud.set(max(8.0, lo - 1.0),  forKey: Key.remBreathMin.rawValue)
            ud.set(min(30.0, hi + 1.0), forKey: Key.remBreathMax.rawValue)
        }

        // Personal quiet amplitude: median amplitude across all non-awake samples
        let sleepSamples = samples.filter { $0.phase != .awake }
        if sleepSamples.count >= minSamplesPerClass {
            let amps = sleepSamples.map(\.averageAmplitude).sorted()
            let median = amps[amps.count / 2]
            // Use 2× median as sleepAmplitudeMax (quiet baseline × safety factor)
            ud.set(min(0.06, max(0.010, median * 2.0)), forKey: Key.quietAmplitude.rawValue)
        }

        ud.set(true, forKey: Key.isCalibrated.rawValue)
    }

    // MARK: - Accessor properties (read by SleepPhaseClassifier)

    var deepBreathMin: Float {
        let v = ud.float(forKey: Key.deepBreathMin.rawValue); return v > 0 ? v : 9.0
    }
    var deepBreathMax: Float {
        let v = ud.float(forKey: Key.deepBreathMax.rawValue); return v > 0 ? v : 15.0
    }
    var lightBreathMin: Float {
        let v = ud.float(forKey: Key.lightBreathMin.rawValue); return v > 0 ? v : 14.0
    }
    var lightBreathMax: Float {
        let v = ud.float(forKey: Key.lightBreathMax.rawValue); return v > 0 ? v : 19.0
    }
    var remBreathMin: Float {
        let v = ud.float(forKey: Key.remBreathMin.rawValue); return v > 0 ? v : 11.0
    }
    var remBreathMax: Float {
        let v = ud.float(forKey: Key.remBreathMax.rawValue); return v > 0 ? v : 24.0
    }
    var sleepAmplitudeMax: Float {
        let v = ud.float(forKey: Key.quietAmplitude.rawValue); return v > 0 ? v : 0.028
    }
}
