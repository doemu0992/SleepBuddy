import Foundation

// MARK: - PersonalCalibrationService
// Inlined here to avoid requiring a separate Xcode build target entry.
// Learns user-specific sleep feature baselines from accumulated TrainingSamples.
// After ≥ 7 nights the generic classifier thresholds are replaced with personal ones.
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

    var isCalibrated: Bool { ud.bool(forKey: Key.isCalibrated.rawValue) }
    var nightCount: Int    { ud.integer(forKey: Key.nightCount.rawValue) }

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

        let sleepSamples = samples.filter { $0.phase != .awake }
        if sleepSamples.count >= minSamplesPerClass {
            let amps = sleepSamples.map(\.averageAmplitude).sorted()
            let median = amps[amps.count / 2]
            ud.set(min(0.06, max(0.010, median * 2.0)), forKey: Key.quietAmplitude.rawValue)
        }

        ud.set(true, forKey: Key.isCalibrated.rawValue)
    }

    var deepBreathMin: Float  { let v = ud.float(forKey: Key.deepBreathMin.rawValue);  return v > 0 ? v : 9.0  }
    var deepBreathMax: Float  { let v = ud.float(forKey: Key.deepBreathMax.rawValue);  return v > 0 ? v : 15.0 }
    var lightBreathMin: Float { let v = ud.float(forKey: Key.lightBreathMin.rawValue); return v > 0 ? v : 14.0 }
    var lightBreathMax: Float { let v = ud.float(forKey: Key.lightBreathMax.rawValue); return v > 0 ? v : 19.0 }
    var remBreathMin: Float   { let v = ud.float(forKey: Key.remBreathMin.rawValue);   return v > 0 ? v : 11.0 }
    var remBreathMax: Float   { let v = ud.float(forKey: Key.remBreathMax.rawValue);   return v > 0 ? v : 24.0 }
    var sleepAmplitudeMax: Float { let v = ud.float(forKey: Key.quietAmplitude.rawValue); return v > 0 ? v : 0.028 }
}

// MARK: - SleepPhaseClassifier

/// Rule-based sleep phase classifier using audio + motion features.
/// Used as fallback until k-NN accumulates enough training data (~40 samples).
final class SleepPhaseClassifier {

    // MARK: - Thresholds

    private var awakeAmplitudeThreshold: Float {
        guard UserDefaults.standard.bool(forKey: "partnerModus_aktiv") else { return 0.035 }
        switch UserDefaults.standard.integer(forKey: "partnerModus_stufe") {
        case 1: return 0.062
        case 2: return 0.095
        default: return 0.035
        }
    }
    private var sleepAmplitudeMax: Float { PersonalCalibrationService.shared.sleepAmplitudeMax }
    private let snoringThreshold: Float = 0.3

    // Motion threshold: raised in partner mode because partner movements
    // add variance to the 30 s window and would falsely trigger "awake".
    private var awakeMotionThreshold: Float {
        guard UserDefaults.standard.bool(forKey: "partnerModus_aktiv") else { return 0.35 }
        switch UserDefaults.standard.integer(forKey: "partnerModus_stufe") {
        case 1: return 0.50   // phone between partners
        case 2: return 0.65   // partner closer to phone
        default: return 0.35
        }
    }

    private var deepBreathMin: Float  { PersonalCalibrationService.shared.deepBreathMin }
    private var deepBreathMax: Float  { PersonalCalibrationService.shared.deepBreathMax }
    private var lightBreathMin: Float { PersonalCalibrationService.shared.lightBreathMin }
    private var lightBreathMax: Float { PersonalCalibrationService.shared.lightBreathMax }
    private var remBreathMin: Float   { PersonalCalibrationService.shared.remBreathMin }
    private var remBreathMax: Float   { PersonalCalibrationService.shared.remBreathMax }
    private let remMaxRegularity: Float = 0.68

