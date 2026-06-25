import CoreML
import Foundation
import HealthKit
import SwiftData

/// Entry point for classification. Priority:
///   1. CoreML trained model (ApplicationSupport — retrained nightly, or bundled fallback)
///   2. Online k-NN (learns from every night)
///   3. Rule-based fallback (Nacht 1)
final class MLSleepClassifier {

    let onlineClassifier = OnlineSleepClassifier()
    private var coreMLModel: MLModel?
    private(set) var isCoreMLAvailable = false

    private var retrainObserver: NSObjectProtocol?

    init() {
        // Load CoreML model on background thread — avoid blocking main thread at startup
        Task.detached(priority: .utility) { [weak self] in
            self?.loadCoreMLModel()
        }
        // Reload model whenever SleepModelTrainingService finishes a new training run
        retrainObserver = NotificationCenter.default.addObserver(
            forName: .sleepModelRetrained,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.loadCoreMLModel()
        }
    }

    deinit {
        if let obs = retrainObserver { NotificationCenter.default.removeObserver(obs) }
    }

    func loadSamples(from context: ModelContext) {
        onlineClassifier.loadSamples(from: context)
    }

    // MARK: - Model Loading (ApplicationSupport → Bundle)

    func loadCoreMLModel() {
        // 1. Prefer nightly-trained model in ApplicationSupport
        if let trainedURL = SleepModelTrainingService.trainedModelURL,
           FileManager.default.fileExists(atPath: trainedURL.path),
           let model = try? MLModel(contentsOf: trainedURL) {
            coreMLModel = model
            isCoreMLAvailable = true
            return
        }
        // 2. Fall back to bundled model (if shipped)
        if let bundleURL = Bundle.main.url(forResource: "SleepPhaseClassifier", withExtension: "mlmodelc"),
           let model = try? MLModel(contentsOf: bundleURL) {
            coreMLModel = model
            isCoreMLAvailable = true
            return
        }
        coreMLModel = nil
        isCoreMLAvailable = false
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

    var currentHRBPM: Double {
        get { onlineClassifier.currentHRBPM }
        set { onlineClassifier.currentHRBPM = newValue }
    }

    var currentHRVms: Double {
        get { onlineClassifier.currentHRVms }
        set { onlineClassifier.currentHRVms = newValue }
    }

    func reset() { onlineClassifier.reset() }

    func flushSessionBuffer(to context: ModelContext) {
        onlineClassifier.flushSessionBuffer(to: context)
    }

    func correctSamples(from start: Date, to end: Date, correctPhase: SleepPhaseType, context: ModelContext) {
        onlineClassifier.correctSamples(from: start, to: end, correctPhase: correctPhase, context: context)
    }

    var sampleCount: Int { onlineClassifier.sampleCount }

    func applyWatchCalibration(_ segments: [HealthKitService.WatchSleepSegment], context: ModelContext) {
        onlineClassifier.applyWatchCalibration(segments, context: context)
    }

    // MARK: - CoreML inference

    private func coreMLClassify(audio: AudioFeatures, motion: MotionFeatures) -> (phase: SleepPhaseType, confidence: Double)? {
        guard let model = coreMLModel else { return nil }
        let input: [String: Any] = [
            "averageAmplitude":    Double(audio.averageAmplitude),
            "amplitudeVariance":   Double(audio.amplitudeVariance),
            "breathingRateBPM":    Double(audio.breathingRateBPM),
            "breathingRegularity": Double(audio.breathingRegularity),
            "movementIntensity":   Double(motion.movementIntensity),
            "snoringIntensity":    Double(audio.snoringIntensity)
        ]
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: input),
              let output = try? model.prediction(from: provider),
              let label = output.featureValue(for: "phase")?.stringValue,
              !label.isEmpty else { return nil }

        let conf = (output.featureValue(for: "phaseProbability")?.dictionaryValue as? [String: Double])?[label] ?? 0.7
        return (SleepPhaseType(rawValue: label) ?? .awake, conf)
    }
}
