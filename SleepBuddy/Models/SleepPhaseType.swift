import SwiftUI

enum SleepPhaseType: String, Codable, CaseIterable {
    case awake = "Wach"
    case light = "Leichtschlaf"
    case deep  = "Tiefschlaf"
    case rem   = "REM"

    var color: Color {
        switch self {
        case .awake: return .orange
        case .light: return Color(red: 0.40, green: 0.65, blue: 1.0)   // Hellblau
        case .deep:  return Color(red: 0.50, green: 0.30, blue: 0.90)  // Violett
        case .rem:   return Color(red: 0.95, green: 0.35, blue: 0.65)  // Pink
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
