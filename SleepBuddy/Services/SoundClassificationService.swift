import SoundAnalysis
import AVFoundation
import Observation
import CoreMedia
import Accelerate

@Observable
final class SoundClassificationService: NSObject {
    var onSoundDetected: ((SoundEventType, Double) -> Void)?

    /// Global sensitivity: subtracted from every per-class confidence threshold.
    /// Higher = more (and quieter) detections. Single knob to tune overall recall.
    static let sensitivityOffset: Double = 0.12

    /// Apple identifier → our event type + base confidence threshold.
    /// IMPORTANT: each `id` must EXACTLY match a string in Apple's `.version1` taxonomy
    /// (`SNClassifySoundRequest(.version1).knownClassifications`). A mismatch means
    /// `classification(forIdentifier:)` returns nil and the class NEVER fires — verify with
    /// `auditText()` (Einstellungen → "Geräusch-Klassen prüfen").
    // All ids below are VERIFIED against Apple .version1 knownClassifications (303 classes).
    // Re-verify with the audit after any edit. NOTE: bruxism (teeth grinding) has NO
    // matching Apple class — it cannot be ML-detected and is left to manual correction.
    static let mappings: [(id: String, type: SoundEventType, minConf: Double)] = [
        // Personal sleep sounds
        ("snoring",                  .snoring,    0.40),
        ("speech",                   .talking,    0.45),
        ("whispering",               .talking,    0.50),
        ("cough",                    .coughing,   0.40),
        ("sneeze",                   .sneezing,   0.45),
        // Gasping / heavy breathing
        ("breathing",                .gasping,    0.50),
        ("gasp",                     .gasping,    0.40),
        // Laughing / giggling
        ("laughter",                 .laughing,   0.50),
        ("giggling",                 .laughing,   0.45),
        ("belly_laugh",              .laughing,   0.50),
        ("chuckle_chortle",          .laughing,   0.50),
        ("snicker",                  .laughing,   0.50),
        // External disturbances — dog
        ("dog",                      .dogBarking, 0.30),
        ("dog_bark",                 .dogBarking, 0.30),
        ("dog_bow_wow",              .dogBarking, 0.35),
        ("dog_howl",                 .dogBarking, 0.40),
        ("dog_growl",                .dogBarking, 0.45),
        ("dog_whimper",              .dogBarking, 0.45),
        // Cat
        ("cat",                      .cat,        0.40),
        ("cat_meow",                 .cat,        0.40),
        ("cat_purr",                 .cat,        0.45),
        // Bird
        ("bird",                     .bird,       0.45),
        ("bird_vocalization",        .bird,       0.45),
        ("bird_chirp_tweet",         .bird,       0.45),
        ("bird_squawk",              .bird,       0.50),
        ("crow_caw",                 .bird,       0.50),
        ("rooster_crow",             .bird,       0.50),
        ("owl_hoot",                 .bird,       0.45),
        ("pigeon_dove_coo",          .bird,       0.50),
        // Music — higher threshold: AC/fan noise is often misclassified as music
        ("music",                    .music,      0.65),
        ("singing",                  .music,      0.60),
        ("orchestra",                .music,      0.65),
        ("choir_singing",            .music,      0.60),
        // Alarms / sirens — distinct sounds, moderate threshold
        ("alarm_clock",              .alarm,      0.50),
        ("smoke_detector",           .alarm,      0.50),
        ("siren",                    .alarm,      0.50),
        ("civil_defense_siren",      .alarm,      0.50),
        ("police_siren",             .alarm,      0.55),
        ("ambulance_siren",          .alarm,      0.55),
        ("fire_engine_siren",        .alarm,      0.55),
        ("beep",                     .alarm,      0.55),
        ("reverse_beeps",            .alarm,      0.55),
        ("emergency_vehicle",        .alarm,      0.55),
        ("air_horn",                 .alarm,      0.55),
        ("bell",                     .alarm,      0.55),
        // Doorbell
        ("door_bell",                .doorbell,   0.45),
        ("chime",                    .doorbell,   0.50),
        // Phone
        ("telephone",                .phone,      0.50),
        ("telephone_bell_ringing",   .phone,      0.50),
        ("ringtone",                 .phone,      0.50),
        // Traffic — ambient engines misclassify easily, keep threshold moderate
        ("car_horn",                 .traffic,    0.50),
        ("traffic_noise",            .traffic,    0.55),
        ("car_passing_by",           .traffic,    0.55),
        ("engine",                   .traffic,    0.60),
        ("motorcycle",               .traffic,    0.55),
        ("truck",                    .traffic,    0.55),
        ("bus",                      .traffic,    0.55),
        ("train",                    .traffic,    0.55),
        ("train_horn",               .traffic,    0.55),
        ("train_whistle",            .traffic,    0.55),
        ("airplane",                 .traffic,    0.55),
        ("aircraft",                 .traffic,    0.55),
        ("helicopter",               .traffic,    0.55),
        // Baby
        ("baby_crying",              .baby,       0.45),
        // Thunder / rain — rain on window can be confused with traffic
        ("thunder",                  .thunder,    0.50),
        ("thunderstorm",             .thunder,    0.50),
        ("rain",                     .thunder,    0.55),
        ("raindrop",                 .thunder,    0.55),
        // Wind
        ("wind",                     .wind,       0.50),
        ("wind_noise_microphone",    .wind,       0.50),
        ("wind_rustling_leaves",     .wind,       0.55),
        // Knock / door — ML-primary, keep low
        ("knock",                    .knock,      0.40),
        ("door",                     .knock,      0.50),
        ("door_slam",                .knock,      0.45),
        ("door_sliding",             .knock,      0.50),
        ("thump_thud",               .knock,      0.50),
        // Glass break — ML-primary, very distinct sound
        ("glass_breaking",           .glassBreak, 0.35),
        // Crowd / voices
        ("crowd",                    .crowd,      0.55),
        ("chatter",                  .crowd,      0.50),
        ("babble",                   .crowd,      0.55),
        ("applause",                 .crowd,      0.55),
        ("clapping",                 .crowd,      0.55),
        ("cheering",                 .crowd,      0.55),
        ("children_shouting",        .crowd,      0.55),
        ("screaming",                .crowd,      0.55),
        ("shout",                    .crowd,      0.55),
        ("yell",                     .crowd,      0.55),
        // Water
        ("water",                    .water,      0.50),
        ("water_tap_faucet",         .water,      0.50),
        ("liquid_dripping",          .water,      0.50),
        ("sink_filling_washing",     .water,      0.55),
        ("stream_burbling",          .water,      0.55),
        ("toilet_flush",             .water,      0.50),
        ("bathtub_filling_washing",  .water,      0.55),
        ("liquid_pouring",           .water,      0.55),
    ]

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

