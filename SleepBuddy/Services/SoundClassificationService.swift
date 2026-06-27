import SoundAnalysis
import AVFoundation
import Observation
import CoreMedia
import Accelerate

@Observable
final class SoundClassificationService: NSObject {
    var onSoundDetected: ((SoundEventType, Double) -> Void)?

    private var analyzer: SNAudioStreamAnalyzer?
    private let analysisQueue = DispatchQueue(label: "com.sleepbuddy.soundanalysis", qos: .utility)
    private var bufferCounter = 0
    private let analyzeEveryN = 1  // analyze every buffer for maximum night detection accuracy

    func start(format: AVAudioFormat) {
        guard #available(iOS 15, *) else { return }
        do {
            analyzer = SNAudioStreamAnalyzer(format: format)
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTimeMakeWithSeconds(1.5, preferredTimescale: 44100)
            request.overlapFactor = 0.75  // more overlap = more frequent results = less missed events
            try analyzer?.add(request, withObserver: self)
        } catch {
            analyzer = nil
        }
    }

    func analyze(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard let analyzer else { return }
        bufferCounter += 1
        guard bufferCounter % analyzeEveryN == 0 else { return }
        // The AVAudioSession runs in .measurement mode (AGC off) for accurate
        // breathing analysis — this yields a very low input level. A phone on the
        // mattress muffles it further. Without a gain boost the ML classifier
        // never reaches confidence, so NO sounds (incl. external) are detected.
        // Boost a copy fed to the ML analyzer only; raw signal stays for breathing.
        let boosted = Self.applyGain(buffer, gain: 8.0) ?? buffer
        let sampleTime = time.sampleTime
        analysisQueue.async {
            analyzer.analyze(boosted, atAudioFramePosition: sampleTime)
        }
    }

    /// Returns a gain-scaled copy of the buffer, hard-clipped to [-1, 1].
    private static func applyGain(_ buffer: AVAudioPCMBuffer, gain: Float) -> AVAudioPCMBuffer? {
        guard let inCh = buffer.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity),
              let outCh = out.floatChannelData else { return nil }
        out.frameLength = buffer.frameLength
        let n = vDSP_Length(buffer.frameLength)
        var g = gain
        var lo: Float = -1.0
        var hi: Float = 1.0
        for c in 0..<Int(buffer.format.channelCount) {
            vDSP_vsmul(inCh[c], 1, &g, outCh[c], 1, n)
            vDSP_vclip(outCh[c], 1, &lo, &hi, outCh[c], 1, n)
        }
        return out
    }

    func stop() {
        analyzer = nil
        bufferCounter = 0
    }
}

@available(iOS 15, *)
extension SoundClassificationService: SNResultsObserving {
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classifications = result as? SNClassificationResult else { return }

