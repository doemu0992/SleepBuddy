import SwiftUI
import SwiftData

struct SchlafindexView: View {
    let session: SleepSession
    @State private var zeigeInfo = false
    @AppStorage("schlafZielStunden") private var schlafZielStunden = 8.0

    static func score(for session: SleepSession) -> Int {
        let total = session.totalDuration
        let actualSleep = max(total - session.awakeDuration, 0)
        let ziel = max(UserDefaults.standard.double(forKey: "schlafZielStunden"), 5.0).isZero ? 8.0 : max(UserDefaults.standard.double(forKey: "schlafZielStunden"), 5.0)

        // Dauer: echte Schlafzeit vs. Schlafziel
        let dauerScore = Int(min(actualSleep / 3600 / ziel * 50, 50))

        // Effizienz: echte Schlafzeit / Zeit im Bett (90%+ = perfekt, 50% = 0)
        let efficiency = total > 0 ? actualSleep / total : 0
        let effizienzScore = Int(max(0, min((efficiency - 0.50) / 0.40, 1.0)) * 30)

        // Unterbrechungen: nur Wachphasen NACH dem Einschlafen
        let postOnsetAwakeMin: Double
        if let onset = session.sleepOnsetDate {
            postOnsetAwakeMin = session.phasesArray
                .filter { $0.phaseType == .awake && $0.startDate >= onset }
                .reduce(0.0) { $0 + $1.duration } / 60
        } else {
            postOnsetAwakeMin = session.awakeDuration / 60
        }
        let unterbrechungsScore = Int((1 - min(postOnsetAwakeMin / 45, 1.0)) * 20)

        return dauerScore + effizienzScore + unterbrechungsScore
    }

    // Sub-scores: Dauer /50 + Effizienz /30 + Unterbrechungen /20 = 100
    private var actualSleep: TimeInterval { max(session.totalDuration - session.awakeDuration, 0) }

    private var sleepEfficiency: Double {
        session.totalDuration > 0 ? actualSleep / session.totalDuration : 0
    }

    private var dauerScore: Int {
        let ziel = schlafZielStunden < 5 ? 8.0 : schlafZielStunden
        return Int(min(actualSleep / 3600 / ziel * 50, 50))
    }

    // "Effizienz" replaces "Schlafenszeit": actual sleep / time in bed
    // 90%+ → 30, 75% → 18, 65% → 11, 50% → 0
    private var effizienzScore: Int {
        Int(max(0, min((sleepEfficiency - 0.50) / 0.40, 1.0)) * 30)
    }

    private var postOnsetAwakeMinutes: Double {
        if let onset = session.sleepOnsetDate {
            return session.phasesArray
                .filter { $0.phaseType == .awake && $0.startDate >= onset }
                .reduce(0.0) { $0 + $1.duration } / 60
        }
        return session.awakeDuration / 60
    }

    private var unterbrechungsScore: Int {
        Int((1 - min(postOnsetAwakeMinutes / 45, 1.0)) * 20)
    }

    private var score: Int { dauerScore + effizienzScore + unterbrechungsScore }

    private var scoreLabel: String {
        switch score {
        case 85...: return "Sehr hoch"
        case 70..<85: return "Hoch"
        case 50..<70: return "OK"
        case 30..<50: return "Niedrig"
        default: return "Sehr niedrig"
        }
    }

    private var scoreColor: Color {
        switch score {
        case 85...: return .green
        case 70..<85: return .mint
        case 50..<70: return .yellow
        case 30..<50: return .orange
        default: return .red
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                scoreKarte
                scoreErklaerung
                subScoreKarte
                phasenKarte
                infoKarte
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Schlafindex")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $zeigeInfo) { infoSheet }
    }

    // MARK: - Score Ring

    private var scoreKarte: some View {
        VStack(spacing: 16) {
            HStack {
                Text(session.startDate, format: .dateTime.weekday(.wide).day().month())
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button { zeigeInfo = true } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.indigo.opacity(0.8))
                }
                .buttonStyle(.plain)
            }

            ZStack {
                Circle()
                    .stroke(Color.indigo.opacity(0.12), lineWidth: 16)
                Circle()
                    .trim(from: 0, to: CGFloat(score) / 100)
                    .stroke(scoreColor, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.8), value: score)

                VStack(spacing: 4) {
                    Text("\(score)")
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .foregroundStyle(scoreColor)
                    Text(scoreLabel)
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
            }
            .frame(width: 160, height: 160)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
    }

    // MARK: - Score Erklärung

    private var scoreErklaerung: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Warum \(score)%?", systemImage: "questionmark.circle.fill")
                .font(.headline).foregroundStyle(.indigo)

            VStack(alignment: .leading, spacing: 8) {
                erklaerungsZeile(
                    icon: "clock.fill", color: .indigo,
                    text: dauerErklaerung
                )
                Divider()
                erklaerungsZeile(
                    icon: "moon.fill", color: .purple,
                    text: effizienzErklaerung
                )
                Divider()
                erklaerungsZeile(
                    icon: "waveform.path", color: .orange,
                    text: unterbrechungsErklaerung
                )
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
    }

