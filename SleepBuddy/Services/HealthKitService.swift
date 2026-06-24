import HealthKit
import Foundation

@Observable
final class HealthKitService {
    private let store = HKHealthStore()

    private let sleepType  = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
    private let hrType     = HKObjectType.quantityType(forIdentifier: .heartRate)!
    private let hrvType    = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!
    private let spo2Type   = HKObjectType.quantityType(forIdentifier: .oxygenSaturation)!

    var isAuthorized: Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        return store.authorizationStatus(for: sleepType) == .sharingAuthorized
    }

    var hasHeartRateAccess: Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        return store.authorizationStatus(for: hrType) != .notDetermined
    }

    var hasSpO2Access: Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        return store.authorizationStatus(for: spo2Type) != .notDetermined
    }

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try? await store.requestAuthorization(
            toShare: [sleepType],
            read: [hrType, hrvType, spo2Type]
        )
    }

    // MARK: - Heart Rate for a time window

    func heartRateSummary(from start: Date, to end: Date) async -> (avgBPM: Double, sdnnMs: Double)? {
        guard HKHealthStore.isHealthDataAvailable() else { return nil }

        async let bpm  = averageHR(from: start, to: end)
        async let sdnn = latestHRV(from: start, to: end)
        let (b, s) = await (bpm, sdnn)
        guard let b else { return nil }
        return (b, s ?? 0)
    }

    private func averageHR(from start: Date, to end: Date) async -> Double? {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let descriptor = HKStatisticsQueryDescriptor(
            quantitySamples: HKSamplePredicate.quantitySample(type: hrType, predicate: predicate),
            options: .discreteAverage
        )
        guard let stats = try? await descriptor.result(for: store),
              let qty = stats.averageQuantity() else { return nil }
        return qty.doubleValue(for: .count().unitDivided(by: .minute()))
    }

    private func latestHRV(from start: Date, to end: Date) async -> Double? {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let descriptor = HKStatisticsQueryDescriptor(
            quantitySamples: HKSamplePredicate.quantitySample(type: hrvType, predicate: predicate),
            options: .discreteAverage
        )
        guard let stats = try? await descriptor.result(for: store),
              let qty = stats.averageQuantity() else { return nil }
        return qty.doubleValue(for: .secondUnit(with: .milli))
    }

    // MARK: - SpO₂ for a sleep session

    /// Returns average blood oxygen saturation (0–1) over the session duration.
    func averageSpO2(from start: Date, to end: Date) async -> Double? {
        guard HKHealthStore.isHealthDataAvailable() else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let descriptor = HKStatisticsQueryDescriptor(
            quantitySamples: HKSamplePredicate.quantitySample(type: spo2Type, predicate: predicate),
            options: .discreteAverage
        )
        guard let stats = try? await descriptor.result(for: store),
              let qty = stats.averageQuantity() else { return nil }
        return qty.doubleValue(for: .percent())
    }

    // MARK: - Real-time heart rate during sleep

    private var hrObserverTask: Task<Void, Never>?

    func startHeartRatePolling(onUpdate: @escaping (Double, Double?) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        hrObserverTask = Task {
            while !Task.isCancelled {
                let end   = Date()
                let start = end.addingTimeInterval(-300)
                if let result = await heartRateSummary(from: start, to: end) {
                    onUpdate(result.avgBPM, result.sdnnMs > 0 ? result.sdnnMs : nil)
                }
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    func stopHeartRatePolling() {
        hrObserverTask?.cancel()
        hrObserverTask = nil
    }

    // MARK: - Sleep export

    func saveSleepSession(_ session: SleepSession) async throws {
        guard isAuthorized, let endDate = session.endDate else { return }

        var samples: [HKCategorySample] = []

        let inBed = HKCategorySample(
            type: sleepType,
            value: HKCategoryValueSleepAnalysis.inBed.rawValue,
            start: session.startDate,
            end: endDate
        )
        samples.append(inBed)

        for phase in session.phasesArray {
            let value = hkValue(for: phase.phaseType)
            let sample = HKCategorySample(
                type: sleepType,
                value: value,
                start: phase.startDate,
                end: phase.endDate
            )
            samples.append(sample)
        }

        try await store.save(samples)
    }

    private func hkValue(for phase: SleepPhaseType) -> Int {
        switch phase {
        case .awake: return HKCategoryValueSleepAnalysis.awake.rawValue
        case .light: return HKCategoryValueSleepAnalysis.asleepCore.rawValue
        case .deep:  return HKCategoryValueSleepAnalysis.asleepDeep.rawValue
        case .rem:   return HKCategoryValueSleepAnalysis.asleepREM.rawValue
        }
    }

    // MARK: - Heart Rate for a time window

    /// Returns average heart rate (bpm) and SDNN (ms) for the given interval.
    /// Returns nil if no Apple Watch data is available.
    func heartRateSummary(from start: Date, to end: Date) async -> (avgBPM: Double, sdnnMs: Double)? {
        guard HKHealthStore.isHealthDataAvailable() else { return nil }

        async let bpm  = averageHR(from: start, to: end)
        async let sdnn = latestHRV(from: start, to: end)
        let (b, s) = await (bpm, sdnn)
        guard let b else { return nil }
        return (b, s ?? 0)
    }

    private func averageHR(from start: Date, to end: Date) async -> Double? {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let descriptor = HKStatisticsQueryDescriptor(
            quantitySamples: HKSamplePredicate.quantitySample(type: hrType, predicate: predicate),
            options: .discreteAverage
        )
        guard let stats = try? await descriptor.result(for: store),
              let qty = stats.averageQuantity() else { return nil }
        return qty.doubleValue(for: .count().unitDivided(by: .minute()))
    }

    private func latestHRV(from start: Date, to end: Date) async -> Double? {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let descriptor = HKStatisticsQueryDescriptor(
            quantitySamples: HKSamplePredicate.quantitySample(type: hrvType, predicate: predicate),
            options: .discreteAverage
        )
        guard let stats = try? await descriptor.result(for: store),
              let qty = stats.averageQuantity() else { return nil }
        return qty.doubleValue(for: .secondUnit(with: .milli))
    }

    // MARK: - Real-time heart rate during sleep
    // Polls HealthKit every 5 min and delivers latest HR to the classifier.

    private var hrObserverTask: Task<Void, Never>?

    func startHeartRatePolling(onUpdate: @escaping (Double, Double?) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        hrObserverTask = Task {
            while !Task.isCancelled {
                let end   = Date()
                let start = end.addingTimeInterval(-300)  // last 5 min
                if let result = await heartRateSummary(from: start, to: end) {
                    onUpdate(result.avgBPM, result.sdnnMs > 0 ? result.sdnnMs : nil)
                }
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    func stopHeartRatePolling() {
        hrObserverTask?.cancel()
        hrObserverTask = nil
    }

    // MARK: - Sleep export

    func saveSleepSession(_ session: SleepSession) async throws {
        guard isAuthorized, let endDate = session.endDate else { return }

        var samples: [HKCategorySample] = []

        let inBed = HKCategorySample(
            type: sleepType,
            value: HKCategoryValueSleepAnalysis.inBed.rawValue,
            start: session.startDate,
            end: endDate
        )
        samples.append(inBed)

        for phase in session.phasesArray {
            let value = hkValue(for: phase.phaseType)
            let sample = HKCategorySample(
                type: sleepType,
                value: value,
                start: phase.startDate,
                end: phase.endDate
            )
            samples.append(sample)
        }

        try await store.save(samples)
    }

    private func hkValue(for phase: SleepPhaseType) -> Int {
        switch phase {
        case .awake: return HKCategoryValueSleepAnalysis.awake.rawValue
        case .light: return HKCategoryValueSleepAnalysis.asleepCore.rawValue
        case .deep:  return HKCategoryValueSleepAnalysis.asleepDeep.rawValue
        case .rem:   return HKCategoryValueSleepAnalysis.asleepREM.rawValue
        }
    }
}
