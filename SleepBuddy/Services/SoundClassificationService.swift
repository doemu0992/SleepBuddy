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
    private let analyzeEveryN = 4  // run ML every 4th buffer to reduce CPU load

    func start(format: AVAudioFormat) {
        guard #available(iOS 15, *) else { return }
        do {
            analyzer = SNAudioStreamAnalyzer(format: format)
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTimeMakeWithSeconds(1.5, preferredTimescale: 44100)
            request.overlapFactor = 0.5
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
            ("snoring",          .snoring,    0.50),
            ("speech",           .talking,    0.55),
            ("cough",            .coughing,   0.50),
            ("coughing",         .coughing,   0.50),
            ("teeth_chattering", .bruxism,    0.40),
            ("teeth_grinding",   .bruxism,    0.40),
            // External disturbances
            ("dog",              .dogBarking, 0.55),
            ("dog_barking",      .dogBarking, 0.55),
            ("barking",          .dogBarking, 0.50),
            ("music",            .music,      0.60),
            ("musical_instrument", .music,    0.60),
            ("alarm_clock",      .alarm,      0.55),
            ("alarm",            .alarm,      0.55),
            ("smoke_detector",   .alarm,      0.55),
            ("siren",            .alarm,      0.55),
            ("car_horn",         .traffic,    0.55),
            ("honking",          .traffic,    0.50),
            ("vehicle",          .traffic,    0.60),
            ("baby_cry",         .baby,       0.55),
            ("crying",           .baby,       0.55),
            ("infant_cry",       .baby,       0.55),
        ]

        for (id, type, minConf) in mappings {
            if let c = classifications.classification(forIdentifier: id), c.confidence >= minConf {
                let confidence = c.confidence
                DispatchQueue.main.async { [weak self] in
                    self?.onSoundDetected?(type, confidence)
                }
                return
            }
        }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {}
}
