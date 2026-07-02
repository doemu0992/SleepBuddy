import AVFoundation
import Foundation
import Observation
import Accelerate

/// Single source of truth for the Partnermodus (bindend, modulweit).
/// Zwei Stufen — 1 = Partner in normalem Abstand, 2 = Partner direkt daneben.
/// Höhere Stufe = stärkere Filterung, damit Bewegungen/Geräusche des Partners nicht als
/// die eigenen gezählt werden. Die Faktoren sind **Multiplikatoren** auf die adaptiven
/// Basis-Schwellen jedes Services — so wirkt der Modus zuverlässig für Matratze
/// (adaptive Bewegungs-/Median-Schwellen) UND Nachttisch (adaptive Audio-Kalibrierung).
enum PartnerMode {
    static var isActive: Bool { UserDefaults.standard.bool(forKey: "partnerModus_aktiv") }

    /// Nur 1 oder 2 sind gültig (geklemmt) — schützt vor Alt-Wert 0.
    static var stufe: Int {
        let s = UserDefaults.standard.integer(forKey: "partnerModus_stufe")
        return min(max(s, 1), 2)
    }

    /// Multiplikator für Bewegungs-/Wach-Schwellen (Classifier, Onset, Movement-Wake).
    static var motionFactor: Float {
        guard isActive else { return 1.0 }
        return stufe == 2 ? 1.8 : 1.4
    }

    /// Multiplikator für Audio-Amplituden-Schwellen (Sound-Events, Onset, Classifier).
    static var amplitudeFactor: Float {
        guard isActive else { return 1.0 }
        return stufe == 2 ? 2.4 : 1.6
    }
}

/// Detects sound events during sleep (snoring, talking, coughing, bruxism, other) and saves
/// 30-second audio clips to iCloud Documents on opt-in.
///
/// ShutEye-style: event detection uses the instantaneous 125 ms RMS, NOT the 30 s average.
/// Ring buffer runs always — iCloud/local saves are gated by isEnabled.
@Observable
final class SoundEventService {

    // MARK: - iCloud container

    private static let iCloudContainerID = "iCloud.DG-Software-Solution.PainDiary"
    private static let soundsFolder = "SleepSounds"

