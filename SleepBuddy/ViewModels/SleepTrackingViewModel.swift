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
    private(set) var liveHeartRateBPM: Double = 0   // HealthKit Watch HR (primary)
    private(set) var liveBCGHeartRateBPM: Float = 0 // BCG accelerometer HR (fallback)

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

    // Phase smoothing state: candidate phase before it's committed
    private var pendingPhase: SleepPhaseType = .awake
    private var pendingPhaseStartDate = Date()

    // Ambient noise sampling: accumulate amplitudes and write one dB value per minute
    private var noiseAccumulator: [Float] = []
    private var lastNoiseSampleDate = Date.distantPast

    // BCG heart rate sampling: last known BCG HR, written once per minute
    private var lastBCGSampleDate = Date.distantPast

    // Turn detection: track consecutive still periods so a movement spike counts as a turn
    private var stillSince: Date? = nil
    private var lastTurnDate: Date = .distantPast
    private let turnMovementThreshold: Double = 0.5
    private let stillMovementThreshold: Double = 0.08
    private let minStillBeforeTurn: TimeInterval = 120  // 2 min still before a spike counts
    private let turnCooldown: TimeInterval = 30          // min gap between two turns

    // Phase smoothing: commit after stability window.
    // 60 s is enough to catch genuine brief wake events (phone check, turning over)
    // while still filtering 8 Hz audio noise spikes (which last < 5 s).
    private let minPhaseDuration: TimeInterval = 60

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
        lastBCGSampleDate = .distantPast
        stillSince = nil
        lastTurnDate = .distantPast

        motionService.onFeaturesUpdated = { [weak self] motion in
            self?.latestMotionFeatures = motion
            if motion.isOnMattress && motion.bcgHeartRateBPM > 0 {
                self?.liveBCGHeartRateBPM = motion.bcgHeartRateBPM
            } else if !(motion.isOnMattress) {
                self?.liveBCGHeartRateBPM = 0
            }
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
            // snoringEventCount ist computed aus soundEventsArray — kein manuelles Increment nötig
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
                    self?.liveHeartRateBPM = bpm
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

        // If awake was pending (detected but < minPhaseDuration elapsed) when the user
        // pressed "Aufwachen", honour it: close the sleep phase at pendingPhaseStartDate
        // and add a short awake phase up to now. This captures both morning wakes and
        // brief mid-night phone checks that ended at session stop.
        if pendingPhase == .awake && pendingPhaseStartDate > currentPhaseStartDate {
            finalizeCurrentPhase(endDate: pendingPhaseStartDate, session: session)
            currentPhaseStartDate = pendingPhaseStartDate
            currentPhase = .awake
        }
        finalizeCurrentPhase(endDate: .now, session: session)
        session.endDate = .now
        // Use first non-awake phase as onset for display (most accurate).
        // classifier.sleepOnsetDate (set by detector during the night) is kept for
        // historical REM-window calculations; it must fire early so REM windows open
        // in time — but that early value is wrong for the "Einschlafen" latency display.
        // Prefer onset detector's timestamp (start of first quiet window) for display —
        // it's earlier and more accurate than the first committed non-awake phase,
        // which can be delayed by the isSleepOnsetDetected gate.
        session.sleepOnsetDate = onsetDetector.sleepOnset
            ?? session.phasesArray.first(where: { $0.phaseType != .awake })?.startDate
        session.alarmFiredDate = smartAlarm.alarmFiredDate
        session.sleepQualityScore = Double(SchlafindexView.score(for: session))

        if let context = modelContext {
            classifier.flushSessionBuffer(to: context)
        }

        // Feature 4: retroactive k-NN calibration via Apple Watch sleep phases
        if healthKit.isAuthorized, let context = modelContext {
            let watchPhases = await healthKit.readAppleWatchSleepPhases(
                from: session.startDate, to: session.endDate ?? .now
            )
            if !watchPhases.isEmpty {
                classifier.applyWatchCalibration(watchPhases, context: context)
            }
        }

        classifier.reset()
        try? modelContext?.save()

        // Retrain CoreML model in background with session quality weighting
        let samplesToTrain = classifier.onlineClassifier.allSamples
        if samplesToTrain.count >= 40, let ctx = modelContext {
            let descriptor = FetchDescriptor<SleepSession>(
                predicate: #Predicate { $0.endDate != nil }
            )
            let allSessions = (try? ctx.fetch(descriptor)) ?? []
            let qualityWindows: [SleepModelTrainingService.QualityWindow] = allSessions.compactMap { s in
                guard let end = s.endDate else { return nil }
                return SleepModelTrainingService.QualityWindow(
                    start: s.startDate, end: end, quality: s.subjectiveQuality
                )
            }
            Task.detached(priority: .background) {
                await SleepModelTrainingService.shared.train(
                    samples: samplesToTrain,
                    qualityWindows: qualityWindows
                )
            }
        }

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

    /// User taps "Snooze" — pauses alarm for 5 minutes, tracking continues.
    func snoozeAlarm() {
        smartAlarm.snooze()
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

        // Sleep onset: set as soon as detector fires.
        // We no longer require classifier agreement — the onset detector already
        // uses both audio silence and motion stillness windows, so it's reliable.
        // Requiring classifier agreement caused a chicken-and-egg problem where
        // sleepOnsetDate was never set, preventing inREMWindow() from ever returning true.
        if !isSleepOnsetDetected && onsetDetector.update(audio: audio, motion: motion) {
            isSleepOnsetDetected = true
            classifier.sleepOnsetDate = onsetDetector.sleepOnset
        }

        // Snoring — count via confirmed SoundEvents in onEventCaptured (not raw feature ticks).
        // The raw snoringIntensity feature oscillates at 8 Hz and would produce thousands of
        // false positives from fans/HVAC. We keep isSnoring for the live badge only.
        isSnoring = audio.snoringIntensity > 0.4

        // Smart alarm check
        smartAlarm.checkPhase(result.phase)

        // Phase smoothing: track candidate phase, only commit after 2 min stability
        let now = Date()
        if result.phase != pendingPhase {
            pendingPhase = result.phase
            pendingPhaseStartDate = now
        } else if result.phase != currentPhase,
                  now.timeIntervalSince(pendingPhaseStartDate) >= minPhaseDuration,
                  isSleepOnsetDetected || result.phase == .awake {
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

        // Turn detection: movement spike after ≥2 min of stillness = body turn
        if isSleepOnsetDetected, let session = currentSession {
            let intensity = Double(motion.movementIntensity)
            let now = Date()
            if intensity < stillMovementThreshold {
                if stillSince == nil { stillSince = now }
            } else if intensity > turnMovementThreshold,
                      let since = stillSince,
                      now.timeIntervalSince(since) >= minStillBeforeTurn,
                      now.timeIntervalSince(lastTurnDate) >= turnCooldown {
                session.positionChanges += 1
                lastTurnDate = now
                stillSince = nil
            } else if intensity > stillMovementThreshold {
                stillSince = nil
            }
        }

        // BCG heart rate: store one sample per minute (0 = no data this minute)
        if Date().timeIntervalSince(lastBCGSampleDate) >= 60, let session = currentSession {
            let hr = liveBCGHeartRateBPM > 0 ? Double(liveBCGHeartRateBPM)
                   : liveHeartRateBPM > 0 ? liveHeartRateBPM : 0
            session.heartRateSamples.append(hr)
            lastBCGSampleDate = Date()
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
