import Foundation
import SwiftData
import SwiftUI

enum SoundEventType: String, Codable, CaseIterable {
    case snoring = "Schnarchen"
    case talking = "Sprechen"
    case other = "Geräusch"
    case bruxism = "Zähneknirschen"
    case coughing = "Husten"

    var icon: String {
        switch self {
        case .snoring:  return "waveform"
        case .talking:  return "bubble.left.fill"
        case .other:    return "speaker.wave.2.fill"
        case .bruxism:  return "mouth.fill"
        case .coughing: return "lungs.fill"
        }
    }

    var color: Color {
        switch self {
        case .snoring:  return .orange
        case .talking:  return .blue
        case .other:    return .secondary
        case .bruxism:  return .pink
        case .coughing: return .teal
        }
    }
}

@Model
final class SleepSoundEvent {
    // CloudKit: all attributes need defaults
    var timestamp: Date = Date()
    var typeRaw: String = SoundEventType.other.rawValue
    var durationSeconds: Double = 0.0
    var iCloudFileName: String?
    var decibelLevel: Double = 0.0
    var confidenceScore: Double = 0.0

    // Inverse relationship required by CloudKit
    var session: SleepSession?

    init(timestamp: Date, type: SoundEventType, durationSeconds: Double, iCloudFileName: String? = nil, decibelLevel: Double = 0.0, confidenceScore: Double = 0.0) {
        self.timestamp = timestamp
        self.typeRaw = type.rawValue
        self.durationSeconds = durationSeconds
        self.iCloudFileName = iCloudFileName
        self.decibelLevel = decibelLevel
        self.confidenceScore = confidenceScore
    }

    var type: SoundEventType {
        SoundEventType(rawValue: typeRaw) ?? .other
    }
}
