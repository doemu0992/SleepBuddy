import SoundAnalysis
import AVFoundation
import Observation
import CoreMedia
import Accelerate

@Observable
final class SoundClassificationService: NSObject {
    /// (type, confidence, label) — `label` carries the specific German sound name for
    /// catch-all `.ambient` events, nil for the 24 named categories.
    var onSoundDetected: ((SoundEventType, Double, String?) -> Void)?

    /// Global sensitivity: subtracted from every per-class confidence threshold.
    /// Higher = more (and quieter) detections. Single knob to tune overall recall.
    static let sensitivityOffset: Double = 0.12

    /// Catch-all: any Apple class NOT explicitly mapped above is still captured as `.other`
    /// when it is the top result above this confidence — so effectively ALL ~300 classes are
    /// active. Set `catchAllEnabled = false` to fall back to the curated mappings only.
    static let catchAllEnabled = true
    // Catch-all is the lowest-priority detector and shares the single event pipeline, so keep
    // it conservative: only clearly-confident ambient sounds, to avoid crowding out named
    // sounds (snoring etc.). Named sounds additionally pre-empt / bypass catch-all events.
    static let catchAllThreshold = 0.62

    /// Continuous / noise-floor / irrelevant Apple classes excluded from the catch-all.
    /// These run for minutes (AC, fan, clock, ocean, fire, appliances, vehicles idling) and
    /// would otherwise spam events + 30s clips all night long.
    static let catchAllExcluded: Set<String> = [
        "silence", "air_conditioner", "mechanical_fan", "clock", "tick", "tick_tock",
        "ocean", "sea_waves", "waterfall", "fire", "fire_crackle", "boiling",
        "vacuum_cleaner", "hair_dryer", "electric_shaver", "blender", "microwave_oven",
        "sewing_machine", "printer", "drill", "chainsaw", "lawn_mower", "power_tool",
        "hedge_trimmer", "engine_idling", "engine_accelerating_revving", "water_pump",
        "underwater_bubbling", "white_noise", "static",
    ]

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

    /// Identifiers that have an explicit mapping above (so the catch-all skips them).
    static let mappedIDs: Set<String> = Set(mappings.map { $0.id })

    /// German display names for catch-all (.ambient) sounds. Curated for the classes most
    /// likely at night; anything else falls back to a humanised version of the identifier.
    private static let germanNames: [String: String] = [
        "typing": "Tippen", "typing_computer_keyboard": "Tastatur-Tippen", "keyboard_musical": "Keyboard",
        "writing": "Schreiben", "clapping": "Klatschen", "footsteps": "Schritte",
        "person_walking": "Schritte", "person_running": "Laufen", "person_shuffling": "Schlurfen",
        "cutlery_silverware": "Besteck", "dishes_pots_pans": "Geschirr", "coin_dropping": "Münze",
        "keys_jangling": "Schlüssel", "zipper": "Reißverschluss", "drawer_open_close": "Schublade",
        "door_sliding": "Schiebetür", "scissors": "Schere", "camera": "Kamera",
        "snoring": "Schnarchen", "burp": "Rülpsen", "hiccup": "Schluckauf", "sigh": "Seufzen",
        "nose_blowing": "Naseschnäuzen", "gargling": "Gurgeln", "slurp": "Schlürfen",
        "humming": "Summen", "whistling": "Pfeifen", "yodeling": "Jodeln",
        "duck_quack": "Ente", "frog_croak": "Frosch", "owl_hoot": "Eule", "cricket_chirp": "Grille",
        "insect": "Insekt", "bee_buzz": "Biene", "mosquito_buzz": "Mücke", "fly_buzz": "Fliege",
        "horse_neigh": "Pferd", "sheep_bleat": "Schaf", "pig_oink": "Schwein", "cow_moo": "Kuh",
        "chicken_cluck": "Huhn", "rooster_crow": "Hahn", "snake_hiss": "Schlange",
        "gunshot_gunfire": "Schuss", "fireworks": "Feuerwerk", "firecracker": "Knaller",
        "boom": "Knall", "thump_thud": "Dumpfer Schlag", "wood_cracking": "Holzknacken",
        "tearing": "Reißen", "crumpling_crinkling": "Knistern", "squeak": "Quietschen",
        "hammer": "Hammer", "click": "Klicken", "beep": "Piepton", "boiling": "Kochen",
        "liquid_pouring": "Eingießen", "frying_food": "Braten", "chopping_food": "Schneiden",
        "helicopter": "Hubschrauber", "airplane": "Flugzeug", "aircraft": "Flugzeug",
        "train_horn": "Zughupe", "train_whistle": "Zugpfiff", "church_bell": "Kirchenglocke",
        "wind_chime": "Windspiel", "singing_bowl": "Klangschale",
    ]

