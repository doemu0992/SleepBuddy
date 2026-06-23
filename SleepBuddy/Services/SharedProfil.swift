import Foundation
import Observation

private let kAppGroup = "group.com.doemu0992.sleepbuddy"

@Observable
final class SharedProfil {
    static let shared = SharedProfil()

    private let defaults = UserDefaults(suiteName: kAppGroup)

    var vorname: String {
        get { defaults?.string(forKey: "shared_vorname") ?? "" }
        set { defaults?.set(newValue, forKey: "shared_vorname") }
    }

    var nachname: String {
        get { defaults?.string(forKey: "shared_nachname") ?? "" }
        set { defaults?.set(newValue, forKey: "shared_nachname") }
    }

    var geburtsdatum: Date? {
        get {
            let ts = defaults?.double(forKey: "shared_geburtsdatum") ?? 0
            return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
        }
        set {
            defaults?.set(newValue.map { $0.timeIntervalSince1970 } ?? 0.0, forKey: "shared_geburtsdatum")
        }
    }

    var geschlecht: String {
        get { defaults?.string(forKey: "shared_geschlecht") ?? "" }
        set { defaults?.set(newValue, forKey: "shared_geschlecht") }
    }

    var anzeigeName: String {
        let n = "\(vorname) \(nachname)".trimmingCharacters(in: .whitespaces)
        return n
    }

    private init() {}
}
