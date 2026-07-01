import SwiftUI
import SwiftData
import Observation
import UIKit

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
    // Freshness of the live BCG value: when it was last updated from a REAL reading.
    // The live badge may hold the last value, but the stored per-minute series must only
    // use BCG when it is fresh — otherwise a stale value freezes into a fake flat line.
    private var lastBCGUpdate = Date.distantPast

    // Snoring pattern analysis: rolling timestamps of last 12 snoring events
    private var snoringTimestamps: [Date] = []
    private(set) var snoringIsObstructive: Bool = false  // periodic pattern = OSA-like

    // Phone-usage awake detection: the device being UNLOCKED during tracking is a strong
    // "awake" signal (checking the phone, browsing, gaming). When asleep the phone is locked.
    // Uses the protectedData lock notifications, which fire reliably when a passcode/FaceID
    // is set (the vast majority of devices). Without a passcode the feature is simply inert.
    private var usageAwakeIntervals: [(start: Date, end: Date)] = []
    private var currentUnlockStart: Date?
    private var usageObservers: [NSObjectProtocol] = []
    /// True once a real lock/unlock event fired — proves the device reports lock state
    /// (passcode/FaceID set). Without it the usage signal is untrustworthy and stays inert.
    private var sawLockEvent = false
    /// True while the device is unlocked / actively used during tracking (live awake hint).
    private(set) var deviceInUse = false

    // Turn detection: track consecutive still periods so a movement spike counts as a turn

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
        lastBCGUpdate = .distantPast
        snoringTimestamps.removeAll()
        snoringIsObstructive = false

        beginUsageMonitoring()

        motionService.onFeaturesUpdated = { [weak self] motion in
            self?.latestMotionFeatures = motion
            // Lower the sound-event threshold while the phone rests on the mattress.
            self?.soundEventService.isOnMattress = motion.isOnMattress
            if motion.isOnMattress && motion.bcgHeartRateBPM > 0 {
                self?.liveBCGHeartRateBPM = motion.bcgHeartRateBPM
                self?.lastBCGUpdate = Date()       // mark this value as fresh
            } else if !(motion.isOnMattress) {
                self?.liveBCGHeartRateBPM = 0
            }
            // Note: on-mattress but no valid BCG → keep the value for the live badge, but
            // do NOT refresh lastBCGUpdate, so the per-minute sampler treats it as missing.
        }

        audioService.onFeaturesUpdated = { [weak self] audio in
            self?.soundEventService.tick(
                instantAmplitude: audio.instantAmplitude,
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
        soundClassifier.onSoundDetected = { [weak self] type, confidence, label in
            self?.soundEventService.hintMLDetection(type: type, confidence: confidence, label: label)
        }

        soundEventService.onEventCaptured = { [weak self] timestamp, type, duration, fileName, decibelLevel, confidenceScore, mlLabel in
            guard let self, let session = self.currentSession, let ctx = self.modelContext else { return }
            let event = SleepSoundEvent(timestamp: timestamp, type: type, durationSeconds: duration, iCloudFileName: fileName, decibelLevel: decibelLevel, confidenceScore: confidenceScore, mlLabel: mlLabel)
            ctx.insert(event)
            session.soundEvents?.append(event)
            if type == .snoring {
                self.snoringTimestamps.append(timestamp)
                if self.snoringTimestamps.count > 12 { self.snoringTimestamps.removeFirst() }
                self.snoringIsObstructive = self.analyzeSnoringSnoringPattern()
            }
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
        endUsageMonitoring()

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
        // Use the first chronological non-awake phase as sleep onset for the latency display.
        // Sort is mandatory — SwiftData does not guarantee relationship order.
        // The onset detector fires earlier (good for REM-window timing via classifier.sleepOnsetDate)
        // but that early timestamp produces an unrealistically short "Einschlafen" latency.
        session.sleepOnsetDate = session.phasesArray
            .sorted { $0.startDate < $1.startDate }
            .first(where: { $0.phaseType != .awake })?.startDate
            ?? onsetDetector.sleepOnset
        session.alarmFiredDate = smartAlarm.alarmFiredDate
        session.sleepQualityScore = Double(SchlafindexView.score(for: session))

        if let context = modelContext {
            classifier.flushSessionBuffer(to: context)
        }

        // Post-hoc HR-based phase correction: re-type clear mislabels using the
        // cleaned full-night heart rate (only where real measured HR dominates).
        applyHeartRatePhaseCorrection(to: session)

        // Align REM to the night's actual cycle length (data-driven, not fixed 90 min).
        applyCycleRemRefinement(to: session)

        // Breathing-based refinement (relative, whole-night): confirm deep, support REM.
        if let ctx = modelContext { applyBreathingRefinement(to: session, context: ctx) }

        // Redistribute over-allocated deep sleep (circadian: deep is concentrated early).
        applyDeepRedistribution(to: session)

        // Post-hoc edge-wake detection: elevated HR at the start/end means the
        // user was lying awake (falling asleep / morning wake) — mark as awake.
        applyEdgeWakeCorrection(to: session)

        // Post-hoc mid-night wake from sustained body movement (turning, getting up).
        if let ctx = modelContext { applyMovementWake(to: session, context: ctx) }

        // Post-hoc: phone was unlocked / in use → that time was clearly awake.
        applyUsageAwake(to: session)

        // Post-hoc plausibility correction: remove/merge implausibly short isolated phases
        applyPlausibilityCorrection(to: session)

        classifier.reset()
        try? modelContext?.save()

        // UI can dismiss immediately — set isTracking = false now
        isTracking = false
        SleepBuddyApp.isTrackingActive = false

        // Slow work (HealthKit, Watch calibration, CoreML retraining, insights)
        // runs in a separate Task so the tracking screen closes without waiting.
        Task { [weak self] in
            guard let self else { return }

            // Feature 4: retroactive k-NN calibration via Apple Watch sleep phases
            if healthKit.isAuthorized, let context = modelContext {
                let watchPhases = await healthKit.readAppleWatchSleepPhases(
                    from: session.startDate, to: session.endDate ?? .now
                )
                if !watchPhases.isEmpty {
                    classifier.applyWatchCalibration(watchPhases, context: context)
                }
            }

            // Personal calibration: learn user's breathing baselines after 7+ nights
            let samplesForCal = classifier.onlineClassifier.allSamples
            if !samplesForCal.isEmpty {
                PersonalCalibrationService.shared.updateCalibration(samples: samplesForCal)
            }

            if healthKit.isAuthorized {
                try? await healthKit.saveSleepSession(session)
            }

            PainDiaryVerknuepfungView.exportiereSession(session)
            await insights.generateInsights(for: session)
        }
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
        var result = classifier.classify(audio: audio, motion: motion)

        // Phone in active use (device unlocked) → the user is awake, regardless of what the
        // cycle model would draw. This overrides the live phase so browsing/gaming after
        // starting tracking is not counted as sleep. Gated on sawLockEvent so a no-passcode
        // device (which never reports lock state) can't get stuck forcing awake all night.
        if deviceInUse && sawLockEvent {
            result = (.awake, max(result.confidence, 0.9))
        }

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

        // BCG heart rate: store one sample per minute (0 = no data this minute).
        // Source gate: only accept physiologically plausible values (40–110 BPM
        // during sleep). Implausible BCG artifacts (e.g. spikes to 140) are
        // stored as 0 so they don't pollute the stored series; the display
        // filter then holds the last good value (Variante B).
        if Date().timeIntervalSince(lastBCGSampleDate) >= 60, let session = currentSession {
            let watchHR = liveHeartRateBPM
            // Only use BCG if it was refreshed by a real reading in the last 90 s — a stale
            // held value must NOT be stored as if measured (that caused fake flat lines).
            let bcgFresh = Date().timeIntervalSince(lastBCGUpdate) < 90
            let bcgHR = bcgFresh ? Double(liveBCGHeartRateBPM) : 0
            let hr: Double
            if watchHR >= 40 && watchHR <= 110 {
                hr = watchHR                       // Apple Watch is authoritative
            } else if bcgHR >= 40 && bcgHR <= 110 {
                hr = bcgHR                         // plausible, fresh BCG
            } else {
                hr = 0                             // implausible / stale / no data
            }
            session.heartRateSamples.append(hr)
            lastBCGSampleDate = Date()
        }
    }

    /// Returns true when snoring events arrive at regular 4–12 s intervals
    /// (coefficient of variation < 0.35) — characteristic of obstructive apnea cycling.
    private func analyzeSnoringSnoringPattern() -> Bool {
        guard snoringTimestamps.count >= 6 else { return false }
        let intervals = zip(snoringTimestamps, snoringTimestamps.dropFirst())
            .map { $1.timeIntervalSince($0) }
        let qualifying = intervals.filter { $0 >= 4 && $0 <= 14 }
        guard qualifying.count >= 5 else { return false }
        let mean = qualifying.reduce(0, +) / Double(qualifying.count)
        let variance = qualifying.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(qualifying.count)
        let cv = sqrt(variance) / mean   // coefficient of variation
        return cv < 0.35
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

    // MARK: - Retroactive re-correction of existing sessions

    /// Rebuilds phases from the stored raw per-minute labels (TrainingSample) and
    /// re-runs the post-hoc corrections. Because it re-derives from the untouched
    /// raw labels, it recovers even nights whose phases were previously mangled by
    /// an over-aggressive correction. Returns the number of sessions processed.
    @discardableResult
    func reapplyPhaseCorrections(to sessions: [SleepSession], context: ModelContext) -> Int {
        modelContext = context
        var count = 0
        for session in sessions where !session.isActive {
            guard rebuildPhasesFromSamples(session, context: context) else { continue }
            applyHeartRatePhaseCorrection(to: session)
            applyCycleRemRefinement(to: session)
            applyBreathingRefinement(to: session, context: context)
            applyDeepRedistribution(to: session)
            applyEdgeWakeCorrection(to: session)
            applyMovementWake(to: session, context: context)
            applyPlausibilityCorrection(to: session)
            count += 1
        }
        try? context.save()
        return count
    }

    /// Rebuilds a session's SleepPhase list from its TrainingSamples (raw live
    /// labels, never touched by post-hoc corrections). Uses a per-minute majority
    /// vote + a 5-minute smoothing window so the result is clean blocks (not the
    /// choppy sub-minute fragments raw grouping would produce). Returns false if
    /// there are too few samples.
    private func rebuildPhasesFromSamples(_ session: SleepSession, context: ModelContext) -> Bool {
        let start = session.startDate
        let end = session.endDate ?? Date()
        let desc = FetchDescriptor<TrainingSample>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp <= end },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        guard let samples = try? context.fetch(desc), samples.count >= 4 else { return false }

        let totalMin = max(1, Int(end.timeIntervalSince(start) / 60))

        // 1. Per-minute majority label from the samples in that minute.
        var votes = Array(repeating: [SleepPhaseType: Int](), count: totalMin)
        for s in samples {
            let m = Int(s.timestamp.timeIntervalSince(start) / 60)
            if m >= 0 && m < totalMin { votes[m][s.phase, default: 0] += 1 }
        }
        var minuteLabel = [SleepPhaseType?](repeating: nil, count: totalMin)
        for m in 0..<totalMin { minuteLabel[m] = votes[m].max { $0.value < $1.value }?.key }
        // Forward-fill minutes without samples.
        var last: SleepPhaseType = minuteLabel.first(where: { $0 != nil }).flatMap { $0 } ?? .light
        for m in 0..<totalMin { if let l = minuteLabel[m] { last = l } else { minuteLabel[m] = last } }

        // 2. Smooth with a ±2-minute majority window to remove single-minute spikes.
        let smoothed: [SleepPhaseType] = (0..<totalMin).map { m in
            var w: [SleepPhaseType: Int] = [:]
            for k in max(0, m - 2)...min(totalMin - 1, m + 2) { w[minuteLabel[k]!, default: 0] += 1 }
            return w.max { $0.value < $1.value }!.key
        }

        // 3. Remove existing phases and group consecutive minutes into phases.
        for p in session.phasesArray { context.delete(p) }
        session.phases = []
        var gStart = 0
        for m in 1...totalMin {
            if m == totalMin || smoothed[m] != smoothed[gStart] {
                let ps = start.addingTimeInterval(Double(gStart) * 60)
                let pe = (m == totalMin) ? end : start.addingTimeInterval(Double(m) * 60)
                if pe > ps {
                    let phase = SleepPhase(startDate: ps, endDate: pe, phaseType: smoothed[gStart], confidence: 0.7)
                    phase.session = session
                    context.insert(phase)
                    session.phases?.append(phase)
                }
                gStart = m
            }
        }
        return true
    }

    // MARK: - Post-hoc HR-based phase correction
    // Uses the cleaned full-night heart rate (same robust filter as the display)
    // to fix CLEAR mislabels — only where real measured HR dominates the phase,
    // never on awake or on estimated (held) spans. Conservative: only corrects
    // when the existing label clearly contradicts the heart rate.
    private func applyHeartRatePhaseCorrection(to session: SleepSession) {
        let pts = cleanedHeartRate(session)
        guard !pts.isEmpty else { return }

        func median(_ a: [Double]) -> Double { let s = a.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }

        // Whole-night HR distribution → personalised (relative) thresholds, clamped
        // to sane absolute ranges. Adapts to each person/night instead of fixed BPM.
        let allMeasured = pts.filter { !$0.estimated }.map { $0.bpm }.sorted()
        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
        let deepCeil:  Double   // above this in a "deep" phase → not deep
        let cal = PersonalCalibrationService.shared
        if allMeasured.count >= 10 {
            func pct(_ p: Double) -> Double { allMeasured[min(allMeasured.count - 1, Int(Double(allMeasured.count) * p))] }
            let nightP50 = pct(0.50)
            let nightDeepFloor = clamp(pct(0.25), 48, 56)
            // Keep learning the personal baseline (still used elsewhere), then blend.
            cal.updateHRBaseline(median: nightP50, deepFloor: nightDeepFloor)
            let blendedP50 = cal.hrMedian.map { 0.5 * $0 + 0.5 * nightP50 } ?? nightP50
            deepCeil = clamp(blendedP50 + 4, 60, 70)
        } else if let pm = cal.hrMedian {
            // Too little data tonight → fall back to the learned personal baseline.
            deepCeil = clamp(pm + 4, 60, 70)
        } else {
            deepCeil = 65   // global fallback
        }

        var changed = false
        for phase in session.phasesArray where phase.phaseType != .awake {
            let startMin = Int(phase.startDate.timeIntervalSince(session.startDate) / 60)
            let endMin   = Int(phase.endDate.timeIntervalSince(session.startDate) / 60)
            guard endMin > startMin else { continue }

            let span = pts.filter { $0.index >= startMin && $0.index < endMin }
            let measured = span.filter { !$0.estimated }.map { $0.bpm }
            // Only act when real measured HR covers at least half the phase.
            guard measured.count >= 3, Double(measured.count) / Double(max(1, span.count)) >= 0.5 else { continue }

            let m = median(measured)

            switch phase.phaseType {
            case .deep:
                // Deep sleep sits in the lower part of the night's HR. Clearly above
                // the night's median → not deep → light (not REM, avoids REM hops).
                if m >= deepCeil { phase.phaseType = .light; changed = true }
            case .light:
                // De-emphasised after PSG validation (Walch et al., n=20): a LOW absolute
                // pulse is NOT predominantly deep sleep — real deep-sleep HR sits around the
                // night's p60, basically at the median and indistinguishable from REM
                // (offsets only ±1.4 BPM). Promoting light→deep on low HR therefore mislabels
                // epochs and inflated deep. Deep is now decided by movement + breathing
                // regularity + cycle structure, not by absolute HR level.
                break
            case .rem:
                // Do NOT convert REM→deep on low HR: BCG underestimates the pulse,
                // and REM HR is similar to light — this was wiping out almost all REM
                // and inflating deep. REM is left to the cycle/breathing logic.
                break
            case .awake:
                break
            }
        }
        if changed { try? modelContext?.save() }
    }

    // MARK: - Data-driven sleep-cycle length

    /// Estimates the night's actual ultradian cycle length (min) via autocorrelation
    /// of a depth proxy (low HR = deep), instead of assuming a fixed 90 min. Returns
    /// 90 when there isn't a clear rhythm or too little data.
    private func detectCycleLength(_ session: SleepSession) -> Int {
        let hr = cleanedHeartRate(session).map { $0.bpm }
        // Fallback 100 min = real PSG median (Walch et al., n=31: Median 101, IQR 78–112),
        // not the textbook 90. Search widened to 70…120 because real cycles routinely exceed
        // 110 (the old ceiling cut them off).
        guard hr.count >= 140 else { return 100 }         // need ≳ 2.5 h
        let mean = hr.reduce(0, +) / Double(hr.count)
        let sig = hr.map { mean - $0 }                    // high when HR low (deep)
        let denom = sig.reduce(0) { $0 + $1 * $1 }
        guard denom > 0 else { return 100 }
        var bestLag = 100, bestVal = -2.0
        for lag in 70...120 where lag < sig.count {
            var num = 0.0
            for i in 0..<(sig.count - lag) { num += sig[i] * sig[i + lag] }
            let v = num / denom
            if v > bestVal { bestVal = v; bestLag = lag }
        }
        return bestVal > 0.10 ? bestLag : 100             // require a meaningful peak
    }

    /// REM almost never occurs in the first ~20 min after falling asleep (the first
    /// REM bout is ~70–90 min in). Only that genuinely-too-early REM is demoted to
    /// light. (Earlier this used the detected cycle position, which conflicted with
    /// the live 90-min REM placement and wiped out legitimate REM.)
    private func applyCycleRemRefinement(to session: SleepSession) {
        guard let onset = session.sleepOnsetDate else { return }
        let onsetMin = onset.timeIntervalSince(session.startDate) / 60
        var changed = false
        for phase in session.phasesArray where phase.phaseType == .rem {
            let centerMin = (phase.startDate.timeIntervalSince(session.startDate)
                             + phase.endDate.timeIntervalSince(session.startDate)) / 120
            if centerMin - onsetMin < 20 { phase.phaseType = .light; changed = true }
        }
        if changed { try? modelContext?.save() }
    }

    // MARK: - Deep-sleep circadian redistribution
    // The 90-min cycle model allocates deep every cycle (≈50%), but physiologically
    // deep sleep is concentrated in the first third of the night and almost absent
    // later (the rest is light). Late-night deep that isn't HR-confirmed is demoted
    // to light → realistic ratios (deep ~15–25 %, light dominant).
    private func applyDeepRedistribution(to session: SleepSession) {
        // The cycle model over-allocates deep AND rem (BCG bias + zone model), so a
        // single night can show e.g. deep 36 % / rem 38 % / light 16 %. Enforce a
        // physiological budget: cap deep and REM at realistic maxima and give the
        // excess to LIGHT (which is otherwise too low). Demote the LATEST deep first
        // (deep concentrates early) and the EARLIEST REM first (REM grows toward
        // morning) — so what remains is also correctly positioned.
        let sleepPhases = session.phasesArray.filter { $0.phaseType != .awake }
        func dur(_ p: SleepPhase) -> TimeInterval { p.endDate.timeIntervalSince(p.startDate) }
        let totalSleep = sleepPhases.reduce(0) { $0 + dur($1) }
        guard totalSleep > 0 else { return }

        let deepCap = 0.22 * totalSleep
        let remCap  = 0.25 * totalSleep
        var changed = false

        var deepDur = sleepPhases.filter { $0.phaseType == .deep }.reduce(0) { $0 + dur($1) }
        if deepDur > deepCap {
            for p in sleepPhases.filter({ $0.phaseType == .deep }).sorted(by: { $0.startDate > $1.startDate }) {
                if deepDur <= deepCap { break }
                p.phaseType = .light; deepDur -= dur(p); changed = true
            }
        }

        var remDur = sleepPhases.filter { $0.phaseType == .rem }.reduce(0) { $0 + dur($1) }
        if remDur > remCap {
            for p in sleepPhases.filter({ $0.phaseType == .rem }).sorted(by: { $0.startDate < $1.startDate }) {
                if remDur <= remCap { break }
                p.phaseType = .light; remDur -= dur(p); changed = true
            }
        }
        if changed { try? modelContext?.save() }
    }

    // MARK: - Breathing-based refinement (relative, whole-night)

    /// Uses per-minute breathing rate + regularity (TrainingSamples), relative to
    /// the night's own distribution, to confirm deep sleep (slow + very regular)
    /// and support REM (irregular breathing in the detected cycle's REM window).
    /// Conservative: only upgrades `.light` where the sensors clearly agree.
    private func applyBreathingRefinement(to session: SleepSession, context: ModelContext) {
        let start = session.startDate
        let end = session.endDate ?? Date()
        let desc = FetchDescriptor<TrainingSample>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp <= end },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        guard let samples = try? context.fetch(desc), samples.count >= 20 else { return }
        let totalMin = max(1, Int(end.timeIntervalSince(start) / 60))

        // Per-minute breathing rate + regularity (average of that minute's samples,
        // only valid readings: rate 5–35 BPM, regularity > 0).
        var rateSum = [Double](repeating: 0, count: totalMin)
        var regSum  = [Double](repeating: 0, count: totalMin)
        var cnt     = [Int](repeating: 0, count: totalMin)
        for s in samples {
            guard s.breathingRateBPM > 5, s.breathingRateBPM < 35, s.breathingRegularity > 0 else { continue }
            let m = Int(s.timestamp.timeIntervalSince(start) / 60)
            if m >= 0 && m < totalMin {
                rateSum[m] += Double(s.breathingRateBPM); regSum[m] += Double(s.breathingRegularity); cnt[m] += 1
            }
        }
        let validRates = (0..<totalMin).filter { cnt[$0] > 0 }.map { rateSum[$0] / Double(cnt[$0]) }.sorted()
        let validRegs  = (0..<totalMin).filter { cnt[$0] > 0 }.map { regSum[$0]  / Double(cnt[$0]) }.sorted()
        guard validRates.count >= 10 else { return }
        func pct(_ a: [Double], _ p: Double) -> Double { a[min(a.count - 1, Int(Double(a.count) * p))] }
        let nSlow = pct(validRates, 0.25)   // slow breathing (deep)
        let nRegHigh = pct(validRegs, 0.70) // very regular (deep)
        let nRegLow  = pct(validRegs, 0.40) // irregular (REM) — slightly looser for more REM
        // Learn personal breathing baseline, then blend night + personal for stability.
        let cal = PersonalCalibrationService.shared
        cal.updateBreathBaseline(slowRate: nSlow, regHigh: nRegHigh, regLow: nRegLow)
        let slowRate = cal.brSlowRate.map { 0.5 * $0 + 0.5 * nSlow } ?? nSlow
        let regHigh  = cal.brRegHigh.map  { 0.5 * $0 + 0.5 * nRegHigh } ?? nRegHigh
        let regLow   = cal.brRegLow.map   { 0.5 * $0 + 0.5 * nRegLow } ?? nRegLow

        let L = Double(detectCycleLength(session))
        let onsetMin = session.sleepOnsetDate.map { $0.timeIntervalSince(start) / 60 } ?? 0

        var changed = false
        for phase in session.phasesArray where phase.phaseType == .light {
            let s0 = Int(phase.startDate.timeIntervalSince(start) / 60)
            let s1 = Int(phase.endDate.timeIntervalSince(start) / 60)
            guard s1 > s0 else { continue }
            let mins = (s0..<min(s1, totalMin)).filter { cnt[$0] > 0 }
            guard mins.count >= 2, Double(mins.count) / Double(s1 - s0) >= 0.5 else { continue }
            let medRate = mins.map { rateSum[$0] / Double(cnt[$0]) }.sorted()[mins.count / 2]
            let medReg  = mins.map { regSum[$0]  / Double(cnt[$0]) }.sorted()[mins.count / 2]

            // Deep confirmation: slow + very regular breathing.
            if medRate <= slowRate && medReg >= regHigh {
                phase.phaseType = .deep; changed = true; continue
            }
            // REM support: irregular breathing inside the cycle's REM window.
            let center = Double(s0 + s1) / 2
            var pos = (center - onsetMin).truncatingRemainder(dividingBy: L); if pos < 0 { pos += L }
            if pos >= 0.55 * L && medReg <= regLow {
                phase.phaseType = .rem; changed = true
            }
        }
        if changed { try? context.save() }
    }

    /// Robust per-minute heart rate (plausibility + median-5 + delta-limit) with
    /// Variante-B held gaps flagged `estimated`. Mirrors SleepDetailView.heartRatePoints.
    private func cleanedHeartRate(_ session: SleepSession) -> [(index: Int, bpm: Double, estimated: Bool)] {
        let raw = session.heartRateSamples
        guard !raw.isEmpty else { return [] }
        func median(_ a: [Double]) -> Double { let s = a.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }

        let vals: [Double?] = raw.map { ($0 >= 40 && $0 <= 110) ? $0 : nil }
        var smoothed: [Double?] = Array(repeating: nil, count: vals.count)
        for i in vals.indices where vals[i] != nil {
            var win: [Double] = []
            for j in max(0, i - 2)...min(vals.count - 1, i + 2) { if let x = vals[j] { win.append(x) } }
            smoothed[i] = win.isEmpty ? vals[i] : median(win)
        }
        var accepted: [Double?] = Array(repeating: nil, count: smoothed.count)
        var last: Double? = nil
        var rejectRun: [Double] = []
        for i in smoothed.indices {
            guard let v = smoothed[i] else { continue }
            if let l = last {
                if abs(v - l) <= 12 { accepted[i] = v; last = v; rejectRun.removeAll() }
                else {
                    rejectRun.append(v)
                    if rejectRun.count >= 3 { let mm = median(rejectRun); accepted[i] = mm; last = mm; rejectRun.removeAll() }
                }
            } else { accepted[i] = v; last = v }
        }
        guard let firstIdx = accepted.firstIndex(where: { $0 != nil }),
              let lastIdx = accepted.lastIndex(where: { $0 != nil }) else { return [] }

        var out: [(index: Int, bpm: Double, estimated: Bool)] = []
        var hold = accepted[firstIdx]!
        for i in firstIdx...lastIdx {
            let measured = accepted[i]
            let est = measured == nil
            let bpm = measured ?? hold
            if let mm = measured { hold = mm }
            out.append((index: i, bpm: bpm, estimated: est))
        }
        return out
    }

    // MARK: - Post-hoc edge-wake detection
    // Lying awake (falling asleep at night, waking in the morning) shows little
    // movement but a clearly elevated heart rate. Using the cleaned measured HR,
    // mark the leading/trailing stretches with awake-level HR (≥ 72 BPM) as awake.
    private func applyEdgeWakeCorrection(to session: SleepSession) {
        let pts = cleanedHeartRate(session)
        guard !pts.isEmpty else { return }
        var hrByMin: [Int: Double] = [:]
        for p in pts where !p.estimated { hrByMin[p.index] = p.bpm }
        guard !hrByMin.isEmpty, let maxIdx = hrByMin.keys.max() else { return }

        // Adaptive awake threshold: relative to the night's sleeping heart rate
        // so a modest morning rise is still caught (not just a fixed 72 BPM).
        let allHR = hrByMin.values.sorted()
        let sleepMedian = allHR[allHR.count / 2]
        let awakeHR = min(max(sleepMedian + 8.0, 62.0), 78.0)

        let extendThresholdEve = max(sleepMedian + 3.0, 60.0)

        // Evening: detect an elevated start (within the first 5 min), then extend
        // forward with a lower threshold to capture the whole settling-down period.
        var eveningEnd: Int? = nil
        var eveningDetected = false
        for i in 0...min(maxIdx, 5) {
            if let hr = hrByMin[i], hr >= awakeHR { eveningDetected = true; break }
        }
        if eveningDetected {
            var gap = 0
            for i in 0...maxIdx {
                if let hr = hrByMin[i] {
                    if hr >= extendThresholdEve { eveningEnd = i; gap = 0 } else { break }
                } else { gap += 1; if gap > 3 { break } }
            }
        }

        // Fallback: visualise the known sleep-onset latency as evening awake even
        // when the user lay calm (low HR) — the app already computes "Einschlafen X
        // min" from sleepOnsetDate, so show that period as awake at the start.
        if let onset = session.sleepOnsetDate {
            let latencyMin = Int(onset.timeIntervalSince(session.startDate) / 60)
            if latencyMin >= 3 { eveningEnd = max(eveningEnd ?? 0, latencyMin - 1) }
        }

        // Morning wake before stopping. Detect a wake near the end (elevated HR or
        // a lost BCG signal = movement/getting up), then extend backward using a
        // LOWER threshold so the whole gradual rise is captured — not just the 1
        // peak minute. Signal-loss minutes count as awake during this trailing run.
        let sessionMaxMin = max(0, Int(session.totalDuration / 60))
        let extendThreshold = max(sleepMedian + 3.0, 60.0)
        let manualStop = session.alarmFiredDate == nil

        // Wake detected if any of the last 4 measured minutes are clearly elevated,
        // or the BCG signal dropped out in the last 2 min (≈ got up / moved).
        var morningDetected = (sessionMaxMin - maxIdx) >= 2
        for i in stride(from: maxIdx, through: max(0, maxIdx - 4), by: -1) {
            if let hr = hrByMin[i], hr >= awakeHR { morningDetected = true; break }
        }

        var morningStart: Int? = nil
        if morningDetected {
            var start = sessionMaxMin
            var asleepRun = 0
            var i = sessionMaxMin - 1
            while i >= 0 {
                if let hr = hrByMin[i] {
                    if hr >= extendThreshold { start = i; asleepRun = 0 }
                    else { asleepRun += 1; if asleepRun >= 2 { break } }
                } else {
                    start = i   // signal lost → likely awake/moving
                }
                if sessionMaxMin - start >= 30 { break }   // cap morning wake at 30 min
                i -= 1
            }
            // Manual stop with a detected wake → ensure at least ~8 min.
            if manualStop { start = min(start, max(0, sessionMaxMin - 8)) }
            morningStart = start
        }

        var changed = false
        // Evening: at least 2 min of awake-level HR to count as latency.
        if let e = eveningEnd, e >= 2 { markAwake(in: session, fromMinute: 0, toMinute: e + 1); changed = true }
        // Morning: mark from the detected wake start to the end of the session.
        if let m = morningStart, (sessionMaxMin - m) >= 2 {
            markAwake(in: session, fromMinute: m, toMinute: sessionMaxMin + 1); changed = true
        }

        if changed { try? modelContext?.save() }
    }

    /// Marks [startMin, endMinExclusive) as awake, splitting phases at the
    /// boundaries so short awake segments are preserved.
    private func markAwake(in session: SleepSession, fromMinute startMin: Int, toMinute endMinExclusive: Int) {
        guard endMinExclusive > startMin else { return }
        let rangeStart = session.startDate.addingTimeInterval(Double(startMin) * 60)
        let rangeEnd   = session.startDate.addingTimeInterval(Double(endMinExclusive) * 60)
        for phase in session.phasesArray where !(phase.endDate <= rangeStart || phase.startDate >= rangeEnd) {
            if phase.startDate >= rangeStart && phase.endDate <= rangeEnd {
                phase.phaseType = .awake
            } else if phase.startDate < rangeStart && phase.endDate <= rangeEnd {
                let awake = SleepPhase(startDate: rangeStart, endDate: phase.endDate, phaseType: .awake, confidence: 0.7)
                phase.endDate = rangeStart
                awake.session = session
                modelContext?.insert(awake)
                session.phases?.append(awake)
            } else if phase.startDate >= rangeStart && phase.endDate > rangeEnd {
                let awake = SleepPhase(startDate: phase.startDate, endDate: rangeEnd, phaseType: .awake, confidence: 0.7)
                phase.startDate = rangeEnd
                awake.session = session
                modelContext?.insert(awake)
                session.phases?.append(awake)
            } else {
                let after = SleepPhase(startDate: rangeEnd, endDate: phase.endDate, phaseType: phase.phaseType, confidence: phase.confidence)
                let awake = SleepPhase(startDate: rangeStart, endDate: rangeEnd, phaseType: .awake, confidence: 0.7)
                phase.endDate = rangeStart
                after.session = session; awake.session = session
                modelContext?.insert(after); modelContext?.insert(awake)
                session.phases?.append(after); session.phases?.append(awake)
            }
        }
    }

    // MARK: - Phone-usage awake detection

    private func beginUsageMonitoring() {
        usageAwakeIntervals.removeAll()
        sawLockEvent = false
        // Tracking just started via a tap → device is unlocked and in use right now.
        currentUnlockStart = Date()
        deviceInUse = true
        let nc = NotificationCenter.default
        func observe(_ name: Notification.Name, _ handler: @escaping () -> Void) {
            usageObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in handler() }
            })
        }
        observe(UIApplication.protectedDataWillBecomeUnavailableNotification) { [weak self] in
            self?.deviceDidLock()
        }
        observe(UIApplication.protectedDataDidBecomeAvailableNotification) { [weak self] in
            self?.deviceDidUnlock()
        }
    }

    private func deviceDidLock() {
        guard isTracking else { return }
        sawLockEvent = true
        if let start = currentUnlockStart {
            usageAwakeIntervals.append((start, Date()))
            currentUnlockStart = nil
        }
        deviceInUse = false
    }

    private func deviceDidUnlock() {
        guard isTracking else { return }
        sawLockEvent = true
        if currentUnlockStart == nil { currentUnlockStart = Date() }
        deviceInUse = true
    }

    private func endUsageMonitoring() {
        // Only trust the still-open interval if lock state actually works on this device —
        // otherwise a no-passcode phone would report the whole night as "in use".
        if sawLockEvent, let start = currentUnlockStart {
            usageAwakeIntervals.append((start, Date()))
        }
        currentUnlockStart = nil
        deviceInUse = false
        usageObservers.forEach { NotificationCenter.default.removeObserver($0) }
        usageObservers.removeAll()
    }

    /// Marks every interval the phone was unlocked / in use during the night as awake.
    /// Short glances (< 90 s) are ignored so a quick time-check isn't over-weighted.
    private func applyUsageAwake(to session: SleepSession) {
        let start = session.startDate
        let end = session.endDate ?? Date()
        let totalMin = max(1, Int(end.timeIntervalSince(start) / 60))
        var marked = false
        for interval in usageAwakeIntervals {
            guard interval.end.timeIntervalSince(interval.start) >= 90 else { continue }
            let from = max(0, Int(interval.start.timeIntervalSince(start) / 60))
            let to = min(totalMin, Int(ceil(interval.end.timeIntervalSince(start) / 60)))
            if to > from {
                markAwake(in: session, fromMinute: from, toMinute: to)
                marked = true
            }
        }
        if marked { try? modelContext?.save() }
    }

    // MARK: - Mid-night wake from movement
    // Sustained elevated body movement (turning over, getting up, restlessness)
    // is the most reliable awake signal. Uses per-minute movementIntensity from
    // TrainingSamples. Calm motionless wakefulness stays undetectable (sensor limit).
    private func applyMovementWake(to session: SleepSession, context: ModelContext) {
        let start = session.startDate
        let end = session.endDate ?? Date()
        let desc = FetchDescriptor<TrainingSample>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp <= end },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        guard let samples = try? context.fetch(desc), !samples.isEmpty else { return }
        let totalMin = max(1, Int(end.timeIntervalSince(start) / 60))
        var rawMove = [Float](repeating: 0, count: totalMin)
        for s in samples {
            let m = Int(s.timestamp.timeIntervalSince(start) / 60)
            if m >= 0 && m < totalMin { rawMove[m] = max(rawMove[m], s.movementIntensity) }
        }

        // Actigraphy (Cole-Kripke-inspired): weight each minute by its neighbours so
        // a movement event counts across its surroundings, not just one isolated bin.
        var moveByMin = [Float](repeating: 0, count: totalMin)
        let w: [Float] = [0.25, 0.5, 1.0, 0.5, 0.25]   // window [-2…+2]
        for m in 0..<totalMin {
            var acc: Float = 0, wsum: Float = 0
            for (k, wk) in w.enumerated() {
                let idx = m + k - 2
                if idx >= 0 && idx < totalMin { acc += wk * rawMove[idx]; wsum += wk }
            }
            moveByMin[m] = wsum > 0 ? acc / wsum : rawMove[m]
        }

        // Relative thresholds: a movement is "elevated" relative to THIS night's own
        // quiet-sleep level, not a fixed value (adapts to person/mattress/phone).
        let sortedMove = moveByMin.sorted()
        let baseline = sortedMove[sortedMove.count / 2]                 // median = quiet sleep
        let p90 = sortedMove[min(sortedMove.count - 1, Int(Double(sortedMove.count) * 0.90))]
        let elevated: Float = max(min(baseline * 2.5, 0.30), 0.12)      // clearly above quiet sleep
        let strong:   Float = max(min(p90, 0.55), 0.35)                 // a strong spike (getting up)
        var changed = false
        var i = 0
        while i < totalMin {
            if moveByMin[i] > elevated {
                var j = i
                while j < totalMin && moveByMin[j] > elevated { j += 1 }
                let runLen = j - i
                // Sustained restlessness (≥ 2 min) or one strong getting-up spike.
                if runLen >= 2 || moveByMin[i] > strong || rawMove[i] > strong {
                    markAwake(in: session, fromMinute: i, toMinute: j)
                    changed = true
                }
                i = j
            } else { i += 1 }
        }

        // Intermittent restlessness (Umherwälzen): tossing and turning is often NOT
        // continuous — roll, lie still 30–60 s, roll again. A sustained-run check misses
        // this. Slide a 10-min window; if ≥ 3 of its minutes show elevated movement, the
        // whole window counts as restless → awake. Catches "die ganze Nacht hin und her".
        let windowLen = 10
        let minActive = 3
        var m = 0
        while m < totalMin {
            let hi = min(totalMin, m + windowLen)
            let active = (m..<hi).filter { moveByMin[$0] > elevated }.count
            if active >= minActive {
                markAwake(in: session, fromMinute: m, toMinute: hi)
                changed = true
                m = hi
            } else {
                m += 1
            }
        }

        if changed { try? context.save() }
    }

    // MARK: - Post-hoc plausibility correction
    // After all phases are committed, scan for physiologically implausible short "islands".
    // A phase < 3 min sandwiched between two identical neighbours is replaced with the
    // neighbour's type. This handles edge-case noise in the classifier without touching
    // longer bouts where the label is more reliable.
    private func applyPlausibilityCorrection(to session: SleepSession) {
        let minPlausibleDuration: TimeInterval = 180   // 3 minutes
        let phases = session.phasesArray.sorted { $0.startDate < $1.startDate }
        guard phases.count >= 3 else { return }

        var changed = false
        for i in 1..<(phases.count - 1) {
            let prev = phases[i - 1]
            let curr = phases[i]
            let next = phases[i + 1]
            let duration = curr.endDate.timeIntervalSince(curr.startDate)
            // Short phase flanked by the same type on both sides → merge into neighbours.
            // Never merge away .awake — a brief mid-night wake (turning, toilet) is a
            // real, meaningful interruption even if short.
            if duration < minPlausibleDuration && prev.phaseType == next.phaseType
                && curr.phaseType != prev.phaseType && curr.phaseType != .awake {
                curr.phaseType = prev.phaseType
                changed = true
            }
            // Deep→REM direct without light: a very short deep phase (< 4 min) that is
            // immediately followed by REM is physiologically unlikely — call it light sleep.
            if curr.phaseType == .deep && next.phaseType == .rem && duration < 240 {
                curr.phaseType = .light
                changed = true
            }
            // REM "hops": only a VERY short REM island (< 3 min) that directly abuts
            // deep sleep is implausible (transition goes deep→light→REM) → light.
            // Conservative: real REM bouts are preserved (don't wipe all REM).
            if curr.phaseType == .rem && duration < 180
                && prev.phaseType != .rem && next.phaseType != .rem
                && (prev.phaseType == .deep || next.phaseType == .deep) {
                curr.phaseType = .light
                changed = true
            }
        }
        // Terminal awake: if the session is long (> 5 h) and the final phase is not already
        // awake, the user was very likely lying still in bed before stopping the tracker.
        // Reclassify the last 15 minutes as awake to capture this "resting in bed" period.
        let sorted2 = session.phasesArray.sorted { $0.startDate < $1.startDate }
        if session.totalDuration > 5 * 3600,
           let lastPhase = sorted2.last,
           lastPhase.phaseType != .awake,
           let end = session.endDate {
            let terminalStart = end.addingTimeInterval(-15 * 60)
            if lastPhase.startDate < terminalStart {
                // Shorten the last phase and append a 15-min awake phase
                lastPhase.endDate = terminalStart
                let awakePhase = SleepPhase(startDate: terminalStart, endDate: end, phaseType: .awake, confidence: 0.68)
                awakePhase.session = session
                modelContext?.insert(awakePhase)
                if session.phases == nil { session.phases = [] }
                session.phases?.append(awakePhase)
            } else {
                // Phase is already shorter than 15 min — just flip its type
                lastPhase.phaseType = .awake
            }
            changed = true
        }

        if mergeAdjacentSamePhases(session) { changed = true }

        if changed { try? modelContext?.save() }
    }

    /// Merges consecutive phases of the same type into one (e.g. the edge-wake
    /// split can leave several adjacent .awake segments → show as a single phase).
    @discardableResult
    private func mergeAdjacentSamePhases(_ session: SleepSession) -> Bool {
        let sorted = session.phasesArray.sorted { $0.startDate < $1.startDate }
        guard sorted.count >= 2 else { return false }
        var changed = false
        var keep = sorted[0]
        for next in sorted.dropFirst() {
            if next.phaseType == keep.phaseType && next.startDate <= keep.endDate.addingTimeInterval(1) {
                // extend the kept phase, delete the redundant one
                if next.endDate > keep.endDate { keep.endDate = next.endDate }
                modelContext?.delete(next)
                changed = true
            } else {
                keep = next
            }
        }
        return changed
    }

}
