import HealthKit
import Foundation

@Observable
final class HealthKitService {
    private let store = HKHealthStore()

    private let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!

    var isAuthorized: Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        return store.authorizationStatus(for: sleepType) == .sharingAuthorized
    }

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try? await store.requestAuthorization(toShare: [sleepType], read: [])
    }

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
