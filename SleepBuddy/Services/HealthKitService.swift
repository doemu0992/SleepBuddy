import HealthKit
import Foundation

@Observable
final class HealthKitService {
    private let store = HKHealthStore()
    private(set) var isAuthorized = false

    private let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        do {
            try await store.requestAuthorization(toShare: [sleepType], read: [])
            isAuthorized = true
        } catch {
            isAuthorized = false
        }
    }

    func saveSleepSession(_ session: SleepSession) async throws {
        guard isAuthorized, let endDate = session.endDate else { return }

        var samples: [HKCategorySample] = []

        // Overall session as inBed
        let inBed = HKCategorySample(
            type: sleepType,
            value: HKCategoryValueSleepAnalysis.inBed.rawValue,
            start: session.startDate,
            end: endDate
        )
        samples.append(inBed)

        // Individual phases as asleepUnspecified / asleepDeep / asleepREM / asleepCore
        for phase in session.phases {
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

        // Share quality score via App Group for PainDiary
        let defaults = UserDefaults(suiteName: "group.com.doemu0992.sleepbuddy")
        defaults?.set(session.computedQualityScore, forKey: "lastNightSleepQuality")
        defaults?.set(session.startDate, forKey: "lastNightSleepDate")
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
