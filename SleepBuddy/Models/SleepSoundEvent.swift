import Foundation
import SwiftData
import SwiftUI

enum SoundEventType: String, Codable, CaseIterable {
    // Personal sleep sounds
    case snoring   = "Schnarchen"
    case talking   = "Sprechen"
    case coughing  = "Husten"
    case bruxism   = "Zähneknirschen"
    case sneezing  = "Niesen"
    case other     = "Geräusch"
    // External / ambient disturbances
    case dogBarking = "Hundebellen"
    case cat        = "Katze"
    case music      = "Musik/TV"
    case alarm      = "Alarm"
    case traffic    = "Verkehr"
    case baby       = "Babyweinen"
    case thunder    = "Donner/Regen"
    case knock      = "Klopfen"
    case glassBreak = "Glasbruch"

    var icon: String {
        switch self {
        case .snoring:    return "waveform"
        case .talking:    return "bubble.left.fill"
        case .other:      return "speaker.wave.2.fill"
        case .bruxism:    return "mouth.fill"
        case .coughing:   return "lungs.fill"
        case .sneezing:   return "wind"
        case .dogBarking: return "pawprint.fill"
        case .cat:        return "pawprint"
        case .music:      return "music.note"
        case .alarm:      return "bell.fill"
        case .traffic:    return "car.fill"
        case .baby:       return "figure.and.child.holdinghands"
        case .thunder:    return "cloud.bolt.fill"
        case .knock:      return "hand.raised.fill"
        case .glassBreak: return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .snoring:    return .orange
        case .talking:    return .blue
        case .other:      return .secondary
        case .bruxism:    return .pink
        case .coughing:   return .teal
        case .sneezing:   return .teal
        case .dogBarking: return .brown
        case .cat:        return .brown
        case .music:      return .indigo
        case .alarm:      return .red
        case .traffic:    return .gray
        case .baby:       return .mint
        case .thunder:    return .cyan
        case .knock:      return .secondary
        case .glassBreak: return .red
        }
    }

    /// External disturbances (from the environment, not the sleeping person).
    var isExternal: Bool {
        switch self {
        case .dogBarking, .cat, .music, .alarm, .traffic, .baby, .thunder, .knock, .glassBreak:
            return true
        default:
            return false
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
