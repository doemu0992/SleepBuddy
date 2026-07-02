import Foundation

// MARK: - PersonalCalibrationService
// Inlined here to avoid requiring a separate Xcode build target entry.
// Learns the user's quiet amplitude baseline to avoid false "awake" detections
// in noisy environments. Breathing-rate thresholds no longer used — cycle model
// is the primary classifier.
final class PersonalCalibrationService {

    static let shared = PersonalCalibrationService()

    private enum Key: String {
        case quietAmplitude = "cal_quietAmplitude"
        case nightCount     = "cal_nightCount"
        case isCalibrated   = "cal_isCalibrated"
        // Multi-night personal baselines (EMA over nights)
        case hrMedian       = "cal_hrMedian"
        case hrDeepFloor    = "cal_hrDeepFloor"
        case brSlowRate     = "cal_brSlowRate"
        case brRegHigh      = "cal_brRegHigh"
        case brRegLow       = "cal_brRegLow"
    }

    private let ud = UserDefaults.standard
    private let minNights = 3

    // MARK: - Multi-night personal baselines
    // Each night's relative thresholds are blended with these slowly-learned
    // personal values (EMA) so they become stable and personalised over time.

    private func ema(_ key: String, _ value: Double, alpha: Double = 0.3) {
        let old = ud.double(forKey: key)
        ud.set(old <= 0 ? value : old * (1 - alpha) + value * alpha, forKey: key)
    }
    private func value(_ key: String) -> Double? { let v = ud.double(forKey: key); return v > 0 ? v : nil }

    func updateHRBaseline(median: Double, deepFloor: Double) {
        ema(Key.hrMedian.rawValue, median); ema(Key.hrDeepFloor.rawValue, deepFloor)
    }
    var hrMedian: Double?    { value(Key.hrMedian.rawValue) }
    var hrDeepFloor: Double? { value(Key.hrDeepFloor.rawValue) }

    func updateBreathBaseline(slowRate: Double, regHigh: Double, regLow: Double) {
        ema(Key.brSlowRate.rawValue, slowRate); ema(Key.brRegHigh.rawValue, regHigh); ema(Key.brRegLow.rawValue, regLow)
    }
    var brSlowRate: Double? { value(Key.brSlowRate.rawValue) }
    var brRegHigh: Double?  { value(Key.brRegHigh.rawValue) }
    var brRegLow: Double?   { value(Key.brRegLow.rawValue) }

    var isCalibrated: Bool { ud.bool(forKey: Key.isCalibrated.rawValue) }
    var nightCount: Int    { ud.integer(forKey: Key.nightCount.rawValue) }

    func updateCalibration(samples: [TrainingSample]) {
        let nights = ud.integer(forKey: Key.nightCount.rawValue) + 1
        ud.set(nights, forKey: Key.nightCount.rawValue)

        let sleepSamples = samples.filter { $0.phase != .awake }
        guard sleepSamples.count >= 20 else { return }

        let amps = sleepSamples.map(\.averageAmplitude).sorted()
        let median = amps[amps.count / 2]
        ud.set(min(0.06, max(0.010, median * 2.0)), forKey: Key.quietAmplitude.rawValue)

        if nights >= minNights {
            ud.set(true, forKey: Key.isCalibrated.rawValue)
        }
    }

    // Maximum amplitude still considered "asleep" (not awake-level noise)
    var sleepAmplitudeMax: Float {
        let v = ud.float(forKey: Key.quietAmplitude.rawValue)
        return v > 0 ? v : 0.028
    }
}

// MARK: - SleepPhaseClassifier
//
// ShutEye-style classifier. Primary logic:
//   1. Movement / loud audio → awake
//   2. Person is asleep → use 90-minute sleep cycle position to determine phase
//      • 0–20 min  into cycle: light sleep  (transition)
//      • 20–65 min into cycle: deep sleep   (NREM slow-wave)
//      • 65–90 min into cycle: REM sleep
// Heart rate from Apple Watch is a secondary confirmation signal.
// Microphone is used only for sound-event detection (SoundEventService),
// NOT for breathing-rate analysis in the phase classifier.

