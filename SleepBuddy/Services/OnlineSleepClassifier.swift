import Foundation
import SwiftData

/// Weighted k-NN classifier that learns from every recorded night.
/// Feature space: amplitude, variance, breathingRate, regularity, movement, snoring (6D).
final class OnlineSleepClassifier {

    private let k = 7
    private let minSamplesForKNN = 40
    private let correctedWeight: Float = 3.0
    private let historySize = 3

    private var samples: [TrainingSample] = []
    private var history: [(phase: SleepPhaseType, confidence: Double)] = []
    private let fallback = SleepPhaseClassifier()

    private var sessionBuffer: [(timestamp: Date, audio: AudioFeatures, motion: MotionFeatures, phase: SleepPhaseType)] = []

    // MARK: - Lifecycle

    func loadSamples(from context: ModelContext) {
        let descriptor = FetchDescriptor<TrainingSample>(sortBy: [SortDescriptor(\.timestamp)])
        samples = (try? context.fetch(descriptor)) ?? []
    }

    func reset() {
        history.removeAll()
        fallback.reset()
        sessionBuffer.removeAll()
    }

    // MARK: - Classification

    func classify(audio: AudioFeatures, motion: MotionFeatures) -> (phase: SleepPhaseType, confidence: Double) {
        let raw = samples.count >= minSamplesForKNN
            ? knnClassify(audio: audio, motion: motion)
            : fallback.classify(audio: audio, motion: motion)

        history.append(raw)
        if history.count > historySize { history.removeFirst() }

        let result = smoothed()
        sessionBuffer.append((timestamp: Date(), audio: audio, motion: motion, phase: result.phase))
        return result
    }

    // MARK: - Persistence

    func flushSessionBuffer(to context: ModelContext) {
        for entry in sessionBuffer {
            let sample = TrainingSample(
                timestamp: entry.timestamp,
                audio: entry.audio,
                motion: entry.motion,
                label: entry.phase
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

    // MARK: - k-NN

    private func knnClassify(audio: AudioFeatures, motion: MotionFeatures) -> (phase: SleepPhaseType, confidence: Double) {
        struct Neighbour { let phase: SleepPhaseType; let weight: Float }

        let neighbours = samples
            .sorted { $0.distance(to: audio, motion: motion) < $1.distance(to: audio, motion: motion) }
            .prefix(k)
            .map { s -> Neighbour in
                let d = s.distance(to: audio, motion: motion)
                let w = (d < 1e-6 ? 1000 : 1.0 / d) * (s.isUserCorrected ? correctedWeight : 1)
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
