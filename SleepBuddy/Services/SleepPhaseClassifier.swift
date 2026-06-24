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
    private let sleepAmplitudeMax: Float = 0.020
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

    private let deepBreathMin: Float = 9
    private let deepBreathMax: Float = 15
    private let lightBreathMin: Float = 14
    private let lightBreathMax: Float = 19
    private let remBreathMin: Float = 12
    private let remBreathMax: Float = 22
    private let remMaxRegularity: Float = 0.50

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
    /// REM follows a ~90-min cycle: first REM ~70 min after onset,
    /// then every 90 min. Later cycles are longer (up to 30 min).
    private func inREMWindow() -> Bool {
        guard let onset = sleepOnsetDate else { return false }
        let elapsedMin = Date().timeIntervalSince(onset) / 60
        guard elapsedMin >= 65 else { return false }   // no REM before ~65 min
        let cycle = elapsedMin.truncatingRemainder(dividingBy: 90)
        // Last 25 min of each 90-min cycle = REM likely
        return cycle >= 65
    }

    // MARK: - History smoothing

    private var history: [(phase: SleepPhaseType, confidence: Double)] = []
    private let historySize = 3

    func reset() {
        history.removeAll()
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
        let remWindow = inREMWindow()

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

        let hasHR    = effectiveHRBPM > 0
        let hrLow    = effectiveHRBPM < 56
        let hrMed    = effectiveHRBPM >= 56 && effectiveHRBPM < 68
        let hrREM    = effectiveHRBPM >= 60 && effectiveHRBPM < 78
        // High HRV = parasympathetic dominance = deep or REM sleep
        let hrvHigh  = currentHRVms > 50
        // Low HRV = stressed or awake
        let hrvLow   = currentHRVms > 0 && currentHRVms < 20

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
            return amp > sleepAmplitudeMax ? (.awake, 0.6) : (.light, 0.4)
        }

        // 4. Deep sleep: slow + regular + quiet (only outside REM windows)
        if !remWindow
            && bpm >= deepBreathMin && bpm <= deepBreathMax
            && reg >= deepRegularityMin
            && amp <= sleepAmplitudeMax
        {
            let breathScore = 1.0 - Double(abs(bpm - 12) / 3)
            let hrBoost: Double = hasHR && hrLow && hrvHigh ? 0.10 * hrConfidenceScale
                                : hasHR && hrLow ? 0.05 * hrConfidenceScale : 0.0
            return (.deep, min(0.5 + Double(reg) * 0.3 + breathScore * 0.2 + hrBoost, 0.95))
        }

        // 5. REM: irregular breathing, quiet.
        //    In a REM window the thresholds are relaxed — less regularity required.
        //    HR-based REM boost: slightly elevated HR + low HRV is classic REM.
        let remRegMax: Float = remWindow ? 0.72 : remMaxRegularity
        let remVarMin: Float = remWindow ? 0.000003 : 0.00002
        let remConfBoost: Double = remWindow ? 0.18 : 0.0
        let hrREMBoost: Double  = hasHR && hrREM && !hrvHigh ? 0.12 * hrConfidenceScale : 0.0

        if bpm >= remBreathMin && bpm <= remBreathMax
            && reg < remRegMax
            && variance > remVarMin
            && amp <= sleepAmplitudeMax
        {
            let irregularity = Double(remRegMax - reg) / Double(remRegMax)
            return (.rem, min(0.48 + irregularity * 0.35 + remConfBoost + hrREMBoost, 0.92))
        }

        // 5b. HR strongly indicates REM even when audio signal is weak (Watch only — BCG too noisy)
        if hasHR && !usingBCG && hrREM && remWindow && amp <= sleepAmplitudeMax && !hrvHigh {
            return (.rem, 0.70)
        }

        // 6. Deep sleep outside REM window (relaxed — catches cases missed above)
        if bpm >= deepBreathMin && bpm <= deepBreathMax && reg >= deepRegularityMin {
            let hrBoost: Double = hasHR && hrLow ? 0.07 * hrConfidenceScale : 0.0
            return (.deep, min(0.65 + hrBoost, 0.80))
        }

        // 7. Light sleep
        if bpm >= lightBreathMin && bpm <= lightBreathMax {
            // Low HRV during supposed light sleep → might actually be awake
            if hasHR && hrvLow { return (.awake, 0.55) }
            return (.light, min(0.45 + Double(reg) * 0.25 + (hasHR && hrMed ? 0.05 : 0.0), 0.78))
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
