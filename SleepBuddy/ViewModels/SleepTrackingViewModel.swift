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
    /// Selbsttest-Warnung (nil = alles ok) — wird auf dem Tracking-Screen angezeigt,
    /// damit tote Subsysteme (ML, Sonar, Watch) SOFORT auffallen, nicht erst morgens.
    private(set) var systemWarning: String?

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
    let sonar = SonarService()

    // Sonar (experimentell, opt-in): letzte Features + Flag
    private var sonarEnabled = false
    private var latestSonar = SonarFeatures.neutral
    private var lastSonarUpdate = Date.distantPast

    private var modelContext: ModelContext?
    private var currentPhaseStartDate = Date()
    private var latestMotionFeatures = MotionFeatures.neutral
    // Zeitpunkt des letzten Wecker-Klingelns (für die Geräusch-Unterdrückung + Nachlauf).
    private var lastAlarmRinging = Date.distantPast

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
    /// Letzter echt gemessener HR-Wert (Watch/BCG) — Anker für den Sonar-Lücken-Füller.
    private var lastGoodHRForSonar: Double = 0
    /// Letztes Audio/Motion-Feature-Update — Selbsttest-Puls der Sensor-Pipeline.
    private var lastFeatureUpdate = Date.distantPast

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
        lastGoodHRForSonar = 0
        snoringTimestamps.removeAll()
        snoringIsObstructive = false

        beginUsageMonitoring()

        // Sonar (experimentell): wenn aktiviert, Ton+Demodulation über AudioAnalysisService.
        sonarEnabled = UserDefaults.standard.bool(forKey: "sonar_enabled")
        latestSonar = .neutral
        lastSonarUpdate = .distantPast
        if sonarEnabled {
            audioService.sonar = sonar
            sonar.onFeaturesUpdated = { [weak self] f in
                self?.latestSonar = f
                self?.lastSonarUpdate = Date()
            }
            sonar.beginNightLog()
        } else {
            audioService.sonar = nil
        }

        // Feature-Nachtlog: kompletter Sensor-Strom pro Minute (Replay-Grundlage).
        FeatureNightLog.shared.begin()
        PassAudit.reset()
        PassAudit.note("Tracking gestartet (sonar=\(sonarEnabled))")

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
            guard let self else { return }
            // Eigenen Weckerton nie als Geräusch-Event erfassen (+5 s Nachlauf für Hall/Ausklang).
            if self.smartAlarm.alarmFired { self.lastAlarmRinging = Date() }
            self.soundEventService.suppressed = Date().timeIntervalSince(self.lastAlarmRinging) < 5
            self.soundEventService.tick(
                instantAmplitude: audio.instantAmplitude,
                snoringScore: audio.snoringIntensity,
                speechLikelihood: audio.speechLikelihood
            )
            self.handleFeatures(audio: audio, motion: self.latestMotionFeatures)
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

            // Selbsttest: nach 3 min und dann alle 10 min prüfen, ob alle Subsysteme
            // leben — tote Systeme (ML-Analyzer, stummer Sonar-Ton, versiegte Sensor-
            // Pipeline) sollen SOFORT sichtbar sein, nicht erst morgens in den Logs.
            systemWarning = nil
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 180_000_000_000)
                while let self, self.isTracking {
                    self.runSelfTest()
                    try? await Task.sleep(nanoseconds: 600_000_000_000)
                }
            }
        } catch {
            errorMessage = "Mikrofon konnte nicht gestartet werden: \(error.localizedDescription)"
        }
    }

    /// Prüft die kritischen Subsysteme und setzt/löscht die Tracking-Screen-Warnung.
    private func runSelfTest() {
        var warnings: [String] = []
        if Date().timeIntervalSince(lastFeatureUpdate) > 120 {
            warnings.append("Sensor-Pipeline liefert keine Daten")
        }
        if UserDefaults.standard.bool(forKey: "soundEvents_enabled"), !soundClassifier.isAlive {
            warnings.append("Geräusch-Erkennung stumm")
        }
        if sonarEnabled, sonar.signalLevel < 0.0002 {
            warnings.append("Sonar-Ton stumm (Medienlautstärke prüfen)")
        }
        let new = warnings.isEmpty ? nil : "⚠︎ " + warnings.joined(separator: " · ")
        if new != systemWarning {
            systemWarning = new
            if let new { PassAudit.note("Selbsttest: \(new)") }
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
        sonar.endNightLog()
        FeatureNightLog.shared.end()
        audioService.sonar = nil
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

        // Nachtcheck: eine Bilanz-Zeile ins Korrektur-Protokoll — tote Subsysteme
        // stehen morgens sofort im DebugInfo, ohne die CSVs durchsuchen zu müssen.
        let mlStatus = soundClassifier.isAlive ? "aktiv" : "TOT"
        let hrCov = session.heartRateSamples.isEmpty ? 0 :
            100 * session.heartRateSamples.filter { $0 > 0 }.count / session.heartRateSamples.count
        let sonarPct = Int(sonar.nightLockRate * 100)
        PassAudit.note("Nachtcheck: ML \(mlStatus) · Sonar-Lock \(sonarPct) % · HR-Abdeckung \(hrCov) % · \(session.soundEventsArray.count) Sound-Events · Watch-HR live \(liveHeartRateBPM > 0 ? "ja" : "nein")")
        session.sleepQualityScore = Double(SchlafindexView.score(for: session))

        if let context = modelContext {
            classifier.flushSessionBuffer(to: context)
        }

        // Watch-HR nachladen (bindend): HealthKit ist bei gesperrtem Gerät nicht lesbar —
        // live kam die Watch-HR nachts daher NIE an (FeatureLog: watch_hr 0 % trotz
        // getragener Watch). Jetzt (Gerät entsperrt) die echte Serie holen und die
        // Minuten-Reihe überschreiben, wo Watch-Messungen existieren: die Watch schlägt
        // BCG/Sonar — alle nachgelagerten HR-Pässe rechnen dann mit Ground-Truth-Puls.
        let watchSeries = await healthKit.readHeartRateSeries(from: session.startDate,
                                                              to: session.endDate ?? Date())
        if watchSeries.count >= 10 {
            var filled = 0
            for (d, bpm) in watchSeries where bpm >= 35 && bpm <= 140 {
                let m = Int(d.timeIntervalSince(session.startDate) / 60)
                if m >= 0 && m < session.heartRateSamples.count {
                    session.heartRateSamples[m] = bpm
                    filled += 1
                }
            }
            PassAudit.note("Watch-HR nachgeladen: \(watchSeries.count) Messungen → \(filled) Minuten")
        }

        // Post-hoc HR-based phase correction: re-type clear mislabels using the
        // cleaned full-night heart rate (only where real measured HR dominates).
        applyHeartRatePhaseCorrection(to: session)

        // Align REM to the night's actual cycle length (data-driven, not fixed 90 min).
        applyCycleRemRefinement(to: session)

        // Breathing-based refinement (relative, whole-night): confirm deep, support REM.
        if let ctx = modelContext { applyBreathingRefinement(to: session, context: ctx) }

        // REM-Verfeinerung über Sonar-Atemregularität (Replay-validiert, +4 Pkt bei gutem Sonar).
        if let ctx = modelContext { applyRegularityRemRefinement(to: session, context: ctx) }

        // Redistribute over-allocated deep sleep (circadian: deep is concentrated early).
        applyDeepRedistribution(to: session)

        // Post-hoc edge-wake detection: elevated HR at the start/end means the
        // user was lying awake (falling asleep / morning wake) — mark as awake.
        applyEdgeWakeCorrection(to: session)

        // Atem-basiertes Rand-Wach: erhöhte Atemrate am Anfang/Ende = wachliegen
        // (funktioniert auch, wenn HR fehlt/verschmutzt und Bewegung still ist).
        if let ctx = modelContext { applyBreathingEdgeWake(to: session, context: ctx) }

        // Post-hoc mid-night wake from sustained body movement (turning, getting up).
        if let ctx = modelContext { applyMovementWake(to: session, context: ctx) }

        // Post-hoc: phone was unlocked / in use → that time was clearly awake.
        applyUsageAwake(to: session)

        // Harter Fakt: ab dem Wecker-Klingeln ist der Nutzer wach (geweckt) —
        // unabhängig davon, ob HR/Bewegung das Morgen-Wach erkannt haben.
        applyAlarmWake(to: session)

        // Post-hoc plausibility correction: remove/merge implausibly short isolated phases
        applyPlausibilityCorrection(to: session)

        // Optional (Beta-Toggle): probabilistischer Gesamtnacht-Glätter als letzter Pass.
        if let ctx = modelContext { applyHMMSmoothing(to: session, context: ctx) }

        // Onset NACH allen Pässen neu ableiten — die Pässe können die Abend-Wachphase
        // verändert haben; eine veraltete Latenz verfälscht Anzeige UND Zyklus-Pässe.
        session.sleepOnsetDate = session.phasesArray
            .sorted { $0.startDate < $1.startDate }
            .first(where: { $0.phaseType != .awake })?.startDate ?? session.sleepOnsetDate

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

    private func handleFeatures(audio: AudioFeatures, motion motionIn: MotionFeatures) {
        lastFeatureUpdate = Date()
        // Sonar (experimentell): wenn ein sauberes Reflexionssignal vorliegt, ist es die
        // bevorzugte Atem-/Bewegungsquelle (funktioniert auch vom Nachttisch). Mit vollem
        // Fallback: ohne Signal bleibt alles beim Accelerometer/Mikro.
        var motion = motionIn
        if sonarEnabled, latestSonar.signalPresent {
            let s = latestSonar
            // Qualitäts-Gate (nachtbelegt): verrauschte Sonar-Atmung (Regularität < 0.3,
            // z.B. bei übersteuertem Ton) fütterte den Klassifikator mit Pseudo-REM-
            // Signalen (unregelmäßig + schnell) → Tiefschlaf wurde nachtweit zu Leicht
            // degradiert. Lieber Accelerometer-Fallback als schlechte Sonar-Daten.
            let hasBreath = s.breathingRateBPM > 0 && s.breathingRegularity >= 0.3
            motion = MotionFeatures(
                movementIntensity: max(motionIn.movementIntensity, s.movementIntensity),
                breathingRateBPM: hasBreath ? s.breathingRateBPM : motionIn.breathingRateBPM,
                breathingRegularity: hasBreath ? s.breathingRegularity : motionIn.breathingRegularity,
                isOnMattress: hasBreath ? true : motionIn.isOnMattress,
                bcgHeartRateBPM: motionIn.bcgHeartRateBPM,
                isPLMSuspected: motionIn.isPLMSuspected,
                timestamp: motionIn.timestamp
            )
        }

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
                  now.timeIntervalSince(pendingPhaseStartDate) >= minPhaseDuration {
            guard let session = currentSession else { return }
            // Fallback onset: the dedicated onset detector can fail to fire on a
            // nightstand (it needs 10 consecutive audio-quiet windows; a single room
            // noise resets the counter). When the classifier itself has settled on a
            // stable NON-awake phase, that IS sleep onset. Without this the commit gate
            // blocked every sleep phase and the whole night was recorded as one awake
            // block ("keine Phasen erkannt"). It also gives the classifier its cycle
            // reference (classifier.sleepOnsetDate) so the 90-min model can start.
            if !isSleepOnsetDetected && result.phase != .awake {
                isSleepOnsetDetected = true
                classifier.sleepOnsetDate = pendingPhaseStartDate
            }
            finalizeCurrentPhase(endDate: now, session: session)
            currentPhaseStartDate = now
            currentPhase = result.phase
        }

        currentConfidence = result.confidence

        // Feature-Nachtlog (1 Zeile/min, intern gedrosselt): alle Sensorwerte + Live-Label.
        // WICHTIG: das gemergte `motion` loggen (nicht motionIn) — atem_best/reg_best
        // müssen exakt das widerspiegeln, was Klassifikator + TrainingSamples sehen,
        // sonst rechnet das Offline-Replay mit anderen Daten als der Geräte-Pass.
        FeatureNightLog.shared.append(audio: audio, motion: motion, sonar: latestSonar,
                                      sonarLevel: sonar.signalLevel,
                                      bcgHR: Int(liveBCGHeartRateBPM), watchHR: liveHeartRateBPM,
                                      phase: result.phase,
                                      confidence: result.confidence,
                                      hrvMs: classifier.currentHRVms)

        // Ambient noise: accumulate amplitude and store one dB sample per minute
        noiseAccumulator.append(audio.averageAmplitude)
        if Date().timeIntervalSince(lastNoiseSampleDate) >= 60, let session = currentSession {
            var avg = noiseAccumulator.reduce(0, +) / max(Float(noiseAccumulator.count), 1)
            // Sonar-Kompensation: Der 19-kHz-Ton lässt die Mikrofon-Hardware die
            // Empfindlichkeit um ~10–12 dB absenken → die dB-Kurve klebt bei ~15 dB
            // (real beobachtet, Matratze). Der ML-Pfad misst diese Dämpfung bereits
            // über den Ruheboden (adaptiveGain, Referenz ×8 ohne Sonar) — derselbe
            // Faktor hebt die dB-Skala zurück auf das Nicht-Sonar-Niveau.
            if sonarEnabled {
                avg *= max(soundClassifier.adaptiveGain / 8.0, 1.0)
            }
            let db = max(0, min(120, 20.0 * log10(max(Double(avg), 1e-6)) + 90.0))
            session.noiseSamples.append(db)
            noiseAccumulator.removeAll()
            lastNoiseSampleDate = Date()
            // Tracking-Heartbeat: zeigt morgens, WANN iOS die App ggf. beendet hat.
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "tracking.heartbeat")
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
            // Sonar-HR (experimentell) als DRITTE Quelle + BCG-Plausibilitätsstütze.
            // Nur frische Werte (< 90 s) und nur im Schlaf-Plausibilitätsband.
            let sonarFresh = sonarEnabled && Date().timeIntervalSince(lastSonarUpdate) < 90
            let sonarHR = sonarFresh ? Double(latestSonar.heartRateBPM) : 0
            let sonarValid = sonarHR >= 40 && sonarHR <= 110
            let hr: Double
            if watchHR >= 40 && watchHR <= 110 {
                hr = watchHR                       // Apple Watch is authoritative
            } else if bcgHR >= 40 && bcgHR <= 110 {
                // BCG primär. Sonar stützt: Zeigt das (unabhängige) Sonar denselben
                // Puls in etwa halber BCG-Höhe, ist der BCG-Wert ein Oberwellen-Sprung
                // (harmonischer Lock) → Sonar-Wert nehmen. Bei grober Übereinstimmung
                // oder ohne Sonar-Lock bleibt BCG unangetastet.
                if sonarValid && bcgHR > sonarHR * 1.7 && bcgHR < sonarHR * 2.3 {
                    hr = sonarHR
                } else {
                    hr = bcgHR
                }
            } else if sonarValid, lastGoodHRForSonar > 0, abs(sonarHR - lastGoodHRForSonar) <= 15 {
                // Sonar füllt Lücken NUR, wenn es an den letzten echt gemessenen Wert
                // (Watch/BCG) anschließt. Nie frei laufen lassen: Der rohe Sonar-Puls
                // kann stabil auf einer Artefakt-Familie locken (real beobachtet,
                // Nachttisch: 93/96/100/103 in 94 % der Fenster, ganze Nacht) — das
                // Stabilitäts-Gate allein hält so etwas nicht auf.
                hr = sonarHR
            } else {
                hr = 0                             // implausible / stale / no data
            }
            if watchHR >= 40 && watchHR <= 110 { lastGoodHRForSonar = watchHR }
            else if bcgHR >= 40 && bcgHR <= 110 { lastGoodHRForSonar = bcgHR }
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
            // Pass-Bilanz: existiert eine Watch-Referenz für diese Nacht, wird die
            // Übereinstimmung NACH JEDEM Pass gemessen — zeigt sofort, welcher Pass
            // trägt und welcher schadet (statt nur das Endergebnis zu sehen).
            let watchRef = loadGoldenWatchRef(for: session)
            var bilanz: [String] = []
            func snap(_ label: String) {
                if let ref = watchRef, let pct = stageAgreementPct(session, ref: ref) {
                    let wMin = Int(session.awakeDuration / 60)
                    bilanz.append("\(label) \(pct)%/\(wMin)W")
                }
            }
            cleanHeartRateFlatlines(session)
            guard rebuildPhasesFromSamples(session, context: context) else { continue }
            snap("Rebuild")
            applyHeartRatePhaseCorrection(to: session); snap("HR")
            applyCycleRemRefinement(to: session); snap("ZyklusREM")
            applyBreathingRefinement(to: session, context: context); snap("Atem")
            applyRegularityRemRefinement(to: session, context: context); snap("RegREM")
            applyDeepRedistribution(to: session); snap("DeepRedist")
            applyEdgeWakeCorrection(to: session); snap("EdgeWake")
            applyBreathingEdgeWake(to: session, context: context); snap("AtemWake")
            applyMovementWake(to: session, context: context); snap("BewegWake")
            applyPersistedUsageAwake(to: session)
            applyAlarmWake(to: session)
            applyPlausibilityCorrection(to: session); snap("Final")
            applyHMMSmoothing(to: session, context: context)
            session.sleepOnsetDate = session.phasesArray
                .sorted { $0.startDate < $1.startDate }
                .first(where: { $0.phaseType != .awake })?.startDate ?? session.sleepOnsetDate
            if !bilanz.isEmpty {
                PassAudit.note("Pass-Bilanz \(session.startDate.formatted(date: .abbreviated, time: .omitted)): " + bilanz.joined(separator: " → "))
            }
            count += 1
        }
        try? context.save()
        return count
    }

    /// Lädt die datierte Watch-Referenz dieser Nacht (vom Watch-Vergleich gespeichert).
    private func loadGoldenWatchRef(for session: SleepSession) -> [Int: SleepPhaseType]? {
        let url = FeatureNightLog.logDirectory
            .appendingPathComponent("WatchRef-\(Int(session.startDate.timeIntervalSince1970)).csv")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var ref: [Int: SleepPhaseType] = [:]
        for line in content.split(separator: "\n") where !line.hasPrefix("#") && !line.hasPrefix("minute") {
            let c = line.split(separator: ",", omittingEmptySubsequences: false)
            guard c.count >= 2, let m = Int(c[0]), let ph = SleepPhaseType(rawValue: String(c[1])) else { continue }
            ref[m] = ph
        }
        return ref.isEmpty ? nil : ref
    }

    /// Phasen-Übereinstimmung (in %) der aktuellen Session-Phasen gegen eine Watch-Referenz.
    private func stageAgreementPct(_ session: SleepSession, ref: [Int: SleepPhaseType]) -> Int? {
        let phases = session.phasesArray.sorted { $0.startDate < $1.startDate }
        guard !phases.isEmpty else { return nil }
        var agree = 0, total = 0
        for (m, w) in ref {
            let t = session.startDate.addingTimeInterval(Double(m) * 60 + 30)
            guard let o = phases.first(where: { $0.startDate <= t && t < $0.endDate })?.phaseType else { continue }
            total += 1
            if o == w { agree += 1 }
        }
        return total > 0 ? 100 * agree / total : nil
    }

    // MARK: - HMM-Glätter (Beta, Toggle "hmm_enabled" in Entwickleroptionen)
    //
    // Probabilistisches Gesamtnacht-Modell statt Regel-Kette: pro Minute liefern die
    // Sensoren Log-Likelihoods für [Wach, Leicht, Tief, REM] (relative, boden-adaptive
    // Maße + das bisherige Phasen-Ergebnis als weicher Prior), die Schlafphysiologie
    // steckt in der Übergangsmatrix (Verweildauer, plausible Wechsel). Viterbi liefert
    // den wahrscheinlichsten Phasenpfad der GANZEN Nacht in einem Schritt.
    // Läuft als LETZTER Pass — mit Toggle aus = exakt bisheriges Verhalten (A/B-Test).
    private func applyHMMSmoothing(to session: SleepSession, context: ModelContext) {
        guard UserDefaults.standard.bool(forKey: "hmm_enabled") else { return }
        let start = session.startDate
        let end = session.endDate ?? Date()
        let totalMin = Int(end.timeIntervalSince(start) / 60)
        guard totalMin >= 60 else { return }
        let desc = FetchDescriptor<TrainingSample>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp <= end },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        guard let samples = try? context.fetch(desc), samples.count >= 30 else { return }

        // Pro-Minute-Features (forward-filled)
        var brS = [Float](repeating: 0, count: totalMin), brC = [Int](repeating: 0, count: totalMin)
        var rgS = [Float](repeating: 0, count: totalMin)
        var mvMax = [Float](repeating: 0, count: totalMin)
        var ampS = [Float](repeating: 0, count: totalMin)
        for s in samples {
            let m = Int(s.timestamp.timeIntervalSince(start) / 60)
            guard m >= 0 && m < totalMin else { continue }
            if s.breathingRateBPM > 6 && s.breathingRateBPM < 30 {
                brS[m] += s.breathingRateBPM; rgS[m] += s.breathingRegularity; brC[m] += 1
            }
            mvMax[m] = max(mvMax[m], s.movementIntensity)
            ampS[m] += s.averageAmplitude
        }
        func med(_ a: [Float]) -> Float { let s = a.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
        let brVals = (0..<totalMin).compactMap { brC[$0] > 0 ? brS[$0] / Float(brC[$0]) : nil }
        let brMed = med(brVals)
        let mvMed = max(med(mvMax.filter { $0 > 0 }), 0.02)
        let ampMed = max(med(ampS.filter { $0 > 0 }), 1e-5)

        // Bisheriges Ergebnis als weicher Prior (Zyklus-Wissen bleibt erhalten)
        let phases = session.phasesArray.sorted { $0.startDate < $1.startDate }
        func priorPhase(_ m: Int) -> SleepPhaseType? {
            let t = start.addingTimeInterval(Double(m) * 60 + 30)
            return phases.first(where: { $0.startDate <= t && t < $0.endDate })?.phaseType
        }

        // Zustände: 0=wach 1=leicht 2=tief 3=rem
        let states: [SleepPhaseType] = [.awake, .light, .deep, .rem]
        func emission(_ m: Int) -> [Double] {
            var ll = [0.0, 0.0, 0.0, 0.0]
            let br = brC[m] > 0 ? brS[m] / Float(brC[m]) : 0
            let rg = brC[m] > 0 ? rgS[m] / Float(brC[m]) : 0
            let mv = mvMax[m] / mvMed          // 1 = typisch, >2.5 = unruhig
            let am = (ampS[m]) / ampMed
            // Bewegung: stärkstes Wach-Signal
            if mv > 2.5 { ll[0] += 2.0; ll[1] -= 0.5; ll[2] -= 2.0; ll[3] -= 1.0 }
            else if mv > 1.6 { ll[0] += 0.8; ll[2] -= 0.8 }
            else { ll[2] += 0.3 }
            // Lautstärke deutlich über Boden → eher wach
            if am > 2.0 { ll[0] += 0.6; ll[2] -= 0.4 }
            // Atmung (nur gemessene Minuten): schnell → wach/REM, langsam+regelmäßig → tief
            if br > 0, brMed > 0 {
                let rel = br - brMed
                if rel >= 3 { ll[0] += 1.0; ll[3] += 0.4; ll[2] -= 1.2 }
                else if rel <= -1.5 && rg > 0.5 { ll[2] += 1.2; ll[0] -= 0.6 }
                if rg < 0.35 && rel > 0 { ll[3] += 0.5 }
                if rg > 0.6 { ll[3] -= 0.4 }
            }
            // Weicher Prior aus dem bisherigen Ergebnis (Gewicht bewusst moderat)
            if let p = priorPhase(m), let idx = states.firstIndex(of: p) { ll[idx] += 0.9 }
            return ll
        }
        // Übergänge (log): hohe Verweildauer, nur physiologische Wechsel günstig
        let stay = log(0.90), toNb = log(0.045)
        let trans: [[Double]] = [
            // von wach      leicht        tief          rem
            [stay,          log(0.09),    log(0.005),   log(0.005)],   // wach →
            [log(0.03),     stay,         log(0.035),   log(0.035)],   // leicht →
            [log(0.005),    log(0.09),    stay,         log(0.005)],   // tief →
            [log(0.01),     log(0.085),   log(0.005),   stay]          // rem →
        ]
        _ = toNb

        // Viterbi
        var vit = [[Double]](repeating: [Double](repeating: -1e12, count: 4), count: totalMin)
        var back = [[Int]](repeating: [Int](repeating: 0, count: 4), count: totalMin)
        let e0 = emission(0)
        for s in 0..<4 { vit[0][s] = e0[s] + (s == 0 ? log(0.7) : log(0.1)) }  // Nacht beginnt meist wach
        for m in 1..<totalMin {
            let em = emission(m)
            for s in 0..<4 {
                var best = -1e12; var bi = 0
                for p in 0..<4 {
                    let v = vit[m-1][p] + trans[p][s]
                    if v > best { best = v; bi = p }
                }
                vit[m][s] = best + em[s]
                back[m][s] = bi
            }
        }
        var path = [Int](repeating: 0, count: totalMin)
        path[totalMin-1] = (0..<4).max(by: { vit[totalMin-1][$0] < vit[totalMin-1][$1] })!
        for m in stride(from: totalMin - 2, through: 0, by: -1) { path[m] = back[m+1][path[m+1]] }

        // Pfad → Phasen (bestehende ersetzen)
        for p in session.phasesArray { context.delete(p) }
        session.phases = []
        var gStart = 0
        for m in 1...totalMin {
            if m == totalMin || path[m] != path[gStart] {
                let ps = start.addingTimeInterval(Double(gStart) * 60)
                let pe = (m == totalMin) ? end : start.addingTimeInterval(Double(m) * 60)
                if pe > ps {
                    let phase = SleepPhase(startDate: ps, endDate: pe, phaseType: states[path[gStart]], confidence: 0.75)
                    phase.session = session
                    context.insert(phase)
                    session.phases?.append(phase)
                }
                gStart = m
            }
        }
        try? context.save()
    }

    /// Atem-basiertes Rand-Wach (so machen es Sleep Cycle & Co.): Wachliegen hat eine
    /// klare Atem-Signatur — schneller als der Schlaf-Median der Nacht (real belegt:
    /// 23-Uhr-Stunde 20/min vs. Nacht-Median 15/min). Ruhiges Wachliegen ist für
    /// Bewegung/Audio unsichtbar, für die Atemrate nicht. Konservativ: nur die RÄNDER
    /// (erste 75 / letzte 45 min), nur bei genug Messabdeckung, nur ≥ +3 BPM über dem
    /// Kern-Median. Erweitert Wach nur (markAwake), löscht nie Schlaf in der Nachtmitte.
    private func applyBreathingEdgeWake(to session: SleepSession, context: ModelContext) {
        let start = session.startDate
        let end = session.endDate ?? Date()
        let desc = FetchDescriptor<TrainingSample>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp <= end },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        guard let samples = try? context.fetch(desc), samples.count >= 60 else { return }
        let totalMin = max(1, Int(end.timeIntervalSince(start) / 60))
        guard totalMin >= 120 else { return }

        // Pro-Minute-Atemrate (nur plausible Messwerte 6–30 BPM).
        var sum = [Float](repeating: 0, count: totalMin)
        var cnt = [Int](repeating: 0, count: totalMin)
        for s in samples where s.breathingRateBPM > 6 && s.breathingRateBPM < 30 {
            let m = Int(s.timestamp.timeIntervalSince(start) / 60)
            if m >= 0 && m < totalMin { sum[m] += s.breathingRateBPM; cnt[m] += 1 }
        }
        func br(_ m: Int) -> Float { cnt[m] > 0 ? sum[m] / Float(cnt[m]) : 0 }

        // Schlaf-Kern-Median (Ränder ausgeschlossen) als persönliche Nacht-Baseline.
        let coreLo = min(75, totalMin / 3), coreHi = max(coreLo + 1, totalMin - 45)
        let core = (coreLo..<coreHi).compactMap { cnt[$0] > 0 ? br($0) : nil }
        guard core.count >= 45 else { return }   // genug Abdeckung im Kern nötig
        // Qualitäts-Gate (nachtbelegt): bei dünner Abdeckung (< 50 % der Kern-Minuten
        // gemessen) ist die Reihe rausch-selektiert und der Median verzerrt — eine
        // Nacht mit nur 27 % Atem-Lock erzeugte daraus 70 min falsches Abend-Wach.
        // Dann lieber GAR NICHT eingreifen.
        guard Double(core.count) >= 0.5 * Double(coreHi - coreLo) else {
            PassAudit.note("BreathingEdgeWake: übersprungen (Kern-Abdeckung \(core.count)/\(coreHi - coreLo) Minuten)")
            return
        }
        let med = core.sorted()[core.count / 2]
        guard med > 8 && med < 22 else { return }
        // Schwelle relativ UND absolut über dem Median — bei niedrigem Median (11/min)
        // lag med+3 sonst mitten im Rauschband der Minuten-Snapshots.
        let thresh = max(med + 3, med * 1.35)

        // Abend (Watch-kalibriert, bindend): 10-min-BLOCK-MEDIANE statt einzelner
        // Minuten — Einzelspitzen (9,9,27,9…) sind Messrauschen, kein Wachliegen.
        // Wach nur als ZUSAMMENHÄNGENDER Block ab Tracking-Start: der erste Block,
        // dessen Median unter der Schwelle liegt, beendet das Abend-Wach. (Die alte
        // "letzte schnelle Minute in 75 min"-Regel zog Wach bis Min 74, während die
        // Watch ab Min 16 Schlaf und ab Min 47 TIEFSCHLAF zeigte — und verschob damit
        // das gesamte Zyklusmodell um ~1 h.)
        let evEnd = min(80, totalMin)
        var wakeEnd = 0
        var b = 0
        while b + 10 <= evEnd {
            let block = (b..<(b + 10)).compactMap { cnt[$0] > 0 ? br($0) : nil }
            guard block.count >= 5 else { break }             // zu wenig Messung → stopp
            let bMed = block.sorted()[block.count / 2]
            if bMed >= thresh { wakeEnd = b + 10; b += 10 } else { break }
        }
        if wakeEnd > 0 {
            markAwake(in: session, fromMinute: 0, toMinute: wakeEnd)
            PassAudit.note("BreathingEdgeWake: Abend-Wach 0–\(wakeEnd) min (Block-Median, Nacht-Median \(Int(med))/min)")
        } else {
            PassAudit.note("BreathingEdgeWake: kein Abend-Wach (erster 10-min-Block unter Schwelle)")
        }
        // Morgen: NUR ein zusammenhängender schneller Block, der bis zum Tracking-Ende
        // reicht (wer morgens wach ist, schläft nicht wieder ein). Die frühere Regel
        // „erste schnelle Minute im letzten Fenster" las REM-Atmung als Wach (REM atmet
        // ebenfalls schnell/unregelmäßig — real beobachtet: 50 min Falsch-Wach ab der
        // 5-Uhr-REM-Phase). Rückwärts vom Ende scannen; die erste klar LANGSAME
        // gemessene Minute beendet den Block. Mindestens 5 gemessene schnelle Minuten.
        let moStart = max(0, totalMin - 45)
        var m = totalMin - 1
        var fastCnt = 0
        var wakeStart = totalMin
        while m >= moStart {
            if cnt[m] > 0 {
                if br(m) >= thresh { fastCnt += 1; wakeStart = m }
                else { break }
            }
            m -= 1
        }
        if fastCnt >= 5 && wakeStart < totalMin {
            markAwake(in: session, fromMinute: wakeStart, toMinute: totalMin)
            PassAudit.note("BreathingEdgeWake: Morgen-Wach ab Minute \(wakeStart)")
        }
        try? context.save()
    }

    /// REM-Verfeinerung über die ATEM-REGULARITÄT (Replay-validiert gegen 2 Watch-Nächte):
    /// Die Sonar-Regularität trennt REM klar von Leichtschlaf (REM ~0.39 vs. Leicht ~0.60),
    /// während Atemrate/Bewegung REM nicht sehen. Personalisierte Perzentil-Schwellen
    /// (p35/p65 der Nacht); nur ZUSAMMENHÄNGENDE Blöcke ≥ 8 min:
    /// (a) Leicht-Block mit anhaltend NIEDRIGER Regularität (+ Puls ≥ Nacht-Median) → REM
    /// (b) REM-Block mit anhaltend HOHER Regularität → Leicht
    /// Guard: braucht echte Streuung (p65−p35 ≥ 0.08) — Audio-Regularität klebt bei 1.0
    /// und deaktiviert die Regel automatisch (Replay: gute Sonar-Nacht +4 Punkte
    /// Phasen-Übereinstimmung, schwache Nacht exakt neutral).
    private func applyRegularityRemRefinement(to session: SleepSession, context: ModelContext) {
        let start = session.startDate
        let end = session.endDate ?? Date()
        let totalMin = Int(end.timeIntervalSince(start) / 60)
        guard totalMin >= 120 else { return }
        let desc = FetchDescriptor<TrainingSample>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp <= end },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        guard let samples = try? context.fetch(desc), samples.count >= 60 else { return }

        var regSum = [Float](repeating: 0, count: totalMin)
        var regCnt = [Int](repeating: 0, count: totalMin)
        // reg >= 0.95 ist die Audio-Fallback-Signatur (1/(1+var*1000) sättigt in stiller
        // Umgebung auf 1.0) — als "nicht gemessen" behandeln, sonst verschieben die
        // gepinnten 1.0-Minuten p65 auf 1.0 und REM wird flächig falsch demotiert
        // (real beobachtet: 50 % -> 42 % Phasen-Übereinstimmung nach Neuberechnen).
        for smp in samples where smp.breathingRateBPM > 6 && smp.breathingRateBPM < 30 && smp.breathingRegularity > 0 && smp.breathingRegularity < 0.95 {
            let m = Int(smp.timestamp.timeIntervalSince(start) / 60)
            if m >= 0 && m < totalMin { regSum[m] += smp.breathingRegularity; regCnt[m] += 1 }
        }
        func reg(_ m: Int) -> Float { regCnt[m] > 0 ? regSum[m] / Float(regCnt[m]) : 0 }
        let valid = (0..<totalMin).compactMap { regCnt[$0] > 0 ? reg($0) : nil }.sorted()
        guard valid.count >= 60 else { return }
        let p35 = valid[Int(Double(valid.count) * 0.35)]
        let p65 = valid[Int(Double(valid.count) * 0.65)]
        guard p65 - p35 >= 0.08 else { return }   // keine Streuung (Audio-Reg) → inaktiv

        let hrs = session.heartRateSamples.filter { $0 >= 40 && $0 <= 110 }.sorted()
        let hrMed = hrs.count >= 30 ? hrs[hrs.count / 2] : nil
        func hrAt(_ m: Int) -> Double { m < session.heartRateSamples.count ? session.heartRateSamples[m] : 0 }

        let phases = session.phasesArray.sorted { $0.startDate < $1.startDate }
        func phaseAt(_ m: Int) -> SleepPhaseType? {
            let t = start.addingTimeInterval(Double(m) * 60 + 30)
            return phases.first(where: { $0.startDate <= t && t < $0.endDate })?.phaseType
        }
        // Kandidaten-Masken
        var toREM = [Bool](repeating: false, count: totalMin)
        var toLight = [Bool](repeating: false, count: totalMin)
        for m in 0..<totalMin {
            guard regCnt[m] > 0 else { continue }
            let p = phaseAt(m)
            if p == .light, reg(m) <= p35,
               hrMed == nil || hrAt(m) == 0 || hrAt(m) >= hrMed! {
                toREM[m] = true
            } else if p == .rem, reg(m) >= p65 {
                toLight[m] = true
            }
        }
        // Nur zusammenhängende Blöcke ≥ 8 min umtypen (via markiere + Phasen-Splitting
        // wäre schwer — stattdessen bestehende Phasen minutenweise neu gruppieren wie
        // in rebuild: hier konservativ ganze Kandidaten-Blöcke über markAwake-ähnliche
        // Phase-Retypisierung: wir nutzen die vorhandene Phasenliste und retypen nur
        // Phasen, deren Minuten mehrheitlich im Block liegen).
        func apply(_ mask: [Bool], to newType: SleepPhaseType, from oldType: SleepPhaseType) -> Int {
            var changed = 0
            var i = 0
            while i < totalMin {
                if mask[i] {
                    var j = i
                    while j < totalMin && mask[j] { j += 1 }
                    if j - i >= 8 {
                        let bs = start.addingTimeInterval(Double(i) * 60)
                        let be = start.addingTimeInterval(Double(j) * 60)
                        for ph in phases where ph.phaseType == oldType {
                            let os = max(ph.startDate, bs), oe = min(ph.endDate, be)
                            let overlap = oe.timeIntervalSince(os)
                            if overlap > 0, overlap >= ph.endDate.timeIntervalSince(ph.startDate) * 0.6 {
                                ph.phaseType = newType
                                changed += 1
                            }
                        }
                    }
                    i = j
                } else { i += 1 }
            }
            return changed
        }
        let promoted = apply(toREM, to: .rem, from: .light)
        let demoted = apply(toLight, to: .light, from: .rem)
        if promoted + demoted > 0 {
            PassAudit.note("RegularityREM: \(promoted) Phasen Leicht→REM, \(demoted) REM→Leicht (p35=\(String(format: "%.2f", p35)), p65=\(String(format: "%.2f", p65)))")
            try? context.save()
        }
    }

    /// Ab dem Wecker-Klingeln ist der Nutzer wach — deterministisch, kein Sensor nötig.
    /// (Real beobachtet: Wecker 6:11, aber das Hypnogramm endete mit Tiefschlaf, weil
    /// weder HR noch Bewegung das Morgen-Wach belegten.)
    private func applyAlarmWake(to session: SleepSession) {
        guard let fired = session.alarmFiredDate else { return }
        let end = session.endDate ?? Date()
        guard end > fired else { return }
        let totalMin = max(1, Int(end.timeIntervalSince(session.startDate) / 60))
        let fromMin = max(0, Int(fired.timeIntervalSince(session.startDate) / 60))
        guard fromMin < totalMin else { return }
        markAwake(in: session, fromMinute: fromMin, toMinute: totalMin)
        PassAudit.note("AlarmWake: Wach ab Wecker (Minute \(fromMin)–\(totalMin))")
    }

    /// Removes physiologically impossible FLATLINES from the stored heart-rate
    /// series: a real pulse varies minute to minute, but two artifact sources
    /// wrote hour-long constant values — the early stale-BCG bug (exactly 70) and
    /// the sonar filter artifact (~96 via the fusion gap-filler). Runs of >= 15
    /// consecutive minutes within a +-2 BPM band are set to 0 (= no measurement);
    /// the display filter then bridges them honestly as "geschätzt".
    private func cleanHeartRateFlatlines(_ session: SleepSession) {
        var hr = session.heartRateSamples
        guard hr.count >= 15 else { return }
        var changed = false
        var i = 0
        while i < hr.count {
            guard hr[i] > 0 else { i += 1; continue }
            var j = i
            var lo = hr[i], hi = hr[i]
            var distinct = Set<Int>()
            while j < hr.count, hr[j] > 0 {
                let nlo = min(lo, hr[j]), nhi = max(hi, hr[j])
                // Band ±8: das Sonar-Artefakt pendelt zwischen 93/96/100 (benachbarte
                // Lag-Quantisierungsstufen, Spannweite 7) — mit dem früheren ±2-Band
                // brach der Lauf ständig ab und die Bereinigung fand NIE 15 Minuten.
                if nhi - nlo > 8 { break }
                lo = nlo; hi = nhi
                distinct.insert(Int(hr[j].rounded()))
                j += 1
            }
            // Artefakt-Signatur: langer Lauf aus höchstens 3 diskreten Werten.
            // Echter Puls streut in 15+ Minuten über deutlich mehr Stufen; ein
            // fälschlich entfernter, wirklich stabiler Abschnitt würde vom
            // Anzeige-Filter ohnehin auf gleichem Niveau „geschätzt" überbrückt.
            if j - i >= 15 && distinct.count <= 3 {
                for k in i..<j { hr[k] = 0 }
                changed = true
                PassAudit.note("HR-Flatline entfernt: Minute \(i)–\(j)")
            }
            i = max(j, i + 1)
        }
        // Quantisierungs-Artefakt (Sonar-Lag-Familie, nachtbelegt): 93/96/100/103,
        // von Null-Minuten durchsetzt — zusammenhängende Läufe erreichen nie 15 min,
        // deshalb ein zweiter Pass über die GEMESSENEN Werte (Nullen überspringen):
        // ≥ 15 Messwerte, Spannweite ≤ 12 BPM, ≤ 5 diskrete Stufen → Artefakt.
        // Echter Puls streut über 15+ Messungen kontinuierlich auf mehr Stufen.
        let idxVals = hr.enumerated().filter { $0.element > 0 }
        var a = 0
        while a < idxVals.count {
            var b = a
            var lo = idxVals[a].element, hi = idxVals[a].element
            var steps = Set<Int>()
            while b < idxVals.count {
                let v = idxVals[b].element
                if max(hi, v) - min(lo, v) > 12 { break }
                lo = min(lo, v); hi = max(hi, v)
                steps.insert(Int(v.rounded()))
                b += 1
            }
            // NUR im Hochpuls-Band (≥ 85): die Artefakt-Familie liegt bei 93–103.
            // Echter stabiler Schlafpuls (54–63 über sparse Watch-Messungen) erfüllt
            // die Stufen-Signatur ebenfalls — der wurde real fälschlich gelöscht.
            if b - a >= 15 && steps.count <= 5 && lo >= 85 {
                for k in a..<b { hr[idxVals[k].offset] = 0 }
                changed = true
                PassAudit.note("HR-Quantisierungs-Artefakt entfernt: \(b - a) Messwerte (\(Int(lo))–\(Int(hi)) BPM)")
            }
            a = max(b, a + 1)
        }
        if changed {
            session.heartRateSamples = hr
            try? modelContext?.save()
        }
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

        // 1b. Fallback cycle overlay for STRUCTURELESS nights (onset bug):
        // If the raw live labels have essentially no deep/REM (the signature of a
        // night that ran without a sleep-onset reference, so the 90-min cycle model
        // never engaged), reconstruct an onset from the movement data and overlay the
        // cycle architecture retroactively — exactly what would have happened live.
        // Real wake minutes (from movement/noise) are preserved; only the flat
        // light/quiet stretch is given deep/REM structure. Normal nights (which have
        // real deep/REM in their labels) are left completely untouched.
        let sleepMin = minuteLabel.reduce(0) { $0 + (($1 == .awake || $1 == nil) ? 0 : 1) }
        let deepRemMin = minuteLabel.reduce(0) { $0 + (($1 == .deep || $1 == .rem) ? 1 : 0) }
        // Strukturlos = (a) Schlafminuten ohne Tief/REM (Onset-Bug) ODER (b) praktisch
        // die GANZE Nacht als „wach" gelabelt (lauter Raum / heißes Mikrofon → die alte
        // fixe Amplitude-Schwelle feuerte durchgehend; real beobachtet: Nachttisch-Gerät
        // mit 60–67-dB-Boden, 100 % Wach, Neuberechnung half nicht).
        let allAwake = sleepMin < 20 && totalMin >= 60
        if allAwake || (sleepMin >= 20 && Double(deepRemMin) / Double(max(1, sleepMin)) < 0.05) {
            // Per-minute mean movement + amplitude + MAX movement (forward-filled).
            var moveSum = [Float](repeating: 0, count: totalMin)
            var moveMax = [Float](repeating: 0, count: totalMin)
            var ampSum = [Float](repeating: 0, count: totalMin)
            var cnt = [Int](repeating: 0, count: totalMin)
            for s in samples {
                let m = Int(s.timestamp.timeIntervalSince(start) / 60)
                if m >= 0 && m < totalMin {
                    moveSum[m] += s.movementIntensity
                    moveMax[m] = max(moveMax[m], s.movementIntensity)
                    ampSum[m] += s.averageAmplitude
                    cnt[m] += 1
                }
            }
            var minuteMove = [Float](repeating: 0, count: totalMin)
            var minuteMoveMax = [Float](repeating: 0, count: totalMin)
            var minuteAmp = [Float](repeating: 0, count: totalMin)
            var lastMove: Float = 0, lastMoveMax: Float = 0, lastAmp: Float = 0
            for m in 0..<totalMin {
                if cnt[m] > 0 {
                    lastMove = moveSum[m] / Float(cnt[m])
                    lastMoveMax = moveMax[m]
                    lastAmp = ampSum[m] / Float(cnt[m])
                }
                minuteMove[m] = lastMove
                minuteMoveMax[m] = lastMoveMax
                minuteAmp[m] = lastAmp
            }
            // Boden-relative Ruhe-Schwelle für die Amplitude (Median × 1.5) — die
            // absolute Skala ist geräteabhängig und hier unbrauchbar.
            let ampSorted = minuteAmp.sorted()
            let ampQuiet = ampSorted[ampSorted.count / 2] * 1.5
            // Relative Unruhe-Schwelle auf der MAX-Bewegung — dieselbe Logik wie
            // applyMovementWake (Median × 2.5). Die Minuten-DURCHSCHNITTS-Bewegung
            // verwässert kurze Handling-/Umdreh-Spitzen und übersieht Unruhe, die
            // applyMovementWake später als Wach markiert → der Onset-Check muss auf
            // derselben Skala rechnen, sonst hält er unruhige Minuten für Schlaf.
            let moveMaxSorted = minuteMoveMax.sorted()
            let elevatedRel = max(moveMaxSorted[moveMaxSorted.count / 2] * 2.5, 0.12)

            // „Schlaf-kompatible" Minute: bei (a) das Live-Label, bei (b) sind die Labels
            // wertlos → rein sensorisch (ruhig, nicht klar lauter als der Boden, und
            // ohne Unruhe-Spitze auf der Max-Skala).
            let quiet: Float = 0.30
            func canSleep(_ m: Int) -> Bool {
                if allAwake {
                    return minuteMove[m] < quiet && minuteAmp[m] <= ampQuiet
                        && minuteMoveMax[m] <= elevatedRel
                }
                return minuteLabel[m] != .awake
            }

            // Onset = Beginn des ersten ruhigen Blocks (≥ 5 min mit Label-Stütze,
            // ≥ 10 min im rein sensorischen All-Awake-Fall — konservativer).
            // NACHHALTIGKEIT (nutzerbelegt): Eine kurze ruhige Insel beim Wachliegen
            // (real: 1m Wach → 15m „Schlaf" → 22m Wach → Tief) darf den Onset NICHT
            // setzen — sie gehört noch zur Abend-Wachphase. Ein Kandidat zählt nur,
            // wenn die 45 min danach zu ≥ 70 % schlaf-kompatibel sind; sonst weitersuchen.
            let needRun = allAwake ? 10 : 5
            var onsetMin = 0, run = 0
            for m in 0..<totalMin {
                if canSleep(m) && minuteMove[m] < quiet {
                    run += 1
                    if run >= needRun {
                        let candidate = m - (needRun - 1)
                        let hi = min(totalMin, candidate + 45)
                        let sleepy = (candidate..<hi).filter { canSleep($0) }.count
                        if sleepy >= Int(Double(hi - candidate) * 0.7) {
                            onsetMin = candidate
                            break
                        }
                        run = 0   // ruhige Insel im Wachliegen → weiter suchen
                    }
                } else { run = 0 }
            }
            let cycleLen = Double(detectCycleLength(session))   // HR-empty → 100 min fallback
            for m in 0..<totalMin {
                if m < onsetMin { minuteLabel[m] = .awake; continue }
                if !canSleep(m) { minuteLabel[m] = .awake; continue }   // echtes Sensor-Wach behalten
                let frac = (Double(m - onsetMin).truncatingRemainder(dividingBy: cycleLen)) / cycleLen
                // Zones scaled from the 90-min model: A(light) B(deep) C(rem).
                if frac < 0.22 { minuteLabel[m] = .light }
                else if frac < 0.72 { minuteLabel[m] = .deep }
                else { minuteLabel[m] = .rem }
            }
            // Give the correction passes (RemRefinement/detectCycleLength) an onset ref.
            session.sleepOnsetDate = start.addingTimeInterval(Double(onsetMin) * 60)
        }

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

        // Personalisierte Budgets: aus den Watch-Nächten gelernte Anteile (EMA im
        // Watch-Vergleich, "cal_watchDeepPct"/"cal_watchRemPct") ersetzen ab 3
        // Watch-Nächten die Population-Defaults 22 %/25 % — geklemmt auf
        // physiologisch sinnvolle Bereiche.
        let ud = UserDefaults.standard
        var deepPct = 0.22, remPct = 0.25
        if ud.integer(forKey: "cal_watchNights") >= 3 {
            let dp = ud.double(forKey: "cal_watchDeepPct"), rp = ud.double(forKey: "cal_watchRemPct")
            if dp > 0 { deepPct = min(max(dp, 0.10), 0.28) }
            if rp > 0 { remPct = min(max(rp, 0.15), 0.30) }
        }
        let deepCap = deepPct * totalSleep
        let remCap  = remPct * totalSleep
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
            // reg >= 0.95 = Audio-Pin-Signatur (sättigt auf 1.0) → "nicht gemessen".
            // Ohne den Filter verschieben die Pins die Perzentile (regHigh → ~1.0) und
            // der Pass verfeinert mit Phantom-Schwellen (Pass-Bilanz: −7 Punkte real).
            // Identischer Fix wie in applyRegularityRemRefinement (bindend).
            guard s.breathingRateBPM > 5, s.breathingRateBPM < 35,
                  s.breathingRegularity > 0, s.breathingRegularity < 0.95 else { continue }
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
        // Baseline-Werte >= 0.9 sind aus der Pin-Ära gelernt (real: 0.9999/0.958) —
        // ignorieren, bis die EMA mit pin-freien Nächten neu gelernt hat.
        let slowRate = cal.brSlowRate.map { 0.5 * $0 + 0.5 * nSlow } ?? nSlow
        let regHigh  = (cal.brRegHigh.flatMap { $0 < 0.9 ? $0 : nil }).map { 0.5 * $0 + 0.5 * nRegHigh } ?? nRegHigh
        let regLow   = (cal.brRegLow.flatMap  { $0 < 0.9 ? $0 : nil }).map { 0.5 * $0 + 0.5 * nRegLow } ?? nRegLow

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

        // ALARM-GATE (bindend, watch-validiert): Hat der Wecker den Nutzer geweckt
        // (alarmFiredDate ≈ Session-Ende), gab es VOR dem Alarm kein Morgen-Wach —
        // er hat bis zum Klingeln geschlafen (Watch: REM bis zur letzten Minute; die
        // Rückwärts-Erweiterung zeichnete trotzdem bis zu 30 min Falsch-Wach).
        let alarmWokeUser: Bool = {
            guard let fired = session.alarmFiredDate, let end = session.endDate else { return false }
            return end.timeIntervalSince(fired) < 180
        }()
        // Wake detected if any of the last 4 measured minutes are clearly elevated,
        // or the BCG signal dropped out in the last 2 min (≈ got up / moved).
        var morningDetected = !alarmWokeUser && (sessionMaxMin - maxIdx) >= 2
        if !alarmWokeUser {
            for i in stride(from: maxIdx, through: max(0, maxIdx - 4), by: -1) {
                if let hr = hrByMin[i], hr >= awakeHR { morningDetected = true; break }
            }
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

    /// Wendet die beim Tracking-Stopp persistierten Nutzungs-Intervalle rückwirkend an
    /// (Neuberechnen-Batch) — gleiche Regeln wie applyUsageAwake (< 90 s ignoriert).
    private func applyPersistedUsageAwake(to session: SleepSession) {
        let start = session.startDate
        let end = session.endDate ?? Date()
        let flat = UserDefaults.standard.array(forKey: "usageIntervals.\(Int(start.timeIntervalSince1970))") as? [Double] ?? []
        guard flat.count >= 2 else { return }
        let totalMin = max(1, Int(end.timeIntervalSince(start) / 60))
        for i in stride(from: 0, to: flat.count - 1, by: 2) {
            let s = Date(timeIntervalSince1970: flat[i]), e = Date(timeIntervalSince1970: flat[i + 1])
            guard e.timeIntervalSince(s) >= 90 else { continue }
            let from = max(0, Int(s.timeIntervalSince(start) / 60))
            let to = min(totalMin, Int(ceil(e.timeIntervalSince(start) / 60)))
            if to > from { markAwake(in: session, fromMinute: from, toMinute: to) }
        }
    }

    /// Marks every interval the phone was unlocked / in use during the night as awake.
    /// Short glances (< 90 s) are ignored so a quick time-check isn't over-weighted.
    private func applyUsageAwake(to session: SleepSession) {
        let start = session.startDate
        let end = session.endDate ?? Date()
        let totalMin = max(1, Int(end.timeIntervalSince(start) / 60))
        // Intervalle persistieren (UserDefaults, Key = Session-Start) — sonst sind sie
        // nach der Nacht weg und weder Replay noch Neuberechnen können sie anwenden.
        let flat = usageAwakeIntervals.flatMap { [$0.start.timeIntervalSince1970, $0.end.timeIntervalSince1970] }
        UserDefaults.standard.set(flat, forKey: "usageIntervals.\(Int(start.timeIntervalSince1970))")
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
        // Minuten-MINIMUM zusätzlich: eine Minute gilt nur als "erhöht", wenn BEIDE
        // 30-s-Messungen über der Schwelle liegen (Ganz-Minuten-Bewegung). REM-Zuckungen
        // sind halbe-Minuten-Spitzen (0.5–1.0 für ein Sample, danach still) — echtes
        // Aufstehen/Wälzen ist durchgängig. Watch-validiert (2 Nächte): die alte
        // Nur-Max-Zählung erzeugte 46–48 Falsch-Wach-Minuten AUF Watch-REM-Blöcken.
        var rawMoveMin = [Float](repeating: -1, count: totalMin)
        for s in samples {
            let m = Int(s.timestamp.timeIntervalSince(start) / 60)
            if m >= 0 && m < totalMin {
                rawMove[m] = max(rawMove[m], s.movementIntensity)
                rawMoveMin[m] = rawMoveMin[m] < 0 ? s.movementIntensity : min(rawMoveMin[m], s.movementIntensity)
            }
        }
        for m in 0..<totalMin where rawMoveMin[m] < 0 { rawMoveMin[m] = 0 }

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
        // Partner mode raises the bar so the partner's mattress-transmitted (= weaker,
        // farther) movements don't get flagged as the user being awake.
        let pf = PartnerMode.motionFactor
        // REIN RELATIV (bindend): keine feste Obergrenze mehr. Der Peak-Anteil in
        // movementIntensity hebt den Grundpegel; eine Deckelung (früher 0.30) lag dann UNTER
        // dem Median → praktisch alles galt als „erhöht" → massive Falsch-Wach (39 % beobachtet).
        // Schwellen skalieren jetzt mit dem tatsächlichen Nacht-Niveau.
        // Floor 0.20 (war 0.12): 0.12 lag unter typischen REM-Twitch-Spitzen; mit dem
        // Ganz-Minuten-Kriterium + 0.20 sind beide Watch-Nächte falsch-wach-frei.
        let elevated: Float = max(baseline * 2.5, 0.20) * pf   // klar über dem Ruhe-Niveau
        let strong:   Float = max(p90 * 1.3, baseline * 4.0, 0.40) * pf   // starker Einzel-Spike
        var changed = false
        var i = 0
        while i < totalMin {
            if moveByMin[i] > elevated {
                var j = i
                while j < totalMin && moveByMin[j] > elevated { j += 1 }
                let runLen = j - i
                // Real awakening = SUSTAINED elevated movement (≥ 3 min). Crucially the
                // sustain check counts RAW minutes: the ±2-min neighbour smoothing smears
                // a single turn-over spike into a 3–5 min "elevated" run, which made the
                // smoothed run length alone always pass. A turn-over has 1–2 raw elevated
                // minutes; getting up (toilet) has several — only the latter is a wake.
                // KONSEKUTIV + GANZE MINUTEN (bindend, watch-validiert): verstreute
                // Zuckungen über einen verschmierten Lauf zählten sonst zusammen.
                var best = 0, cur = 0
                for k in i..<j {
                    cur = (rawMove[k] > elevated && rawMoveMin[k] > elevated) ? cur + 1 : 0
                    best = max(best, cur)
                }
                let rawElev = best
                if runLen >= 3 && rawElev >= 3 {
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
        // Konservativ (bindend): ein 10-min-Fenster gilt nur als unruhig, wenn die MEHRHEIT
        // der Minuten erhöht ist UND mindestens ein echter starker Spike drin ist. Sonst
        // markierte sporadisches Umdrehen ganze Stunden fälschlich als wach.
        let windowLen = 10
        let minActive = 6
        var m = 0
        while m < totalMin {
            let hi = min(totalMin, m + windowLen)
            // RAW minutes — smoothed counting let two turn-over spikes (smeared to
            // ~5 min each) fill the window and flag calm sleep as restless.
            let active = (m..<hi).filter { rawMove[$0] > elevated && rawMoveMin[$0] > elevated }.count
            let hasStrong = (m..<hi).contains { rawMove[$0] > strong }
            if active >= minActive && hasStrong {
                markAwake(in: session, fromMinute: m, toMinute: hi)
                changed = true
                m = hi
            } else {
                m += 1
            }
        }

        // Remove SPURIOUS mid-night wake: brief awake islands flanked by sleep on BOTH
        // sides that are NOT backed by sustained elevated movement (< 3 elevated minutes)
        // are turn-overs or a single noise blip — not real awakenings. The live
        // classifier commits these from a momentary movement/amplitude spike; the user
        // reported never being awake mid-night. Retype them to the surrounding sleep
        // phase, then merge. Evening/morning edge-wake (contiguous awake, or first/last
        // phase) is never touched — only islands with sleep on both sides.
        let phasesForClean = session.phasesArray.sorted { $0.startDate < $1.startDate }
        if phasesForClean.count >= 3 {
            for idx in 1..<(phasesForClean.count - 1) {
                let p = phasesForClean[idx]
                guard p.phaseType == .awake else { continue }
                let prev = phasesForClean[idx - 1], next = phasesForClean[idx + 1]
                guard prev.phaseType != .awake, next.phaseType != .awake else { continue }
                guard p.endDate.timeIntervalSince(p.startDate) < 10 * 60 else { continue }
                let sMin = max(0, Int(p.startDate.timeIntervalSince(start) / 60))
                let eMin = min(totalMin, max(sMin + 1, Int(p.endDate.timeIntervalSince(start) / 60)))
                // Count RAW elevated minutes — the smoothed curve smears one spike over
                // ±2 min and would falsely "back" the island with 3+ elevated minutes.
                let elevMin = (sMin..<eMin).filter { rawMove[$0] > elevated }.count
                if elevMin < 3 {
                    p.phaseType = prev.phaseType   // absorb into the surrounding sleep
                    changed = true
                }
            }
            if changed { _ = mergeAdjacentSamePhases(session) }
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
        // ALARM-GATE (wie EdgeWake, watch-validiert): Hat der Wecker geweckt, schlief
        // der Nutzer bis zum Klingeln — die 15-min-Pauschale zeichnete sonst genau
        // das Falsch-Wach wieder ein, das das EdgeWake-Gate entfernt hatte (+15W real).
        let alarmWoke: Bool = {
            guard let fired = session.alarmFiredDate, let e = session.endDate else { return false }
            return e.timeIntervalSince(fired) < 180
        }()
        let sorted2 = session.phasesArray.sorted { $0.startDate < $1.startDate }
        if !alarmWoke,
           session.totalDuration > 5 * 3600,
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