    private func erklaerungsZeile(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 20)
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dauerErklaerung: String {
        let h = actualSleep / 3600
        let ziel = schlafZielStunden < 5 ? 8.0 : schlafZielStunden
        if dauerScore >= 45 {
            return "Dauer top: \(String(format: "%.1f", h))h Schlaf entspricht deinem Ziel von \(Int(ziel))h."
        } else if dauerScore >= 30 {
            return "Dauer ok: \(String(format: "%.1f", h))h Schlaf – noch \(String(format: "%.1f", ziel - h))h unter deinem Ziel."
        } else {
            return "Dauer zu kurz: Nur \(String(format: "%.1f", h))h Schlaf. Ziel: \(Int(ziel))h — \(String(format: "%.1f", ziel - h))h fehlen."
        }
    }

    private var effizienzErklaerung: String {
        let eff = Int(sleepEfficiency * 100)
        if effizienzScore >= 25 {
            return "Effizienz ausgezeichnet: \(eff)% deiner Zeit im Bett hast du wirklich geschlafen (Ziel ≥ 90%)."
        } else if effizienzScore >= 15 {
            return "Effizienz gut: \(eff)% Schlafeffizienz – etwas Zeit wach im Bett verbracht."
        } else {
            return "Effizienz niedrig: Nur \(eff)% Schlafeffizienz. Lange Einschlafzeit oder nächtliches Aufwachen drücken den Wert."
        }
    }

    private var unterbrechungsErklaerung: String {
        let min = Int(postOnsetAwakeMinutes)
        if unterbrechungsScore >= 18 {
            return "Kaum unterbrochen: Du warst nach dem Einschlafen praktisch gar nicht mehr wach."
        } else if unterbrechungsScore >= 10 {
            return "Wenige Unterbrechungen: \(min) Min wach nach dem Einschlafen – leicht erhöht aber normal."
        } else {
            return "Viele Unterbrechungen: \(min) Min wach nach dem Einschlafen. Stressabbau vor dem Schlaf kann helfen."
        }
    }

    // MARK: - Sub Scores

    private var subScoreKarte: some View {
        VStack(spacing: 12) {
            subScoreRow(
                icon: "clock.fill",
                color: .indigo,
                titel: "Dauer",
                wert: max(session.totalDuration - session.awakeDuration, 0).formattedDuration,
                score: dauerScore,
                maxScore: 50
            )
            Divider()
            subScoreRow(
                icon: "moon.fill",
                color: .purple,
                titel: "Effizienz",
                wert: "\(Int(sleepEfficiency * 100))% Schlafeffizienz",
                score: effizienzScore,
                maxScore: 30
            )
            Divider()
            subScoreRow(
                icon: "waveform.path",
                color: .orange,
                titel: "Unterbrechungen",
                wert: postOnsetAwakeMinutes < 1 ? "Nie aufgewacht" : "\(Int(postOnsetAwakeMinutes)) Min wach (nach Einschlafen)",
                score: unterbrechungsScore,
                maxScore: 20
            )
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
    }

    private func subScoreRow(icon: String, color: Color, titel: String, wert: String, score: Int, maxScore: Int) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(titel).font(.subheadline.bold())
                Text(wert).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(score)/\(maxScore)")
                .font(.subheadline.bold())
                .foregroundStyle(color)
        }
    }

    // MARK: - Phasen

    private var phasenKarte: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Schlaf: Phasen", systemImage: "bed.double.fill")
                .font(.headline).foregroundStyle(.indigo)

            Text("Hier ist ein Überblick über deine Schlafphasen.")
                .font(.subheadline).foregroundStyle(.secondary)

            VStack(spacing: 8) {
                phasenZeile(label: "Wach", duration: session.awakeDuration, color: .orange)
                phasenZeile(label: "REM", duration: session.remSleepDuration, color: .purple)
                phasenZeile(label: "Leicht", duration: session.lightSleepDuration, color: .blue)
                phasenZeile(label: "Tief", duration: session.deepSleepDuration, color: .indigo)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
    }

    private func phasenZeile(label: String, duration: TimeInterval, color: Color) -> some View {
        let total = max(session.totalDuration, 1)
        let fraction = CGFloat(duration / total)
        return HStack(spacing: 10) {
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(color)
                .frame(width: 44, alignment: .leading)
            Text(duration.formattedDuration)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.12)).frame(height: 10)
                    Capsule().fill(color).frame(width: geo.size.width * fraction, height: 10)
                }
            }
            .frame(height: 10)
        }
    }

    // MARK: - Info

    private var infoKarte: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Über den Schlafindex", systemImage: "info.circle.fill")
                .font(.headline).foregroundStyle(.indigo)
            Text("Der Schlafindex bewertet, wie erholsam dein Schlaf war — basierend auf Dauer, Einschlafzeit, Unterbrechungen und Schlafphasenverhältnis.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
    }

    private var infoSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("""
                    Hierbei handelt es sich um eine Messung, wie erholsam dein Schlaf letzte Nacht für deinen Körper und Geist wahrscheinlich war.

                    Jede Schlafaufzeichnung kann anhand eines Index nach den Stufen „Sehr hoch", „Hoch", „OK", „Niedrig" und „Sehr niedrig" eingestuft werden. Die Messung basiert auf mehreren Aspekten deines Schlafs — Gesamtdauer, Einschlafzeit und Unterbrechungen.

                    Die Klassifizierung entspricht nicht unbedingt deinem Wohlbefinden, wenn du aufwachst, kann dir aber einen Eindruck davon vermitteln, ob dein Körper ausreichend Schlaf zum Erholen bekommen hat.
                    """)
                    .font(.body)
                }
                .padding()
            }
            .navigationTitle("Über den Schlafindex")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { zeigeInfo = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
