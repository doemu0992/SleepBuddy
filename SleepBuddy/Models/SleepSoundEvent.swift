import Foundation
import SwiftData
import SwiftUI

enum SoundEventType: String, Codable, CaseIterable {
    case snoring = "Schnarchen"
    case talking = "Sprechen"
    case other = "Geräusch"

    var icon: String {
        switch self {
        case .snoring: return "waveform"
        case .talking: return "bubble.left.fill"
        case .other:   return "speaker.wave.2.fill"
        }
    }

    var color: Color {
        switch self {
        case .snoring: return .orange
        case .talking: return .blue
        case .other:   return .secondary
        }
    }
}

@Model
final class SleepSoundEvent {
    var timestamp: Date
    var typeRaw: String
    var durationSeconds: Double
    var iCloudFileName: String?

    init(timestamp: Date, type: SoundEventType, durationSeconds: Double, iCloudFileName: String? = nil) {
        self.timestamp = timestamp
        self.typeRaw = type.rawValue
        self.durationSeconds = durationSeconds
        self.iCloudFileName = iCloudFileName
    }

    var type: SoundEventType {
        SoundEventType(rawValue: typeRaw) ?? .other
    }
}
