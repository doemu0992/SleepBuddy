import SwiftUI
import SwiftData
import Observation

@Observable
@MainActor
final class SleepTrackingViewModel {
    // Published state
    private(set) var currentSession: SleepSession?
    private(set) var currentPhase: SleepPhaseType = .awake
    private(set) var currentConfidence: Double = 0
    private(set) var isTracking = false
    private(set) var isSleepOnsetDetected = false
    private(set) var isSnoring = false
    private(set) var errorMessage: String?

    // Services
    let insights = SleepInsightService()
    let smartAlarm = SmartAlarmService()
    let classifier = MLSleepClassifier()

    private let audioService = AudioAnalysisService()
    private let motionService = MotionAnalysisService()
    private let onsetDetector = SleepOnsetDetector()
    private let healthKit = HealthKitService()
    let soundEventService = SoundEventService()

    private var modelContext: ModelContext?
    private var currentPhaseStartDate = Date()
    private var latestMotionFeatures = MotionFeatures.neutral

    // Phase smoothing: only commit a phase change after it's been stable for 2 minutes
    private var pendingPhase: SleepPhaseType = .awake
    private var pendingPhaseStartDate = Date()
    private static let minPhaseDuration: TimeInterval = 120

    // Smart alarm state (surfaced to UI)
    var alarmFired: Bool { smartAlarm.alarmFired }

    // MARK: - Setup

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        classifier.loadSamples(from: modelContext)
    }

    // MARK: - Tracking

    func startTracking() {
        guard !isTracking else { return }

        let session = SleepSession(startDate: .now)
        if smartAlarm.isEnabled {
            session.alarmEarliestTime = smartAlarm.earliestWakeTime
            session.alarmLatestTime   = smartAlarm.latestWakeTime
        }
        modelContext?.insert(session)
        currentSession = session
        currentPhaseStartDate = .now
        currentPhase = .awake
        isSleepOnsetDetected = false
        isSnoring = false
        insights.reset()
        pendingPhase = .awake
        pendingPhaseStartDate = .now

        onsetDetector.reset()
        classifier.reset()
        soundEventService.reset()

        motionService.onFeaturesUpdated = { [weak self] motion in
            self?.latestMotionFeatures = motion
        }

        audioService.onFeaturesUpdated = { [weak self] audio in
            self?.soundEventService.tick(
                amplitude: audio.averageAmplitude,
                snoringScore: audio.snoringIntensity,
                speechLikelihood: audio.speechLikelihood
            )
            self?.handleFeatures(audio: audio, motion: self?.latestMotionFeatures ?? .neutral)
        }

        audioService.onRawChunk = { [weak self] samples, sampleRate, _ in
            self?.soundEventService.appendSamples(samples, actualSampleRate: sampleRate)
        }

        soundEventService.onEventCaptured = { [weak self] timestamp, type, duration, fileName in
            guard let self, let session = self.currentSession, let ctx = self.modelContext else { return }
            let event = SleepSoundEvent(timestamp: timestamp, type: type, durationSeconds: duration, iCloudFileName: fileName)
            ctx.insert(event)
            session.soundEvents.append(event)
        }

        do {
            try audioService.start()
            soundEventService.configure(sampleRate: 44100)
            motionService.start()
            smartAlarm.arm()
            isTracking = true
            SleepBuddyApp.isTrackingActive = true
        } catch {
            errorMessage = "Mikrofon konnte nicht gestartet werden: \(error.localizedDescription)"
        }
    }

    func stopTracking() async {
        guard isTracking, let session = currentSession else { return }

        audioService.stop()
        motionService.stop()
        smartAlarm.disarm()
        smartAlarm.stopAlarm()
        soundEventService.reset()

        finalizeCurrentPhase(endDate: .now, session: session)
        session.endDate = .now
        session.sleepOnsetDate = onsetDetector.sleepOnset
        session.alarmFiredDate = smartAlarm.alarmFiredDate
        session.sleepQualityScore = session.computedQualityScore

        if let context = modelContext {
            classifier.flushSessionBuffer(to: context)
        }

        classifier.reset()
        try? modelContext?.save()

        if healthKit.isAuthorized {
            try? await healthKit.saveSleepSession(session)
        }

        PainDiaryVerknuepfungView.exportiereSession(session)

        isTracking = false
        SleepBuddyApp.isTrackingActive = false
        await insights.generateInsights(for: session)
    }

    /// User taps "Aufwachen" when smart alarm is ringing.
    func dismissAlarm() async {
        smartAlarm.stopAlarm()
        await stopTracking()
    }

    func correctPhase(_ phase: SleepPhase, to newType: SleepPhaseType) {
        guard let context = modelContext else { return }
        phase.phaseType = newType
        classifier.correctSamples(from: phase.startDate, to: phase.endDate, correctPhase: newType, context: context)
        try? context.save()
    }

    func clearError() { errorMessage = nil }

    func requestHealthKitAccess() async { await healthKit.requestAuthorization() }

    func requestAlarmPermission() async { await smartAlarm.requestPermission() }

    // MARK: - Feature handling

    private func handleFeatures(audio: AudioFeatures, motion: MotionFeatures) {
        // Sleep onset detection
        if !isSleepOnsetDetected && onsetDetector.update(audio: audio, motion: motion) {
            isSleepOnsetDetected = true
        }

        // Snoring
        isSnoring = audio.snoringIntensity > 0.4
        if isSnoring { currentSession?.snoringEventCount += 1 }

        // Classification
        let result = classifier.classify(audio: audio, motion: motion)

        // Smart alarm check
        smartAlarm.checkPhase(result.phase)

        // Phase smoothing: track candidate phase, only commit after 2 min stability
        let now = Date()
        if result.phase != pendingPhase {
            pendingPhase = result.phase
            pendingPhaseStartDate = now
        } else if result.phase != currentPhase,
                  now.timeIntervalSince(pendingPhaseStartDate) >= Self.minPhaseDuration {
            guard let session = currentSession else { return }
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