final class SleepPhaseClassifier {

    // MARK: - Awake thresholds

    // Raised in partner mode because partner movements inflate the 30 s motion window.
    // Reduced by FeedbackCalibrationService when user reports "öfter wach als angezeigt".
    private var awakeMotionThreshold: Float {
        // Base × Partnerfaktor (1.0 / 1.4 / 1.8) — zentral in PartnerMode definiert.
        let offset = Float(UserDefaults.standard.double(forKey: "calibration.awakeMotionOffset"))
        return max(0.15, 0.35 * PartnerMode.motionFactor + offset)
    }

    // Raised in partner mode because partner's voice / TV / ambient noise is louder.
    // Reduced by FeedbackCalibrationService when user reports "öfter wach als angezeigt".
    private var awakeAmplitudeThreshold: Float {
        let offset = Float(UserDefaults.standard.double(forKey: "calibration.awakeAmplitudeOffset"))
        return max(0.010, 0.035 * PartnerMode.amplitudeFactor + offset)
    }

    private var sleepAmplitudeMax: Float { PersonalCalibrationService.shared.sleepAmplitudeMax }

    // Adaptiver Geräuschboden (kritisch, gerätebelegt): die fixe Amplitude-Schwelle
    // (0.035 ≈ ~61 dB) versagt auf Geräten mit heißerem Mikrofon-Gain oder in lauten
    // Räumen — real beobachtet: Dauerboden 60–67 dB → JEDE Messung wurde „wach",
    // ganze Nacht 100 % Wach. Deshalb rollender Median der Amplitude; die effektive
    // Wach-Schwelle liegt IMMER klar über dem gemessenen Boden dieser Nacht.
    private var ambientAmpBuf: [Float] = []
    private var ambientAmpMedian: Float = 0
    private var ambientAmpCounter = 0

    private func updateAmbientFloor(_ amp: Float) {
        ambientAmpBuf.append(amp)
        if ambientAmpBuf.count > 4800 { ambientAmpBuf.removeFirst(ambientAmpBuf.count - 4800) }
        ambientAmpCounter += 1
        if ambientAmpMedian == 0 || ambientAmpCounter >= 64 {
            ambientAmpCounter = 0
            let s = ambientAmpBuf.sorted()
            ambientAmpMedian = s[s.count / 2]
        }
    }

    /// Wach-Schwelle: fixer Basiswert ODER 2.2× Nacht-Boden — was höher ist.
    private var effectiveAwakeAmplitude: Float {
        max(awakeAmplitudeThreshold, ambientAmpMedian * 2.2)
    }
    /// Schlaf-kompatible Maximal-Amplitude, ebenfalls boden-relativ.
    private var effectiveSleepAmplitudeMax: Float {
        max(sleepAmplitudeMax, ambientAmpMedian * 1.8)
    }

    // MARK: - Heart rate input (Apple Watch via HealthKit, updated every 5 min)

    var currentHRBPM: Double = 0
    var currentHRVms: Double  = 0

    // MARK: - Sleep cycle timing

    /// Set when sleep onset is confirmed by SleepOnsetDetector.
    var sleepOnsetDate: Date?

    /// 90-minute cycle position (0–89 min). Returns nil before onset is detected.
    private func cyclePosition() -> Double? {
        guard let onset = sleepOnsetDate else { return nil }
        let elapsedMin = Date().timeIntervalSince(onset) / 60
        guard elapsedMin >= 0 else { return nil }
        return elapsedMin.truncatingRemainder(dividingBy: 90)
    }

    /// Total minutes elapsed since sleep onset.
    private func elapsedSleepMinutes() -> Double {
        guard let onset = sleepOnsetDate else { return 0 }
        return max(0, Date().timeIntervalSince(onset) / 60)
    }

    // MARK: - HR trend tracking

    private var hrHistory: [Double]  = []
    private var hrvHistory: [Double] = []
    private let hrHistorySize = 6

