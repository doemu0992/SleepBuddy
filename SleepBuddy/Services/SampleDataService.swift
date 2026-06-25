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
        session.subjectiveQuality = 4          // bewertet mit "Gut"
        session.positionChanges = 7            // 7 Lageänderungen erkannt
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
            session.phases?.append(phase)
            context.insert(phase)
            cursor = phaseEnd
        }

        // Prepare SleepSounds folder
        let soundsDir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SleepSounds")
        try? FileManager.default.createDirectory(at: soundsDir, withIntermediateDirectories: true)

        // Sound events: (type, hoursAfterStart, durationSec, audioFile or nil, decibelLevel, confidenceScore)
        let events: [(SoundEventType, Double, Double?, String?, Double, Double)] = [
            (.snoring,    2.75, 22, "sample_snore_1.wav", 62.0, 0.0),
            (.talking,    4.17, 14, "sample_talk_1.wav",  48.0, 0.0),
            (.snoring,    5.33, 31, nil,                   58.0, 0.0),
            (.other,      5.83,  8, nil,                    0.0, 0.0),
            (.snoring,    6.67, 18, "sample_snore_2.wav",  70.0, 0.0),
            (.bruxism,    3.25,  7, nil,                   50.0, 0.8),
            (.bruxism,    5.00,  5, nil,                   47.0, 0.8),
            (.bruxism,    6.10,  9, nil,                   53.0, 0.8),
            (.coughing,   2.10,  4, nil,                   59.0, 0.8),
            (.coughing,   4.80,  6, nil,                   63.0, 0.8),
            // External disturbances
            (.dogBarking, 1.50, 18, nil,                   68.0, 0.8),
            (.dogBarking, 3.90, 25, nil,                   71.0, 0.9),
            (.music,      0.75, 90, nil,                   55.0, 0.85),
            (.traffic,    6.20, 12, nil,                   52.0, 0.7),
        ]

        // Ambient noise samples: one dB per minute for the session (~495 min)
        let totalMinutes = Int((end.timeIntervalSince(start)) / 60)
        var noiseSamples: [Double] = []
        for i in 0..<totalMinutes {
            let base: Double = 28.0
            let musicBoost: Double = (i >= 45 && i <= 90) ? 18.0 : 0.0
            let dogBoost: Double = ((i >= 90 && i <= 92) || (i >= 234 && i <= 236)) ? 25.0 : 0.0
            let trafficRamp: Double = i > 420 ? Double(i - 420) * 0.06 : 0.0
            let noise = base + musicBoost + dogBoost + trafficRamp + Double.random(in: -2...2)
            noiseSamples.append(max(20, min(90, noise)))
        }
        session.noiseSamples = noiseSamples

        // Heart rate samples: one per minute, realistic sleep HR curve
        var hrSamples: [Double] = []
        for i in 0..<totalMinutes {
            let t = Double(i) / Double(totalMinutes)
            // Base HR dips during deep sleep, rises during REM
            let base: Double = 58.0
            let deepDip = sin(t * .pi * 3) * 6.0          // slow deep-sleep dips
            let remRise = (t > 0.3 && t < 0.4) || (t > 0.6 && t < 0.7) ? 8.0 : 0.0
            let noise = Double.random(in: -2...2)
            hrSamples.append(max(48, min(85, base + deepDip + remRise + noise)))
        }
        session.heartRateSamples = hrSamples

        for (type, hoursOffset, duration, filename, decibelLevel, confidenceScore) in events {
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
                iCloudFileName: iCloudName,
                decibelLevel: decibelLevel,
                confidenceScore: confidenceScore
            )
            event.session = session
            context.insert(event)
            session.soundEvents?.append(event)
        }

        // TrainingSamples: ~120 samples (one per 30s for the non-awake part ≈ 60 min × 2)
        // Realistic feature values per phase
        insertTrainingSamples(from: start, arch: arch, into: context)

        try? context.save()
    }

    // MARK: - TrainingSamples

    private static func insertTrainingSamples(
        from start: Date,
        arch: [(SleepPhaseType, Double)],
        into context: ModelContext
    ) {
        // Feature profiles per phase (amp, var, bpm, reg, mov, snoring)
        struct Profile {
            var amp: ClosedRange<Float>
            var ampVar: ClosedRange<Float>
            var bpm: ClosedRange<Float>
            var reg: ClosedRange<Float>
            var mov: ClosedRange<Float>
            var snor: ClosedRange<Float>
        }
        let profiles: [SleepPhaseType: Profile] = [
            .awake: Profile(amp: 0.025...0.060, ampVar: 0.004...0.012, bpm: 16...22, reg: 0.40...0.65, mov: 0.30...0.70, snor: 0.00...0.05),
            .light: Profile(amp: 0.006...0.015, ampVar: 0.001...0.003, bpm: 14...18, reg: 0.60...0.80, mov: 0.02...0.12, snor: 0.00...0.08),
            .deep:  Profile(amp: 0.003...0.009, ampVar: 0.000...0.001, bpm: 9...14,  reg: 0.75...0.95, mov: 0.00...0.04, snor: 0.05...0.30),
            .rem:   Profile(amp: 0.004...0.012, ampVar: 0.001...0.004, bpm: 14...22, reg: 0.30...0.65, mov: 0.01...0.08, snor: 0.00...0.05),
        ]

        var cursor = start
        for (type, minutes) in arch {
            let phaseEnd = cursor.addingTimeInterval(minutes * 60)
            guard let p = profiles[type] else { cursor = phaseEnd; continue }

            // One sample per 30 seconds
            let count = max(1, Int(minutes * 2))
            for i in 0..<count {
                let ts = cursor.addingTimeInterval(Double(i) * 30)
                let sample = TrainingSample(
                    timestamp: ts,
                    averageAmplitude: Float.random(in: p.amp),
                    amplitudeVariance: Float.random(in: p.ampVar),
                    breathingRateBPM: Float.random(in: p.bpm),
                    breathingRegularity: Float.random(in: p.reg),
                    movementIntensity: Float.random(in: p.mov),
                    snoringIntensity: Float.random(in: p.snor),
                    label: type,
                    isUserCorrected: false
                )
                context.insert(sample)
            }
            cursor = phaseEnd
        }
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
