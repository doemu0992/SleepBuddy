import SwiftUI

enum SleepPhaseType: String, Codable, CaseIterable {
    case awake = "Wach"
    case light = "Leichtschlaf"
    case deep  = "Tiefschlaf"
    case rem   = "REM"

    var color: Color {
        switch self {
        case .awake: return .orange
        case .light: return .blue
        case .deep:  return .indigo
        case .rem:   return .purple
        }
    }

    var icon: String {
        switch self {
        case .awake: return "eye.fill"
        case .light: return "moon"
        case .deep:  return "moon.fill"
        case .rem:   return "sparkles"
        }
    }
}