        let mappings: [(id: String, type: SoundEventType, minConf: Double)] = [
            // Personal sleep sounds
            ("snoring",              .snoring,    0.40),
            ("snoring_breathing",    .snoring,    0.40),
            ("speech",               .talking,    0.45),
            ("cough",                .coughing,   0.40),
            ("coughing",             .coughing,   0.40),
            ("sneezing",             .sneezing,   0.45),
            ("sneeze",               .sneezing,   0.45),
            ("teeth_chattering",     .bruxism,    0.35),
            ("teeth_grinding",       .bruxism,    0.35),
            // Gasping / heavy breathing
            ("breathing",            .gasping,    0.50),
            ("breathing_heavily",    .gasping,    0.45),
            ("gasping",              .gasping,    0.40),
            ("choking",              .gasping,    0.40),
            // Laughing / giggling
            ("laughing",             .laughing,   0.50),
            ("laughter",             .laughing,   0.50),
            ("giggling",             .laughing,   0.45),
            // External disturbances — dog
            ("dog",                  .dogBarking, 0.40),
            ("dog_barking",          .dogBarking, 0.40),
            ("barking",              .dogBarking, 0.40),
            ("growling",             .dogBarking, 0.45),
            // Cat
            ("cat",                  .cat,        0.40),
            ("meow",                 .cat,        0.40),
            ("cat_meowing",          .cat,        0.40),
            ("purring",              .cat,        0.45),
            // Bird
            ("bird",                 .bird,       0.45),
            ("bird_song",            .bird,       0.45),
            ("bird_vocalization",    .bird,       0.45),
            ("chirping",             .bird,       0.45),
            ("crow",                 .bird,       0.50),
            // Music / TV — higher threshold: AC/fan noise is often misclassified as music
            ("music",                .music,      0.65),
            ("musical_instrument",   .music,      0.65),
            ("singing",              .music,      0.60),
            ("television",           .music,      0.60),
            // Alarms — distinct sounds, moderate threshold
            ("alarm_clock",          .alarm,      0.50),
            ("alarm",                .alarm,      0.50),
            ("smoke_detector",       .alarm,      0.50),
            ("siren",                .alarm,      0.50),
            ("fire_alarm",           .alarm,      0.50),
            ("bell",                 .alarm,      0.55),
            // Doorbell
            ("doorbell",             .doorbell,   0.45),
            ("door_bell",            .doorbell,   0.45),
            ("chime",                .doorbell,   0.50),
            // Phone
            ("telephone",            .phone,      0.50),
            ("phone_ringing",        .phone,      0.50),
            ("ringtone",             .phone,      0.50),
            ("cell_phone",           .phone,      0.50),
            // Traffic — ambient engines misclassify easily, keep threshold moderate
            ("car_horn",             .traffic,    0.50),
            ("honking",              .traffic,    0.50),
            ("vehicle",              .traffic,    0.55),
            ("engine",               .traffic,    0.60),
            ("motorcycle",           .traffic,    0.55),
            ("train",                .traffic,    0.55),
            // Baby
            ("baby_cry",             .baby,       0.45),
            ("crying",               .baby,       0.45),
            ("infant_cry",           .baby,       0.45),
            // Thunder / rain — rain on window can be confused with traffic
            ("thunder",              .thunder,    0.50),
            ("thunderstorm",         .thunder,    0.50),
            ("rain",                 .thunder,    0.55),
            ("raindrop",             .thunder,    0.55),
            // Wind
            ("wind",                 .wind,       0.50),
            ("wind_noise",           .wind,       0.50),
            ("gust_of_wind",         .wind,       0.50),
            // Knock / door — ML-primary, keep low
            ("knock",                .knock,      0.40),
            ("door_knock",           .knock,      0.40),
            ("door",                 .knock,      0.50),
            // Glass break — ML-primary, very distinct sound
            ("glass_breaking",       .glassBreak, 0.35),
            ("glass_break",          .glassBreak, 0.35),
            ("breaking",             .glassBreak, 0.45),
            ("shatter",              .glassBreak, 0.40),
            // Crowd / voices
            ("crowd",                .crowd,      0.55),
            ("applause",             .crowd,      0.55),
            ("cheering",             .crowd,      0.55),
            ("chatter",              .crowd,      0.50),
            // Water
            ("water",                .water,      0.50),
            ("running_water",        .water,      0.50),
            ("dripping",             .water,      0.50),
            ("toilet_flush",         .water,      0.50),
            ("water_tap",            .water,      0.50),
        ]

        // Pick the highest-confidence match — threshold nudged by user feedback stored in UserDefaults.
        var best: (type: SoundEventType, confidence: Double)? = nil
        for (id, type, baseConf) in mappings {
            let minConf = adjustedThreshold(for: type, base: baseConf)
            if let c = classifications.classification(forIdentifier: id),
               c.confidence >= minConf,
               c.confidence > (best?.confidence ?? 0) {
                best = (type, c.confidence)
            }
        }
        if let best {
            DispatchQueue.main.async { [weak self] in
                self?.onSoundDetected?(best.type, best.confidence)
            }
        }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {}

    /// Adjusts the base confidence threshold using cumulative user feedback stored in UserDefaults.
    /// False positives (rejections) raise the threshold; missed detections lower it.
    private func adjustedThreshold(for type: SoundEventType, base: Double) -> Double {
        let ud = UserDefaults.standard
        let confirmed = ud.integer(forKey: "soundFeedback.\(type.rawValue).confirmed")
        let rejected  = ud.integer(forKey: "soundFeedback.\(type.rawValue).rejected")
        let missed    = ud.integer(forKey: "soundFeedback.\(type.rawValue).missed")
        let total = confirmed + rejected + missed
        guard total >= 5 else { return base }
        let fpr = Double(rejected) / Double(max(1, confirmed + rejected))
        let mr  = Double(missed)   / Double(max(1, confirmed + missed))
        let adjustment = (fpr - mr) * 0.10
        return min(0.90, max(0.20, base + adjustment))
    }
}