    private var hrTrend: Double {
        guard hrHistory.count >= 4 else { return 0 }
        let half  = hrHistory.count / 2
        let early = hrHistory.prefix(half).reduce(0, +) / Double(half)
        let late  = hrHistory.suffix(half).reduce(0, +) / Double(half)
        return late - early
    }

    private var hrvTrend: Double {
        guard hrvHistory.count >= 4 else { return 0 }
        let half  = hrvHistory.count / 2
        let early = hrvHistory.prefix(half).reduce(0, +) / Double(half)
        let late  = hrvHistory.suffix(half).reduce(0, +) / Double(half)
        return late - early
    }

    // MARK: - BCG reliability tracking

    private var bcgHRHistory: [Float] = []
    private let bcgHRHistorySize = 6
    private var bcgReliable = false
    private var bcgMedian: Float = 0
    /// Latches once a clean BCG lock was achieved — used to detect signal
    /// degradation (lock lost = likely restlessness) later in the night.
    private var bcgWasReliable = false

    // Sustained breathing-override streaks (cycle stays the backbone unless the
    // sensor reading holds for breathOverrideMin consecutive measurements).
    private var breathDeepStreak = 0
    private var breathREMStreak = 0
    private let breathOverrideMin = 3

    // MARK: - Phase transition matrix
    // Weights reflect physiological plausibility of phase-to-phase transitions.

    private let transitionMatrix: [SleepPhaseType: [SleepPhaseType: Double]] = [
        .awake: [.awake: 1.00, .light: 0.85, .deep: 0.35, .rem: 0.25],
        .light: [.awake: 0.90, .light: 1.00, .deep: 0.85, .rem: 0.70],
        .deep:  [.awake: 0.55, .light: 0.90, .deep: 1.00, .rem: 0.20],
        .rem:   [.awake: 0.80, .light: 0.90, .deep: 0.15, .rem: 1.00],
    ]

    // MARK: - History smoothing

    private var history: [(phase: SleepPhaseType, confidence: Double)] = []
    private let historySize = 6
    private var lastCommittedPhase: SleepPhaseType = .awake

    // MARK: - Public interface

    func reset() {
        history.removeAll()
        hrHistory.removeAll()
        hrvHistory.removeAll()
        bcgHRHistory.removeAll()
        bcgReliable      = false
        bcgMedian        = 0
        bcgWasReliable   = false
        breathDeepStreak = 0
        breathREMStreak  = 0
        sleepOnsetDate   = nil
        lastCommittedPhase = .awake
        ambientAmpBuf.removeAll()
        ambientAmpMedian = 0
        ambientAmpCounter = 0
    }

    func classify(audio: AudioFeatures, motion: MotionFeatures) -> (phase: SleepPhaseType, confidence: Double) {
        var raw = rawClassify(audio: audio, motion: motion)

        // Apply physiological transition penalty for unlikely jumps
        let transWeight = transitionMatrix[lastCommittedPhase]?[raw.phase] ?? 1.0
        raw = (raw.phase, raw.confidence * transWeight)

        // Circadian prior: adjust confidence by time-of-night expectations
        raw = applyCircadianPrior(to: raw)

        history.append(raw)
        if history.count > historySize { history.removeFirst() }
        let result = smoothed()
        lastCommittedPhase = result.phase
        return result
    }

    // MARK: - Circadian prior

    private func applyCircadianPrior(to result: (phase: SleepPhaseType, confidence: Double))
        -> (phase: SleepPhaseType, confidence: Double)
    {
        guard let onset = sleepOnsetDate else { return result }
        let progress = min(Date().timeIntervalSince(onset) / (8 * 3600), 1.0)

        let multiplier: Double
        switch result.phase {
        case .deep:
            multiplier = progress < 0.40 ? 1.12 : (progress < 0.65 ? 1.0 : 0.82)
        case .rem:
            multiplier = progress < 0.15 ? 0.65 : (progress < 0.50 ? 1.0 : 1.18)
        case .light:
            multiplier = 1.0
        case .awake:
            multiplier = progress > 0.88 ? 1.28 : (progress > 0.75 ? 1.10 : 1.0)
        }
        return (result.phase, min(result.confidence * multiplier, 0.95))
    }

