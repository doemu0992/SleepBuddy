import SwiftUI
import SwiftData
import Charts

private struct TrendPoint: Identifiable {
    let id = UUID()
    let date: Date
    let duration: Double   // hours
    let score: Int
}

struct StatistikView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SleepSession.startDate, order: .reverse) private var sessions: [SleepSession]

    @State private var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var trendPeriod: TrendPeriod = .month
    @AppStorage("schlafZielStunden") private var schlafZiel = 8.0

    private enum TrendPeriod: String, CaseIterable {
        case month = "30 T"
        case threeMonths = "3 M"
        case sixMonths = "6 M"

        var days: Int {
            switch self {
            case .month: return 30
            case .threeMonths: return 90
            case .sixMonths: return 180
            }
        }
    }

    private var weekDays: [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (-6...0).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
    }

    private var sessionForSelected: SleepSession? {
        let cal = Calendar.current
        return sessions.first(where: {
            !$0.isActive &&
            (cal.isDate($0.startDate, inSameDayAs: selectedDate) ||
             cal.isDate($0.endDate ?? .distantPast, inSameDayAs: selectedDate))
        })
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Color(.systemGroupedBackground).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        weekStrip
                            .padding(.top, 8)
                            .padding(.bottom, 16)

                        if let session = sessionForSelected {
                            sleepContent(session: session)
                        } else {
                            emptyState
                        }
                    }
                    .padding(.bottom, 96)
                }
            }
            .navigationTitle("Statistik")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(destination: SleepHistoryView()) {
                        Image(systemName: "list.bullet")
                            .foregroundStyle(.indigo)
                    }
                }
            }
        }
    }

    // MARK: - Week Strip

    private var weekStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(weekDays, id: \.self) { day in
                    weekDayButton(day)
                }
            }
            .padding(.horizontal)
        }
    }

    private func weekDayButton(_ day: Date) -> some View {
        let cal = Calendar.current
        let isSelected = cal.isDate(day, inSameDayAs: selectedDate)
        let isToday = cal.isDateInToday(day)
        let hasData = sessions.contains(where: {
            !$0.isActive && (cal.isDate($0.startDate, inSameDayAs: day) ||
                             cal.isDate($0.endDate ?? .distantPast, inSameDayAs: day))
        })

        return Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { selectedDate = day } } label: {
            VStack(spacing: 4) {
                Text(day.formatted(.dateTime.weekday(.narrow)))
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .white : .secondary)

                ZStack {
                    Circle()
                        .fill(isSelected ? Color.indigo : (isToday ? Color.indigo.opacity(0.12) : Color.clear))
                        .frame(width: 36, height: 36)
                    if isSelected {
                        Circle()
                            .strokeBorder(.white.opacity(0.3), lineWidth: 1)
                            .frame(width: 36, height: 36)
                    }
                    Text(day.formatted(.dateTime.day()))
                        .font(.subheadline.bold())
                        .foregroundStyle(isSelected ? .white : (isToday ? .indigo : .primary))
                }

                Circle()
                    .fill(hasData ? Color.indigo.opacity(isSelected ? 0 : 0.5) : Color.clear)
                    .frame(width: 4, height: 4)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sleep Content

    @ViewBuilder
    private func sleepContent(session: SleepSession) -> some View {
        VStack(spacing: 16) {
            // ── Diese Nacht ──
            sectionHeader("Diese Nacht")
            heroCard(session: session)
            hypnogramCard(session: session)
            combinedStatsCard(session: session)

            // ── Trends ──
            sectionHeader("Trends")
            SchlafapnoeRisikoView(sessions: Array(sessions))
                .padding(.horizontal)

            if trendPoints(for: trendPeriod).count >= 3 {
                langzeitCard
            }

            if trendPoints(for: .sixMonths).count >= 7 {
                wochentagCard
            }
        }
    }

    // MARK: - Section Header (Dashboard-Stil)

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.caption.bold())
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    // MARK: - Nacht-Hero (tappbar → Detail)

    private func heroCard(session: SleepSession) -> some View {
        NavigationLink(destination: SleepDetailView(session: session)) {
            ZStack {
                LinearGradient(colors: [Color(red: 0.15, green: 0.15, blue: 0.42), .indigo, .purple],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .clipShape(RoundedRectangle(cornerRadius: 24))

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(session.startDate.formatted(.dateTime.weekday(.wide).day().month()))
                            .font(.caption).foregroundStyle(.white.opacity(0.7))
                        Text(session.sleepDuration.formattedDuration)
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        if session.sleepDuration < session.totalDuration {
                            Label("Zeit im Bett \(session.totalDuration.formattedDuration)", systemImage: "bed.double.fill")
                                .font(.caption).foregroundStyle(.white.opacity(0.75))
                        }
                        HStack(spacing: 4) {
                            Text("Nacht im Detail")
                                .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                            Image(systemName: "chevron.right")
                                .font(.caption2.bold()).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    Spacer()
                    scoreRing(SchlafindexView.score(for: session))
                }
                .padding(20)
            }
            .frame(height: 150)
            .shadow(color: .indigo.opacity(0.3), radius: 12, x: 0, y: 6)
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }

    private func scoreRing(_ score: Int) -> some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.2), lineWidth: 8)
            Circle().trim(from: 0, to: CGFloat(min(max(score, 0), 100)) / 100)
                .stroke(scoreColor(score), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(score)").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                Text("Index").font(.caption2).foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(width: 80, height: 80)
    }

    private func scoreColor(_ s: Int) -> Color {
        switch s { case ..<40: return .red; case ..<70: return .orange; case ..<85: return .yellow; default: return .green }
    }

    // MARK: - Hypnogram (vertical bars, Sleep Cycle style)

    private struct HypnoBar: Identifiable {
        let id = UUID()
        let time: Date
        let depth: Double   // 0=wach,1=leicht,2=rem,3=tief
        let phase: SleepPhaseType
        let duration: TimeInterval
    }

    private func hypnoBars(for session: SleepSession) -> [HypnoBar] {
        session.phasesArray
            .sorted { $0.startDate < $1.startDate }
            .map { phase in
                let depth: Double = switch phase.phaseType {
                case .awake: 0.15
                case .light: 0.45
                case .rem:   0.70
                case .deep:  1.00
                }
                return HypnoBar(time: phase.startDate, depth: depth, phase: phase.phaseType, duration: phase.duration)
            }
    }

    private func hypnogramCard(session: SleepSession) -> some View {
        let bars = hypnoBars(for: session)
        let totalDur = max(session.totalDuration, 1)

        return VStack(alignment: .leading, spacing: 14) {
            Label("Schlafphasen", systemImage: "bed.double.fill")
                .font(.headline)

            // Chart
            if !bars.isEmpty {
                GeometryReader { geo in
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(bars) { bar in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(barColor(bar.phase))
                                .frame(
                                    width: max(geo.size.width * CGFloat(bar.duration / totalDur) - 2, 3),
                                    height: geo.size.height * CGFloat(bar.depth)
                                )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
                .frame(height: 100)

                // X-Achse Zeit
                HStack {
                    Text(session.startDate.formatted(date: .omitted, time: .shortened))
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    if let end = session.endDate {
                        Text(end.formatted(date: .omitted, time: .shortened))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            // Legende
            HStack(spacing: 16) {
                ForEach(SleepPhaseType.allCases, id: \.self) { type in
                    let dur = session.phasesArray.filter { $0.phaseType == type }.reduce(0) { $0 + $1.duration }
                    if dur > 0 {
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(barColor(type))
                                .frame(width: 12, height: 10)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(type.rawValue)
                                    .font(.caption2.bold())
                                Text(dur.formattedDuration)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: Color.primary.opacity(0.06), radius: 12, x: 0, y: 3)
        .padding(.horizontal)
    }

    private func barColor(_ phase: SleepPhaseType) -> Color {
        phase.color
    }

    // MARK: - Kombinierte Stat-Karte (Phasen + Extra-Stats)

    private func combinedStatsCard(session: SleepSession) -> some View {
        let hasLatency = (session.sleepOnsetLatency ?? 0) > 0
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                statColumn(icon: "moon.fill", color: SleepPhaseType.deep.color,
                           value: session.deepSleepDuration.formattedDuration, label: "Tiefschlaf", sub: deepSleepLabel(session))
                Divider().frame(height: 52)
                statColumn(icon: "sparkles", color: SleepPhaseType.rem.color,
                           value: session.remSleepDuration.formattedDuration, label: "REM",
                           sub: "\(Int(session.remSleepDuration / max(session.totalDuration, 1) * 100))%")
                Divider().frame(height: 52)
                statColumn(icon: "waveform.path", color: .orange,
                           value: session.snoringEventCount > 0 ? "\(session.snoringEventCount)×" : "—",
                           label: "Schnarchen", sub: session.snoringEventCount > 0 ? "erkannt" : "keines")
            }

            Divider().padding(.vertical, 14)

            HStack(spacing: 0) {
                if hasLatency {
                    miniStat("zzz", color: .indigo, value: formatMin(session.sleepOnsetLatency ?? 0), label: "Einschlafen")
                    Divider().frame(height: 36)
                }
                miniStat("moon.fill", color: .blue, value: "\(Int(session.totalDuration / 3600 * 10) / 10)h", label: "Gesamt")
                Divider().frame(height: 36)
                let eff = session.totalDuration > 0 ? Int((session.totalDuration - session.awakeDuration) / session.totalDuration * 100) : 0
                miniStat("percent", color: .purple, value: "\(eff)%", label: "Effizienz")
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.primary.opacity(0.06), radius: 8, x: 0, y: 2)
        .padding(.horizontal)
    }

    private func deepSleepLabel(_ session: SleepSession) -> String {
        let pct = session.totalDuration > 0 ? Int(session.deepSleepDuration / session.totalDuration * 100) : 0
        if pct >= 20 { return "Gut ✓" }
        if pct >= 12 { return "\(pct)%" }
        return "Kurz"
    }

    private func statColumn(icon: String, color: Color, value: String, label: String, sub: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(color).font(.caption)
            Text(value).font(.title3.bold())
            Text(label).font(.caption2.bold()).foregroundStyle(.primary)
            Text(sub).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func miniStat(_ icon: String, color: Color, value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).foregroundStyle(color).font(.caption)
            Text(value).font(.subheadline.bold())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 48))
                .foregroundStyle(.indigo.opacity(0.4))
            Text("Kein Tracking")
                .font(.headline).foregroundStyle(.secondary)
            Text("Für diesen Tag wurden keine Schlafdaten aufgezeichnet.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(.top, 60)
    }

    // MARK: - Langzeit-Statistik

    private func trendPoints(for period: TrendPeriod) -> [TrendPoint] {
        let cal = Calendar.current
        let cutoff = cal.date(byAdding: .day, value: -period.days, to: Date()) ?? Date()
        return sessions
            .filter { !$0.isActive && $0.totalDuration >= 1800 && $0.startDate >= cutoff }
            .map { s in
                TrendPoint(
                    date: cal.startOfDay(for: s.startDate),
                    duration: s.sleepDuration / 3600,
                    score: SchlafindexView.score(for: s)
                )
            }
            .sorted { $0.date < $1.date }
    }

    private var langzeitCard: some View {
        let points = trendPoints(for: trendPeriod)
        let avgDur = points.isEmpty ? 0 : points.map(\.duration).reduce(0, +) / Double(points.count)
        let avgScore = points.isEmpty ? 0 : points.map(\.score).reduce(0, +) / points.count
        let goal = schlafZiel

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Langzeit-Trend", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.headline).foregroundStyle(.indigo)
                Spacer()
                Picker("", selection: $trendPeriod) {
                    ForEach(TrendPeriod.allCases, id: \.self) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }

            HStack(spacing: 0) {
                miniStat("clock.fill", color: .indigo, value: String(format: "%.1fh", avgDur), label: "Ø Dauer")
                Divider().frame(height: 36)
                miniStat("star.fill", color: .purple, value: "\(avgScore)%", label: "Ø Score")
                Divider().frame(height: 36)
                miniStat("moon.fill", color: SleepPhaseType.deep.color, value: "\(points.count)", label: "Nächte")
            }

            // Duration chart
            Chart {
                ForEach(points) { pt in
                    BarMark(
                        x: .value("Datum", pt.date, unit: .day),
                        y: .value("Stunden", pt.duration)
                    )
                    .foregroundStyle(pt.duration >= goal
                        ? Color.indigo.opacity(0.7)
                        : Color.indigo.opacity(0.35))
                    .cornerRadius(3)
                }
                RuleMark(y: .value("Ziel", goal))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4]))
                    .foregroundStyle(Color.indigo.opacity(0.5))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("Ziel").font(.caption2).foregroundStyle(.indigo.opacity(0.6))
                    }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: trendPeriod == .month ? 7 : trendPeriod == .threeMonths ? 14 : 30)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .chartYAxis {
                AxisMarks(values: .stride(by: 2)) { val in
                    AxisGridLine()
                    AxisValueLabel { if let v = val.as(Double.self) { Text("\(Int(v))h") } }
                }
            }
            .frame(height: 120)

            Text("Balken = Schlafdauer · Gestrichelt = Schlafziel · Dunkel = Ziel erreicht")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: Color.primary.opacity(0.06), radius: 12, x: 0, y: 3)
        .padding(.horizontal)
    }

    // MARK: - Wochentag-Vergleich

    private struct WochentagPunkt: Identifiable {
        let id: Int  // weekday (1=So, 2=Mo…7=Sa)
        let name: String
        let avgScore: Double
        let avgStunden: Double
    }

    private var wochentagPunkte: [WochentagPunkt] {
        let cal = Calendar.current
        let alle = trendPoints(for: .sixMonths)
        let tage = ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"]
        return (1...7).compactMap { wd in
            let matching = alle.filter { cal.component(.weekday, from: $0.date) == wd }
            guard !matching.isEmpty else { return nil }
            return WochentagPunkt(
                id: wd,
                name: tage[wd - 1],
                avgScore: Double(matching.map(\.score).reduce(0, +)) / Double(matching.count),
                avgStunden: matching.map(\.duration).reduce(0, +) / Double(matching.count)
            )
        }
    }

    private var wochentagCard: some View {
        let punkte = wochentagPunkte
        let maxScore = punkte.map(\.avgScore).max() ?? 100
        let minScore = punkte.map(\.avgScore).min() ?? 0

        return VStack(alignment: .leading, spacing: 14) {
            Label("Schlaf nach Wochentag", systemImage: "calendar.badge.clock")
                .font(.headline).foregroundStyle(.indigo)

            Chart(punkte) { p in
                BarMark(
                    x: .value("Tag", p.name),
                    y: .value("Score", p.avgScore)
                )
                .foregroundStyle(p.avgScore == maxScore ? Color.green.opacity(0.8)
                                 : p.avgScore == minScore ? Color.orange.opacity(0.8)
                                 : Color.indigo.opacity(0.55))
                .cornerRadius(5)
                .annotation(position: .top) {
                    Text("\(Int(p.avgScore))%")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks { val in
                    AxisValueLabel().font(.caption2)
                }
            }
            .frame(height: 100)

            HStack(spacing: 16) {
                if let best = punkte.max(by: { $0.avgScore < $1.avgScore }) {
                    Label("Bester: \(best.name)", systemImage: "star.fill")
                        .font(.caption2).foregroundStyle(.green)
                }
                if let worst = punkte.min(by: { $0.avgScore < $1.avgScore }) {
                    Label("Schwächster: \(worst.name)", systemImage: "arrow.down")
                        .font(.caption2).foregroundStyle(.orange)
                }
                Spacer()
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
        .padding(.horizontal)
    }

    // MARK: - Helpers

    private func formatMin(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        return m < 60 ? "\(m)m" : "\(m/60)h\(m%60 > 0 ? " \(m%60)m" : "")"
    }
}
