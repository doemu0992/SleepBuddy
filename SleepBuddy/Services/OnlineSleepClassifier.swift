import Foundation
import SwiftData

/// Weighted k-NN classifier that learns from every recorded night.
/// Starts with rule-based heuristics and transitions to learned boundaries
/// as more data accumulates. No server, no training step — improves on-device.
final class OnlineSleepClassifier {

    // MARK: - Config

    private let k = 7                   // neighbours to consider
    private let minSamplesForKNN = 40   // need enough variety before trusting k-NN
    private let correctedWeight: Float = 3.0    // boost for user-corrected labels
    private let historySize = 3         // smoothing window (same as rule classifier)

    // MARK: - State

    private var samples: [TrainingSample] = []
    private var history: [(phase: SleepPhaseType, confidence: Double)] = []
    private let fallback = SleepPhaseClassifier()

    // Buffer: features collected THIS session, flushed to SwiftData on stop
    private var sessionBuffer: [(timestamp: Date, features: AudioFeatures, phase: SleepPhaseType)] = []

    // MARK: - Lifecycle

    /// Call once at startup with the persistent store.
    func loadSamples(from context: ModelContext) {
        let descriptor = FetchDescriptor<TrainingSample>(
            sortBy: [SortDescriptor(\.timestamp)]
        )
        samples = (try? context.fetch(descriptor)) ?? []
    }

    func reset() {
        history.removeAll()
        fallback.reset()
        sessionBuffer.removeAll()
    }

    // MARK: - Classification

    func classify(features: AudioFeatures) -> (phase: SleepPhaseType, confidence: Double) {
        let raw = samples.count >= minSamplesForKNN
            ? knnClassify(features: features)
            : fallback.classify(features: features)

        history.append(raw)
        if history.count > historySize { history.removeFirst() }

        let result = smoothed()
        sessionBuffer.append((timestamp: Date(), features: features, phase: result.phase))
        return result
    }

    // MARK: - Persistence

    /// Call after stopTracking() to persist this night's samples.
    func flushSessionBuffer(to context: ModelContext) {
        for entry in sessionBuffer {
            let sample = TrainingSample(timestamp: entry.timestamp, features: entry.features, label: entry.phase)
            context.insert(sample)
            samples.append(sample)
        }
        sessionBuffer.removeAll()
        try? context.save()
    }

    /// Call when the user corrects a phase in SleepDetailView.
    /// Finds in-memory samples for that time range and re-labels them.
    func correctSamples(from start: Date, to end: Date, correctPhase: SleepPhaseType, context: ModelContext) {
        for sample in samples where sample.timestamp >= start && sample.timestamp <= end {
            sample.label = correctPhase.rawValue
            sample.isUserCorrected = true
        }
        try? context.save()
    }

    var sampleCount: Int { samples.count }

    // MARK: - k-NN

    private func knnClassify(features: AudioFeatures) -> (phase: SleepPhaseType, confidence: Double) {
        struct Neighbour {
            let phase: SleepPhaseType
            let weight: Float
        }

        // Sort by distance, take k nearest
        let neighbours = samples
            .sorted { $0.distance(to: features) < $1.distance(to: features) }
            .prefix(k)
            .map { sample -> Neighbour in
                let dist = sample.distance(to: features)
                let baseWeight: Float = dist < 1e-6 ? 1000 : (1.0 / dist)
                let w = sample.isUserCorrected ? baseWeight * correctedWeight : baseWeight
                return Neighbour(phase: sample.phase, weight: w)
            }

        // Weighted vote
        var votes: [SleepPhaseType: Float] = [:]
        let totalWeight = neighbours.map(\.weight).reduce(0, +)
        for n in neighbours {
            votes[n.phase, default: 0] += n.weight
        }

        let winner = votes.max(by: { $0.value < $1.value })!
        let confidence = Double(winner.value / max(totalWeight, 1e-6))
        return (winner.key, 0.4 + confidence * 0.55)  // map to [0.4, 0.95]
    }

    // MARK: - History smoothing (identical to SleepPhaseClassifier)

    private func smoothed() -> (phase: SleepPhaseType, confidence: Double) {
        guard !history.isEmpty else { return (.awake, 0.5) }
        if history.count == 1 { return history[0] }

        var votes: [SleepPhaseType: Double] = [:]
        for entry in history { votes[entry.phase, default: 0] += entry.confidence }

        let winner = votes.max(by: { $0.value < $1.value })!
        let avg = history.filter { $0.phase == winner.key }.map(\.confidence).reduce(0, +)
                  / Double(history.count)
        return (winner.key, avg)
    }
}
