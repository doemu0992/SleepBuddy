import SwiftUI
import SwiftData
import Charts

struct StatistikView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SleepSession.startDate, order: .reverse) private var sessions: [SleepSession]

    @State private var selectedDate: Date = Calendar.current.startOfDay(for: Date())

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
                    .padding(.bottom, 110)
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
            hypnogramCard(session: session)
            statsRow(session: session)
            if let latency = session.sleepOnsetLatency, latency > 0 {
                extraStatsCard(session: session, latency: latency)
            }
            SchlafapnoeRisikoView(sessions: Array(sessions))
                .padding(.horizontal)

            NavigationLink(destination: SleepDetailView(session: session)) {
                HStack {
                    Text("Nacht im Detail")
                        .font(.subheadline.bold())
                        .foregroundStyle(.indigo)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.indigo.opacity(0.6))
                }
                .padding()
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
        }
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
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.startDate.formatted(.dateTime.weekday(.wide).day().month()))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(session.totalDuration.formattedDuration)
                        .font(.title2.bold())
                }
                Spacer()
                QualityBadge(score: Double(SchlafindexView.score(for: session)))
            }

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
        switch phase {
        case .awake: return .orange
        case .light: return .blue.opacity(0.7)
        case .rem:   return .cyan
        case .deep:  return .indigo
        }
    }

    // MARK: - Stats Row

    private func statsRow(session: SleepSession) -> some View {
        HStack(spacing: 12) {
            statCard(
                icon: "moon.fill",
                color: .indigo,
                value: session.deepSleepDuration.formattedDuration,
                label: "Tiefschlaf",
                sub: deepSleepLabel(session)
            )
            statCard(
                icon: "sparkles",
                color: .cyan,
                value: session.remSleepDuration.formattedDuration,
                label: "REM",
                sub: "\(Int(session.remSleepDuration / session.totalDuration * 100))%"
            )
            statCard(
                icon: "waveform.path",
                color: .orange,
                value: session.snoringEventCount > 0 ? "\(session.snoringEventCount)×" : "—",
                label: "Schnarchen",
                sub: session.snoringEventCount > 0 ? "erkannt" : "keines"
            )
        }
        .padding(.horizontal)
    }

    private func deepSleepLabel(_ session: SleepSession) -> String {
        let pct = session.totalDuration > 0 ? Int(session.deepSleepDuration / session.totalDuration * 100) : 0
        if pct >= 20 { return "Gut ✓" }
        if pct >= 12 { return "\(pct)%" }
        return "Kurz"
    }

    private func statCard(icon: String, color: Color, value: String, label: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).foregroundStyle(color).font(.caption)
            Text(value).font(.title3.bold())
            Text(label).font(.caption2.bold()).foregroundStyle(.primary)
            Text(sub).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.primary.opacity(0.06), radius: 8, x: 0, y: 2)
    }

    // MARK: - Extra Stats

    private func extraStatsCard(session: SleepSession, latency: TimeInterval) -> some View {
        HStack(spacing: 0) {
            miniStat("zzz", color: .indigo, value: formatMin(latency), label: "Einschlafen")
            Divider().frame(height: 36)
            miniStat("moon.fill", color: .blue, value: "\(Int(session.totalDuration / 3600 * 10) / 10)h", label: "Gesamt")
            Divider().frame(height: 36)
            let eff = session.totalDuration > 0 ? Int((session.totalDuration - session.awakeDuration) / session.totalDuration * 100) : 0
            miniStat("percent", color: .purple, value: "\(eff)%", label: "Effizienz")
        }
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.primary.opacity(0.06), radius: 8, x: 0, y: 2)
        .padding(.horizontal)
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

    // MARK: - Helpers

    private func formatMin(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        return m < 60 ? "\(m)m" : "\(m/60)h\(m%60 > 0 ? " \(m%60)m" : "")"
    }
}
