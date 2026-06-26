import Foundation
import SwiftData
import HealthKit

/// Weighted k-NN classifier that learns from every recorded night.
/// Feature space: amplitude, variance, breathingRate, regularity, movement, snoring (6D).
final class OnlineSleepClassifier {

    private let k = 7
    private let minSamplesForKNN = 40
    private let correctedWeight: Float = 3.0
    private let historySize = 6
    /// Exponential half-life for time decay: samples 30 days old get 50% weight.
    private let decayHalfLifeDays: Double = 30.0

    // k-NN is expensive — only run every 240 ticks (30s at 8 Hz), cache result in between
    private var knnTickCounter = 0
    private let knnRunEveryNTicks = 240
    private var cachedKNNResult: (phase: SleepPhaseType, confidence: Double) = (.light, 0.5)

    // Session buffer: one entry per 30s (every knnRunEveryNTicks calls), not per 8Hz tick
    private var bufferTickCounter = 0

    private var samples: [TrainingSample] = []
    private var history: [(phase: SleepPhaseType, confidence: Double)] = []
    private let fallback = SleepPhaseClassifier()

    var sleepOnsetDate: Date? {
        get { fallback.sleepOnsetDate }
        set { fallback.sleepOnsetDate = newValue }
    }

    var currentHRBPM: Double {
        get { fallback.currentHRBPM }
        set { fallback.currentHRBPM = newValue }
    }

    var currentHRVms: Double {
        get { fallback.currentHRVms }
        set { fallback.currentHRVms = newValue }
    }

    private var sessionBuffer: [(timestamp: Date, audio: AudioFeatures, motion: MotionFeatures, phase: SleepPhaseType, elapsedMinutes: Float)] = []

    // MARK: - Lifecycle

    func loadSamples(from context: ModelContext) {
        let descriptor = FetchDescriptor<TrainingSample>(sortBy: [SortDescriptor(\.timestamp)])
        samples = (try? context.fetch(descriptor)) ?? []
    }

    func reset() {
        history.removeAll()
        fallback.reset()
        sessionBuffer.removeAll()
        knnTickCounter = 0
        bufferTickCounter = 0
        cachedKNNResult = (.light, 0.5)
    }

    // MARK: - Classification

    func classify(audio: AudioFeatures, motion: MotionFeatures) -> (phase: SleepPhaseType, confidence: Double) {
        // k-NN is O(n) per call — throttle to once per 30s (every knnRunEveryNTicks audio ticks)
        knnTickCounter += 1
        let raw: (phase: SleepPhaseType, confidence: Double)
        if samples.count >= minSamplesForKNN {
            if knnTickCounter >= knnRunEveryNTicks {
                knnTickCounter = 0
                cachedKNNResult = knnClassify(audio: audio, motion: motion)
            }
            raw = cachedKNNResult
        } else {
            raw = fallback.classify(audio: audio, motion: motion)
        }

        history.append(raw)
        if history.count > historySize { history.removeFirst() }

        return smoothed()
    }

    /// Records a training sample labeled by the ShutEye classifier — called by MLSleepClassifier
    /// so that stored samples reflect cycle-based ground truth, not k-NN self-labels.
    func recordSample(audio: AudioFeatures, motion: MotionFeatures, phase: SleepPhaseType) {
        bufferTickCounter += 1
        if bufferTickCounter >= knnRunEveryNTicks {
            bufferTickCounter = 0
            let elapsed = sleepOnsetDate.map { Float(Date().timeIntervalSince($0) / 60) } ?? 0
            sessionBuffer.append((timestamp: Date(), audio: audio, motion: motion, phase: phase, elapsedMinutes: elapsed))
        }
    }

    // MARK: - Persistence

    func flushSessionBuffer(to context: ModelContext) {
        for entry in sessionBuffer {
            let sample = TrainingSample(
                timestamp: entry.timestamp,
                audio: entry.audio,
                motion: entry.motion,
                label: entry.phase,
                elapsedMinutes: entry.elapsedMinutes
            )
            context.insert(sample)
            samples.append(sample)
        }
        sessionBuffer.removeAll()
        try? context.save()
    }

    func correctSamples(from start: Date, to end: Date, correctPhase: SleepPhaseType, context: ModelContext) {
        for sample in samples where sample.timestamp >= start && sample.timestamp <= end {
            sample.label = correctPhase.rawValue
            sample.isUserCorrected = true
        }
        try? context.save()
    }

    var sampleCount: Int { samples.count }
    var allSamples: [TrainingSample] { samples }

    /// Soft-corrects TrainingSamples whose classifier label disagrees with Apple Watch for the same time window.
    /// Only updates samples not already manually corrected by the user.
    func applyWatchCalibration(_ segments: [HealthKitService.WatchSleepSegment], context: ModelContext) {
        var changed = false
        for seg in segments {
            for sample in samples
            where !sample.isUserCorrected
               && sample.timestamp >= seg.start
               && sample.timestamp <= seg.end
               && sample.phase != seg.phase {
                sample.label = seg.phase.rawValue
                changed = true
            }
        }
        if changed { try? context.save() }
    }

    // MARK: - k-NN

    private func knnClassify(audio: AudioFeatures, motion: MotionFeatures) -> (phase: SleepPhaseType, confidence: Double) {
        struct Neighbour { let phase: SleepPhaseType; let weight: Float }

        let now = Date()
        let secPerDay: Double = 86400
        let lambda = Float(log(2.0) / decayHalfLifeDays)
        let currentElapsed = sleepOnsetDate.map { Float(now.timeIntervalSince($0) / 60) } ?? 0

        let neighbours = samples
            .sorted { $0.distance(to: audio, motion: motion, currentElapsed: currentElapsed) < $1.distance(to: audio, motion: motion, currentElapsed: currentElapsed) }
            .prefix(k)
            .map { s -> Neighbour in
                let d = s.distance(to: audio, motion: motion, currentElapsed: currentElapsed)
                let daysSince = Float(now.timeIntervalSince(s.timestamp) / secPerDay)
                let timeDecay = exp(-lambda * max(0, daysSince))
                let w = (d < 1e-6 ? 1000 : 1.0 / d) * (s.isUserCorrected ? correctedWeight : 1) * timeDecay
                return Neighbour(phase: s.phase, weight: w)
            }

        var votes: [SleepPhaseType: Float] = [:]
        let total = neighbours.map(\.weight).reduce(0, +)
        for n in neighbours { votes[n.phase, default: 0] += n.weight }

        let winner = votes.max(by: { $0.value < $1.value })!
        return (winner.key, Double(0.4 + (winner.value / max(total, 1e-6)) * 0.55))
    }

    // MARK: - Smoothing

    private func smoothed() -> (phase: SleepPhaseType, confidence: Double) {
        guard !history.isEmpty else { return (.awake, 0.5) }
        if history.count == 1 { return history[0] }
        var votes: [SleepPhaseType: Double] = [:]
        for e in history { votes[e.phase, default: 0] += e.confidence }
        let winner = votes.max(by: { $0.value < $1.value })!
        let avg = history.filter { $0.phase == winner.key }.map(\.confidence).reduce(0, +) / Double(history.count)
        return (winner.key, avg)
    }
}
