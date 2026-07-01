import Foundation

/// Syncs app settings and profile data between UserDefaults / App Group and iCloud Key-Value Store.
/// Call `ICloudSettingsSync.start()` once on app launch.
final class ICloudSettingsSync {

    static let shared = ICloudSettingsSync()
    private let icloud = NSUbiquitousKeyValueStore.default
    private let appGroup = "group.com.doemu0992.sleepbuddy"

    // Keys synced from standard UserDefaults
    private let standardKeys: [String] = [
        "einst_erinnerung_aktiv",
        "einst_erinnerung_zeit",
        "soundEvents_enabled",
        "sonar_enabled",
        "partnerModus_aktiv",
        "partnerModus_stufe",
        "profil_paindiary_verknuepft",
        "profil_schlafziel",
        "profil_einschlafzeit_h",
        "profil_einschlafzeit_m",
        "onboardingAbgeschlossen",
    ]

    // Keys synced from App Group UserDefaults (profile/shared data)
    private let appGroupKeys: [String] = [
        "shared_vorname",
        "shared_nachname",
        "shared_geburtsdatum",
        "shared_geschlecht",
    ]

    private init() {}

    func start() {
        // Pull from iCloud → local on start
        icloud.synchronize()
        pullFromICloud()

        // Listen for iCloud changes (other device updated)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(icloudDidChange),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: icloud
        )

        // Listen for local UserDefaults changes → push to iCloud
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(defaultsDidChange),
            name: UserDefaults.didChangeNotification,
            object: UserDefaults.standard
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appGroupDefaultsDidChange),
            name: UserDefaults.didChangeNotification,
            object: UserDefaults(suiteName: appGroup)
        )
    }

    // MARK: - Pull iCloud → local

    private func pullFromICloud() {
        let standard = UserDefaults.standard
        let group = UserDefaults(suiteName: appGroup)

        for key in standardKeys {
            if let value = icloud.object(forKey: key) {
                standard.set(value, forKey: key)
            }
        }
        for key in appGroupKeys {
            if let value = icloud.object(forKey: "ag_\(key)") {
                group?.set(value, forKey: key)
            }
        }
    }

    // MARK: - Push local → iCloud

    private func pushToICloud() {
        let standard = UserDefaults.standard
        let group = UserDefaults(suiteName: appGroup)

        for key in standardKeys {
            if let value = standard.object(forKey: key) {
                icloud.set(value, forKey: key)
            }
        }
        for key in appGroupKeys {
            if let value = group?.object(forKey: key) {
                icloud.set(value, forKey: "ag_\(key)")
            }
        }
        icloud.synchronize()
    }

    @objc private func icloudDidChange(_ notification: Notification) {
        pullFromICloud()
    }

    @objc private func defaultsDidChange(_ notification: Notification) {
        pushToICloud()
    }

    @objc private func appGroupDefaultsDidChange(_ notification: Notification) {
        pushToICloud()
    }
}
