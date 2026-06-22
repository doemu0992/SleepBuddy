import Foundation

/// Rule-based sleep phase classifier using audio features.
/// Thresholds are calibrated for typical bedroom noise levels.
final class SleepPhaseClassifier {

    // Amplitude thresholds (RMS, 0.0–1.0)
    private let awakeThreshold: Float = 0.05
    private let deepSleepMaxAmplitude: Float = 0.015

    // Spectral centroid thresholds (zero-crossing rate proxy)
    private let remSpectralMin: Float = 0.08
    private let remSpectralMax: Float = 0.18

    private var recentFeatures: [AudioFeatures] = []
    private let historyWindow = 6 // ~3 minutes of 30s windows

    func classify(features: AudioFeatures) -> (phase: SleepPhaseType, confidence: Double) {
        recentFeatures.append(features)
        if recentFeatures.count > historyWindow {
            recentFeatures.removeFirst()
        }

        let avgAmplitude = recentFeatures.map(\.averageAmplitude).reduce(0, +) / Float(recentFeatures.count)
        let avgCentroid = recentFeatures.map(\.spectralCentroid).reduce(0, +) / Float(recentFeatures.count)

        return classify(amplitude: avgAmplitude, spectralCentroid: avgCentroid)
    }

    private func classify(amplitude: Float, spectralCentroid: Float) -> (phase: SleepPhaseType, confidence: Double) {
        if amplitude > awakeThreshold {
            return (.awake, confidence(for: amplitude, min: awakeThreshold, max: 0.15))
        }

        if amplitude < deepSleepMaxAmplitude && spectralCentroid < remSpectralMin {
            let conf = confidence(for: deepSleepMaxAmplitude - amplitude, min: 0, max: deepSleepMaxAmplitude)
            return (.deep, conf)
        }

        if spectralCentroid >= remSpectralMin && spectralCentroid <= remSpectralMax {
            let centerDist = abs(spectralCentroid - (remSpectralMin + remSpectralMax) / 2)
            let maxDist = (remSpectralMax - remSpectralMin) / 2
            return (.rem, Double(1.0 - centerDist / maxDist))
        }

        return (.light, 0.7)
    }

    private func confidence(for value: Float, min: Float, max: Float) -> Double {
        guard max > min else { return 0.5 }
        return Double(Swift.min(Swift.max((value - min) / (max - min), 0), 1))
    }

    func reset() {
        recentFeatures.removeAll()
    }
}