    // Two overlapping breathing rhythms reduce regularity — lower the bar in partner mode.
    // Homeostatic pressure: when user has a deep-sleep deficit, we widen the deep detection
    // window so the classifier doesn't miss genuine deep sleep bouts.
    private var deepRegularityMin: Float {
        var base: Float
        if UserDefaults.standard.bool(forKey: "partnerModus_aktiv") {
            switch UserDefaults.standard.integer(forKey: "partnerModus_stufe") {
            case 1: base = 0.52
            case 2: base = 0.45
            default: base = 0.65
            }
        } else {
            base = 0.65
        }
        // Deficit > 30 min → lower threshold by up to 0.10 (capped at 0.35)
        if deepSleepDeficitMinutes > 30 {
            let reduction = Float(min(deepSleepDeficitMinutes / 300.0, 1.0)) * 0.10
            base = max(base - reduction, 0.35)
        }
        return base
    }

    // MARK: - Heart rate input (from Apple Watch via HealthKit, updated every 5 min)

    /// Latest heart rate in bpm. 0 = no Watch data available.
    var currentHRBPM: Double = 0
    /// Latest HRV (SDNN) in ms. 0 = no data.
    var currentHRVms: Double = 0

    // MARK: - Sleep cycle timing (for REM window inference)

    /// Set when sleep onset is confirmed by SleepOnsetDetector.
    var sleepOnsetDate: Date?

    /// Returns true when we are likely in a REM window.
    /// Base: ~90-min fixed cycle. Adaptive extension: HR in REM range + rising trend
    /// can open the window up to 15 min early (REM cycles lengthen over the night).
    private func inREMWindow() -> Bool {
        guard let onset = sleepOnsetDate else { return false }
        let elapsedMin = Date().timeIntervalSince(onset) / 60
        guard elapsedMin >= 65 else { return false }
        let cycle = elapsedMin.truncatingRemainder(dividingBy: 90)
        if cycle >= 60 { return true }  // widened from 65 → covers last 30 min of each cycle
        // HR-adaptive: HR elevated above typical deep-sleep level + rising trend
        // suggests REM is starting earlier than the fixed 65/90 min boundary.
        let hrInREMRange = !hrHistory.isEmpty && (hrHistory.last ?? 0) >= 60 && (hrHistory.last ?? 0) < 80
        if hrInREMRange && hrTrend > 2.0 && cycle >= 50 { return true }
        // HRV rising strongly (parasympathetic) in later sleep cycles also hints at REM
        if hrvTrend > 8.0 && cycle >= 55 { return true }
        return false
    }

    // MARK: - HR / HRV trend tracking

    private var hrHistory: [Double] = []      // recent HR readings for trend detection
    private var hrvHistory: [Double] = []     // recent HRV readings for trend detection
    private let hrHistorySize = 6

    /// Positive = HR rising (REM-like), negative = HR falling (deep sleep)
    private var hrTrend: Double {
        guard hrHistory.count >= 4 else { return 0 }
        let half = hrHistory.count / 2
        let early = hrHistory.prefix(half).reduce(0, +) / Double(half)
        let late  = hrHistory.suffix(half).reduce(0, +) / Double(half)
        return late - early
    }

    /// Positive = HRV rising (parasympathetic, deep/REM), negative = falling (arousal)
    private var hrvTrend: Double {
        guard hrvHistory.count >= 4 else { return 0 }
        let half = hrvHistory.count / 2
        let early = hrvHistory.prefix(half).reduce(0, +) / Double(half)
        let late  = hrvHistory.suffix(half).reduce(0, +) / Double(half)
        return late - early
    }

    // MARK: - BCG reliability tracking
    // BCG (ballistocardiography) is noisy. Track the last 6 raw BCG readings;
    // if the range exceeds 20 BPM the sensor is bouncing (phone not stable on mattress)
    // and we discard BCG rather than feed garbage into classification.
    private var bcgHRHistory: [Float] = []
    private let bcgHRHistorySize = 6
    private var bcgReliable = false

