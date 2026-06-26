import SwiftUI

struct SchlafapnoeRisikoView: View {
    let sessions: [SleepSession]

    private enum Risiko {
        case niedrig, mild, mittel, erhoeht

        var label: String {
            switch self {
            case .niedrig:  return "Niedrig"
            case .mild:     return "Mild"
            case .mittel:   return "Mittel"
            case .erhoeht:  return "Erhöht"
            }
        }
        var color: Color {
            switch self {
            case .niedrig:  return .green
            case .mild:     return .yellow
            case .mittel:   return .orange
            case .erhoeht:  return .red
            }
        }
        var icon: String {
            switch self {
            case .niedrig:  return "checkmark.circle.fill"
            case .mild:     return "exclamationmark.triangle"
            case .mittel:   return "exclamationmark.triangle.fill"
            case .erhoeht:  return "xmark.octagon.fill"
            }
        }
        var position: Double { // 0...1
            switch self {
            case .niedrig:  return 0.12
            case .mild:     return 0.37
            case .mittel:   return 0.62
            case .erhoeht:  return 0.87
            }
        }
    }

    private var qualifyingSessions: [SleepSession] {
        Array(sessions.filter { !$0.isActive && $0.totalDuration >= 3600 }.prefix(7))
    }

    private var snoringPerHour: Double {
        guard !qualifyingSessions.isEmpty else { return 0 }
        let rates = qualifyingSessions.map { s -> Double in
            let hours = s.totalDuration / 3600
            return hours > 0 ? Double(s.snoringEventCount) / hours : 0
        }
        return rates.reduce(0, +) / Double(rates.count)
    }

    /// Sessions where snoring events arrive in a regular 4–14 s pattern (OSA-like)
    private var obstructiveNightCount: Int {
        qualifyingSessions.filter { session in
            let events = session.soundEventsArray
                .filter { $0.type == .snoring }
                .sorted { $0.timestamp < $1.timestamp }
            guard events.count >= 6 else { return false }
            let intervals = zip(events, events.dropFirst())
                .map { $1.timestamp.timeIntervalSince($0.timestamp) }
            let qualifying = intervals.filter { $0 >= 4 && $0 <= 14 }
            guard qualifying.count >= 5 else { return false }
            let mean = qualifying.reduce(0, +) / Double(qualifying.count)
            guard mean > 0 else { return false }
            let variance = qualifying.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(qualifying.count)
            return sqrt(variance) / mean < 0.35
        }.count
    }

    private var risiko: Risiko {
        var score = snoringPerHour
        let obstrFraction = Double(obstructiveNightCount) / max(Double(qualifyingSessions.count), 1)
        score += obstrFraction * 20                          // periodic snoring = strong OSA signal
        if score < 25 { return .niedrig }
        if score < 50 { return .mild }
        if score < 75 { return .mittel }
        return .erhoeht
    }

    private var hasData: Bool {
        sessions.contains { !$0.isActive && $0.totalDuration >= 3600 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Schlafapnoe-Risiko", systemImage: "lungs.fill")
                    .font(.headline)
                    .foregroundStyle(.indigo)
                Spacer()
                if hasData {
                    Label(risiko.label, systemImage: risiko.icon)
                        .font(.caption.bold())
                        .foregroundStyle(risiko.color)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(risiko.color.opacity(0.12), in: Capsule())
                } else {
                    Label("Monitoring läuft", systemImage: "waveform")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                }
            }

            if hasData {
                // Gradient bar + marker
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        LinearGradient(
                            colors: [.green, .yellow, .orange, .red],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(height: 10)
                        .clipShape(Capsule())

                        let x = geo.size.width * risiko.position
                        Triangle()
                            .fill(Color.primary)
                            .frame(width: 14, height: 10)
                            .offset(x: x - 7, y: 11)
                    }
                }
                .frame(height: 22)
                .padding(.vertical, 4)

                HStack {
                    Text("Niedrig").font(.caption2).foregroundStyle(.green)
                    Spacer()
                    Text("Mild").font(.caption2).foregroundStyle(.yellow)
                    Spacer()
                    Text("Mittel").font(.caption2).foregroundStyle(.orange)
                    Spacer()
                    Text("Erhöht").font(.caption2).foregroundStyle(.red)
                }

                // Additional detail rows
                if obstructiveNightCount > 0 {
                    Divider()
                    HStack {
                        Label("\(obstructiveNightCount) Nacht/Nächte mit periodischem Schnarchen",
                              systemImage: "waveform.badge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.red)
                        Spacer()
                    }
                }
            } else {
                HStack(spacing: 16) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.indigo.opacity(0.4))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Noch keine Daten")
                            .font(.subheadline.bold())
                        Text("Nach deiner ersten vollständigen Nacht (≥ 1 Stunde) erscheint hier deine Schnarchen-Analyse.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()

            HStack(spacing: 4) {
                Image(systemName: "info.circle").font(.caption).foregroundStyle(.secondary)
                Text(infoText)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
    }

    private var infoText: String {
        let n = qualifyingSessions.count
        if n == 0 { return "Kein Ersatz für eine ärztliche Diagnose." }
        let rate = String(format: "%.0f", snoringPerHour)
        let pauses = String(format: "%.1f", pausesPerHour)
        return "Ø \(rate) Schnarch-Ereignisse/h, \(pauses) Atempausen/h (letzte \(n) Nächte). Kein medizinischer Befund."
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
        }
    }
}
