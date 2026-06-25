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

    // MARK: - Training

    /// Trains a BoostedTreeClassifier on the given samples and saves the compiled model.
    /// Requires at least 40 samples with at least 2 distinct phase labels.
    func train(samples: [TrainingSample]) async {
        guard !isTraining, samples.count >= 40 else { return }
        let labels = Set(samples.map(\.label))
        guard labels.count >= 2 else { return }

        isTraining = true
        defer { isTraining = false }

        do {
            // 1. Write CSV
            let tempDir = FileManager.default.temporaryDirectory
            let csvURL = tempDir.appendingPathComponent("sleep_train_\(Int(Date().timeIntervalSince1970)).csv")
            let csv = buildCSV(from: samples)
            try csv.write(to: csvURL, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: csvURL) }

            // 2. Build MLDataTable
            let table = try MLDataTable(contentsOf: csvURL)

            // 3. Train classifier — user-corrected samples are duplicated 3× to match k-NN weighting
            let weightedTable = weightedTable(from: samples, baseTable: table)
            var params = MLBoostedTreeClassifier.ModelParameters()
            params.maxDepth = 5
            params.maxIterations = 80

            let classifier = try MLBoostedTreeClassifier(
                trainingData: weightedTable,
                targetColumn: "phase",
                parameters: params
            )

            // Capture training accuracy before actor isolation issues
            let accuracy = classifier.trainingMetrics.classificationError
            lastTrainingAccuracy = 1.0 - accuracy

            // 4. Write .mlmodel → compile → move to ApplicationSupport
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

            // Notify MLSleepClassifier to reload on next session
            await MainActor.run {
                NotificationCenter.default.post(name: .sleepModelRetrained, object: nil)
            }

        } catch {
            // Training failure is non-critical — k-NN continues working
        }
    }

    // MARK: - CSV Builder

    private func buildCSV(from samples: [TrainingSample]) -> String {
        var lines = ["averageAmplitude,amplitudeVariance,breathingRateBPM,breathingRegularity,movementIntensity,snoringIntensity,phase"]
        for s in samples {
            let row = "\(s.averageAmplitude),\(s.amplitudeVariance),\(s.breathingRateBPM),\(s.breathingRegularity),\(s.movementIntensity),\(s.snoringIntensity),\(s.label)"
            lines.append(row)
        }
        return lines.joined(separator: "\n")
    }

    /// Duplicates user-corrected samples 3× to match the k-NN correctedWeight of 3.0.
    private func weightedTable(from samples: [TrainingSample], baseTable: MLDataTable) -> MLDataTable {
        let correctedSamples = samples.filter(\.isUserCorrected)
        guard !correctedSamples.isEmpty else { return baseTable }

        // Build extra rows CSV for corrected samples (2 extra copies = 3× total)
        var extras: [String] = []
        for s in correctedSamples {
            let row = "\(s.averageAmplitude),\(s.amplitudeVariance),\(s.breathingRateBPM),\(s.breathingRegularity),\(s.movementIntensity),\(s.snoringIntensity),\(s.label)"
            extras.append(row)
            extras.append(row)
        }
        guard !extras.isEmpty else { return baseTable }

        let tempDir = FileManager.default.temporaryDirectory
        let extraCSVURL = tempDir.appendingPathComponent("sleep_extra_\(Int(Date().timeIntervalSince1970)).csv")
        let header = "averageAmplitude,amplitudeVariance,breathingRateBPM,breathingRegularity,movementIntensity,snoringIntensity,phase"
        let csv = ([header] + extras).joined(separator: "\n")
        guard (try? csv.write(to: extraCSVURL, atomically: true, encoding: .utf8)) != nil,
              let extraTable = try? MLDataTable(contentsOf: extraCSVURL)
        else { return baseTable }
        defer { try? FileManager.default.removeItem(at: extraCSVURL) }

        return (try? baseTable.appending(extraTable)) ?? baseTable
    }
}

extension Notification.Name {
    static let sleepModelRetrained = Notification.Name("sleepbuddy.model.retrained")
}
