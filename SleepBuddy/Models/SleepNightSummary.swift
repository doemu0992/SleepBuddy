import Foundation

struct SleepNightSummary: Codable {
    var datum: TimeInterval
    var qualitaet: Double
    var dauerSek: Double
    var tiefPct: Double
    var remPct: Double
    var leichtPct: Double
    var wachPct: Double
    var schnarchenAnzahl: Int
    var sprechenAnzahl: Int
    var geraeuschAnzahl: Int
}

extension SleepNightSummary {
    static let appGroupKey = "sb_sessions"
    static let appGroupSuite = "group.com.doemu0992.sleepbuddy"

    static func laden() -> [SleepNightSummary] {
        guard let defaults = UserDefaults(suiteName: appGroupSuite),
              let data = defaults.data(forKey: appGroupKey),
              let decoded = try? JSONDecoder().decode([SleepNightSummary].self, from: data)
        else { return [] }
        return decoded
    }

    static func speichern(_ summaries: [SleepNightSummary]) {
        guard let defaults = UserDefaults(suiteName: appGroupSuite),
              let data = try? JSONEncoder().encode(summaries)
        else { return }
        defaults.set(data, forKey: appGroupKey)
        defaults.set(Date().timeIntervalSince1970, forKey: "lastNightSleepQualityTimestamp")
    }
}
