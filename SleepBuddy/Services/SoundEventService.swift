import AVFoundation
import Foundation
import Observation

/// Detects sound events during sleep (snoring, talking, other) and saves 30-second
/// audio clips to iCloud Documents. Raw audio stays in RAM until an event is confirmed.
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

    // MARK: - Circular raw-sample buffer (last 30 s at native sample rate)

    private let clipDuration: TimeInterval = 30
    private var sampleRate: Double = 44100
    private var circularBuffer: [Float] = []
    private var maxRingSize: Int { Int(sampleRate * (clipDuration + 5)) }  // 35s headroom

    // MARK: - Event detection state

    private let amplitudeThreshold: Float = 0.045
    private let minEventSeconds: TimeInterval = 2.5
    private let cooldownAfterEventSeconds: TimeInterval = 10.0

    private var eventStartDate: Date?
    private var pendingEventType: SoundEventType = .other
    private var consecutiveLoudTicks = 0      // at 8 Hz (AudioAnalysisService envelope rate)
    private var consecutiveQuietTicks = 0
    private let quietTicksToEnd = 8           // 1 s of quiet ends the event
    private let loudTicksToStart = 4          // 0.5 s of noise starts an event
    private var lastEventEndDate: Date?

    // MARK: - Callback (fires on main actor)

    /// Provides (timestamp, type, duration, optional iCloud file name) to the caller.
    var onEventCaptured: ((Date, SoundEventType, TimeInterval, String?) -> Void)?

    // MARK: - Public API

    /// Call once when recording starts.
    func configure(sampleRate: Double) {
        self.sampleRate = sampleRate
        circularBuffer.removeAll()
        circularBuffer.reserveCapacity(maxRingSize)
        reset()
    }

    /// Feed raw PCM samples from AudioAnalysisService (called on background queue).
    func appendSamples(_ samples: [Float], actualSampleRate: Double? = nil) {
        guard isEnabled else { return }
        if let sr = actualSampleRate, sr != sampleRate {
            sampleRate = sr  // auto-calibrate on first chunk
        }
        circularBuffer.append(contentsOf: samples)
        if circularBuffer.count > maxRingSize {
            circularBuffer.removeFirst(circularBuffer.count - maxRingSize)
        }
    }

    /// Feed amplitude + snoring score per 8 Hz envelope tick (called on background queue).
    func tick(amplitude: Float, snoringScore: Float, speechLikelihood: Float) {
        guard isEnabled else { return }

        let isLoud = amplitude > amplitudeThreshold

        // Cooldown: skip detection shortly after last event to avoid repeated saves
        if let lastEnd = lastEventEndDate,
           Date().timeIntervalSince(lastEnd) < cooldownAfterEventSeconds {
            return
        }

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
                if consecutiveQuietTicks >= quietTicksToEnd {
                    finaliseEvent()
                }
            }
        }
    }

    func reset() {
        eventStartDate = nil
        consecutiveLoudTicks = 0
        consecutiveQuietTicks = 0
        lastEventEndDate = nil
        circularBuffer.removeAll()
    }

    // MARK: - Audio file URL for playback

    func audioURL(for fileName: String) -> URL? {
        iCloudDocumentsURL?
            .appendingPathComponent(Self.soundsFolder)
            .appendingPathComponent(fileName)
    }

    // MARK: - Private helpers

    private func classifyEvent(snoringScore: Float, speechLikelihood: Float) -> SoundEventType {
        if snoringScore > 0.45 { return .snoring }
        if speechLikelihood > 0.4 { return .talking }
        return .other
    }

    private func finaliseEvent() {
        guard let start = eventStartDate else { return }
        let duration = Date().timeIntervalSince(start)
        lastEventEndDate = Date()
        eventStartDate = nil
        consecutiveQuietTicks = 0

        guard duration >= minEventSeconds else { return }

        let type = pendingEventType
        let samples = Array(circularBuffer)          // copy before async
        let sr = sampleRate
        let timestamp = start

        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            let fileName = self.saveToICloud(samples: samples, sampleRate: sr, timestamp: timestamp)
            await MainActor.run {
                self.onEventCaptured?(timestamp, type, duration, fileName)
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

        // Write .m4a to tmp
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

        // Move to iCloud Documents / SleepSounds
        let destFolder = iCloudDocumentsURL?.appendingPathComponent(Self.soundsFolder)
        guard let folder = destFolder else {
            // iCloud not available — fall back to local Documents
            return saveLocally(from: tmpURL, fileName: fileName)
        }
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
        return "local://\(fileName)"  // mark as local
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
