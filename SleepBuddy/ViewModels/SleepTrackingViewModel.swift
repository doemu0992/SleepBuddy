import SwiftUI
import SwiftData
import Observation

@Observable
@MainActor
final class SleepTrackingViewModel {
    private(set) var currentSession: SleepSession?
    private(set) var currentPhase: SleepPhaseType = .awake
    private(set) var currentConfidence: Double = 0
    private(set) var isTracking = false
    private(set) var errorMessage: String?
    let insights = SleepInsightService()

    private let audioService = AudioAnalysisService()
    let classifier = MLSleepClassifier()
    private let healthKit = HealthKitService()

    private var modelContext: ModelContext?
    private var currentPhaseStartDate = Date()

    var isUsingML: Bool { classifier.sampleCount >= 40 }
    var sampleCount: Int { classifier.sampleCount }

    // MARK: - Setup

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        classifier.loadSamples(from: modelContext)
    }

    // MARK: - Tracking

    func startTracking() {
        guard !isTracking else { return }

        let session = SleepSession(startDate: .now)
        modelContext?.insert(session)
        currentSession = session
        currentPhaseStartDate = .now
        currentPhase = .awake
        insights.summary = nil
        insights.recommendations = []

        audioService.onFeaturesUpdated = { [weak self] features in
            self?.handleFeatures(features)
        }

        do {
            try audioService.start()
            isTracking = true
        } catch {
            errorMessage = "Mikrofon konnte nicht gestartet werden: \(error.localizedDescription)"
        }
    }

    func stopTracking() async {
        guard isTracking, let session = currentSession else { return }

        audioService.stop()

        finalizeCurrentPhase(endDate: .now, session: session)
        session.endDate = .now
        session.sleepQualityScore = session.computedQualityScore

        // Persist this night's training samples BEFORE resetting
        if let context = modelContext {
            classifier.flushSessionBuffer(to: context)
        }

        classifier.reset()
        try? modelContext?.save()

        if healthKit.isAuthorized {
            try? await healthKit.saveSleepSession(session)
        }

        isTracking = false

        await insights.generateInsights(for: session)
    }

    /// Called from SleepDetailView when user corrects a phase label.
    func correctPhase(_ phase: SleepPhase, to newType: SleepPhaseType) {
        guard let context = modelContext else { return }
        phase.phaseType = newType
        classifier.correctSamples(from: phase.startDate, to: phase.endDate, correctPhase: newType, context: context)
        try? context.save()
    }

    func clearError() { errorMessage = nil }

    func requestHealthKitAccess() async {
        await healthKit.requestAuthorization()
    }

    // MARK: - Private

    private func handleFeatures(_ features: AudioFeatures) {
        let result = classifier.classify(features: features)

        if result.phase != currentPhase {
            guard let session = currentSession else { return }
            let now = Date()
            finalizeCurrentPhase(endDate: now, session: session)
            currentPhaseStartDate = now
            currentPhase = result.phase
        }

        currentConfidence = result.confidence
    }

    private func finalizeCurrentPhase(endDate: Date, session: SleepSession) {
        guard endDate > currentPhaseStartDate else { return }
        let phase = SleepPhase(
            startDate: currentPhaseStartDate,
            endDate: endDate,
            phaseType: currentPhase,
            confidence: currentConfidence
        )
        session.phases.append(phase)
        modelContext?.insert(phase)
    }
}
