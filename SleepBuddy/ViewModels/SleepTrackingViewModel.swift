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

    // Snoring pattern analysis: rolling timestamps of last 12 snoring events
    private var snoringTimestamps: [Date] = []
    private(set) var snoringIsObstructive: Bool = false  // periodic pattern = OSA-like

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
        snoringTimestamps.removeAll()
        snoringIsObstructive = false

        motionService.onFeaturesUpdated = { [weak self] motion in
            self?.latestMotionFeatures = motion
            // Lower the sound-event threshold while the phone rests on the mattress.
            self?.soundEventService.isOnMattress = motion.isOnMattress
            if motion.isOnMattress && motion.bcgHeartRateBPM > 0 {
                self?.liveBCGHeartRateBPM = motion.bcgHeartRateBPM
            } else if !(motion.isOnMattress) {
                self?.liveBCGHeartRateBPM = 0
            }
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
        soundClassifier.onSoundDetected = { [weak self] type, confidence in
            self?.soundEventService.hintMLDetection(type: type, confidence: confidence)
        }

        soundEventService.onEventCaptured = { [weak self] timestamp, type, duration, fileName, decibelLevel, confidenceScore in
            guard let self, let session = self.currentSession, let ctx = self.modelContext else { return }
            let event = SleepSoundEvent(timestamp: timestamp, type: type, durationSeconds: duration, iCloudFileName: fileName, decibelLevel: decibelLevel, confidenceScore: confidenceScore)
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

        // Post-hoc edge-wake detection: elevated HR at the start/end means the
        // user was lying awake (falling asleep / morning wake) — mark as awake.
        applyEdgeWakeCorrection(to: session)

        // Post-hoc mid-night wake from sustained body movement (turning, getting up).
        if let ctx = modelContext { applyMovementWake(to: session, context: ctx) }

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

        // BCG heart rate: store one sample per minute (0 = no data this minute).
        // Source gate: only accept physiologically plausible values (40–110 BPM
        // during sleep). Implausible BCG artifacts (e.g. spikes to 140) are
        // stored as 0 so they don't pollute the stored series; the display
        // filter then holds the last good value (Variante B).
        if Date().timeIntervalSince(lastBCGSampleDate) >= 60, let session = currentSession {
            let watchHR = liveHeartRateBPM
            let bcgHR = Double(liveBCGHeartRateBPM)
            let hr: Double
            if watchHR >= 40 && watchHR <= 110 {
                hr = watchHR                       // Apple Watch is authoritative
            } else if bcgHR >= 40 && bcgHR <= 110 {
                hr = bcgHR                         // plausible BCG
            } else {
                hr = 0                             // implausible / no data
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
        let deepFloor: Double   // below this in a "light/rem" phase → deep
        let remFloor:  Double   // below this in a "rem" phase → deep
        if allMeasured.count >= 10 {
            func pct(_ p: Double) -> Double { allMeasured[min(allMeasured.count - 1, Int(Double(allMeasured.count) * p))] }
            let p25 = pct(0.25), p50 = pct(0.50)
            deepCeil  = clamp(p50 + 4, 60, 70)
            deepFloor = clamp(p25,     48, 56)
            remFloor  = clamp(p25 - 3, 44, 50)
        } else {
            deepCeil = 65; deepFloor = 54; remFloor = 48   // fallback (too little data)
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
                // In the night's lowest quartile + steady → actually deep.
                if m < deepFloor { phase.phaseType = .deep; changed = true }
            case .rem:
                // Only a clearly deep-level HR (below the night's low quartile)
                // contradicts REM → deep. Conservative so normal REM survives.
                if m < remFloor { phase.phaseType = .deep; changed = true }
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
        guard hr.count >= 140 else { return 90 }          // need ≳ 2.5 h
        let mean = hr.reduce(0, +) / Double(hr.count)
        let sig = hr.map { mean - $0 }                    // high when HR low (deep)
        let denom = sig.reduce(0) { $0 + $1 * $1 }
        guard denom > 0 else { return 90 }
        var bestLag = 90, bestVal = -2.0
        for lag in 70...110 where lag < sig.count {
            var num = 0.0
            for i in 0..<(sig.count - lag) { num += sig[i] * sig[i + lag] }
            let v = num / denom
            if v > bestVal { bestVal = v; bestLag = lag }
        }
        return bestVal > 0.10 ? bestLag : 90              // require a meaningful peak
    }

    /// Aligns REM to the detected cycle: REM in the early part of a cycle is
    /// physiologically implausible (REM clusters late in each cycle). Such
    /// mis-timed REM is demoted to light. Conservative — late REM is untouched.
    private func applyCycleRemRefinement(to session: SleepSession) {
        guard let onset = session.sleepOnsetDate else { return }
        let L = Double(detectCycleLength(session))
        let onsetMin = onset.timeIntervalSince(session.startDate) / 60
        var changed = false
        for phase in session.phasesArray where phase.phaseType == .rem {
            let centerMin = (phase.startDate.timeIntervalSince(session.startDate)
                             + phase.endDate.timeIntervalSince(session.startDate)) / 120
            var pos = (centerMin - onsetMin).truncatingRemainder(dividingBy: L)
            if pos < 0 { pos += L }
            if pos < 0.35 * L { phase.phaseType = .light; changed = true }
        }
        if changed { try? modelContext?.save() }
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
        var moveByMin = [Float](repeating: 0, count: totalMin)
        for s in samples {
            let m = Int(s.timestamp.timeIntervalSince(start) / 60)
            if m >= 0 && m < totalMin { moveByMin[m] = max(moveByMin[m], s.movementIntensity) }
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
                if runLen >= 2 || moveByMin[i] > strong {
                    markAwake(in: session, fromMinute: i, toMinute: j)
                    changed = true
                }
                i = j
            } else { i += 1 }
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
