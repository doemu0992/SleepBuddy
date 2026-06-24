import CoreML
import Foundation
import SwiftData

/// Entry point for classification. Priority:
///   1. CoreML trained model (if bundled)
///   2. Online k-NN (learns from every night)
///   3. Rule-based fallback (Nacht 1)
final class MLSleepClassifier {

    let onlineClassifier = OnlineSleepClassifier()
    private var coreMLModel: MLModel?
    private(set) var isCoreMLAvailable = false

    init() { loadCoreMLModel() }

    func loadSamples(from context: ModelContext) {
        onlineClassifier.loadSamples(from: context)
    }

    private func loadCoreMLModel() {
        guard let url = Bundle.main.url(forResource: "SleepPhaseClassifier", withExtension: "mlmodelc"),
              let model = try? MLModel(contentsOf: url) else { return }
        coreMLModel = model
        isCoreMLAvailable = true
    }

    // MARK: - Classification

    func classify(audio: AudioFeatures, motion: MotionFeatures) -> (phase: SleepPhaseType, confidence: Double) {
        if isCoreMLAvailable, let result = coreMLClassify(audio: audio, motion: motion) { return result }
        return onlineClassifier.classify(audio: audio, motion: motion)
    }

    var sleepOnsetDate: Date? {
        get { onlineClassifier.sleepOnsetDate }
        set { onlineClassifier.sleepOnsetDate = newValue }
    }

    func reset() { onlineClassifier.reset() }

    func flushSessionBuffer(to context: ModelContext) {
        onlineClassifier.flushSessionBuffer(to: context)
    }

    func correctSamples(from start: Date, to end: Date, correctPhase: SleepPhaseType, context: ModelContext) {
        onlineClassifier.correctSamples(from: start, to: end, correctPhase: correctPhase, context: context)
    }

    var sampleCount: Int { onlineClassifier.sampleCount }

    // MARK: - CoreML inference

    private func coreMLClassify(audio: AudioFeatures, motion: MotionFeatures) -> (phase: SleepPhaseType, confidence: Double)? {
        guard let model = coreMLModel else { return nil }
        let input: [String: Any] = [
            "averageAmplitude":   Double(audio.averageAmplitude),
            "amplitudeVariance":  Double(audio.amplitudeVariance),
            "breathingRateBPM":   Double(audio.breathingRateBPM),
            "breathingRegularity":Double(audio.breathingRegularity),
            "movementIntensity":  Double(motion.movementIntensity),
            "snoringIntensity":   Double(audio.snoringIntensity)
        ]
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: input),
              let output = try? model.prediction(from: provider),
              let label = output.featureValue(for: "phase")?.stringValue,
              !label.isEmpty else { return nil }

        let conf = (output.featureValue(for: "phaseProbability")?.dictionaryValue as? [String: Double])?[label] ?? 0.7
        return (SleepPhaseType(rawValue: label) ?? .awake, conf)
    }
}
