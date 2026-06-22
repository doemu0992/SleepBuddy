import Foundation

/// Classifies sleep phases from measured audio features.
/// No time-based assumptions — all decisions come from actual signal data.
///
/// Signal → Phase mapping:
///
///   High amplitude / high variance          → Awake (movement, talking)
///   No detectable breathing pattern         → Awake or uncertain
///   10–14 bpm, high regularity, quiet       → Deep sleep (N3)
///   14–18 bpm, moderate regularity          → Light sleep (N1/N2)
///   Irregular breathing, some variance      → REM (atonia + irregular breathing)
final class SleepPhaseClassifier {

    // MARK: - Thresholds (tunable)

    /// Above this RMS amplitude → almost certainly awake
    private let awakeAmplitudeThreshold: Float = 0.035

    /// Below this → very quiet environment (sleep-compatible)
    private let sleepAmplitudeMax: Float = 0.020

    /// Breathing rate ranges (breaths per minute)
    private let deepBreathMin: Float = 9
    private let deepBreathMax: Float = 15
    private let lightBreathMin: Float = 14
    private let lightBreathMax: Float = 19
    private let remBreathMin: Float = 12
    private let remBreathMax: Float = 22

    /// Regularity threshold — deep sleep is highly regular
    private let deepRegularityMin: Float = 0.65
    private let remMaxRegularity: Float = 0.50

    // MARK: - History smoothing

    private var history: [(phase: SleepPhaseType, confidence: Double)] = []
    private let historySize = 3   // smooth over ~3 windows = ~90 seconds

    // MARK: - Public API

    func reset() { history.removeAll() }

    func classify(features: AudioFeatures) -> (phase: SleepPhaseType, confidence: Double) {
        let raw = rawClassify(features: features)
        history.append(raw)
        if history.count > historySize { history.removeFirst() }

        // Majority vote over recent history
        return smoothed()
    }

    // MARK: - Core classification logic

    private func rawClassify(features: AudioFeatures) -> (phase: SleepPhaseType, confidence: Double) {
        let amp = features.averageAmplitude
        let bpm = features.breathingRateBPM
        let reg = features.breathingRegularity
        let variance = features.amplitudeVariance

        // 1. Wach: high amplitude or high variance = movement/noise
        if amp > awakeAmplitudeThreshold {
            let conf = min(Double((amp - awakeAmplitudeThreshold) / awakeAmplitudeThreshold) + 0.5, 0.95)
            return (.awake, conf)
        }

        // 2. No detectable breathing pattern → still awake or ambiguous
        if bpm == 0 {
            // Could be lying still not yet asleep, or very noisy environment
            return amp > sleepAmplitudeMax ? (.awake, 0.6) : (.light, 0.4)
        }

        // 3. Deep sleep: slow + regular breathing + quiet
        if bpm >= deepBreathMin && bpm <= deepBreathMax
            && reg >= deepRegularityMin
            && amp <= sleepAmplitudeMax
        {
            let breathScore = 1.0 - Double(abs(bpm - 12) / 3)   // peak at 12 bpm
            let conf = 0.5 + (Double(reg) * 0.3) + (breathScore * 0.2)
            return (.deep, min(conf, 0.92))
        }

        // 4. REM: breathing irregular (low regularity), moderate amplitude variation
        if bpm >= remBreathMin && bpm <= remBreathMax
            && reg < remMaxRegularity
            && variance > 0.00002
        {
            let irregularityScore = Double(remMaxRegularity - reg) / Double(remMaxRegularity)
            return (.rem, 0.5 + irregularityScore * 0.3)
        }

        // 5. Light sleep: breathing in normal range, moderate regularity
        if bpm >= lightBreathMin && bpm <= lightBreathMax {
            let conf = 0.45 + Double(reg) * 0.25
            return (.light, min(conf, 0.75))
        }

        // 6. Ambiguous — use amplitude as tiebreaker
        return amp <= sleepAmplitudeMax ? (.light, 0.45) : (.awake, 0.55)
    }

    // MARK: - History smoothing

    private func smoothed() -> (phase: SleepPhaseType, confidence: Double) {
        guard !history.isEmpty else { return (.awake, 0.5) }
        if history.count == 1 { return history[0] }

        var votes: [SleepPhaseType: Double] = [:]
        for entry in history {
            votes[entry.phase, default: 0] += entry.confidence
        }

        let winner = votes.max(by: { $0.value < $1.value })!
        let avgConfidence = history.filter { $0.phase == winner.key }.map(\.confidence).reduce(0, +)
                            / Double(history.count)
        return (winner.key, avgConfidence)
    }
}
