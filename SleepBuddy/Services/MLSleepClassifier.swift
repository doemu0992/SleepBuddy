import CoreML
import Foundation
import SwiftData

/// Entry point for sleep phase classification.
/// Uses on-device learned k-NN (OnlineSleepClassifier) enriched by any
/// trained CoreML model that may be bundled in the future.
final class MLSleepClassifier {

    let onlineClassifier = OnlineSleepClassifier()
    private var coreMLModel: MLModel?
    private(set) var isCoreMLAvailable = false

    init() {
        loadCoreMLModel()
    }

    // MARK: - Setup

    func loadSamples(from context: ModelContext) {
        onlineClassifier.loadSamples(from: context)
    }

    private func loadCoreMLModel() {
        guard let url = Bundle.main.url(forResource: "SleepPhaseClassifier", withExtension: "mlmodelc"),
              let model = try? MLModel(contentsOf: url) else {
            isCoreMLAvailable = false
            return
        }
        coreMLModel = model
        isCoreMLAvailable = true
    }

    // MARK: - Classification

    func classify(features: AudioFeatures) -> (phase: SleepPhaseType, confidence: Double) {
        // CoreML takes priority if available (highest quality when trained model exists)
        if isCoreMLAvailable, let result = coreMLClassify(features: features) {
            return result
        }
        // Otherwise: online k-NN (learns from every night)
        return onlineClassifier.classify(features: features)
    }

    func reset() {
        onlineClassifier.reset()
    }

    func flushSessionBuffer(to context: ModelContext) {
        onlineClassifier.flushSessionBuffer(to: context)
    }

    func correctSamples(from start: Date, to end: Date, correctPhase: SleepPhaseType, context: ModelContext) {
        onlineClassifier.correctSamples(from: start, to: end, correctPhase: correctPhase, context: context)
    }

    var sampleCount: Int { onlineClassifier.sampleCount }

    // MARK: - CoreML inference

    private func coreMLClassify(features: AudioFeatures) -> (phase: SleepPhaseType, confidence: Double)? {
        guard let model = coreMLModel else { return nil }

        let input: [String: Any] = [
            "averageAmplitude": Double(features.averageAmplitude),
            "amplitudeVariance": Double(features.amplitudeVariance),
            "breathingRateBPM": Double(features.breathingRateBPM),
            "breathingRegularity": Double(features.breathingRegularity)
        ]

        guard let provider = try? MLDictionaryFeatureProvider(dictionary: input),
              let output = try? model.prediction(from: provider),
              let labelValue = output.featureValue(for: "phase"),
              !labelValue.stringValue.isEmpty else { return nil }

        let label = labelValue.stringValue
        let confidence: Double
        if let probs = output.featureValue(for: "phaseProbability")?.dictionaryValue as? [String: Double] {
            confidence = probs[label] ?? 0.7
        } else {
            confidence = 0.7
        }

        return (SleepPhaseType(rawValue: label) ?? .awake, confidence)
    }
}
