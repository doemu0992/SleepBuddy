import SwiftData
import Foundation

// MARK: - V1 Schema (original, before CloudKit inverse-relationship fix)

enum SleepSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] = [
        SleepSchemaV1.SleepSession.self,
        SleepSchemaV1.SleepPhase.self,
        SleepSchemaV1.SleepSoundEvent.self
    ]

    @Model final class SleepSession {
        var startDate: Date = Date()
        var endDate: Date?
        @Relationship(deleteRule: .cascade) var phases: [SleepPhase] = []
        var sleepQualityScore: Double?
        var healthKitSampleID: String?
        var sleepOnsetDate: Date?
        var snoringEventCount: Int = 0
        var alarmEarliestTime: Date?
        var alarmLatestTime: Date?
        var alarmFiredDate: Date?
        @Relationship(deleteRule: .cascade) var soundEvents: [SleepSoundEvent] = []
        init(startDate: Date = .now) { self.startDate = startDate }
    }

    @Model final class SleepPhase {
        var startDate: Date = Date()
        var endDate: Date = Date()
        var phaseTypeRaw: String = "awake"
        var confidence: Double = 1.0
        init(startDate: Date, endDate: Date, phaseTypeRaw: String, confidence: Double) {
            self.startDate = startDate; self.endDate = endDate
            self.phaseTypeRaw = phaseTypeRaw; self.confidence = confidence
        }
    }

    @Model final class SleepSoundEvent {
        var timestamp: Date = Date()
        var typeRaw: String = "Geräusch"
        var durationSeconds: Double = 0.0
        var iCloudFileName: String?
        var decibelLevel: Double = 0.0
        var confidenceScore: Double = 0.0
        init(timestamp: Date, typeRaw: String, durationSeconds: Double) {
            self.timestamp = timestamp; self.typeRaw = typeRaw; self.durationSeconds = durationSeconds
        }
    }
}

// MARK: - V2 Schema (current, with CloudKit inverse relationships)

enum SleepSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] = [
        SleepSession.self,
        SleepPhase.self,
        SleepSoundEvent.self
    ]
}

// MARK: - Migration Plan

enum SleepMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] = [
        SleepSchemaV1.self,
        SleepSchemaV2.self
    ]
    static var stages: [MigrationStage] = [
        // Lightweight: adds optional inverse relationships and defaults — no data transformation needed
        .lightweight(fromVersion: SleepSchemaV1.self, toVersion: SleepSchemaV2.self)
    ]
}