    // MARK: - Breathing rate trend
    // Tracks the last 5 breathing rate measurements to detect direction of change.
    // Falling rate → deepening sleep → boost deep confidence.
    // Rising rate → arousal or lighter sleep → reduce deep, boost light/awake.
    private var bpmHistory: [Float] = []
    private let bpmHistorySize = 5

    /// Positive = rate rising (arousal/REM), negative = falling (deepening).
    private var bpmTrend: Float {
        guard bpmHistory.count >= 4 else { return 0 }
        let half = bpmHistory.count / 2
        let early = bpmHistory.prefix(half).reduce(0, +) / Float(half)
        let late  = bpmHistory.suffix(half).reduce(0, +) / Float(half)
        return late - early
    }

    // MARK: - Homeostatic sleep pressure
    // When user has accumulated a deep-sleep deficit, lower the regularity threshold
    // so deep sleep is detected more easily — reflecting increased sleep pressure.
    var deepSleepDeficitMinutes: Double = 0

    // MARK: - Phase transition matrix
    // Weights reflect physiological plausibility of transitions.
    // Applied as a confidence multiplier to the raw classification result.
    private let transitionMatrix: [SleepPhaseType: [SleepPhaseType: Double]] = [
        .awake:  [.awake: 1.00, .light: 0.85, .deep: 0.40, .rem: 0.30],
        .light:  [.awake: 0.90, .light: 1.00, .deep: 0.85, .rem: 0.70],
        .deep:   [.awake: 0.60, .light: 0.90, .deep: 1.00, .rem: 0.25],
        .rem:    [.awake: 0.85, .light: 0.90, .deep: 0.20, .rem: 1.00],
    ]

    // MARK: - History smoothing

    private var history: [(phase: SleepPhaseType, confidence: Double)] = []
    private let historySize = 6
    private var lastCommittedPhase: SleepPhaseType = .awake

    func reset() {
        history.removeAll()
        hrHistory.removeAll()
        hrvHistory.removeAll()
        bpmHistory.removeAll()
        bcgHRHistory.removeAll()
        bcgReliable = false
        sleepOnsetDate = nil
        lastCommittedPhase = .awake
        deepSleepDeficitMinutes = 0
    }

    func classify(audio: AudioFeatures, motion: MotionFeatures) -> (phase: SleepPhaseType, confidence: Double) {
        var raw = rawClassify(audio: audio, motion: motion)

        // Apply transition matrix: penalise physiologically unlikely jumps
        let transWeight = transitionMatrix[lastCommittedPhase]?[raw.phase] ?? 1.0
        raw = (raw.phase, raw.confidence * transWeight)

        // Apply circadian prior: adjust confidence based on time since sleep onset
        raw = applyCircadianPrior(to: raw)

        // PLM: periodic limb movements suggest fragmented light sleep
        if motion.isPLMSuspected && raw.phase == .deep {
            raw = (.light, min(raw.confidence * 0.75, 0.65))
        }

        history.append(raw)
        if history.count > historySize { history.removeFirst() }
        let result = smoothed()
        lastCommittedPhase = result.phase
        return result
    }

    // MARK: - Circadian prior
    // Deep sleep peaks in first third of night; REM peaks in last third.
    private func applyCircadianPrior(to result: (phase: SleepPhaseType, confidence: Double))
        -> (phase: SleepPhaseType, confidence: Double)
    {
        guard let onset = sleepOnsetDate else { return result }
        let elapsed = Date().timeIntervalSince(onset)
        let expected: TimeInterval = 8 * 3600   // assume 8 h sleep
        let progress = min(elapsed / expected, 1.0)  // 0 = just fell asleep, 1 = end of night

        let multiplier: Double
        switch result.phase {
        case .deep:
            // Deep most likely in first ~40% of night, fades toward morning
            multiplier = progress < 0.40 ? 1.15 : (progress < 0.65 ? 1.0 : 0.80)
        case .rem:
            // REM barely present before 90 min; dominant in last third
            multiplier = progress < 0.15 ? 0.70 : (progress < 0.50 ? 1.0 : 1.20)
        case .light:
            multiplier = 1.0   // light sleep distributed evenly
        case .awake:
            // End of night: spontaneous waking becomes increasingly likely after ~85% of the
            // expected sleep window (≈ 6.8 h into an 8 h night). A person lying still in bed
            // produces signals almost identical to light sleep, so we need an extra push here.
            multiplier = progress > 0.88 ? 1.30 : (progress > 0.75 ? 1.12 : 1.0)
        }
        return (result.phase, min(result.confidence * multiplier, 0.95))
    }