    // MARK: - Taxonomy audit

    /// Compares our mapped identifiers against Apple's actual `.version1` taxonomy and
    /// returns a human-readable report. Identifiers Apple does not know are DEAD — they
    /// can never fire. Run from Einstellungen → "Geräusch-Klassen prüfen", then send the
    /// report so the dead mappings can be corrected to the real Apple class names.
    @available(iOS 15, *)
    static func auditText() -> String {
        guard let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else {
            return "Fehler: Apple-Klassifikator konnte nicht geladen werden."
        }
        let known = Set(request.knownClassifications)
        let ours = Array(Set(mappings.map { $0.id })).sorted()
        let unknown = ours.filter { !known.contains($0) }
        let valid = ours.filter { known.contains($0) }

        var s = "APPLE SOUND-TAXONOMIE ABGLEICH\n"
        s += "Apple .version1 kennt \(known.count) Klassen.\n"
        s += "Unsere Identifier: \(ours.count) — gültig: \(valid.count), TOT: \(unknown.count)\n\n"
        s += "❌ TOTE Identifier (Apple kennt sie NICHT → feuern NIE):\n"
        s += unknown.isEmpty ? "   (keine — alle Mappings gültig!)\n"
                             : unknown.map { "   ✗ \($0)" }.joined(separator: "\n") + "\n"
        s += "\n✅ Gültige Identifier:\n"
        s += valid.map { "   ✓ \($0)" }.joined(separator: "\n") + "\n"
        s += "\n— — — ALLE \(known.count) APPLE-KLASSEN (an Claude schicken) — — —\n"
        s += known.sorted().joined(separator: ", ")
        return s
    }
}

@available(iOS 15, *)
extension SoundClassificationService: SNResultsObserving {
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classifications = result as? SNClassificationResult else { return }
        let mappings = SoundClassificationService.mappings

        // Pick the highest-confidence match — threshold nudged by user feedback stored in UserDefaults.
        // A global sensitivity offset lowers ALL thresholds uniformly (single tuning
        // knob) — raise it to catch more / quieter sounds, lower it to reduce noise.
        var best: (type: SoundEventType, confidence: Double)? = nil
        for (id, type, baseConf) in mappings {
            // Snoring already detects well — keep its proven threshold; lower the rest.
            let offset = type == .snoring ? 0.0 : Self.sensitivityOffset
            let minConf = max(0.25, adjustedThreshold(for: type, base: baseConf) - offset)
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
