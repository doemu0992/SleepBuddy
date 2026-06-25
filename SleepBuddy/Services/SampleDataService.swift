import Foundation
import SwiftData

enum SampleDataService {

    // MARK: - Public entry point

    static func insertSampleNight(into context: ModelContext) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let nightIndex = existingSessionCount(in: context) % 3

        switch nightIndex {
        case 0:  insertNight1_Schnarchen(today: today, into: context)
        case 1:  insertNight2_Umgebung(today: today, into: context)
        default: insertNight3_AllTypes(today: today, into: context)
        }
        try? context.save()
    }

    private static func existingSessionCount(in context: ModelContext) -> Int {
        (try? context.fetchCount(FetchDescriptor<SleepSession>())) ?? 0
    }

    // MARK: - Night 1: Personal sleep sounds (snoring-heavy night)

    private static func insertNight1_Schnarchen(today: Date, into context: ModelContext) {
        let cal = Calendar.current
        let start = makeDate(today: today, offsetDays: -2, hour: 23, minute: 0)
        let end   = makeDate(today: today, offsetDays: -1, hour: 7,  minute: 10)
        let session = makeSession(start: start, end: end, quality: 3, changes: 5, context: context)
        session.sleepOnsetDate = start.addingTimeInterval(12 * 60)

        let arch: [(SleepPhaseType, Double)] = [
            (.awake, 12), (.light, 35), (.deep, 80), (.light, 25),
            (.rem,  45),  (.light, 20), (.deep, 60), (.light, 18),
            (.rem,  40),  (.light, 22), (.deep, 35), (.light, 20),
            (.rem,  35),  (.awake, 28),
        ]
        insertPhases(from: start, arch: arch, session: session, context: context)

        let events: [(SoundEventType, Double, Double, Double, Double)] = [
            // Personal sounds — schnarchen dominant
            (.snoring,   1.0,  28, 72, 0.0),
            (.snoring,   2.2,  35, 68, 0.0),
            (.snoring,   3.5,  22, 65, 0.0),
            (.snoring,   4.1,  42, 74, 0.0),
            (.snoring,   5.3,  31, 70, 0.0),
            (.snoring,   6.0,  18, 66, 0.0),
            (.talking,   2.8,  12, 48, 0.72),
            (.talking,   5.1,   8, 44, 0.68),
            (.coughing,  1.5,   4, 61, 0.85),
            (.coughing,  4.7,   6, 59, 0.82),
            (.bruxism,   3.2,   7, 50, 0.80),
            (.bruxism,   5.8,   9, 53, 0.78),
            (.gasping,   2.5,   8, 58, 0.71),
            (.sneezing,  4.0,   3, 70, 0.90),
            (.laughing,  3.7,   5, 45, 0.65),
        ]
        insertEvents(events, start: start, session: session, context: context,
                     generateAudio: [.snoring, .talking, .coughing, .bruxism, .gasping, .sneezing, .laughing])

        session.noiseSamples = generateNoiseCurve(minutes: totalMinutes(start, end), baseDB: 27)
        session.heartRateSamples = generateHRCurve(minutes: totalMinutes(start, end))
        insertTrainingSamples(from: start, arch: arch, into: context)
    }

    // MARK: - Night 2: External disturbances

    private static func insertNight2_Umgebung(today: Date, into context: ModelContext) {
        let start = makeDate(today: today, offsetDays: -1, hour: 22, minute: 30)
        let end   = makeDate(today: today, offsetDays: 0,  hour: 6,  minute: 45)
        let session = makeSession(start: start, end: end, quality: 2, changes: 8, context: context)
        session.sleepOnsetDate = start.addingTimeInterval(20 * 60)

        let arch: [(SleepPhaseType, Double)] = [
            (.awake, 20), (.light, 28), (.deep, 55), (.light, 22),
            (.rem,  38),  (.awake, 15), (.light, 18), (.deep, 45),
            (.light, 18), (.rem,  35),  (.light, 20), (.deep, 30),
            (.light, 18), (.rem,  30),  (.awake, 25),
        ]
        insertPhases(from: start, arch: arch, session: session, context: context)

        let events: [(SoundEventType, Double, Double, Double, Double)] = [
            // External sounds — störende Nacht
            (.dogBarking, 1.2,  18, 72, 0.88),
            (.dogBarking, 3.8,  25, 74, 0.92),
            (.dogBarking, 5.5,  12, 68, 0.85),
            (.cat,        2.3,  15, 62, 0.78),
            (.cat,        6.1,  10, 58, 0.74),
            (.bird,       6.5,  20, 55, 0.70),
            (.bird,       7.0,  18, 52, 0.68),
            (.music,      0.5,  90, 58, 0.87),
            (.traffic,    5.8,  14, 55, 0.73),
            (.traffic,    6.8,  22, 60, 0.76),
            (.thunder,    4.2,  30, 68, 0.82),
            (.thunder,    4.6,  25, 70, 0.84),
            (.wind,       3.0,  45, 48, 0.65),
            (.knock,      2.0,   2, 75, 0.90),
            (.doorbell,   1.8,   3, 80, 0.92),
            (.phone,      3.3,  12, 72, 0.88),
            (.baby,       4.9,  35, 65, 0.83),
            (.glassBreak, 5.2,   4, 82, 0.95),
            (.crowd,      0.8,  60, 52, 0.72),
            (.water,      2.7,  20, 45, 0.68),
            // A few personal sounds too
            (.snoring,    2.5,  20, 65, 0.0),
            (.coughing,   4.5,   5, 60, 0.80),
        ]
        insertEvents(events, start: start, session: session, context: context,
                     generateAudio: SoundEventType.allCases.filter { $0 != .other })

        // Noisy night with music and dog spikes
        let mins = totalMinutes(start, end)
        var noise = generateNoiseCurve(minutes: mins, baseDB: 32)
        for i in 0..<mins {
            if i >= 30 && i <= 90  { noise[i] = min(90, noise[i] + 20) }  // music
            if i >= 72 && i <= 74  { noise[i] = min(90, noise[i] + 30) }  // dog
            if i >= 228 && i <= 230 { noise[i] = min(90, noise[i] + 28) } // dog again
            if i >= 252 && i <= 280 { noise[i] = min(90, noise[i] + 18) } // thunder
        }
        session.noiseSamples = noise
        session.heartRateSamples = generateHRCurve(minutes: mins)
        insertTrainingSamples(from: start, arch: arch, into: context)
    }

    // MARK: - Night 3: All types showcase

    private static func insertNight3_AllTypes(today: Date, into context: ModelContext) {
        let start = makeDate(today: today, offsetDays: -3, hour: 23, minute: 15)
        let end   = makeDate(today: today, offsetDays: -2, hour: 7,  minute: 30)
        let session = makeSession(start: start, end: end, quality: 4, changes: 6, context: context)
        session.sleepOnsetDate = start.addingTimeInterval(15 * 60)

        let arch: [(SleepPhaseType, Double)] = [
            (.awake, 15), (.light, 30), (.deep, 85), (.light, 25),
            (.rem,  50),  (.light, 20), (.deep, 70), (.light, 20),
            (.rem,  45),  (.light, 20), (.deep, 45), (.light, 20),
            (.rem,  40),  (.awake, 20),
        ]
        insertPhases(from: start, arch: arch, session: session, context: context)

        // One event of every type spread across the night
        var events: [(SoundEventType, Double, Double, Double, Double)] = []
        let types = SoundEventType.allCases.filter { $0 != .other }
        for (i, type) in types.enumerated() {
            let offset = 0.5 + Double(i) * (7.0 / Double(types.count))
            let dur: Double = type.isExternal ? Double.random(in: 8...30) : Double.random(in: 4...20)
            let db: Double  = type.isExternal ? Double.random(in: 55...78) : Double.random(in: 45...68)
            let conf: Double = type == .snoring ? 0.0 : Double.random(in: 0.65...0.92)
            events.append((type, offset, dur, db, conf))
        }
        insertEvents(events, start: start, session: session, context: context,
                     generateAudio: SoundEventType.allCases)

        session.noiseSamples = generateNoiseCurve(minutes: totalMinutes(start, end), baseDB: 30)
        session.heartRateSamples = generateHRCurve(minutes: totalMinutes(start, end))
        insertTrainingSamples(from: start, arch: arch, into: context)
    }

    // MARK: - Shared helpers

    private static func makeSession(start: Date, end: Date, quality: Int, changes: Int, context: ModelContext) -> SleepSession {
        let session = SleepSession(startDate: start)
        session.endDate = end
        session.subjectiveQuality = quality
        session.positionChanges = changes
        context.insert(session)
        return session
    }

    private static func insertPhases(from start: Date, arch: [(SleepPhaseType, Double)], session: SleepSession, context: ModelContext) {
        var cursor = start
        for (type, minutes) in arch {
            let phaseEnd = cursor.addingTimeInterval(minutes * 60)
            let phase = SleepPhase(startDate: cursor, endDate: phaseEnd, phaseType: type, confidence: Double.random(in: 0.80...0.95))
            phase.session = session
            session.phases?.append(phase)
            context.insert(phase)
            cursor = phaseEnd
        }
    }

    private static func insertEvents(
        _ events: [(SoundEventType, Double, Double, Double, Double)],
        start: Date,
        session: SleepSession,
        context: ModelContext,
        generateAudio: [SoundEventType]
    ) {
        let soundsDir = soundsDirectory()
        for (type, hoursOffset, duration, decibelLevel, confidence) in events {
            let ts = start.addingTimeInterval(hoursOffset * 3600)
            var fileName: String? = nil
            if generateAudio.contains(type) {
                let fn = audioFileName(for: type, ts: ts)
                let url = soundsDir.appendingPathComponent(fn)
                generateAudioWAV(type: type, duration: min(duration, 20), url: url)
                fileName = "local://\(fn)"
            }
            let event = SleepSoundEvent(
                timestamp: ts,
                type: type,
                durationSeconds: duration,
                iCloudFileName: fileName,
                decibelLevel: decibelLevel,
                confidenceScore: confidence
            )
            event.session = session
            context.insert(event)
            session.soundEvents?.append(event)
        }
    }

    private static func soundsDirectory() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SleepSounds")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func audioFileName(for type: SoundEventType, ts: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HHmmss"
        return "sample_\(type.rawValue)_\(fmt.string(from: ts)).wav"
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private static func totalMinutes(_ start: Date, _ end: Date) -> Int {
        max(1, Int(end.timeIntervalSince(start) / 60))
    }

    private static func makeDate(today: Date, offsetDays: Int, hour: Int, minute: Int) -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: today)
        comps.day = (comps.day ?? 0) + offsetDays
        comps.hour = hour
        comps.minute = minute
        return cal.date(from: comps) ?? today
    }

    // MARK: - Noise curve

    private static func generateNoiseCurve(minutes: Int, baseDB: Double) -> [Double] {
        (0..<minutes).map { i in
            let morningRamp = i > Int(Double(minutes) * 0.85) ? Double(i - Int(Double(minutes) * 0.85)) * 0.08 : 0
            let noise = baseDB + morningRamp + Double.random(in: -3...3)
            return max(20, min(90, noise))
        }
    }

    // MARK: - Heart rate curve

    private static func generateHRCurve(minutes: Int) -> [Double] {
        (0..<minutes).map { i in
            let t = Double(i) / Double(minutes)
            let base = 57.0
            let dip  = sin(t * .pi * 3) * 7.0
            let rise = (t > 0.30 && t < 0.42) || (t > 0.62 && t < 0.72) ? 9.0 : 0.0
            return max(48, min(88, base + dip + rise + Double.random(in: -2...2)))
        }
    }

    // MARK: - TrainingSamples

    private static func insertTrainingSamples(from start: Date, arch: [(SleepPhaseType, Double)], into context: ModelContext) {
        struct Profile {
            var amp: ClosedRange<Float>; var ampVar: ClosedRange<Float>
            var bpm: ClosedRange<Float>; var reg: ClosedRange<Float>
            var mov: ClosedRange<Float>; var snor: ClosedRange<Float>
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
            let count = max(1, Int(minutes * 2))
            for i in 0..<count {
                let sample = TrainingSample(
                    timestamp: cursor.addingTimeInterval(Double(i) * 30),
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

    // MARK: - WAV audio generator

    /// Generates a characteristic sine-wave tone per SoundEventType so audio clips
    /// are distinguishable when played back. Each type uses a unique frequency profile.
    private static func generateAudioWAV(type: SoundEventType, duration: Double, url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }

        struct Tone { var freq: Double; var harmonics: [Double]; var modFreq: Double }

        let tone: Tone = {
            switch type {
            // Personal sleep sounds
            case .snoring:    return Tone(freq: 130, harmonics: [1, 0.6, 0.3], modFreq: 0.6)
            case .talking:    return Tone(freq: 220, harmonics: [1, 0.4, 0.2, 0.1], modFreq: 4.0)
            case .coughing:   return Tone(freq: 300, harmonics: [1, 0.5, 0.25], modFreq: 8.0)
            case .bruxism:    return Tone(freq: 800, harmonics: [1, 0.3, 0.15], modFreq: 12.0)
            case .sneezing:   return Tone(freq: 400, harmonics: [1, 0.6, 0.4, 0.2], modFreq: 20.0)
            case .gasping:    return Tone(freq: 180, harmonics: [1, 0.5, 0.2], modFreq: 2.0)
            case .laughing:   return Tone(freq: 260, harmonics: [1, 0.7, 0.4, 0.2], modFreq: 6.0)
            case .other:      return Tone(freq: 440, harmonics: [1], modFreq: 0)
            // External sounds
            case .dogBarking: return Tone(freq: 150, harmonics: [1, 0.8, 0.4, 0.2], modFreq: 3.0)
            case .cat:        return Tone(freq: 700, harmonics: [1, 0.5, 0.2], modFreq: 5.0)
            case .bird:       return Tone(freq: 1800, harmonics: [1, 0.3], modFreq: 8.0)
            case .music:      return Tone(freq: 440, harmonics: [1, 0.5, 0.25, 0.12], modFreq: 0.5)
            case .alarm:      return Tone(freq: 880, harmonics: [1, 0.1], modFreq: 1.5)
            case .doorbell:   return Tone(freq: 600, harmonics: [1, 0.4, 0.1], modFreq: 0.8)
            case .phone:      return Tone(freq: 750, harmonics: [1, 0.3], modFreq: 2.0)
            case .traffic:    return Tone(freq: 80,  harmonics: [1, 0.7, 0.5, 0.3, 0.15], modFreq: 0.2)
            case .baby:       return Tone(freq: 550, harmonics: [1, 0.6, 0.3], modFreq: 5.0)
            case .thunder:    return Tone(freq: 60,  harmonics: [1, 0.8, 0.6, 0.4, 0.2], modFreq: 0.1)
            case .wind:       return Tone(freq: 200, harmonics: [1, 0.6, 0.4, 0.2], modFreq: 0.3)
            case .knock:      return Tone(freq: 200, harmonics: [1, 0.4, 0.1], modFreq: 0.0)
            case .glassBreak: return Tone(freq: 2000, harmonics: [1, 0.7, 0.5, 0.3, 0.1], modFreq: 0.0)
            case .crowd:      return Tone(freq: 300, harmonics: [1, 0.5, 0.3, 0.2, 0.1], modFreq: 1.5)
            case .water:      return Tone(freq: 500, harmonics: [1, 0.6, 0.4, 0.2], modFreq: 7.0)
            }
        }()

        let sampleRate = 22050
        let numSamples = Int(Double(sampleRate) * duration)
        var data = Data()

        func append32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }

        let dataBytes = UInt32(numSamples * 2)
        data.append(contentsOf: "RIFF".utf8); append32(36 + dataBytes)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8); append32(16); append16(1); append16(1)
        append32(UInt32(sampleRate)); append32(UInt32(sampleRate * 2)); append16(2); append16(16)
        data.append(contentsOf: "data".utf8); append32(dataBytes)

        for i in 0..<numSamples {
            let t = Double(i) / Double(sampleRate)
            let env = min(t / 0.05, 1.0) * min((duration - t) / 0.05, 1.0)
            let mod = tone.modFreq > 0 ? (0.5 + 0.5 * sin(2.0 * .pi * tone.modFreq * t)) : 1.0
            var sample = 0.0
            for (idx, amp) in tone.harmonics.enumerated() {
                sample += sin(2.0 * .pi * tone.freq * Double(idx + 1) * t) * amp
            }
            // Normalize harmonics
            let total = tone.harmonics.reduce(0, +)
            sample = (sample / total) * mod * env * 0.5
            var pcm = Int16(max(-32767, min(32767, Int(sample * 32767)))).littleEndian
            withUnsafeBytes(of: &pcm) { data.append(contentsOf: $0) }
        }

        try? data.write(to: url)
    }
}
