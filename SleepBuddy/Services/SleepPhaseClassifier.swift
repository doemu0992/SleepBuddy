import Foundation

/// Rule-based sleep phase classifier using audio features + elapsed time.
///
/// Sleep architecture model:
///   0–15 min:   Awake / Sleep onset (light)
///   15–45 min:  Light sleep deepening
///   45–90 min:  Deep sleep (slow-wave)
///   90 min+:    Cycling: Deep → REM → Light, ~90 min cycles
///
/// Audio thresholds are secondary signals that can upgrade/downgrade the
/// time-based phase but cannot override the biological sleep model entirely.
final class SleepPhaseClassifier {

    // MARK: - Audio thresholds (RMS amplitude 0.0–1.0)

    private let awakeAmplitudeThreshold: Float = 0.04
    private let movementThreshold: Float = 0.08
    private let deepSleepMaxAmplitude: Float = 0.012

    // Zero-crossing rate proxy for spectral content
    private let remMinZCR: Float = 0.07
    private let remMaxZCR: Float = 0.20

    // MARK: - State

    private var sessionStartDate: Date?
    private var recentFeatures: [AudioFeatures] = []
    private let historyWindow = 4  // ~2 minutes of 30s windows

    // MARK: - Public API

    func start(at date: Date = .now) {
        sessionStartDate = date
        recentFeatures.removeAll()
    }

    func reset() {
        sessionStartDate = nil
        recentFeatures.removeAll()
    }

    func classify(features: AudioFeatures) -> (phase: SleepPhaseType, confidence: Double) {
        recentFeatures.append(features)
        if recentFeatures.count > historyWindow {
            recentFeatures.removeFirst()
        }

        let avgAmplitude = recentFeatures.map(\.averageAmplitude).reduce(0, +) / Float(recentFeatures.count)
        let avgZCR = recentFeatures.map(\.spectralCentroid).reduce(0, +) / Float(recentFeatures.count)

        // Movement/noise always means awake
        if avgAmplitude > movementThreshold {
            return (.awake, 0.9)
        }

        let elapsed = elapsedMinutes()

        // Time-based expected phase
        let expected = expectedPhase(elapsedMinutes: elapsed)

        // Audio can modify the expected phase
        return refine(expected: expected, amplitude: avgAmplitude, zcr: avgZCR, elapsedMinutes: elapsed)
    }

    // MARK: - Sleep architecture model

    private func expectedPhase(elapsedMinutes: Double) -> SleepPhaseType {
        switch elapsedMinutes {
        case ..<5:
            return .awake
        case 5..<20:
            // Sleep onset — transitioning from awake to light
            return .light
        case 20..<45:
            // Deepening into N2/N3
            return .light
        default:
            // 90-minute cycles after initial deep sleep
            // Cycle position within 90-min window
            let cycleMinutes = (elapsedMinutes - 45).truncatingRemainder(dividingBy: 90)

            switch cycleMinutes {
            case ..<40:
                return .deep   // N3 slow-wave
            case 40..<65:
                return .rem    // REM
            default:
                return .light  // N1/N2 between cycles
            }
        }
    }

    /// Audio signal refines the time-based expectation
    private func refine(
        expected: SleepPhaseType,
        amplitude: Float,
        zcr: Float,
        elapsedMinutes: Double
    ) -> (phase: SleepPhaseType, confidence: Double) {

        // High amplitude when we expect sleep → probably still awake
        if amplitude > awakeAmplitudeThreshold && elapsedMinutes > 5 {
            return (.awake, 0.7)
        }

        // Very quiet + low ZCR strongly suggests deep sleep (if timing allows)
        if amplitude < deepSleepMaxAmplitude && zcr < remMinZCR && elapsedMinutes > 40 {
            return (.deep, 0.85)
        }

        // REM: moderate amplitude, higher ZCR (micro-movements, breathing changes)
        if zcr >= remMinZCR && zcr <= remMaxZCR && elapsedMinutes > 60 {
            // Only suggest REM if audio hints at it AND timing supports it
            if expected == .rem || expected == .light {
                return (.rem, 0.75)
            }
        }

        // Otherwise trust the time-based model with moderate confidence
        let confidence: Double = expected == .awake ? 0.9 : 0.65
        return (expected, confidence)
    }

    private func elapsedMinutes() -> Double {
        guard let start = sessionStartDate else { return 0 }
        return Date().timeIntervalSince(start) / 60
    }
}
