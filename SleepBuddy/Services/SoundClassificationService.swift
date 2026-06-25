import SoundAnalysis
import AVFoundation
import Observation
import CoreMedia

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
        analysisQueue.async {
            analyzer.analyze(buffer, atAudioFramePosition: time.sampleTime)
        }
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
            // External disturbances — dog
            ("dog",                  .dogBarking, 0.40),
            ("dog_barking",          .dogBarking, 0.40),
            ("barking",              .dogBarking, 0.40),
            // Cat
            ("cat",                  .cat,        0.40),
            ("meow",                 .cat,        0.40),
            ("cat_meowing",          .cat,        0.40),
            // Music / TV
            ("music",                .music,      0.45),
            ("musical_instrument",   .music,      0.45),
            ("singing",              .music,      0.50),
            // Alarms
            ("alarm_clock",          .alarm,      0.40),
            ("alarm",                .alarm,      0.40),
            ("smoke_detector",       .alarm,      0.40),
            ("siren",                .alarm,      0.40),
            ("fire_alarm",           .alarm,      0.40),
            ("bell",                 .alarm,      0.50),
            // Traffic
            ("car_horn",             .traffic,    0.40),
            ("honking",              .traffic,    0.40),
            ("vehicle",              .traffic,    0.45),
            ("engine",               .traffic,    0.50),
            // Baby
            ("baby_cry",             .baby,       0.40),
            ("crying",               .baby,       0.40),
            ("infant_cry",           .baby,       0.40),
            // Thunder / rain
            ("thunder",              .thunder,    0.40),
            ("thunderstorm",         .thunder,    0.40),
            ("rain",                 .thunder,    0.50),
            ("raindrop",             .thunder,    0.50),
            // Knock / door
            ("knock",                .knock,      0.40),
            ("door_knock",           .knock,      0.40),
            ("door",                 .knock,      0.50),
            // Glass break
            ("glass_breaking",       .glassBreak, 0.35),
            ("glass_break",          .glassBreak, 0.35),
            ("breaking",             .glassBreak, 0.45),
        ]

        // Pick the highest-confidence match across all mappings — not the first one that
        // passes the threshold, since multiple identifiers can match the same event.
        var best: (type: SoundEventType, confidence: Double)? = nil
        for (id, type, minConf) in mappings {
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
}
