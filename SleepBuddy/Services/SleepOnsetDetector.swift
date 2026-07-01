import Foundation

/// Detects the moment the user falls asleep and when they wake up.
///
/// Two modes:
/// - **Phone on mattress** (`motion.isOnMattress == true`): accelerometer breathing rhythm is
///   a direct sleep confirmation. Only 5 quiet windows (2.5 min) needed.
/// - **Phone on nightstand**: falls back to sustained audio-quiet + minimal motion for ~5 min.
final class SleepOnsetDetector {

    private(set) var sleepOnset: Date?
    private(set) var isAsleep = false

    // Nightstand mode: 10 × 30s = 5 min of quiet audio + stillness
    private let onsetWindowsRequired = 10
    // Mattress mode: accelerometer breathing present → 5 × 30s = 2.5 min is enough
    private let mattressOnsetWindows = 5
    private let wakeWindowsRequired = 3

    private var awakeAmplitude: Float { 0.025 * PartnerMode.amplitudeFactor }

    // Raised in partner mode so partner turning over doesn't reset the onset window.
    private var awakeMotionThreshold: Float { 0.35 * PartnerMode.motionFactor }

    private let windowDuration: TimeInterval = 30
    private var quietWindowCount = 0
    private var awakeWindowCount = 0
    private var firstQuietDate: Date?
    private var lastWindowDate: Date?

    // MARK: - Update

    /// Returns true when sleep onset is first confirmed.
    @discardableResult
    func update(audio: AudioFeatures, motion: MotionFeatures) -> Bool {
        let now = audio.timestamp
        guard let last = lastWindowDate else {
            lastWindowDate = now
            return false
        }
        guard now.timeIntervalSince(last) >= windowDuration else { return false }
        lastWindowDate = now

        let onMattress = motion.isOnMattress && motion.breathingRateBPM > 0
        let requiredWindows = onMattress ? mattressOnsetWindows : onsetWindowsRequired

        // On mattress: breathing rhythm detected → only need no large movement.
        // On nightstand: need quiet audio AND no movement (can't detect breathing directly).
        let isSleepCompatible: Bool
        let isStill = motion.movementIntensity <= awakeMotionThreshold
        if onMattress {
            isSleepCompatible = isStill
        } else {
            isSleepCompatible = audio.averageAmplitude < awakeAmplitude && isStill
        }

        if isSleepCompatible {
            awakeWindowCount = 0
            quietWindowCount += 1
            if quietWindowCount == 1 { firstQuietDate = now }

            if !isAsleep && quietWindowCount >= requiredWindows {
                isAsleep = true
                sleepOnset = firstQuietDate
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
        lastWindowDate = nil
    }
}
