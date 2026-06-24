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

    private var snoringPerHour: Double {
        let qualifying = sessions.filter { !$0.isActive && $0.totalDuration >= 3600 }
            .prefix(7)
        guard !qualifying.isEmpty else { return 0 }
        let rates = qualifying.map { s -> Double in
            let hours = s.totalDuration / 3600
            return hours > 0 ? Double(s.snoringEventCount) / hours : 0
        }
        return rates.reduce(0, +) / Double(rates.count)
    }

    private var risiko: Risiko {
        let r = snoringPerHour
        if r < 25 { return .niedrig }
        if r < 50 { return .mild }
        if r < 75 { return .mittel }
        return .erhoeht
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Schlafapnoe-Risiko", systemImage: "lungs.fill")
                    .font(.headline)
                    .foregroundStyle(.indigo)
                Spacer()
                Label(risiko.label, systemImage: risiko.icon)
                    .font(.caption.bold())
                    .foregroundStyle(risiko.color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(risiko.color.opacity(0.12), in: Capsule())
            }

            // Gradient bar + marker
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    LinearGradient(
                        colors: [.green, .yellow, .orange, .red],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(height: 10)
                    .clipShape(Capsule())

                    // Triangle marker
                    let x = geo.size.width * risiko.position
                    Triangle()
                        .fill(Color.white)
                        .frame(width: 14, height: 10)
                        .offset(x: x - 7, y: 11)
                }
            }
            .frame(height: 22)
            .padding(.vertical, 4)

            // Zone labels
            HStack {
                Text("Niedrig").font(.caption2).foregroundStyle(.green)
                Spacer()
                Text("Mild").font(.caption2).foregroundStyle(.yellow)
                Spacer()
                Text("Mittel").font(.caption2).foregroundStyle(.orange)
                Spacer()
                Text("Erhöht").font(.caption2).foregroundStyle(.red)
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
        let n = min(sessions.filter { !$0.isActive && $0.totalDuration >= 3600 }.count, 7)
        let rate = String(format: "%.0f", snoringPerHour)
        if n == 0 { return "Noch keine ausreichenden Schlafdaten." }
        return "Ø \(rate) Schnarch-Ereignisse/h (letzte \(n) Nächte). Kein medizinischer Befund."
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
