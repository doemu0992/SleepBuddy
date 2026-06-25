import Foundation
import SwiftData

/// Persisted feature vector + ground truth label.
/// 7-dimensional: 4 audio features + motion + snoring + time-of-night.
@Model
final class TrainingSample {
    var timestamp: Date
    var averageAmplitude: Float
    var amplitudeVariance: Float
    var breathingRateBPM: Float
    var breathingRegularity: Float
    var movementIntensity: Float
    var snoringIntensity: Float
    var elapsedMinutesSinceOnset: Float = 0  // 7th feature: 0–480 min normalised by 480
    var label: String               // SleepPhaseType.rawValue
    var isUserCorrected: Bool       // corrected samples get 3× weight

    init(timestamp: Date, audio: AudioFeatures, motion: MotionFeatures, label: SleepPhaseType,
         elapsedMinutes: Float = 0, isUserCorrected: Bool = false) {
        self.timestamp = timestamp
        self.averageAmplitude = audio.averageAmplitude
        self.amplitudeVariance = audio.amplitudeVariance
        self.breathingRateBPM = audio.breathingRateBPM
        self.breathingRegularity = audio.breathingRegularity
        self.movementIntensity = motion.movementIntensity
        self.snoringIntensity = audio.snoringIntensity
        self.elapsedMinutesSinceOnset = elapsedMinutes
        self.label = label.rawValue
        self.isUserCorrected = isUserCorrected
    }

    init(timestamp: Date,
         averageAmplitude: Float, amplitudeVariance: Float,
         breathingRateBPM: Float, breathingRegularity: Float,
         movementIntensity: Float, snoringIntensity: Float,
         elapsedMinutes: Float = 0,
         label: SleepPhaseType, isUserCorrected: Bool = false) {
        self.timestamp = timestamp
        self.averageAmplitude = averageAmplitude
        self.amplitudeVariance = amplitudeVariance
        self.breathingRateBPM = breathingRateBPM
        self.breathingRegularity = breathingRegularity
        self.movementIntensity = movementIntensity
        self.snoringIntensity = snoringIntensity
        self.elapsedMinutesSinceOnset = elapsedMinutes
        self.label = label.rawValue
        self.isUserCorrected = isUserCorrected
    }

    var phase: SleepPhaseType { SleepPhaseType(rawValue: label) ?? .awake }

    /// Euclidean distance in normalised 7D feature space.
    /// Pass `currentElapsed` (minutes since sleep onset) to include the time-of-night dimension.
    /// When 0 (legacy samples), the dimension contributes 0 and is effectively ignored.
    func distance(to audio: AudioFeatures, motion: MotionFeatures, currentElapsed: Float = 0) -> Float {
        let dAmp  = (averageAmplitude - audio.averageAmplitude)       / 0.05
        let dVar  = (amplitudeVariance - audio.amplitudeVariance)      / 0.001
        let dBPM  = (breathingRateBPM - audio.breathingRateBPM)       / 20.0
        let dReg  = (breathingRegularity - audio.breathingRegularity)  / 1.0
        let dMov  = (movementIntensity - motion.movementIntensity)     / 1.0
        let dSnor = (snoringIntensity - audio.snoringIntensity)        / 1.0
        // 7th dimension: 0.5× weight so time-of-night is informative but not dominant
        let dTime = (elapsedMinutesSinceOnset - currentElapsed) / 480.0 * 0.5
        return sqrt(dAmp*dAmp + dVar*dVar + dBPM*dBPM + dReg*dReg + dMov*dMov + dSnor*dSnor + dTime*dTime)
    }
}