    // MARK: - Core classification (ShutEye-style cycle model)

    private func rawClassify(audio: AudioFeatures, motion: MotionFeatures) -> (phase: SleepPhaseType, confidence: Double) {
        let amp = audio.averageAmplitude
        let mov = motion.movementIntensity

        // ── Breathing features ────────────────────────────────────────────────────
        // Accelerometer (phone on mattress) measures chest/torso vibration directly.
        // Audio breathing rate is a decent fallback in nightstand mode.
        // Only use when quality threshold (regularity > 0.30) is met.
        let useMotionBreath = motion.isOnMattress
                              && motion.breathingRateBPM > 0
                              && motion.breathingRegularity > 0.25
        let breathBPM:   Float  = useMotionBreath ? motion.breathingRateBPM   : audio.breathingRateBPM
        let breathReg:   Float  = useMotionBreath ? motion.breathingRegularity : audio.breathingRegularity
        let breathValid          = breathBPM > 5 && breathBPM < 35 && breathReg > 0.25
        let breathScale: Double  = useMotionBreath ? 1.0 : 0.70
        // Deep sleep: slow (< 13 BPM) + very regular. REM: irregular (< 0.45) + not too slow.
        let breathDeep = breathValid && breathBPM < 13 && breathReg > 0.60
        let breathREM  = breathValid && breathReg  < 0.45 && breathBPM > 11

        // Sustained-signal streaks: the cycle model is the backbone; breathing only
        // OVERRIDES it once the same reading has held for several measurements
        // (a single noisy sample must not flip the phase). ShutEye-style: pattern
        // is the skeleton, sensors adapt within it.
        breathDeepStreak = breathDeep ? breathDeepStreak + 1 : 0
        breathREMStreak  = breathREM  ? breathREMStreak  + 1 : 0
        let breathDeepSustained = breathDeepStreak >= breathOverrideMin
        let breathREMSustained  = breathREMStreak  >= breathOverrideMin

        // --- Update BCG history for HR display (not used for phase decisions) ---
        if motion.isOnMattress && motion.bcgHeartRateBPM > 0 {
            bcgHRHistory.append(Float(motion.bcgHeartRateBPM))
            if bcgHRHistory.count > bcgHRHistorySize { bcgHRHistory.removeFirst() }
            if bcgHRHistory.count >= 4 {
                // Median rejects single-sample BCG artifacts (e.g. spikes to 145 BPM).
                let sorted = bcgHRHistory.sorted()
                bcgMedian = sorted[sorted.count / 2]
                // IQR-based spread (middle 50%) instead of full min-max — a single
                // outlier no longer marks the whole window unreliable.
                let lo = sorted[sorted.count / 4]
                let hi = sorted[(sorted.count * 3) / 4]
                bcgReliable = (hi - lo) < 22
            }
        } else if !motion.isOnMattress {
            bcgHRHistory.removeAll()
            bcgReliable = false
            bcgMedian = 0
        }
        if bcgReliable { bcgWasReliable = true }
        // Use the median (denoised) BCG value, not the raw instantaneous reading.
        let bcgAvailable = motion.isOnMattress && bcgMedian > 0 && bcgReliable
        let usingBCG     = currentHRBPM == 0 && bcgAvailable
        let effectiveHR: Double = currentHRBPM > 0 ? currentHRBPM
                                : bcgAvailable ? Double(bcgMedian) : 0
        let hrConfScale: Double = usingBCG ? 0.6 : 1.0

        // Update HR/HRV history
        if effectiveHR > 0 {
            hrHistory.append(effectiveHR)
            if hrHistory.count > hrHistorySize { hrHistory.removeFirst() }
        }
        if currentHRVms > 0 {
            hrvHistory.append(currentHRVms)
            if hrvHistory.count > hrHistorySize { hrvHistory.removeFirst() }
        }

        let hasHR   = effectiveHR > 0
        let hrLow   = effectiveHR < 56
        let hrREM   = effectiveHR >= 60 && effectiveHR < 78
        let hrvHigh = currentHRVms > 50
        let hrvFalling = hrvTrend < -5.0

        // Morning adjustment: after 6 h the awake threshold drops so that
        // "lying still in bed" correctly tips into awake.
        let isMorning = sleepOnsetDate.map { Date().timeIntervalSince($0) > 6 * 3600 } ?? false
        let effectiveAwakeMotion: Float = isMorning ? awakeMotionThreshold * 0.65 : awakeMotionThreshold

        // ── Step 1: Detect wakefulness ──────────────────────────────────────────
        updateAmbientFloor(amp)
        if mov > effectiveAwakeMotion || amp > effectiveAwakeAmplitude {
            let motConf  = min(Double(mov / awakeMotionThreshold) * 0.4 + 0.55, 0.95)
            let ampConf  = min(Double(amp / effectiveAwakeAmplitude) * 0.4 + 0.55, 0.95)
            return (.awake, max(motConf, ampConf))
        }

        // HR > 80 strongly suggests awake (not during first REM cycle; BCG too noisy for this)
        let inREMCycle = (cyclePosition() ?? 0) >= 60
        if hasHR && effectiveHR > 80 && !inREMCycle && !usingBCG {
            return (.awake, 0.72)
        }

        // ── Step 2: HR override (ShutEye-style: HR wins when signal is clear) ──
        // Apple Watch: authoritative. BCG (phone on mattress): confident but scaled.
        // Only override when HR clearly points to a specific phase — ambiguous HR
        // falls through to the cycle model below.
        if hasHR {
            // Distinctly low HR → deep sleep regardless of cycle zone.
            // BCG threshold raised slightly (more noise in BCG signal).
            let deepThresh: Double = usingBCG ? 60.0 : 56.0
            if effectiveHR < deepThresh && !inREMCycle {
                let depthBonus = min((deepThresh - effectiveHR) * 0.012, 0.10)
                let base: Double = usingBCG ? 0.64 : 0.76
                let cap:  Double = usingBCG ? 0.74 : 0.88
                return (.deep, min(base + depthBonus, cap))
            }

            // REM-range HR + REM window open → REM.
            // HRV falling during REM eye movements adds extra confidence (Watch only).
            if hrREM && inREMCycle && !hrvHigh {
                let hrvBonus: Double = (hrvFalling && !usingBCG) ? 0.07 : 0.0
                let base: Double = usingBCG ? 0.60 : 0.72
                let cap:  Double = usingBCG ? 0.70 : 0.84
                return (.rem, min(base + hrvBonus, cap))
            }
        }

        // ── Step 2b: Breathing override (when no HR source available) ────────────
        // Breathing rate is a solid phase signal when measured cleanly, but noisier
        // than HR. Only fires when there is no HR to conflict with.
        if breathValid && !hasHR {
            if breathDeepSustained && !inREMCycle {
                // Slow + very regular → deep, regardless of cycle position
                let regBonus = Double(max(breathReg - 0.60, 0)) * 0.28
                let base: Double = useMotionBreath ? 0.64 : 0.52
                let cap:  Double = useMotionBreath ? 0.76 : 0.63
                return (.deep, min(base + regBonus, cap))
            }
            if breathREMSustained && inREMCycle {
                // Irregular breathing in REM window → REM
                let irregBonus = Double(max(0.45 - breathReg, 0)) * 0.32
                let base: Double = useMotionBreath ? 0.60 : 0.50
                let cap:  Double = useMotionBreath ? 0.70 : 0.60
                return (.rem, min(base + irregBonus, cap))
            }
        }

        // ── BCG lock lost + movement + no usable breathing → restless ──────────
        // Only when we have NO robust signal at all (no HR, no valid breathing)
        // and the previously clean BCG degraded with movement do we fall back to
        // a light-sleep restlessness bias. If breathing is valid it drives the
        // phase below instead (keeps the curve smooth & sensor-grounded).
        let bcgDegraded = motion.isOnMattress && bcgWasReliable && !bcgReliable && !hasHR
        if bcgDegraded && !breathValid && mov > awakeMotionThreshold * 0.25 {
            return (.light, 0.58)
        }

        // ── Step 3: Person is asleep — use cycle position ──────────────────────
        // Fallback when no HR available or HR is in an ambiguous range.
        // Without onset date we have no cycle reference → default to light sleep.
        guard let cyclePos = cyclePosition() else {
            return amp <= effectiveSleepAmplitudeMax ? (.light, 0.50) : (.awake, 0.55)
        }

        let elapsed = elapsedSleepMinutes()

        // ── Zone A: Transition / light (0–20 min into each cycle) ──────────────
        if cyclePos < 20 {
            let hrBoost: Double = (hasHR && hrREM) ? 0.05 : 0.0
            return (.light, min(0.68 + hrBoost, 0.80))
        }

        // ── Zone B: Deep sleep (20–65 min into cycle) ──────────────────────────
        if cyclePos < 65 {
            // Sensor override (only when sustained): clearly irregular breathing
            // held over several measurements in a "deep" zone → light/arousal.
            // A single noisy sample does NOT override the cycle backbone.
            if breathREMSustained {
                let irregBonus = Double(max(0.45 - breathReg, 0)) * 0.25
                return (.light, min(0.60 + irregBonus, 0.74))
            }
            let hrBoost:         Double = (hasHR && hrLow)  ? 0.08 * hrConfScale : 0.0
            let hrPenalty:       Double = (hasHR && hrREM && !usingBCG) ? -0.08 : 0.0
            let hrvBoost:        Double = hrvHigh ? 0.05 : 0.0
            let firstCycleBoost: Double = elapsed < 90 ? 0.07 : 0.0
            let snoringBoost:    Double = audio.snoringIntensity > 0.3 ? 0.05 : 0.0
            // Slow + regular breathing confirms deep
            let breathBoost:   Double = breathDeep ? 0.08 * breathScale : 0.0
            let conf = min(0.70 + hrBoost + hrPenalty + hrvBoost + firstCycleBoost + snoringBoost + breathBoost, 0.92)
            return (.deep, conf)
        }

        // ── Zone C: REM (65–90 min into cycle) ─────────────────────────────────
        // Sensor override (only when sustained): slow + very regular breathing
        // held over several measurements in a "REM" zone → still deep sleep.
        if breathDeepSustained {
            let regBonus = Double(max(breathReg - 0.60, 0)) * 0.25
            return (.deep, min(0.60 + regBonus, 0.76))
        }
        let hrREMBoost:      Double = (hasHR && hrREM && !hrvHigh) ? 0.10 * hrConfScale : 0.0
        let hrvREMBoost:     Double = (hrvFalling && hasHR)         ? 0.06 : 0.0
        let lateNightBoost:  Double = elapsed > 270                  ? 0.06 : 0.0
        // Irregular breathing confirms REM
        let breathREMBoost:   Double = breathREM  ? 0.08 * breathScale : 0.0
        let userREMBoost = UserDefaults.standard.double(forKey: "calibration.remConfBoost")
        let conf = min(0.68 + hrREMBoost + hrvREMBoost + lateNightBoost + breathREMBoost + userREMBoost, 0.90)
        return (.rem, conf)
    }

    // MARK: - Smoothing (weighted majority vote)

    private func smoothed() -> (phase: SleepPhaseType, confidence: Double) {
        guard !history.isEmpty else { return (.awake, 0.5) }
        if history.count == 1 { return history[0] }

        var votes: [SleepPhaseType: Double] = [:]
        for entry in history { votes[entry.phase, default: 0] += entry.confidence }

        let winner = votes.max(by: { $0.value < $1.value })!
        let avg = history.filter { $0.phase == winner.key }.map(\.confidence).reduce(0, +)
                  / Double(history.count)
        return (winner.key, avg)
    }
}