    /// All Apple .version1 classes as (identifier, German name), sorted by German name.
    /// Used by the correction sheet so a sound can be relabelled to any of the ~300 classes.
    @available(iOS 15, *)
    static func allClasses() -> [(id: String, german: String)] {
        guard let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return [] }
        return request.knownClassifications
            .map { (id: $0, german: germanName(for: $0)) }
            .sorted { $0.german.localizedCaseInsensitiveCompare($1.german) == .orderedAscending }
    }

    static func germanName(for identifier: String) -> String {
        if let g = germanNames[identifier] { return g }
        // Humanise: "typing_computer_keyboard" -> "Typing Computer Keyboard"
        return identifier
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private var analyzer: SNAudioStreamAnalyzer?
    private let analysisQueue = DispatchQueue(label: "com.sleepbuddy.soundanalysis", qos: .utility)
    private var bufferCounter = 0
    private let analyzeEveryN = 1  // analyze every buffer for maximum night detection accuracy

    func start(format: AVAudioFormat) {
        guard #available(iOS 15, *) else { return }
        do {
            try? "# SLEEPBUDDY ML-LOG — Start \(Date())\n".write(to: Self.mlLogURL, atomically: true, encoding: .utf8)
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
        //
        // ADAPTIV statt fix ×8 (bindend, nachtbelegt): Spielt der Sonar-Ton, senkt
        // die Mikrofon-Hardware ihre Eingangsempfindlichkeit um ~10–12 dB (Boden real
        // 15–25 dB statt 27–45 dB) — mit fixem Gain brachen alle ML-Konfidenzen ein
        // und eine Nacht mit ECHTEM Schnarchen lieferte null benannte Erkennungen.
        // Der Gain richtet sich nach dem RUHEBODEN (Decay-Min-Tracker: fällt sofort
        // auf leise Buffer, steigt nur ~2 %/s) — Events ziehen ihn NICHT runter
        // (keine AGC-Wirkung auf das Schnarchen selbst). gain = 0.008 / floor,
        // geklemmt 4…48: bei ~30-dB-Boden ergibt das ×8 (= alter Fixwert, kein
        // Verhalten-Bruch ohne Sonar), bei ~20-dB-Sonar-Boden ×25.
        if let ch = buffer.floatChannelData?[0] {
            var rms: Float = 0
            vDSP_rmsqv(ch, 1, &rms, vDSP_Length(buffer.frameLength))
            if rms > 1e-7 {
                floorRMS = min(floorRMS * 1.0005, max(rms, 1e-6))
                adaptiveGain = min(max(0.008 / floorRMS, 4.0), 48.0)
            }
        }
        let boosted = Self.applyGain(buffer, gain: adaptiveGain) ?? buffer
        // EIGENER monotoner Positionszähler statt time.sampleTime (bindend, nachtbelegt):
        // Beim Bildschirm-Sperren rekonfiguriert sich die Audio-Route und der Tap-Zähler
        // kann zurückspringen. SNAudioStreamAnalyzer verlangt streng monotone Positionen
        // und verwirft nach einem Rückwärtssprung STILL alle weiteren Buffer — das ML-Log
        // bewies es: letzte Ergebnisse ~35 s nach Start (Sperren), danach die ganze Nacht
        // nichts, auf beiden Geräten. Events gab es nur bei Bildschirm-an (Start/Wecker).
        let pos = framePosition
        framePosition += Int64(buffer.frameLength)
        analysisQueue.async {
            analyzer.analyze(boosted, atAudioFramePosition: pos)
        }
    }

    // Monoton wachsende Analyzer-Position (unabhängig von Route-/Engine-Neustarts).
    private var framePosition: Int64 = 0

    // Ruheboden-Schätzung (Decay-Min) + daraus abgeleiteter ML-Verstärkungsfaktor.
    private var floorRMS: Float = 0.001
    private var adaptiveGain: Float = 8.0

    // ML-Klassen-Log: Top-3 Apple-Klassen alle ~30 s (Debug: sieht das Modell z.B.
    // "snoring" knapp unter der Schwelle oder gar nichts?). Datei wird bei start()
    // neu begonnen, Teil des Debug-Pakets.
    static var mlLogURL: URL {
        (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())).appendingPathComponent("MLLog.csv")
    }
    private var lastMLLogDate = Date.distantPast

    private func logTopClasses(_ result: SNClassificationResult) {
        guard Date().timeIntervalSince(lastMLLogDate) >= 30 else { return }
        lastMLLogDate = Date()
        let top = result.classifications.prefix(3)
            .map { String(format: "%@:%.2f", $0.identifier, $0.confidence) }
            .joined(separator: " ")
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        let line = "\(f.string(from: Date())),gain=\(String(format: "%.0f", adaptiveGain)),\(top)\n"
        if let h = try? FileHandle(forWritingTo: Self.mlLogURL) {
            h.seekToEndOfFile()
            if let d = line.data(using: .utf8) { h.write(d) }
            try? h.close()
        }
    }

    /// Returns a gain-scaled copy, **soft-clipped** via tanh to [-1, 1].
    /// Hard clipping (vDSP_vclip) erzeugte bei lauten Transienten (z. B. Hundegebell) harsche
    /// Oberwellen, die Apples Modell fälschlich Richtung „snoring" schoben. tanh sättigt weich:
    /// leise Signale bleiben linear verstärkt (tanh(x)≈x), laute werden ohne harte Kanten
    /// begrenzt — bessere, sauberere Klassifikation ohne Empfindlichkeitsverlust.
    private static func applyGain(_ buffer: AVAudioPCMBuffer, gain: Float) -> AVAudioPCMBuffer? {
        guard let inCh = buffer.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity),
              let outCh = out.floatChannelData else { return nil }
        out.frameLength = buffer.frameLength
        let n = vDSP_Length(buffer.frameLength)
        var g = gain
        var count = Int32(buffer.frameLength)
        for c in 0..<Int(buffer.format.channelCount) {
            vDSP_vsmul(inCh[c], 1, &g, outCh[c], 1, n)   // out = in * gain
            vvtanhf(outCh[c], outCh[c], &count)          // out = tanh(out) → weiche Sättigung
        }
        return out
    }

    func stop() {
        analyzer = nil
        bufferCounter = 0
        framePosition = 0
        floorRMS = 0.001
        adaptiveGain = 8.0
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
        logTopClasses(classifications)
        let mappings = SoundClassificationService.mappings

        // Pick the highest-confidence match — threshold nudged by user feedback stored in UserDefaults.
        // A global sensitivity offset lowers ALL thresholds uniformly (single tuning
        // knob) — raise it to catch more / quieter sounds, lower it to reduce noise.
        func selectBest(excluding excluded: SoundEventType?) -> (type: SoundEventType, confidence: Double, label: String?)? {
            var b: (type: SoundEventType, confidence: Double, label: String?)? = nil
            for (id, type, baseConf) in mappings {
                if type == excluded { continue }
                // Snoring already detects well — keep its proven threshold; lower the rest.
                let offset = type == .snoring ? 0.0 : Self.sensitivityOffset
                let minConf = max(0.25, adjustedThreshold(for: type, base: baseConf) - offset)
                if let c = classifications.classification(forIdentifier: id),
                   c.confidence >= minConf,
                   c.confidence > (b?.confidence ?? 0) {
                    b = (type, c.confidence, nil)
                }
            }
            return b
        }

        var best = selectBest(excluding: nil)

        // Schnarch-Verwechslungs-Schutz (bindend): Apples Modell labelt tieffrequente Geräusche
        // — v.a. Hundegebell/-knurren, aber auch andere Tiere — gelegentlich als „snoring".
        // Echtes Schnarchen aktiviert diese Klassen NICHT. Ist also eine Tier-/Fremdklasse klar
        // mit präsent, ist es kein Schnarchen → neu wählen ohne Schnarchen (labelt korrekt den Hund).
        if best?.type == .snoring {
            let competitorIDs = ["dog", "dog_bark", "dog_bow_wow", "dog_howl", "dog_growl",
                                 "dog_whimper", "bark", "bow_wow", "animal", "domestic_animals_pets",
                                 "cat", "cat_meow", "bird", "livestock_farm_animals_working_animals",
                                 "rooster", "crowing_cock_a_doodle_doo", "growling", "whimper_dog"]
            let competingConf = competitorIDs
                .compactMap { classifications.classification(forIdentifier: $0)?.confidence }
                .max() ?? 0
            // Auch wenn Apples #1-Klasse (höchste Konfidenz überhaupt) eine Tier-Klasse ist,
            // obwohl sie unter ihrer eigenen Schwelle liegt: dann ist es kein Schnarchen.
            let topIsAnimal = classifications.classifications.first.map { competitorIDs.contains($0.identifier) } ?? false
            // Schon eine schwache Tier-Aktivierung (≥ 0.08) reicht, um Schnarchen zu vetoen —
            // echtes Schnarchen aktiviert Hunde-/Tierklassen praktisch gar nicht. Ein einzelner
            // verworfener Frame schadet der Schnarch-Zählung nicht (Schnarchen feuert über viele
            // Frames); ein Bellen wird so nicht mehr als Schnarchen gelabelt.
            if competingConf >= 0.08 || topIsAnimal {
                best = selectBest(excluding: .snoring)
            }
        }
        // Catch-all: no explicit mapping fired → capture any other recognised, abgrenzbares
        // sound as .ambient ("Umgebungsgeräusch") WITH its specific German name (so it is not
        // mislabelled as generic "Geräusch"). Effectively all ~300 Apple classes are active,
        // skipping the excluded continuous/noise classes that would spam events all night.
        if best == nil, Self.catchAllEnabled {
            for c in classifications.classifications
            where c.confidence >= Self.catchAllThreshold
                && !Self.mappedIDs.contains(c.identifier)
                && !Self.catchAllExcluded.contains(c.identifier) {
                best = (.ambient, c.confidence, Self.germanName(for: c.identifier))
                break   // classifications are sorted by confidence → first is the top
            }
        }

        if let best {
            DispatchQueue.main.async { [weak self] in
                self?.onSoundDetected?(best.type, best.confidence, best.label)
            }
        }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        // Fehler sichtbar machen — ein stilles Analyzer-Sterben kostete uns Nächte.
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        let line = "\(f.string(from: Date())),FEHLER,\(error.localizedDescription)\n"
        if let h = try? FileHandle(forWritingTo: Self.mlLogURL) {
            h.seekToEndOfFile()
            if let d = line.data(using: .utf8) { h.write(d) }
            try? h.close()
        }
    }

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
