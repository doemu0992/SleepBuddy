import AVFoundation
import Foundation
import Observation
import Accelerate

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
    private let rollingMax = 2400                          // ~5 min of quiet samples @ 8 Hz
    private var rollingAmbient: [Float] = []
    private var lastRecal = Date.distantPast

    private var amplitudeThreshold: Float {
        // Once calibrated, the measured ambient ceiling drives detection.
        if let cal = calibratedThreshold {
            if UserDefaults.standard.bool(forKey: "partnerModus_aktiv") {
                switch UserDefaults.standard.integer(forKey: "partnerModus_stufe") {
                case 1: return cal * 1.6   // raise further between partners
                case 2: return cal * 2.4   // partner very close
                default: return cal
                }
            }
            return cal
        }
        // Pre-calibration fallback (fixed) — used only during the first 60 s.
        guard UserDefaults.standard.bool(forKey: "partnerModus_aktiv") else {
            return isOnMattress ? 0.006 : 0.010
        }
        switch UserDefaults.standard.integer(forKey: "partnerModus_stufe") {
        case 1: return 0.022
        case 2: return 0.040
        default: return 0.010
        }
    }

    // MARK: - Circular raw-sample buffer (last 35 s at native sample rate)

    private let clipDuration: TimeInterval = 30
    private var sampleRate: Double = 44100
    private var circularBuffer: [Float] = []
    private var maxRingSize: Int { Int(sampleRate * (clipDuration + 5)) }

    // MARK: - Event detection state

    private let cooldownAfterEventSeconds: TimeInterval = 4.0

    private var eventStartDate: Date?
    private var pendingEventType: SoundEventType = .other
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
    /// External sounds have higher confidence thresholds in SoundClassificationService (0.50–0.65)
    /// which acts as the false-positive gate — no separate amplitude check needed.
    func hintMLDetection(type: SoundEventType, confidence: Double) {
        mlHintType = type
        mlHintConfidence = confidence
        mlHintDate = Date()

        // External sounds require slightly higher confidence to compensate for ambient noise.
        // Lowered 0.55 → 0.50 now that the ML path receives gain-boosted audio —
        // the per-class thresholds in SoundClassificationService still gate false positives.
        let minConf: Double = type.isExternal ? 0.50 : 0.45
        if confidence >= minConf && eventStartDate == nil && !isInCooldown {
            eventStartDate = Date()
            pendingEventType = type
            consecutiveLoudTicks = loudTicksToStart
            consecutiveQuietTicks = 0
        }
    }

    // MARK: - Callback (fires on main actor)

    var onEventCaptured: ((Date, SoundEventType, TimeInterval, String?, Double, Double) -> Void)?

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

        // ── Rolling re-calibration: feed only quiet, non-event samples so that
        //    events never raise the floor; re-evaluate the threshold every 2 min.
        if eventStartDate == nil, let thr = calibratedThreshold, instantAmplitude < thr {
            rollingAmbient.append(instantAmplitude)
            if rollingAmbient.count > rollingMax {
                rollingAmbient.removeFirst(rollingAmbient.count - rollingMax)
            }
        }
        if Date().timeIntervalSince(lastRecal) >= recalInterval {
            recalibrateRolling()
        }

        if isInCooldown { return }

        // Snoring has a strong low-frequency spectral signature that survives
        // mattress muffling even when the absolute level stays well below the
        // loudness threshold. Trigger on the spectral score with only a low
        // absolute floor (≈ 28 dB) to keep room hiss out.
        let snoringBySpectrum = snoringScore > 0.55 && instantAmplitude > 0.0008

        let isLoud = instantAmplitude > amplitudeThreshold || snoringBySpectrum

        if isLoud {
            consecutiveQuietTicks = 0
            consecutiveLoudTicks += 1
            if eventStartDate == nil && consecutiveLoudTicks >= loudTicksToStart {
                eventStartDate = Date().addingTimeInterval(-Double(loudTicksToStart) / 8.0)
                pendingEventType = classifyEvent(snoringScore: snoringScore, speechLikelihood: speechLikelihood)
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
        circularBuffer.removeAll()
        mlHintType = nil
        mlHintConfidence = 0
        mlHintDate = nil
        // Restart calibration for the new session
        calibrationSamples.removeAll()
        calibrationDeadline = nil
        calibratedThreshold = nil
        rollingAmbient.removeAll()
        lastRecal = .distantPast
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
        calibratedThreshold = max(ceiling * 1.8, 0.004)   // never below ≈ 42 dB
        lastRecal = Date()
    }

    /// Rolling re-calibration: recompute the ambient floor from the last ~5 min of
    /// quiet samples and blend it smoothly into the current threshold (EMA) so the
    /// app adapts to changing room conditions through the night without jumping.
    private func recalibrateRolling() {
        lastRecal = Date()
        guard rollingAmbient.count >= 240 else { return }   // need ≥ ~30 s of quiet data
        let sorted = rollingAmbient.sorted()
        let ceiling = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let candidate = max(ceiling * 1.8, 0.004)
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
        // Amplitude-triggered without fresh ML hint — use strict thresholds to match
        // SoundClassificationService's minimum confidence levels
        if snoringScore > 0.45 { return .snoring }
        if speechLikelihood > 0.40 { return .talking }
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

        let samples = Array(circularBuffer)
        let sr = sampleRate
        let timestamp = start
        let capturedConfidence = mlHintConfidence
        let decibelLevel = computeDecibelLevel(samples)

        mlHintType = nil
        mlHintConfidence = 0
        mlHintDate = nil

        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            let fileName = self.isEnabled
                ? self.saveToICloud(samples: samples, sampleRate: sr, timestamp: timestamp)
                : nil
            await MainActor.run {
                self.onEventCaptured?(timestamp, type, duration, fileName, decibelLevel, capturedConfidence)
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
