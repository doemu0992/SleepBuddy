import CoreML
import Foundation

/// CoreML-based sleep phase classifier.
/// Falls back to signal-based rules when no trained model is available.
/// To train: collect AudioFeatures + ground truth labels, export via Create ML.
final class MLSleepClassifier {

    private var model: MLModel?
    private let signalClassifier = SleepPhaseClassifier()

    private(set) var isMLAvailable = false

    init() {
        loadModel()
    }

    private func loadModel() {
        // Looks for SleepPhaseClassifier.mlmodelc in the app bundle.
        // To generate: use Create ML with time-series audio features as input.
        guard let modelURL = Bundle.main.url(forResource: "SleepPhaseClassifier", withExtension: "mlmodelc"),
              let loaded = try? MLModel(contentsOf: modelURL) else {
            isMLAvailable = false
            return
        }
        model = loaded
        isMLAvailable = true
    }

    func classify(features: AudioFeatures) -> (phase: SleepPhaseType, confidence: Double) {
        if isMLAvailable, let result = mlClassify(features: features) {
            return result
        }
        // Fallback to signal-based classifier
        return signalClassifier.classify(features: features)
    }

    func reset() {
        signalClassifier.reset()
    }

    // MARK: - CoreML inference

    private func mlClassify(features: AudioFeatures) -> (phase: SleepPhaseType, confidence: Double)? {
        guard let model else { return nil }

        let input: [String: Any] = [
            "averageAmplitude": Double(features.averageAmplitude),
            "amplitudeVariance": Double(features.amplitudeVariance),
            "breathingRateBPM": Double(features.breathingRateBPM),
            "breathingRegularity": Double(features.breathingRegularity)
        ]

        guard let provider = try? MLDictionaryFeatureProvider(dictionary: input),
              let output = try? model.prediction(from: provider),
              let labelValue = output.featureValue(for: "phase"),
              let label = labelValue.stringValue.isEmpty ? nil : labelValue.stringValue else {
            return nil
        }

        let confidence: Double
        if let probsFeature = output.featureValue(for: "phaseProbability"),
           let probs = probsFeature.dictionaryValue as? [String: Double] {
            confidence = probs[label] ?? 0.7
        } else {
            confidence = 0.7
        }

        let phase = SleepPhaseType(rawValue: label) ?? .awake
        return (phase, confidence)
    }
}