    // MARK: - Settings

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "soundEvents_enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "soundEvents_enabled") }
    }

    // MARK: - Amplitude threshold (fixed, ShutEye-style)
    //
    // Adaptive calibration: the first 60 s of tracking measure the actual ambient
    // floor of THIS room/placement/mic. The event threshold is then set just
    // above that measured ceiling — anything clearly louder counts as an event.
    // This auto-adapts to mattress vs nightstand, quiet vs noisy rooms, and the
    // device's relative (uncalibrated) dB scale.

    /// Set by the tracking VM (kept for the pre-calibration fallback only).
    var isOnMattress = false

    // Calibration state
    private let calibrationDuration: TimeInterval = 60
    private var calibrationSamples: [Float] = []
    private var calibrationDeadline: Date?
    private(set) var calibratedThreshold: Float?   // nil until first 60 s elapsed

    // Rolling re-calibration: keeps adapting the ambient floor through the night.
    private let recalInterval: TimeInterval = 120          // re-evaluate every 2 min
    private let rollingMax = 2400                          // ~5 min of non-event samples @ 8 Hz
    private var rollingAmbient: [Float] = []
    private var lastRecal = Date.distantPast
    // Ratio threshold/median measured during the 60 s calibration. Lets the rolling pass use
    // the robust MEDIAN of non-event samples (adapts up AND down) while reproducing the same
    // threshold scale. Median is robust to occasional loud bumps, so events can't ratchet it.
    private var thresholdOverMedian: Float = 4.0
    // Spam breaker: counts back-to-back FULL-LENGTH amplitude-triggered .other events
    // (the signature of a raised ambient floor, not discrete sounds). See finaliseEvent().
    private var consecutiveContinuousOther = 0

    private var amplitudeThreshold: Float {
        // Once calibrated, the measured ambient ceiling drives detection (layered with the
        // partner factor → adapts to the room AND keeps the partner's quieter sounds out).
        if let cal = calibratedThreshold {
            return cal * PartnerMode.amplitudeFactor
        }
        // Pre-calibration fallback (fixed) — used only during the first 60 s.
        let base: Float = isOnMattress ? 0.006 : 0.010
        return base * PartnerMode.amplitudeFactor
    }

    // MARK: - Circular raw-sample buffer (last 35 s at native sample rate)

    private let clipDuration: TimeInterval = 30
    private var sampleRate: Double = 44100
    private var circularBuffer: [Float] = []
    private var maxRingSize: Int { Int(sampleRate * (clipDuration + 5)) }

    // MARK: - Event detection state

    private let cooldownAfterEventSeconds: TimeInterval = 4.0
    /// Continuous sound is cut into separate events of at most this length so a
    /// long bout (e.g. dog barking) produces several meaningful 30 s clips.
    private let maxEventDuration: TimeInterval = 30.0

    private var eventStartDate: Date?
    private var pendingEventType: SoundEventType = .other
    private var pendingMLLabel: String?   // specific German name for .ambient catch-all events
    // Priority: the generic catch-all (.ambient) must NEVER block or pre-empt a real named
    // sound (e.g. snoring). Track whether the current/last event is the low-priority catch-all.
    private var currentEventIsAmbient = false
    private var lastEventWasAmbient = false
    private var consecutiveLoudTicks = 0
    private var consecutiveQuietTicks = 0

    // At 8 Hz (one tick per 125 ms):
    private let loudTicksToStart = 4   // 500 ms of continuous sound → event start
    private let quietTicksToEnd  = 8   // 1 s of silence → event end

    private var lastEventEndDate: Date?

    // MARK: - ML hint (from SoundClassificationService)

    private var mlHintType: SoundEventType?
    private var mlHintConfidence: Double = 0
    private var mlHintDate: Date?
    private let mlHintMaxAge: TimeInterval = 3.0

    /// Called by SoundClassificationService when Apple's ML fires.
    /// ShutEye-style: ML is the primary trigger for ALL sound types.
    /// The per-class thresholds in SoundClassificationService are the authoritative
    /// false-positive gate (e.g. dog 0.30, music 0.65). This method must NOT impose
    /// a higher floor on top — that previously suppressed quiet/distant external
    /// sounds (e.g. dog barking never registered). Only a tiny sanity floor remains.
    func hintMLDetection(type: SoundEventType, confidence: Double, label: String? = nil) {
        mlHintType = type
        mlHintConfidence = confidence
        mlHintDate = Date()
        guard confidence >= 0.25 else { return }

        let isAmbient = (type == .ambient)

        if eventStartDate == nil {
            // Idle. The low-priority catch-all (.ambient) may only start when fully idle.
            // A real named sound (snoring etc.) must NOT be blocked by the cooldown that
            // followed a catch-all event — otherwise ambient noise suppresses snoring.
            if isAmbient {
                guard !isInCooldown else { return }
            } else {
                guard !isInCooldown || lastEventWasAmbient else { return }
            }
            eventStartDate = Date()
            pendingEventType = type
            pendingMLLabel = label
            currentEventIsAmbient = isAmbient
            consecutiveLoudTicks = loudTicksToStart
            consecutiveQuietTicks = 0
        } else if !isAmbient && currentEventIsAmbient {
            // A real named sound arrived during a low-priority catch-all event → take it over.
            pendingEventType = type
            pendingMLLabel = nil
            currentEventIsAmbient = false
        }
    }

    // MARK: - Callback (fires on main actor)

    var onEventCaptured: ((Date, SoundEventType, TimeInterval, String?, Double, Double, String?) -> Void)?

    // MARK: - Public API

    func configure(sampleRate: Double) {
        self.sampleRate = sampleRate
        circularBuffer.removeAll()
        circularBuffer.reserveCapacity(maxRingSize)
        reset()
    }

    /// Feed raw PCM samples — always buffers for ring buffer; saves only when isEnabled.
    func appendSamples(_ samples: [Float], actualSampleRate: Double? = nil) {
        if let sr = actualSampleRate, sr != sampleRate { sampleRate = sr }
        // Ring buffer always active — saves are gated by isEnabled in finaliseEvent()
        circularBuffer.append(contentsOf: samples)
        if circularBuffer.count > maxRingSize {
            circularBuffer.removeFirst(circularBuffer.count - maxRingSize)
        }
    }

    /// Feed instantaneous 125 ms RMS amplitude + classification scores (8 Hz tick).
    /// Uses instantAmplitude (NOT the 30 s average) so single snoring bursts are detected.
    func tick(instantAmplitude: Float, snoringScore: Float, speechLikelihood: Float) {
        // ── Calibration window: first 60 s measure the ambient floor ───────────
        if calibratedThreshold == nil {
            if calibrationDeadline == nil {
                calibrationDeadline = Date().addingTimeInterval(calibrationDuration)
            }
            calibrationSamples.append(instantAmplitude)
            if let dl = calibrationDeadline, Date() >= dl {
                finishCalibration()
            }
            return  // no event detection while calibrating
        }

        // ── Rolling re-calibration: feed ALL non-event samples (not only those below the
        //    current threshold). recalibrateRolling() uses the MEDIAN, which is robust to the
        //    loud minority — so the floor can adapt UP (heating, rain, traffic) and DOWN, while
        //    sustained events (eventStartDate set) are still excluded and can't inflate it.
        if eventStartDate == nil {
            rollingAmbient.append(instantAmplitude)
            if rollingAmbient.count > rollingMax {
                rollingAmbient.removeFirst(rollingAmbient.count - rollingMax)
            }
        }
        if Date().timeIntervalSince(lastRecal) >= recalInterval {
            recalibrateRolling()
        }

        if isInCooldown { return }

        // NOTE: the spectral snoring trigger (snoringScore > 0.55) was REMOVED after
        // validation on real labeled audio (ESC-50): the 80–500 Hz band ratio is a generic
        // low-frequency-energy measure (AUC ~0.73), firing on trains, fans, traffic, fireworks
        // etc. just as strongly as on snoring — it inflated false snoring. Snoring is now
        // detected solely by Apple's purpose-trained ML `snoring` class (specific), via
        // hintMLDetection. Events otherwise start on the amplitude threshold only.
        let isLoud = instantAmplitude > amplitudeThreshold

        // Continuous sound (e.g. 2 h of dog barking) would otherwise never see a
        // 1 s gap → one endless event whose clip is just the last 30 s. Cap the
        // duration: finalise at maxEventDuration so a long sound becomes several
        // events/clips, then the cooldown spaces them out before re-triggering.
        if let start = eventStartDate, Date().timeIntervalSince(start) >= maxEventDuration {
            finaliseEvent()
            return
        }

        if isLoud {
            consecutiveQuietTicks = 0
            consecutiveLoudTicks += 1
            if eventStartDate == nil && consecutiveLoudTicks >= loudTicksToStart {
                eventStartDate = Date().addingTimeInterval(-Double(loudTicksToStart) / 8.0)
                pendingEventType = classifyEvent(snoringScore: snoringScore, speechLikelihood: speechLikelihood)
                pendingMLLabel = nil   // amplitude fallback → named/heuristic type, no catch-all label
                currentEventIsAmbient = false
            }
        } else {
            consecutiveLoudTicks = 0
            if eventStartDate != nil {
                consecutiveQuietTicks += 1
                if consecutiveQuietTicks >= quietTicksToEnd { finaliseEvent() }
            }
        }
    }

    func reset() {
        eventStartDate = nil
        consecutiveLoudTicks = 0
        consecutiveQuietTicks = 0
        lastEventEndDate = nil
        currentEventIsAmbient = false
        lastEventWasAmbient = false
        pendingMLLabel = nil
        circularBuffer.removeAll()
        mlHintType = nil
        mlHintConfidence = 0
        mlHintDate = nil
        // Restart calibration for the new session
        calibrationSamples.removeAll()
        calibrationDeadline = nil
        calibratedThreshold = nil
        thresholdOverMedian = 4.0
        rollingAmbient.removeAll()
        lastRecal = .distantPast
        consecutiveContinuousOther = 0
    }

    /// Finalises calibration: threshold = 95th-percentile ambient ceiling × margin,
    /// clamped to a sane floor so a dead-silent room still ignores mic hiss.
    private func finishCalibration() {
        defer { calibrationSamples.removeAll() }
        guard !calibrationSamples.isEmpty else { calibratedThreshold = 0.010; return }
        let sorted = calibrationSamples.sorted()
        // 95th percentile = robust "loudest normal" (ignores a single bump while
        // placing the phone), then +5 dB margin (×1.8) for a clear event.
        let idx = min(sorted.count - 1, Int(Double(sorted.count) * 0.95))
        let ceiling = sorted[idx]
        let threshold = max(ceiling * 1.8, 0.004)         // never below ≈ 42 dB
        calibratedThreshold = threshold
        // Record threshold/median ratio so rolling recal can scale off the robust median.
        let median = sorted[sorted.count / 2]
        thresholdOverMedian = median > 1e-6 ? min(max(threshold / median, 2.0), 12.0) : 4.0
        lastRecal = Date()
    }

    /// Rolling re-calibration: recompute the ambient floor from the last ~5 min of
    /// quiet samples and blend it smoothly into the current threshold (EMA) so the
    /// app adapts to changing room conditions through the night without jumping.
    private func recalibrateRolling() {
        lastRecal = Date()
        guard rollingAmbient.count >= 240 else { return }   // need ≥ ~30 s of non-event data
        let sorted = rollingAmbient.sorted()
        // MEDIAN of non-event samples = robust floor estimate (loud minority ignored), scaled
        // by the calibration-measured ratio. Adapts both up and down.
        let median = sorted[sorted.count / 2]
        let candidate = max(median * thresholdOverMedian, 0.004)
        if let cur = calibratedThreshold {
            calibratedThreshold = cur * 0.6 + candidate * 0.4   // smooth blend
        } else {
            calibratedThreshold = candidate
        }
    }

    // MARK: - Audio file URL for playback

    func audioURL(for fileName: String) -> URL? {
        iCloudDocumentsURL?
            .appendingPathComponent(Self.soundsFolder)
            .appendingPathComponent(fileName)
    }

    func localAudioURL(for fileName: String) -> URL? {
        if fileName.hasPrefix("local://") {
            let name = String(fileName.dropFirst("local://".count))
            return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent(Self.soundsFolder)
                .appendingPathComponent(name)
        }
        return audioURL(for: fileName)
    }

    // MARK: - Private helpers

    private var isInCooldown: Bool {
        guard let lastEnd = lastEventEndDate else { return false }
        return Date().timeIntervalSince(lastEnd) < cooldownAfterEventSeconds
    }

    private func minDuration(for type: SoundEventType) -> TimeInterval {
        switch type {
        case .coughing:                   return 0.5
        case .bruxism:                    return 0.8
        case .sneezing:                   return 0.3
        case .gasping:                    return 0.5
        case .laughing:                   return 0.8
        case .knock, .glassBreak:         return 0.3
        case .doorbell, .phone:           return 0.5
        case .dogBarking, .cat, .bird:    return 0.5
        case .alarm, .baby:               return 0.8
        case .thunder, .traffic, .wind:   return 1.0
        case .crowd, .water:              return 1.5
        default:                          return 2.0
        }
    }

    private func classifyEvent(snoringScore: Float, speechLikelihood: Float) -> SoundEventType {
        if let hintDate = mlHintDate,
           Date().timeIntervalSince(hintDate) < mlHintMaxAge,
           let hint = mlHintType {
            return hint
        }
        // Amplitude-triggered without fresh ML hint → a loud, ML-unidentified noise.
        // Both hand-crafted classifiers (snoringScore, speechLikelihood) are removed: they
        // are generic band-energy measures, too unspecific to assign a real type (snoring
        // ESC-50 AUC ~0.73). Classification is ML-only; such events are honestly `.other`.
        return .other
    }

    private func computeDecibelLevel(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0.0 }
        let sumSquares = samples.reduce(0.0) { $0 + Double($1 * $1) }
        let rms = sqrt(sumSquares / Double(samples.count))
        return max(0.0, min(120.0, 20.0 * log10(max(rms, 1e-6)) + 90.0))
    }

    private func finaliseEvent() {
        guard let start = eventStartDate else { return }
        let duration = Date().timeIntervalSince(start)
        lastEventEndDate = Date()
        eventStartDate = nil
        consecutiveQuietTicks = 0

        let type = pendingEventType
        guard duration >= minDuration(for: type) else { return }

        // ── Spam breaker (raised ambient floor) ────────────────────────────────
        // A chain of FULL-LENGTH amplitude-triggered .other events (30 s slice →
        // 4 s cooldown → immediate re-trigger) means the ambient FLOOR itself rose
        // above the threshold (heating, rain, traffic) — not discrete events. The
        // rolling recalibration can't catch up because during the chain almost all
        // samples fall inside events and are excluded. Real observed failure:
        // minute-by-minute "Geräusch" clips at 46 dB for many minutes. Bump the
        // threshold directly (self-correcting: repeats until the noise is below it;
        // the median-based recal brings it back down once the room quietens), and
        // stop recording the spam events after the second bump.
        let wasContinuousOther = (type == .other) && duration >= maxEventDuration - 1.0
        if wasContinuousOther {
            consecutiveContinuousOther += 1
            if consecutiveContinuousOther >= 2, let cur = calibratedThreshold {
                calibratedThreshold = cur * 1.5
            }
            if consecutiveContinuousOther >= 3 {
                mlHintType = nil; mlHintConfidence = 0; mlHintDate = nil
                pendingMLLabel = nil
                lastEventWasAmbient = currentEventIsAmbient
                currentEventIsAmbient = false
                return   // drop the event: it's floor noise, not a real occurrence
            }
        } else {
            consecutiveContinuousOther = 0
        }

        let samples = Array(circularBuffer)
        let sr = sampleRate
        let timestamp = start
        let capturedConfidence = mlHintConfidence
        let label = pendingMLLabel
        let decibelLevel = computeDecibelLevel(samples)

        mlHintType = nil
        mlHintConfidence = 0
        mlHintDate = nil
        pendingMLLabel = nil
        lastEventWasAmbient = currentEventIsAmbient
        currentEventIsAmbient = false

        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            let fileName = self.isEnabled
                ? self.saveToICloud(samples: samples, sampleRate: sr, timestamp: timestamp)
                : nil
            await MainActor.run {
                self.onEventCaptured?(timestamp, type, duration, fileName, decibelLevel, capturedConfidence, label)
            }
        }
    }

    // MARK: - iCloud save

    private var iCloudDocumentsURL: URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: Self.iCloudContainerID)?
            .appendingPathComponent("Documents")
    }

    /// Normalises a clip so its peak reaches a clearly audible level. Recording
    /// happens in .measurement mode (AGC off) + muffled on the mattress → very
    /// low level; without this the saved clip is barely audible at full volume.
    private func normalized(_ samples: [Float], targetPeak: Float = 0.9, maxGain: Float = 60) -> [Float] {
        guard !samples.isEmpty else { return samples }
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        guard peak > 1e-5 else { return samples }      // essentially silent → leave as is
        var gain = min(targetPeak / peak, maxGain)
        var out = [Float](repeating: 0, count: samples.count)
        vDSP_vsmul(samples, 1, &gain, &out, 1, vDSP_Length(samples.count))
        var lo: Float = -1, hi: Float = 1
        vDSP_vclip(out, 1, &lo, &hi, &out, 1, vDSP_Length(out.count))
        return out
    }

    private func saveToICloud(samples rawSamples: [Float], sampleRate: Double, timestamp: Date) -> String? {
        let samples = normalized(rawSamples)   // boost quiet clip to an audible level
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let fileName = "sleep_\(formatter.string(from: timestamp)).m4a"

        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        guard writeAAC(samples: samples, sampleRate: sampleRate, to: tmpURL) else { return nil }

        let destFolder = iCloudDocumentsURL?.appendingPathComponent(Self.soundsFolder)
        guard let folder = destFolder else { return saveLocally(from: tmpURL, fileName: fileName) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destURL = folder.appendingPathComponent(fileName)
        do {
            try FileManager.default.copyItem(at: tmpURL, to: destURL)
            return fileName
        } catch {
            return saveLocally(from: tmpURL, fileName: fileName)
        }
    }

    private func saveLocally(from src: URL, fileName: String) -> String? {
        let localFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Self.soundsFolder)
        guard let folder = localFolder else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent(fileName)
        try? FileManager.default.copyItem(at: src, to: dest)
        return "local://\(fileName)"
    }

    /// Encodes mono float samples to an AAC .m4a file at `url`. Returns success.
    private func writeAAC(samples: [Float], sampleRate: Double, to url: URL) -> Bool {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate, channels: 1,
                                         interleaved: false) else { return false }
        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ]
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let frameCount = AVAudioFrameCount(samples.count)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return false }
            buffer.frameLength = frameCount
            samples.withUnsafeBufferPointer { ptr in
                buffer.floatChannelData?[0].update(from: ptr.baseAddress!, count: samples.count)
            }
            try file.write(from: buffer)
            return true
        } catch { return false }
    }

    // MARK: - Retroactive normalisation of existing clips

    /// Re-normalises already-saved (quiet) clips so they become audible.
    /// Scans the local + iCloud SleepSounds folders. Safe to run repeatedly
    /// (clips already loud enough are skipped). Returns the number changed.
    @discardableResult
    func normalizeExistingClips() -> Int {
        var folders: [URL] = []
        if let f = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Self.soundsFolder) { folders.append(f) }
        if let f = iCloudDocumentsURL?.appendingPathComponent(Self.soundsFolder) { folders.append(f) }

        var count = 0
        for folder in folders {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil) else { continue }
            for url in files where url.pathExtension.lowercased() == "m4a" {
                if normalizeClipInPlace(at: url) { count += 1 }
            }
        }
        return count
    }

    private func normalizeClipInPlace(at url: URL) -> Bool {
        // Make sure iCloud files are materialised before reading.
        let vals = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        if vals?.ubiquitousItemDownloadingStatus == .notDownloaded {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            return false   // not ready this pass
        }
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return false }
        do { try file.read(into: buf) } catch { return false }
        guard let ch = buf.floatChannelData else { return false }
        let n = Int(buf.frameLength)
        guard n > 0 else { return false }

        var samples = [Float](repeating: 0, count: n)
        samples.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: ch[0], count: n) }

        // Skip clips that are already loud enough (idempotent — don't re-clip).
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(n))
        if peak >= 0.7 { return false }

        let boosted = normalized(samples)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        guard writeAAC(samples: boosted, sampleRate: format.sampleRate, to: tmp) else { return false }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }
}
