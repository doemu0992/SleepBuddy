import AVFoundation
import Foundation
import Observation

/// Detects sound events during sleep (snoring, talking, coughing, bruxism, other) and saves
/// 30-second audio clips to iCloud Documents on opt-in. Raw audio stays in RAM until confirmed.
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

    // MARK: - Adaptive noise-floor calibration (first 60 s of session)

    private var calibrationValues: [Float] = []
    private let calibrationTicks = 480          // 60 s × 8 Hz
    private var calibratedThreshold: Float?     // nil until calibration done

    // MARK: - Circular raw-sample buffer (last 35 s at native sample rate)

    private let clipDuration: TimeInterval = 30
    private var sampleRate: Double = 44100
    private var circularBuffer: [Float] = []
    private var maxRingSize: Int { Int(sampleRate * (clipDuration + 5)) }

    // MARK: - Event detection state

    private var baseAmplitudeThreshold: Float {
        guard UserDefaults.standard.bool(forKey: "partnerModus_aktiv") else { return 0.018 }
        switch UserDefaults.standard.integer(forKey: "partnerModus_stufe") {
        case 1: return 0.035
        case 2: return 0.058
        default: return 0.018
        }
    }

    private var amplitudeThreshold: Float { calibratedThreshold ?? baseAmplitudeThreshold }

    private let cooldownAfterEventSeconds: TimeInterval = 4.0  // reduced from 10 s

    private var eventStartDate: Date?
    private var pendingEventType: SoundEventType = .other
    private var consecutiveLoudTicks = 0
    private var consecutiveQuietTicks = 0
    private let quietTicksToEnd = 8     // 1 s of quiet ends the event
    private let loudTicksToStart = 4    // 0.5 s of noise starts an event
    private var lastEventEndDate: Date?

    // MARK: - ML hint (from SoundClassificationService)

    private var mlHintType: SoundEventType?
    private var mlHintConfidence: Double = 0
    private var mlHintDate: Date?
    private let mlHintMaxAge: TimeInterval = 5.0   // extended from 2 s

    /// Called by SoundClassificationService when Apple's ML fires.
    /// For bruxism and coughing (often quiet), a high-confidence hit directly starts an event
    /// without waiting for the amplitude threshold — these sounds may never cross it.
    func hintMLDetection(type: SoundEventType, confidence: Double) {
        mlHintType = type
        mlHintConfidence = confidence
        mlHintDate = Date()

        let isMLPrimary = type == .bruxism || type == .coughing
        if isMLPrimary && confidence >= 0.65 && eventStartDate == nil && !isInCooldown {
            eventStartDate = Date()
            pendingEventType = type
            consecutiveLoudTicks = loudTicksToStart  // bypass tick counter
            consecutiveQuietTicks = 0
        }
    }

    // MARK: - Callback (fires on main actor)

    /// Provides (timestamp, type, duration, optional iCloud file name, decibelLevel, confidenceScore).
    var onEventCaptured: ((Date, SoundEventType, TimeInterval, String?, Double, Double) -> Void)?

    // MARK: - Public API

    func configure(sampleRate: Double) {
        self.sampleRate = sampleRate
        circularBuffer.removeAll()
        circularBuffer.reserveCapacity(maxRingSize)
        reset()
    }

    /// Feed raw PCM samples (called on background queue). Gated by isEnabled for clip saving.
    func appendSamples(_ samples: [Float], actualSampleRate: Double? = nil) {
        guard isEnabled else { return }
        if let sr = actualSampleRate, sr != sampleRate { sampleRate = sr }
        circularBuffer.append(contentsOf: samples)
        if circularBuffer.count > maxRingSize {
            circularBuffer.removeFirst(circularBuffer.count - maxRingSize)
        }
    }

    /// Feed amplitude + scores per 8 Hz envelope tick (called on background queue).
    func tick(amplitude: Float, snoringScore: Float, speechLikelihood: Float) {
        // Adaptive threshold: sample ambient noise for the first 60 s
        if calibrationValues.count < calibrationTicks {
            calibrationValues.append(amplitude)
            if calibrationValues.count == calibrationTicks {
                let sorted = calibrationValues.sorted()
                let p75 = sorted[Int(Double(sorted.count) * 0.75)]
                // 2.5× the 75th-percentile ambient level; clamped between floor and base value
                calibratedThreshold = max(0.008, min(p75 * 2.5, baseAmplitudeThreshold))
            }
        }

        if isInCooldown { return }

        let isLoud = amplitude > amplitudeThreshold

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
        calibrationValues.removeAll()
        calibratedThreshold = nil
    }

    // MARK: - Audio file URL for playback

    func audioURL(for fileName: String) -> URL? {
        iCloudDocumentsURL?
            .appendingPathComponent(Self.soundsFolder)
            .appendingPathComponent(fileName)
    }

    // MARK: - Private helpers

    private var isInCooldown: Bool {
        guard let lastEnd = lastEventEndDate else { return false }
        return Date().timeIntervalSince(lastEnd) < cooldownAfterEventSeconds
    }

    /// Minimum event duration varies by type.
    /// Coughs (0.5–1.5 s) and bruxism bursts (< 1 s) were previously filtered out by the 2.5 s floor.
    private func minDuration(for type: SoundEventType) -> TimeInterval {
        switch type {
        case .coughing: return 0.5
        case .bruxism:  return 0.8
        default:        return 2.5
        }
    }

    private func classifyEvent(snoringScore: Float, speechLikelihood: Float) -> SoundEventType {
        if let hintDate = mlHintDate,
           Date().timeIntervalSince(hintDate) < mlHintMaxAge,
           let hint = mlHintType {
            return hint
        }
        if snoringScore > 0.45 { return .snoring }
        if speechLikelihood > 0.4 { return .talking }
        return .other
    }

    private func computeDecibelLevel(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0.0 }
        let sumSquares = samples.reduce(0.0) { $0 + Double($1 * $1) }
        let rms = sqrt(sumSquares / Double(samples.count))
        let db = 20.0 * log10(max(rms, 1e-6))
        return max(0.0, min(120.0, db + 90.0))
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
            let fileName = self.isEnabled ? self.saveToICloud(samples: samples, sampleRate: sr, timestamp: timestamp) : nil
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

    private func saveToICloud(samples: [Float], sampleRate: Double, timestamp: Date) -> String? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let fileName = "sleep_\(formatter.string(from: timestamp)).m4a"

        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate, channels: 1,
                                         interleaved: false) else { return nil }
        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ]
            let file = try AVAudioFile(forWriting: tmpURL, settings: settings)
            let frameCount = AVAudioFrameCount(samples.count)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
            buffer.frameLength = frameCount
            samples.withUnsafeBufferPointer { ptr in
                buffer.floatChannelData?[0].update(from: ptr.baseAddress!, count: samples.count)
            }
            try file.write(from: buffer)
        } catch { return nil }

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

    func localAudioURL(for fileName: String) -> URL? {
        if fileName.hasPrefix("local://") {
            let name = String(fileName.dropFirst("local://".count))
            return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent(Self.soundsFolder)
                .appendingPathComponent(name)
        }
        return audioURL(for: fileName)
    }
}
