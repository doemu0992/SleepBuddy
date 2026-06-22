import Foundation

/// Detects the moment the user falls asleep and when they wake up.
/// Sleep onset = sustained quiet audio + minimal motion for ~5 minutes.
/// No manual "I'm asleep" needed — fully automatic.
final class SleepOnsetDetector {

    private(set) var sleepOnset: Date?
    private(set) var isAsleep = false

    // Thresholds
    private let onsetWindowsRequired = 10   // 10 × 30s = 5 min of sleep-compatible signal
    private let wakeWindowsRequired = 3     // 3 × 30s = 1.5 min of awake signal to confirm wake
    private let awakeAmplitude: Float = 0.025
    private let awakeMotion: Float = 0.35

    private var quietWindowCount = 0
    private var awakeWindowCount = 0
    private var firstQuietDate: Date?

    // MARK: - Update

    /// Returns true when sleep onset is first confirmed.
    @discardableResult
    func update(audio: AudioFeatures, motion: MotionFeatures) -> Bool {
        let isSleepCompatible = audio.averageAmplitude < awakeAmplitude
                             && !motion.isSignificant

        if isSleepCompatible {
            awakeWindowCount = 0
            quietWindowCount += 1
            if quietWindowCount == 1 { firstQuietDate = audio.timestamp }

            if !isAsleep && quietWindowCount >= onsetWindowsRequired {
                isAsleep = true
                sleepOnset = firstQuietDate   // retroactively mark onset start
                return true
            }
        } else {
            quietWindowCount = 0
            firstQuietDate = nil

            if isAsleep {
                awakeWindowCount += 1
                if awakeWindowCount >= wakeWindowsRequired {
                    isAsleep = false
                    awakeWindowCount = 0
                }
            }
        }
        return false
    }

    func reset() {
        sleepOnset = nil
        isAsleep = false
        quietWindowCount = 0
        awakeWindowCount = 0
        firstQuietDate = nil
    }
}
