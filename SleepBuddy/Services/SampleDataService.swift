import Foundation
import SwiftData

enum SampleDataService {

    static func insertSampleNight(into context: ModelContext) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        // 22:30 yesterday → 06:45 today  (8h 15min)
        let start = cal.date(byAdding: .minute, value: -(8 * 60 + 15), to: today.addingTimeInterval(6.75 * 3600))!
        let end   = today.addingTimeInterval(6.75 * 3600)

        let session = SleepSession(startDate: start)
        session.endDate = end
        session.sleepOnsetDate = start.addingTimeInterval(18 * 60)
        session.snoringEventCount = 3
        context.insert(session)

        // Realistic sleep architecture (sum = 495 min)
        let arch: [(SleepPhaseType, Double)] = [
            (.awake, 18),
            (.light, 30),
            (.deep,  75),
            (.light, 25),
            (.rem,   50),
            (.light, 20),
            (.deep,  65),
            (.light, 20),
            (.rem,   45),
            (.light, 20),
            (.deep,  40),
            (.light, 20),
            (.rem,   40),
            (.awake, 27),
        ]

        var cursor = start
        for (type, minutes) in arch {
            let phaseEnd = cursor.addingTimeInterval(minutes * 60)
            let phase = SleepPhase(startDate: cursor, endDate: phaseEnd, phaseType: type, confidence: 0.88)
            phase.session = session
            session.phases.append(phase)
            context.insert(phase)
            cursor = phaseEnd
        }

        // Prepare SleepSounds folder
        let soundsDir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SleepSounds")
        try? FileManager.default.createDirectory(at: soundsDir, withIntermediateDirectories: true)

        // Sound events
        let events: [(SoundEventType, Double, Double?, String?)] = [
            // (type, hoursAfterStart, durationSec, audioFile or nil)
            (.snoring, 2.75,  22, "sample_snore_1.wav"),
            (.talking, 4.17,  14, "sample_talk_1.wav"),
            (.snoring, 5.33,  31, nil),               // no audio → waveform.slash icon
            (.other,   5.83,   8, nil),
            (.snoring, 6.67,  18, "sample_snore_2.wav"),
        ]

        for (type, hoursOffset, duration, filename) in events {
            let ts = start.addingTimeInterval(hoursOffset * 3600)
            var iCloudName: String? = nil
            if let fn = filename {
                let url = soundsDir.appendingPathComponent(fn)
                let freq: Double = type == .snoring ? (fn.contains("2") ? 120 : 140) : 220
                generateToneWAV(frequency: freq, duration: duration ?? 10, url: url)
                iCloudName = "local://\(fn)"
            }
            let event = SleepSoundEvent(
                timestamp: ts,
                type: type,
                durationSeconds: duration ?? 10,
                iCloudFileName: iCloudName
            )
            context.insert(event)
            session.soundEvents.append(event)
        }

        try? context.save()
    }

    // MARK: - WAV generator (sine wave with fade in/out)

    private static func generateToneWAV(frequency: Double, duration: Double, url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }

        let sampleRate = 22050
        let numSamples = Int(Double(sampleRate) * duration)
        var data = Data()

        func append32(_ v: UInt32) {
            var x = v.littleEndian
            withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
        }
        func append16(_ v: UInt16) {
            var x = v.littleEndian
            withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
        }

        let dataBytes = UInt32(numSamples * 2)
        data.append(contentsOf: "RIFF".utf8)
        append32(36 + dataBytes)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        append32(16)
        append16(1)                          // PCM
        append16(1)                          // mono
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))     // byte rate
        append16(2)                          // block align
        append16(16)                         // 16-bit
        data.append(contentsOf: "data".utf8)
        append32(dataBytes)

        for i in 0..<numSamples {
            let t = Double(i) / Double(sampleRate)
            let env = min(t / 0.08, 1.0) * min((duration - t) / 0.08, 1.0)
            let sample = sin(2.0 * .pi * frequency * t) * env * 0.55
            var pcm = Int16(max(-32767, min(32767, Int(sample * 32767)))).littleEndian
            withUnsafeBytes(of: &pcm) { data.append(contentsOf: $0) }
        }

        try? data.write(to: url)
    }
}
