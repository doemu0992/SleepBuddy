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
    let soundClassifier = SoundClassificationService()

    private var modelContext: ModelContext?
    private var currentPhaseStartDate = Date()
    private var latestMotionFeatures = MotionFeatures.neutral

    // Ambient noise sampling: accumulate amplitudes and write one dB value per minute
    private var noiseAccumulator: [Float] = []
    private var lastNoiseSampleDate = Date.distantPast

    // Phase smoothing: commit after stability window.
    // With Apple Watch HR available, 60 s is sufficient (HR confirms the phase).
    // Without Watch, keep 90 s to avoid false transitions from audio noise.
    private var pendingPhase: SleepPhaseType = .awake
    private var pendingPhaseStartDate = Date()
    private var minPhaseDuration: TimeInterval {
        healthKit.hasHeartRateAccess ? 60 : 90
    }

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
        noiseAccumulator.removeAll()
        lastNoiseSampleDate = .distantPast

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

        audioService.onBufferReady = { [weak self] buffer, time in
            self?.soundClassifier.analyze(buffer: buffer, time: time)
        }
        soundClassifier.onSoundDetected = { [weak self] type, confidence in
            self?.soundEventService.hintMLDetection(type: type, confidence: confidence)
        }

        soundEventService.onEventCaptured = { [weak self] timestamp, type, duration, fileName, decibelLevel, confidenceScore in
            guard let self, let session = self.currentSession, let ctx = self.modelContext else { return }
            let event = SleepSoundEvent(timestamp: timestamp, type: type, durationSeconds: duration, iCloudFileName: fileName, decibelLevel: decibelLevel, confidenceScore: confidenceScore)
            ctx.insert(event)
            session.soundEvents?.append(event)
        }

        do {
            try audioService.start()
            if let format = audioService.currentFormat {
                soundClassifier.start(format: format)
            }
            soundEventService.configure(sampleRate: 44100)
            motionService.start()
            smartAlarm.arm()

            // Start HealthKit HR polling if Watch is available
            healthKit.startHeartRatePolling { [weak self] bpm, hrv in
                Task { @MainActor [weak self] in
                    self?.classifier.currentHRBPM = bpm
                    self?.classifier.currentHRVms  = hrv ?? 0
                }
            }

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
        soundClassifier.stop()
        soundEventService.reset()
        healthKit.stopHeartRatePolling()

        finalizeCurrentPhase(endDate: .now, session: session)
        session.endDate = .now
        // Prefer onset from detector; fall back to first non-awake phase if detector never fired
        session.sleepOnsetDate = onsetDetector.sleepOnset
            ?? session.phasesArray.first(where: { $0.phaseType != .awake })?.startDate
        session.alarmFiredDate = smartAlarm.alarmFiredDate
        session.sleepQualityScore = Double(SchlafindexView.score(for: session))

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
        // Classification first (onset confirmation needs it)
        let result = classifier.classify(audio: audio, motion: motion)

        // Sleep onset: only confirm when detector AND classifier agree user is asleep
        if !isSleepOnsetDetected && onsetDetector.update(audio: audio, motion: motion) {
            if result.phase != .awake {
                isSleepOnsetDetected = true
                classifier.sleepOnsetDate = onsetDetector.sleepOnset
            } else {
                // Classifier still shows awake — reset onset detector window
                onsetDetector.reset()
            }
        }

        // Snoring — count new onset events regardless of clip-save setting
        let newSnoring = audio.snoringIntensity > 0.4
        if newSnoring && !isSnoring { currentSession?.snoringEventCount += 1 }
        isSnoring = newSnoring

        // Smart alarm check
        smartAlarm.checkPhase(result.phase)

        // Phase smoothing: track candidate phase, only commit after 2 min stability
        let now = Date()
        if result.phase != pendingPhase {
            pendingPhase = result.phase
            pendingPhaseStartDate = now
        } else if result.phase != currentPhase,
                  now.timeIntervalSince(pendingPhaseStartDate) >= minPhaseDuration {
            guard let session = currentSession else { return }
            finalizeCurrentPhase(endDate: now, session: session)
            currentPhaseStartDate = now
            currentPhase = result.phase
        }

        currentConfidence = result.confidence

        // Ambient noise: accumulate amplitude and store one dB sample per minute
        noiseAccumulator.append(audio.averageAmplitude)
        if Date().timeIntervalSince(lastNoiseSampleDate) >= 60, let session = currentSession {
            let avg = noiseAccumulator.reduce(0, +) / max(Float(noiseAccumulator.count), 1)
            let db = max(0, min(120, 20.0 * log10(max(Double(avg), 1e-6)) + 90.0))
            session.noiseSamples.append(db)
            noiseAccumulator.removeAll()
            lastNoiseSampleDate = Date()
        }
    }

    private func finalizeCurrentPhase(endDate: Date, session: SleepSession) {
        guard endDate > currentPhaseStartDate else { return }
        let phase = SleepPhase(
            startDate: currentPhaseStartDate,
            endDate: endDate,
            phaseType: currentPhase,
            confidence: currentConfidence
        )
        session.phases?.append(phase)
        modelContext?.insert(phase)
    }
}
