import SwiftUI
import SwiftData

struct SchlafindexView: View {
    let session: SleepSession
    @State private var zeigeInfo = false

    private var score: Int { Int(session.computedQualityScore) }

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

    // Sub-scores (0–100)
    private var dauerScore: Int {
        let hours = session.totalDuration / 3600
        return Int(min(hours / 8.0 * 100, 100))
    }

    private var nachtruheScore: Int {
        guard let onset = session.sleepOnsetDate, let end = session.endDate else { return 50 }
        let sleep = end.timeIntervalSince(onset)
        let hours = sleep / 3600
        return Int(min(hours / 7.5 * 100, 100))
    }

    private var unterbrechungsScore: Int {
        let awakeMin = session.awakeDuration / 60
        let penalty = min(awakeMin / 30, 1.0)
        return Int((1 - penalty) * 100)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                scoreKarte
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

    // MARK: - Sub Scores

    private var subScoreKarte: some View {
        VStack(spacing: 12) {
            subScoreRow(
                icon: "clock.fill",
                color: .indigo,
                titel: "Dauer",
                wert: session.totalDuration.formattedDuration,
                score: dauerScore,
                maxScore: 100
            )
            Divider()
            subScoreRow(
                icon: "moon.fill",
                color: .purple,
                titel: "Schlafenszeit",
                wert: session.sleepOnsetDate.map { "Eingeschlafen um \($0.formatted(.dateTime.hour().minute()))" } ?? "–",
                score: nachtruheScore,
                maxScore: 100
            )
            Divider()
            subScoreRow(
                icon: "waveform.path",
                color: .orange,
                titel: "Unterbrechungen",
                wert: session.awakeDuration < 60 ? "Nie aufgewacht" : "\(Int(session.awakeDuration / 60)) Min wach",
                score: unterbrechungsScore,
                maxScore: 100
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
