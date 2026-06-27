import AVFoundation
import Foundation
import Observation

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
    // We deliberately do NOT use an adaptive EMA multiplier here.
    // ShutEye uses fixed dB thresholds: ~45 dB normal, raised in partner mode.
    // 45 dB ≈ amplitude 0.006, 50 dB ≈ 0.010, 55 dB ≈ 0.018
    // Use 0.010 as default (≈ 50 dB) — catches moderate snoring, not room hiss.

    /// Set by the tracking VM. When the phone rests on the mattress the mic is
    /// muffled (faces down / into the bedding), so the loudness threshold is
    /// lowered to still catch snoring that would otherwise stay below 50 dB.
    var isOnMattress = false

    private var amplitudeThreshold: Float {
        guard UserDefaults.standard.bool(forKey: "partnerModus_aktiv") else {
            return isOnMattress ? 0.006 : 0.010   // 45 dB on mattress vs 50 dB nightstand
        }
        switch UserDefaults.standard.integer(forKey: "partnerModus_stufe") {
        case 1: return 0.022   // partner's breathing / movement noise is louder
        case 2: return 0.040   // partner very close — only clear loud events
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

        // External sounds require slightly higher confidence to compensate for ambient noise
        let minConf: Double = type.isExternal ? 0.55 : 0.45
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
}
