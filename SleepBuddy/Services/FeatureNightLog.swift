import Foundation

// MARK: - Feature-Nachtlog (Replay-Grundlage, bewusst in dieser in-Target-Datei)

/// Schreibt pro Nacht eine CSV mit ALLEN Sensor-Features pro Minute (kein Audio).
/// Zweck: Algorithmus-Änderungen offline gegen echte Nächte durchrechnen (Replay),
/// statt jede Änderung mit einer Schlafnacht zu bezahlen. Behält die letzten 14 Nächte.
final class FeatureNightLog {
    static let shared = FeatureNightLog()
    private var active = false
    private var url: URL?
    private var lastRow = Date.distantPast
    private init() {}

    static var logDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    static func allLogs() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("FeatureLog-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
    }

    func begin() {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmm"
        let file = FeatureNightLog.logDirectory.appendingPathComponent("FeatureLog-\(f.string(from: Date())).csv")
        let header = "# SLEEPBUDDY FEATURELOG — Start \(Date())\n"
            + "zeit,amp,ampVar,atem_best,reg_best,atem_audio,atem_accel,reg_accel,bewegung,onMattress,"
            + "sonar_atem,sonar_reg,sonar_bew,sonar_pegel,sonar_signal,sonar_puls,bcg_hr,watch_hr,phase\n"
        try? header.write(to: file, atomically: true, encoding: .utf8)
        url = file
        active = true
        lastRow = .distantPast
        // Rotation: nur die letzten 14 Nächte behalten.
        let logs = FeatureNightLog.allLogs()
        if logs.count > 14 { for old in logs.dropFirst(14) { try? FileManager.default.removeItem(at: old) } }
    }

    func end() { active = false; url = nil }

    /// Eine Zeile pro Minute (intern gedrosselt) — Aufruf aus handleFeatures ist billig.
    func append(audio: AudioFeatures, motion: MotionFeatures, sonar: SonarFeatures,
                sonarLevel: Float, bcgHR: Int, watchHR: Double, phase: SleepPhaseType) {
        guard active, let url, Date().timeIntervalSince(lastRow) >= 60 else { return }
        lastRow = Date()
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        let bestBreath = motion.breathingRateBPM > 0 ? motion.breathingRateBPM : audio.breathingRateBPM
        let bestReg = motion.breathingRateBPM > 0 ? motion.breathingRegularity : audio.breathingRegularity
        let line = String(format: "%@,%.5f,%.6f,%.1f,%.2f,%.1f,%.1f,%.2f,%.3f,%d,%.1f,%.2f,%.2f,%.5f,%d,%d,%d,%.0f,%@\n",
                          f.string(from: Date()),
                          audio.averageAmplitude, audio.amplitudeVariance,
                          bestBreath, bestReg,
                          audio.breathingRateBPM, motion.breathingRateBPM, motion.breathingRegularity,
                          motion.movementIntensity, motion.isOnMattress ? 1 : 0,
                          sonar.breathingRateBPM, sonar.breathingRegularity, sonar.movementIntensity,
                          sonarLevel, sonar.signalPresent ? 1 : 0, Int(sonar.heartRateBPM),
                          bcgHR, watchHR, phase.rawValue)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            if let d = line.data(using: .utf8) { h.write(d) }
            try? h.close()
        }
    }
}