    // MARK: - Core logic

    private func rawClassify(audio: AudioFeatures, motion: MotionFeatures) -> (phase: SleepPhaseType, confidence: Double) {
        let amp = audio.averageAmplitude
        let variance = audio.amplitudeVariance
        let mov = motion.movementIntensity
        let snoring = audio.snoringIntensity

        // Prefer accelerometer breathing when phone is on the mattress — it's more direct
        // and less affected by room noise than audio-derived breathing.
        let bpm: Float = motion.isOnMattress && motion.breathingRateBPM > 0
            ? motion.breathingRateBPM : audio.breathingRateBPM
        let reg: Float = motion.isOnMattress && motion.breathingRateBPM > 0
            ? motion.breathingRegularity : audio.breathingRegularity

        // Heart rate: prefer Apple Watch (HealthKit, updated every 5 min),
        // fall back to BCG from accelerometer z-axis (updated every 30 s, on-mattress only).
        // BCG is noisier — lower confidence boosts when using it.
        // Reliability check: if the last 6 BCG readings span > 20 BPM the sensor is
        // bouncing (unstable phone on mattress) → discard rather than mislead the classifier.
        if motion.isOnMattress && motion.bcgHeartRateBPM > 0 {
            bcgHRHistory.append(Float(motion.bcgHeartRateBPM))
            if bcgHRHistory.count > bcgHRHistorySize { bcgHRHistory.removeFirst() }
            if bcgHRHistory.count >= 4 {
                let mn = bcgHRHistory.min()!; let mx = bcgHRHistory.max()!
                bcgReliable = (mx - mn) < 20
            }
        } else if !motion.isOnMattress {
            bcgHRHistory.removeAll()
            bcgReliable = false
        }
        let bcgAvailable = motion.isOnMattress && motion.bcgHeartRateBPM > 0 && bcgReliable
        let effectiveHRBPM: Double = currentHRBPM > 0 ? currentHRBPM
                                   : bcgAvailable ? Double(motion.bcgHeartRateBPM) : 0
        let usingBCG = currentHRBPM == 0 && bcgAvailable
        let hrConfidenceScale: Double = usingBCG ? 0.6 : 1.0   // BCG is less reliable

        // Audio-only mode: no Apple Watch AND BCG is unreliable / phone not on mattress.
        // In this mode audio breathing rate is the only signal — relax the thresholds so
        // the classifier can still distinguish deep sleep and REM.
        let isAudioOnly = currentHRBPM == 0 && !bcgAvailable

        // Update HR/HRV/BPM history for trend analysis
        if effectiveHRBPM > 0 {
            hrHistory.append(effectiveHRBPM)
            if hrHistory.count > hrHistorySize { hrHistory.removeFirst() }
        }
        if currentHRVms > 0 {
            hrvHistory.append(currentHRVms)
            if hrvHistory.count > hrHistorySize { hrvHistory.removeFirst() }
        }
        if bpm > 0 {
            bpmHistory.append(bpm)
            if bpmHistory.count > bpmHistorySize { bpmHistory.removeFirst() }
        }

        let hasHR    = effectiveHRBPM > 0
        let hrLow    = effectiveHRBPM < 56
        let hrMed    = effectiveHRBPM >= 56 && effectiveHRBPM < 68
        let hrREM    = effectiveHRBPM >= 60 && effectiveHRBPM < 78
        // High HRV = parasympathetic dominance = deep or REM sleep
        let hrvHigh  = currentHRVms > 50
        // Low HRV = stressed or awake
        let hrvLow   = currentHRVms > 0 && currentHRVms < 20
        // HRV rising strongly → parasympathetic activation → deep or REM transition
        let hrvRising = hrvTrend > 5.0
        // HRV falling → arousal or light-sleep transition
        let hrvFalling = hrvTrend < -5.0

        let remWindow = inREMWindow()

        // Morning mode: after 6 h since sleep onset the person is more likely to be lying
        // awake resting than genuinely in light sleep. Reduce the motion threshold so that
        // the characteristic stillness of "resting in bed" tips toward awake.
        let isMorning = sleepOnsetDate.map { Date().timeIntervalSince($0) > 6 * 3600 } ?? false
        let effectiveAwakeMotion: Float = isMorning ? awakeMotionThreshold * 0.65 : awakeMotionThreshold

        // 1. Movement → awake (motion is most reliable signal)
        if motion.movementIntensity > effectiveAwakeMotion || amp > awakeAmplitudeThreshold {
            let conf = min(Double(max(mov, (amp - awakeAmplitudeThreshold) / awakeAmplitudeThreshold)) * 0.5 + 0.5, 0.95)
            return (.awake, conf)
        }

        // 1b. HR strongly indicates awake (HR > 80 during supposed sleep)
        if hasHR && effectiveHRBPM > 80 && !remWindow && !usingBCG {
            return (.awake, 0.72)
        }

        // 2. Snoring → light or deep sleep (not REM)
        if snoring > snoringThreshold {
            if bpm >= deepBreathMin && bpm <= deepBreathMax && reg >= deepRegularityMin {
                let hrBoost = hasHR && hrLow ? 0.10 * hrConfidenceScale : 0.0
                return (.deep, min(0.75 + hrBoost, 0.90))
            }
            return (.light, 0.70)
        }

        // 3. No detectable breathing
        if bpm == 0 {
            if hasHR {
                if hrLow && !remWindow { return (.deep, 0.55 + 0.05 * hrConfidenceScale) }
                if hrREM && remWindow  { return (.rem,  0.55 + 0.05 * hrConfidenceScale) }
            }
            if amp > sleepAmplitudeMax { return (.awake, 0.6) }
            // In a REM window with no breathing signal: prefer REM over light
            // Audio-only: slightly higher confidence since no competing signal
            if remWindow { return (.rem, isAudioOnly ? 0.60 : 0.55) }
            return (.light, 0.4)
        }

        // 4. Deep sleep: slow + regular + quiet (only outside REM windows)
        // Audio-only: lower the regularity bar by 0.12 — audio-mic breathing is less
        // precise than accelerometer and tends to read as "moderately regular" even in deep.
        let effectiveDeepRegMin: Float = isAudioOnly ? max(deepRegularityMin - 0.12, 0.38) : deepRegularityMin
        if !remWindow
            && bpm >= deepBreathMin && bpm <= deepBreathMax
            && reg >= effectiveDeepRegMin
            && amp <= sleepAmplitudeMax
        {
            let breathScore = 1.0 - Double(abs(bpm - 12) / 3)
            let hrvBoost: Double = hrvRising || (hasHR && hrvHigh) ? 0.08 : 0.0
            let hrBoost: Double = hasHR && hrLow ? 0.05 * hrConfidenceScale : 0.0
            // Falling BPM trend = deepening sleep = boost; rising = possible arousal = reduce
            let bpmTrendBoost: Double = bpmTrend < -1.5 ? 0.06 : (bpmTrend > 2.0 ? -0.05 : 0.0)
            return (.deep, min(0.5 + Double(reg) * 0.3 + breathScore * 0.2 + hrBoost + hrvBoost + bpmTrendBoost, 0.95))
        }

        // 5. REM: irregular breathing, quiet.
        //    In a REM window the thresholds are relaxed — less regularity required.
        //    HR-based REM boost: slightly elevated HR + no high HRV is classic REM.
        //    Audio-only: raise the regularity ceiling — mic-derived breathing regularity
        //    tends to be higher than true regularity, so we need a wider REM window.
        let audioOnlyREMBonus: Float = isAudioOnly ? 0.15 : 0.0
        let remRegMax: Float = remWindow ? 0.94 : min(remMaxRegularity + audioOnlyREMBonus, 0.88)
        let remVarMin: Float = remWindow ? 0.000002 : 0.000008
        let remConfBoost: Double = remWindow ? 0.20 : 0.0
        // HRV falling during REM window = sympathetic intrusion typical in REM → additional boost
        let hrvREMBoost: Double = hrvFalling && remWindow ? 0.06 : 0.0
        let hrREMBoost: Double  = hasHR && hrREM && !hrvHigh ? 0.12 * hrConfidenceScale : 0.0

        if bpm >= remBreathMin && bpm <= remBreathMax
            && reg < remRegMax
            && variance > remVarMin
            && amp <= sleepAmplitudeMax
        {
            let irregularity = Double(remRegMax - reg) / Double(remRegMax)
            return (.rem, min(0.48 + irregularity * 0.35 + remConfBoost + hrREMBoost + hrvREMBoost, 0.92))
        }

        // 5b. HR strongly indicates REM even when audio signal is weak.
        // Watch gives 0.70 confidence; BCG gives 0.58 (less reliable but still useful).
        if hasHR && hrREM && remWindow && amp <= sleepAmplitudeMax && !hrvHigh {
            let conf: Double = usingBCG ? 0.58 * hrConfidenceScale : 0.70
            return (.rem, conf)
        }

        // 5c. REM window default: still body + quiet room = REM (ShutEye-style).
        // REM sleep features muscle atonia (very still) + period-correct timing.
        // If we're in a REM window and the person is clearly not awake and not deeply
        // breathing, the absence of movement IS the REM signal — we don't need to prove
        // irregular breathing from audio. This is how commercial apps detect REM reliably
        // on a bare mattress without any extra setup.
        if remWindow
            && amp <= sleepAmplitudeMax
            && mov < awakeMotionThreshold * 0.6   // clearly not moving
            && bpm <= remBreathMax                 // not breathing too fast (not awake)
        {
            // Scale confidence: more time into REM window = more confident
            let elapsedInCycle: Double = sleepOnsetDate.map {
                Date().timeIntervalSince($0) / 60
            }.map { $0.truncatingRemainder(dividingBy: 90) } ?? 72
            let windowDepth = min((elapsedInCycle - 60) / 30, 1.0)  // 0 at entry, 1 at cycle end
            let baseConf = 0.58 + windowDepth * 0.12
            let hrBoost: Double = hasHR && hrREM && !hrvHigh ? 0.06 * hrConfidenceScale : 0.0
            return (.rem, min(baseConf + hrBoost, 0.82))
        }

        // 6. Deep sleep outside REM window (relaxed — catches cases missed above)
        if bpm >= deepBreathMin && bpm <= deepBreathMax && reg >= effectiveDeepRegMin {
            let hrBoost: Double = hasHR && hrLow ? 0.07 * hrConfidenceScale : 0.0
            return (.deep, min(0.65 + hrBoost, 0.80))
        }

        // 7. Light sleep
        if bpm >= lightBreathMin && bpm <= lightBreathMax {
            if hasHR && (hrvLow || (hrvFalling && currentHRVms > 0)) { return (.awake, 0.55) }
            let hrvBoost: Double = hrvRising ? 0.06 : 0.0
            // Rising BPM trend toward light range = arousal; falling = may deepen to deep soon
            let bpmTrendAdj: Double = bpmTrend > 2.0 ? 0.05 : (bpmTrend < -2.0 ? -0.04 : 0.0)
            return (.light, min(0.45 + Double(reg) * 0.25 + (hasHR && hrMed ? 0.05 : 0.0) + hrvBoost + bpmTrendAdj, 0.78))
        }

        return amp <= sleepAmplitudeMax ? (.light, 0.45) : (.awake, 0.55)
    }

    // MARK: - Smoothing

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
