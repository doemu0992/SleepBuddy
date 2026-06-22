import Foundation
import SwiftData

/// Persisted audio feature vector + ground truth label.
/// Accumulated over time so the classifier improves each night.
@Model
final class TrainingSample {
    var timestamp: Date
    var averageAmplitude: Float
    var amplitudeVariance: Float
    var breathingRateBPM: Float
    var breathingRegularity: Float
    var label: String           // SleepPhaseType.rawValue
    var isUserCorrected: Bool   // user-corrected samples get 3× weight in k-NN

    init(timestamp: Date, features: AudioFeatures, label: SleepPhaseType, isUserCorrected: Bool = false) {
        self.timestamp = timestamp
        self.averageAmplitude = features.averageAmplitude
        self.amplitudeVariance = features.amplitudeVariance
        self.breathingRateBPM = features.breathingRateBPM
        self.breathingRegularity = features.breathingRegularity
        self.label = label.rawValue
        self.isUserCorrected = isUserCorrected
    }

    var phase: SleepPhaseType { SleepPhaseType(rawValue: label) ?? .awake }

    /// Euclidean distance in normalized feature space.
    func distance(to features: AudioFeatures) -> Float {
        let dAmp  = (averageAmplitude - features.averageAmplitude) / 0.05
        let dVar  = (amplitudeVariance - features.amplitudeVariance) / 0.001
        let dBPM  = (breathingRateBPM - features.breathingRateBPM) / 20.0
        let dReg  = (breathingRegularity - features.breathingRegularity) / 1.0
        return sqrt(dAmp*dAmp + dVar*dVar + dBPM*dBPM + dReg*dReg)
    }
}
