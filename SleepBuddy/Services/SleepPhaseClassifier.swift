import Foundation

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
    private var deepRegularityMin: Float {
        guard UserDefaults.standard.bool(forKey: "partnerModus_aktiv") else { return 0.65 }
        switch UserDefaults.standard.integer(forKey: "partnerModus_stufe") {
        case 1: return 0.52
        case 2: return 0.45
        default: return 0.65
        }
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
        if cycle >= 65 { return true }
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

    // MARK: - History smoothing

    private var history: [(phase: SleepPhaseType, confidence: Double)] = []
    private let historySize = 6

    func reset() {
        history.removeAll()
        hrHistory.removeAll()
        hrvHistory.removeAll()
        sleepOnsetDate = nil
    }

    func classify(audio: AudioFeatures, motion: MotionFeatures) -> (phase: SleepPhaseType, confidence: Double) {
        let raw = rawClassify(audio: audio, motion: motion)
        history.append(raw)
        if history.count > historySize { history.removeFirst() }
        return smoothed()
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
        let bcgAvailable = motion.isOnMattress && motion.bcgHeartRateBPM > 0
        let effectiveHRBPM: Double = currentHRBPM > 0 ? currentHRBPM
                                   : bcgAvailable ? Double(motion.bcgHeartRateBPM) : 0
        let usingBCG = currentHRBPM == 0 && bcgAvailable
        let hrConfidenceScale: Double = usingBCG ? 0.6 : 1.0   // BCG is less reliable

        // Update HR/HRV history for trend analysis
        if effectiveHRBPM > 0 {
            hrHistory.append(effectiveHRBPM)
            if hrHistory.count > hrHistorySize { hrHistory.removeFirst() }
        }
        if currentHRVms > 0 {
            hrvHistory.append(currentHRVms)
            if hrvHistory.count > hrHistorySize { hrvHistory.removeFirst() }
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

        // 1. Movement → awake (motion is most reliable signal)
        if motion.movementIntensity > awakeMotionThreshold || amp > awakeAmplitudeThreshold {
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
            if remWindow { return (.rem, 0.55) }
            return (.light, 0.4)
        }

        // 4. Deep sleep: slow + regular + quiet (only outside REM windows)
        if !remWindow
            && bpm >= deepBreathMin && bpm <= deepBreathMax
            && reg >= deepRegularityMin
            && amp <= sleepAmplitudeMax
        {
            let breathScore = 1.0 - Double(abs(bpm - 12) / 3)
            // HRV rising = increasing parasympathetic tone = deepening sleep → boost
            // HRV already high (>50) = established deep/REM state → also boost
            let hrvBoost: Double = hrvRising || (hasHR && hrvHigh) ? 0.08 : 0.0
            let hrBoost: Double = hasHR && hrLow ? 0.05 * hrConfidenceScale : 0.0
            return (.deep, min(0.5 + Double(reg) * 0.3 + breathScore * 0.2 + hrBoost + hrvBoost, 0.95))
        }

        // 5. REM: irregular breathing, quiet.
        //    In a REM window the thresholds are relaxed — less regularity required.
        //    HR-based REM boost: slightly elevated HR + no high HRV is classic REM.
        let remRegMax: Float = remWindow ? 0.94 : remMaxRegularity
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

        // 6. Deep sleep outside REM window (relaxed — catches cases missed above)
        if bpm >= deepBreathMin && bpm <= deepBreathMax && reg >= deepRegularityMin {
            let hrBoost: Double = hasHR && hrLow ? 0.07 * hrConfidenceScale : 0.0
            return (.deep, min(0.65 + hrBoost, 0.80))
        }

        // 7. Light sleep
        if bpm >= lightBreathMin && bpm <= lightBreathMax {
            // Low HRV or falling HRV during light sleep → arousal, might be awake
            if hasHR && (hrvLow || (hrvFalling && currentHRVms > 0)) { return (.awake, 0.55) }
            // HRV rising suggests deepening → could be transitioning to deep
            let hrvBoost: Double = hrvRising ? 0.06 : 0.0
            return (.light, min(0.45 + Double(reg) * 0.25 + (hasHR && hrMed ? 0.05 : 0.0) + hrvBoost, 0.78))
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
