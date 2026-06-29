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

        // Post-hoc edge-wake detection: elevated HR at the start/end means the
        // user was lying awake (falling asleep / morning wake) — mark as awake.
        applyEdgeWakeCorrection(to: session)

        // Post-hoc out-of-bed detection: a long mid-night run of zero BCG = nobody
        // on the mattress (e.g. a toilet trip) — mark as awake.
        applyOutOfBedWake(to: session)

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
                  // Awake commits faster (30 s) — getting up to use the toilet is a
                  // brief but strong movement that should register as a wake.
                  now.timeIntervalSince(pendingPhaseStartDate) >= (result.phase == .awake ? 30 : minPhaseDuration),
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

    /// Re-runs the post-hoc phase corrections (HR-based, edge-wake, plausibility)
    /// on already-recorded nights — used after the correction logic was improved.
    /// Returns the number of sessions processed.
    @discardableResult
    func reapplyPhaseCorrections(to sessions: [SleepSession], context: ModelContext) -> Int {
        modelContext = context
        var count = 0
        for session in sessions where !session.isActive && !session.phasesArray.isEmpty {
            applyHeartRatePhaseCorrection(to: session)
            applyEdgeWakeCorrection(to: session)
            applyOutOfBedWake(to: session)
            applyPlausibilityCorrection(to: session)
            count += 1
        }
        try? context.save()
        return count
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
                // Deep sleep has a distinctly low HR. Clearly elevated → not deep.
                // Use light (not REM) — creating REM from "deep had high HR" caused
                // implausible short REM hops; REM should come from the cycle/breathing.
                if m >= 65 { phase.phaseType = .light; changed = true }
            case .light:
                // Distinctly low + steady HR → actually deep.
                if m < 54 { phase.phaseType = .deep; changed = true }
            case .rem:
                // Very low HR contradicts REM → deep.
                if m < 54 { phase.phaseType = .deep; changed = true }
            case .awake:
                break
            }
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

        // Evening: leading run of elevated HR = sleep-onset latency.
        var eveningEnd: Int? = nil
        var gap = 0
        for i in 0...maxIdx {
            if let hr = hrByMin[i] {
                if hr >= awakeHR { eveningEnd = i; gap = 0 } else { break }
            } else { gap += 1; if gap > 3 { break } }
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

    /// Marks the minute range [startMin, endMinExclusive) as awake, splitting any
    /// phases that straddle the boundaries so short awake segments are preserved.
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

    // MARK: - Post-hoc out-of-bed (mid-night) wake detection
    // A long run of zero BCG heart rate mid-night = nobody on the mattress
    // (toilet trip). Flanked by valid HR (so not an edge), it is marked awake.
    private func applyOutOfBedWake(to session: SleepSession) {
        let raw = session.heartRateSamples
        guard raw.count > 20 else { return }
        let outOfBedMin = 8                    // ≥ 8 min absence
        func valid(_ v: Double) -> Bool { v >= 40 && v <= 110 }

        var changed = false
        var i = 0
        while i < raw.count {
            if raw[i] == 0 {
                var j = i
                while j < raw.count && raw[j] == 0 { j += 1 }
                let runLen = j - i
                // Flanked by valid HR before AND after → genuine mid-night absence.
                let hasBefore = raw[..<i].contains(where: valid)
                let hasAfter  = raw[j...].contains(where: valid)
                if runLen >= outOfBedMin && hasBefore && hasAfter {
                    markAwake(in: session, fromMinute: i, toMinute: j)
                    changed = true
                }
                i = j
            } else { i += 1 }
        }
        if changed { try? modelContext?.save() }
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
            // Never merge away .awake — a brief mid-night wake (e.g. toilet trip) is a
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
            // REM "hops": a short REM island (< 6 min) not flanked by REM is implausible.
            // REM almost never abuts deep sleep (transition goes deep→light→REM). Replace
            // with light if adjacent to deep, otherwise with the longer neighbour's type.
            if curr.phaseType == .rem && duration < 360
                && prev.phaseType != .rem && next.phaseType != .rem {
                if prev.phaseType == .deep || next.phaseType == .deep {
                    curr.phaseType = .light
                } else {
                    let prevDur = prev.endDate.timeIntervalSince(prev.startDate)
                    let nextDur = next.endDate.timeIntervalSince(next.startDate)
                    curr.phaseType = prevDur >= nextDur ? prev.phaseType : next.phaseType
                }
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
