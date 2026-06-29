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
    case gasping   = "Keuchen"
    case laughing  = "Lachen"
    case other     = "Geräusch"
    // External / ambient disturbances
    case ambient    = "Umgebungsgeräusch"   // catch-all for recognised but uncategorised external sounds
    case dogBarking = "Hundebellen"
    case cat        = "Katze"
    case bird       = "Vogel"
    case music      = "Musik/TV"
    case alarm      = "Alarm"
    case doorbell   = "Türklingel"
    case phone      = "Telefon"
    case traffic    = "Verkehr"
    case baby       = "Babyweinen"
    case thunder    = "Donner/Regen"
    case wind       = "Wind"
    case knock      = "Klopfen"
    case glassBreak = "Glasbruch"
    case crowd      = "Stimmengewirr"
    case water      = "Wasser"

    var icon: String {
        switch self {
        case .snoring:    return "waveform"
        case .talking:    return "bubble.left.fill"
        case .other:      return "speaker.wave.2.fill"
        case .ambient:    return "waveform.badge.magnifyingglass"
        case .bruxism:    return "mouth.fill"
        case .coughing:   return "lungs.fill"
        case .sneezing:   return "wind"
        case .gasping:    return "waveform.path.ecg"
        case .laughing:   return "face.smiling.fill"
        case .dogBarking: return "pawprint.fill"
        case .cat:        return "pawprint"
        case .bird:       return "bird.fill"
        case .music:      return "music.note"
        case .alarm:      return "bell.fill"
        case .doorbell:   return "bell.and.waves.left.and.right.fill"
        case .phone:      return "phone.fill"
        case .traffic:    return "car.fill"
        case .baby:       return "figure.and.child.holdinghands"
        case .thunder:    return "cloud.bolt.fill"
        case .wind:       return "wind"
        case .knock:      return "hand.raised.fill"
        case .glassBreak: return "exclamationmark.triangle.fill"
        case .crowd:      return "person.3.fill"
        case .water:      return "drop.fill"
        }
    }

    var color: Color {
        switch self {
        case .snoring:    return .orange
        case .talking:    return .blue
        case .other:      return .secondary
        case .ambient:    return .gray
        case .bruxism:    return .pink
        case .coughing:   return .teal
        case .sneezing:   return .teal
        case .gasping:    return .red
        case .laughing:   return .yellow
        case .dogBarking: return .brown
        case .cat:        return .brown
        case .bird:       return .green
        case .music:      return .indigo
        case .alarm:      return .red
        case .doorbell:   return .orange
        case .phone:      return .green
        case .traffic:    return .gray
        case .baby:       return .mint
        case .thunder:    return .cyan
        case .wind:       return .cyan
        case .knock:      return .secondary
        case .glassBreak: return .red
        case .crowd:      return .purple
        case .water:      return .blue
        }
    }

    /// External disturbances (from the environment, not the sleeping person).
    var isExternal: Bool {
        switch self {
        case .ambient, .dogBarking, .cat, .bird, .music, .alarm, .doorbell, .phone,
             .traffic, .baby, .thunder, .wind, .knock, .glassBreak, .crowd, .water:
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
    // User feedback — nil = not yet reviewed
    var isUserCorrected: Bool = false
    var originalTypeRaw: String?    // original ML type before correction
    /// For catch-all (.ambient) events: the specific recognised sound name (German),
    /// e.g. "Tippen", "Staubsauger". nil for the 24 named categories.
    var mlLabel: String?

    init(timestamp: Date, type: SoundEventType, durationSeconds: Double, iCloudFileName: String? = nil, decibelLevel: Double = 0.0, confidenceScore: Double = 0.0, mlLabel: String? = nil) {
        self.timestamp = timestamp
        self.typeRaw = type.rawValue
        self.durationSeconds = durationSeconds
        self.iCloudFileName = iCloudFileName
        self.decibelLevel = decibelLevel
        self.confidenceScore = confidenceScore
        self.mlLabel = mlLabel
    }

    var type: SoundEventType {
        SoundEventType(rawValue: typeRaw) ?? .other
    }

    /// Name to show in the UI: the specific recognised sound when available, else the category.
    var displayName: String {
        if let mlLabel, !mlLabel.isEmpty { return mlLabel }
        return type.rawValue
    }

    var originalType: SoundEventType? {
        guard let raw = originalTypeRaw else { return nil }
        return SoundEventType(rawValue: raw)
    }
}
