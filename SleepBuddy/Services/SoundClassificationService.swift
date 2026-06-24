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
            ("snoring", .snoring, 0.50),
            ("speech", .talking, 0.55),
            ("cough", .coughing, 0.50),    // lowered: coughs vary a lot in volume
            ("coughing", .coughing, 0.50),
            ("teeth_chattering", .bruxism, 0.40),  // bruxism is subtle — lower bar
            ("teeth_grinding", .bruxism, 0.40),
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
