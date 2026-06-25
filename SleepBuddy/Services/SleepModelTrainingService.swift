import CreateML
import CoreML
import Foundation
import SwiftData

/// Trains a personal CoreML BoostedTree classifier from the user's accumulated TrainingSamples.
/// Called once per night after session ends. Model is saved to Application Support and loaded
/// by MLSleepClassifier on the next launch (or immediately via reloadModel()).
actor SleepModelTrainingService {

    static let shared = SleepModelTrainingService()

    private(set) var isTraining = false
    private(set) var lastTrainingDate: Date? = nil
    private(set) var lastTrainingAccuracy: Double? = nil

    // MARK: - Model Location

    static var trainedModelURL: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("SleepPhaseClassifier.mlmodelc")
    }

    static var isTrainedModelAvailable: Bool {
        guard let url = trainedModelURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    struct QualityWindow {
        let start: Date
        let end: Date
        let quality: Int  // 1–5, 0 = unrated
    }

    // MARK: - Training

    /// Trains a BoostedTreeClassifier on the given samples and saves the compiled model.
    /// qualityWindows: session time ranges + subjective rating for sample weighting.
    /// Weight table: 5★→3×, 4★→2×, 3★→1×, 2★→1×, 1★→excluded, 0→1×
    func train(samples: [TrainingSample], qualityWindows: [QualityWindow] = []) async {
        guard !isTraining, samples.count >= 40 else { return }
        let labels = Set(samples.map(\.label))
        guard labels.count >= 2 else { return }

        isTraining = true
        defer { isTraining = false }

        do {
            let tempDir = FileManager.default.temporaryDirectory
            let csvURL = tempDir.appendingPathComponent("sleep_train_\(Int(Date().timeIntervalSince1970)).csv")
            let csv = buildWeightedCSV(from: samples, qualityWindows: qualityWindows)
            guard !csv.isEmpty else { return }
            try csv.write(to: csvURL, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: csvURL) }

            let table = try MLDataTable(contentsOf: csvURL)
            guard table.size > 0 else { return }

            var params = MLBoostedTreeClassifier.ModelParameters()
            params.maxDepth = 5
            params.maxIterations = 80

            let classifier = try MLBoostedTreeClassifier(
                trainingData: table,
                targetColumn: "phase",
                parameters: params
            )

            lastTrainingAccuracy = 1.0 - classifier.trainingMetrics.classificationError

            let mlmodelURL = tempDir.appendingPathComponent("SleepPhaseClassifier_\(Int(Date().timeIntervalSince1970)).mlmodel")
            try classifier.write(to: mlmodelURL)
            defer { try? FileManager.default.removeItem(at: mlmodelURL) }

            let compiledTempURL = try MLModel.compileModel(at: mlmodelURL)

            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

            let destURL = appSupport.appendingPathComponent("SleepPhaseClassifier.mlmodelc")
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.moveItem(at: compiledTempURL, to: destURL)

            lastTrainingDate = Date()

            await MainActor.run {
                NotificationCenter.default.post(name: .sleepModelRetrained, object: nil)
            }

        } catch {
            // Non-critical — k-NN continues working
        }
    }

    // MARK: - Weighted CSV Builder

    /// Builds a CSV with rows duplicated according to both subjective quality and isUserCorrected.
    /// Quality weights: 5★→3×, 4★→2×, 3★→1×, 2★→1×, 1★→excluded, 0→1×
    /// User-corrected samples get an extra copy on top of quality weight.
    private func buildWeightedCSV(from samples: [TrainingSample], qualityWindows: [QualityWindow]) -> String {
        let header = "averageAmplitude,amplitudeVariance,breathingRateBPM,breathingRegularity,movementIntensity,snoringIntensity,phase"
        var lines = [header]

        for s in samples {
            let quality = qualityWindows.first(where: { s.timestamp >= $0.start && s.timestamp <= $0.end })?.quality ?? 0
            // Exclude 1-star nights — classifier was probably wrong on these
            if quality == 1 { continue }

            let baseMultiplier: Int
            switch quality {
            case 5: baseMultiplier = 3
            case 4: baseMultiplier = 2
            default: baseMultiplier = 1
            }
            // User-manually-corrected samples get +1 extra copy on top
            let copies = s.isUserCorrected ? baseMultiplier + 1 : baseMultiplier

            let row = "\(s.averageAmplitude),\(s.amplitudeVariance),\(s.breathingRateBPM),\(s.breathingRegularity),\(s.movementIntensity),\(s.snoringIntensity),\(s.label)"
            for _ in 0..<copies { lines.append(row) }
        }

        return lines.joined(separator: "\n")
    }
}


extension Notification.Name {
    static let sleepModelRetrained = Notification.Name("sleepbuddy.model.retrained")
}
