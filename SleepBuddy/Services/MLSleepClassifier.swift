import Foundation
import HealthKit
import SwiftData

/// Entry point for classification.
/// ShutEye-style: the 90-minute cycle classifier (SleepPhaseClassifier) is ALWAYS used
/// for live phase detection. k-NN is kept for training-data collection only
/// and does not influence real-time classification.
final class MLSleepClassifier {

    let onlineClassifier = OnlineSleepClassifier()
    private let shutEyeClassifier = SleepPhaseClassifier()

    func loadSamples(from context: ModelContext) {
        onlineClassifier.loadSamples(from: context)
    }

    // MARK: - Classification

    func classify(audio: AudioFeatures, motion: MotionFeatures) -> (phase: SleepPhaseType, confidence: Double) {
        // ShutEye cycle model is always the live classifier
        let result = shutEyeClassifier.classify(audio: audio, motion: motion)
        // Collect training sample labeled with ShutEye's phase for future model improvement
        onlineClassifier.recordSample(audio: audio, motion: motion, phase: result.phase)
        return result
    }

    var sleepOnsetDate: Date? {
        get { shutEyeClassifier.sleepOnsetDate }
        set {
            shutEyeClassifier.sleepOnsetDate = newValue
            onlineClassifier.sleepOnsetDate = newValue
        }
    }

    var currentHRBPM: Double {
        get { shutEyeClassifier.currentHRBPM }
        set {
            shutEyeClassifier.currentHRBPM = newValue
            onlineClassifier.currentHRBPM = newValue
        }
    }

    var currentHRVms: Double {
        get { shutEyeClassifier.currentHRVms }
        set {
            shutEyeClassifier.currentHRVms = newValue
            onlineClassifier.currentHRVms = newValue
        }
    }

    func reset() { shutEyeClassifier.reset(); onlineClassifier.reset() }

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
}
