import SwiftUI
import SwiftData
import Charts

enum VerlaufZeitraum: String, CaseIterable {
    case woche       = "7 T"
    case monat       = "30 T"
    case dreiMonate  = "3 M"
    case sechsMonate = "6 M"
    case alle        = "Alle"

    var tage: Int? {
        switch self {
        case .woche:       return 7
        case .monat:       return 30
        case .dreiMonate:  return 90
        case .sechsMonate: return 180
        case .alle:        return nil
        }
    }
}

struct SleepHistoryView: View {
    @Query(sort: \SleepSession.startDate, order: .reverse) private var sessions: [SleepSession]
    @Environment(\.modelContext) private var modelContext
    @AppStorage("schlafZielStunden") private var schlafZielStunden = 8.0
    @State private var zeitraum: VerlaufZeitraum = .woche

    private var abgeschlossene: [SleepSession] { sessions.filter { !$0.isActive } }

    private var gefilterte: [SleepSession] {
        guard let tage = zeitraum.tage else { return abgeschlossene }
        let cutoff = Calendar.current.date(byAdding: .day, value: -tage, to: Date())!
        return abgeschlossene.filter { ($0.endDate ?? .distantPast) >= cutoff }
    }

    var body: some View {
        Group {
            if abgeschlossene.isEmpty {
                VStack(spacing: 20) {
                    ContentUnavailableView(
                        "Keine Schlafdaten",
                        systemImage: "moon.zzz",
                        description: Text("Starte deine erste Schlafaufzeichnung")
                    )
                    Button {
                        SampleDataService.insertSampleNight(into: modelContext)
                    } label: {
                        Label("Beispielnacht einfügen", systemImage: "wand.and.stars")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(Color.indigo, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                List {
                    // Zeitraum-Picker
                    Section {
                        Picker("Zeitraum", selection: $zeitraum) {
                            ForEach(VerlaufZeitraum.allCases, id: \.self) { z in
                                Text(z.rawValue).tag(z)
                            }
                        }
                        .pickerStyle(.segmented)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                    .listRowBackground(Color.clear)

                    Section {
                        WochenSummaryCard(sessions: gefilterte, schlafZielStunden: schlafZielStunden, zeitraum: zeitraum)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)

                    if gefilterte.isEmpty {
                        Section {
                            ContentUnavailableView(
                                "Keine Daten",
                                systemImage: "moon.zzz",
                                description: Text("Keine Aufzeichnungen im gewählten Zeitraum")
                            )
                        }
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(gefilterte) { session in
                            NavigationLink(destination: SleepDetailView(session: session)) {
                                SleepSessionRow(session: session)
                            }
                        }
                        .onDelete(perform: delete)
                    }
                }
                .listStyle(.insetGrouped)
                .toolbar { EditButton() }
            }
        }
        .navigationTitle("Verlauf")
        .navigationBarTitleDisplayMode(.large)
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let session = gefilterte[index]
            for phase in session.phasesArray { modelContext.delete(phase) }
            modelContext.delete(session)
        }
        try? modelContext.save()
    }
}

// MARK: - Wochenzusammenfassung

private struct WochenSummaryCard: View {
    let sessions: [SleepSession]
    let schlafZielStunden: Double
    let zeitraum: VerlaufZeitraum

    @State private var ausgewaehltTag: Date? = nil
    @State private var versteckTask: Task<Void, Never>? = nil

    private let cal = Calendar.current

    // Previous period for trend comparison
    private var vorherigeSessionen: [SleepSession] {
        guard let tage = zeitraum.tage else { return [] }
        let start = cal.date(byAdding: .day, value: -tage * 2, to: Date())!
        let end   = cal.date(byAdding: .day, value: -tage,     to: Date())!
        // We don't have access to all sessions here, so use sessions filtered to prev period
        return sessions.filter {
            let d = $0.endDate ?? .distantPast
            return d >= start && d < end
        }
    }

    private var useWeeklyAggregation: Bool {
        zeitraum == .dreiMonate || zeitraum == .sechsMonate || zeitraum == .alle
    }

    private struct TagDaten: Identifiable {
        let datum: Date
        let stunden: Double
        let qualitaet: Int
        var id: Date { datum }
    }

    private var chartDaten: [TagDaten] {
        if useWeeklyAggregation {
            // Group sessions by week start (Monday)
            var byWeek: [Date: [SleepSession]] = [:]
            for s in sessions {
                let weekStart = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: s.endDate ?? s.startDate)
                let key = cal.date(from: weekStart) ?? s.startDate
                byWeek[key, default: []].append(s)
            }
            return byWeek.sorted { $0.key < $1.key }.map { key, ss in
                let avgH = ss.map { $0.totalDuration / 3600 }.reduce(0, +) / Double(ss.count)
                let avgQ = ss.map { SchlafindexView.score(for: $0) }.reduce(0, +) / ss.count
                return TagDaten(datum: key, stunden: avgH, qualitaet: avgQ)
            }
        } else {
            let days = zeitraum.tage ?? 7
            return (0..<days).reversed().compactMap { offset -> TagDaten? in
                guard let tag = cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: Date())) else { return nil }
                let s = sessions.first { cal.isDate($0.endDate ?? .distantPast, inSameDayAs: tag) }
                return TagDaten(datum: tag, stunden: (s?.totalDuration ?? 0) / 3600, qualitaet: s.map { SchlafindexView.score(for: $0) } ?? 0)
            }
        }
    }

    private var avgDauerDiese: Double {
        guard !sessions.isEmpty else { return 0 }
        return sessions.map { $0.totalDuration / 3600 }.reduce(0, +) / Double(sessions.count)
    }

    private var avgQualitaetDiese: Int {
        guard !sessions.isEmpty else { return 0 }
        return sessions.map { SchlafindexView.score(for: $0) }.reduce(0, +) / sessions.count
    }

    private var avgTiefDiese: Double {
        guard !sessions.isEmpty else { return 0 }
        return sessions.map { $0.deepSleepDuration / 60 }.reduce(0, +) / Double(sessions.count)
    }

    private var avgQualitaetLetzte: Int {
        guard !vorherigeSessionen.isEmpty else { return 0 }
        return vorherigeSessionen.map { SchlafindexView.score(for: $0) }.reduce(0, +) / vorherigeSessionen.count
    }

    private var trend: Double {
        guard avgQualitaetLetzte > 0 else { return 0 }
        return Double(avgQualitaetDiese - avgQualitaetLetzte)
    }

    private func balkenFarbe(_ qualitaet: Int) -> Color {
        switch qualitaet {
        case 75...: return .green
        case 50..<75: return .yellow
        case 20..<50: return .orange
        default: return qualitaet == 0 ? Color.indigo.opacity(0.07) : .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Label(zeitraum == .alle ? "Gesamtverlauf" : "Letzte \(zeitraum.rawValue)", systemImage: "chart.bar.fill")
                    .font(.headline).foregroundStyle(.indigo)
                Spacer()
                trendBadge
            }

            // Stats row
            HStack(spacing: 0) {
                statPill(String(format: "%.1fh", avgDauerDiese), label: "Ø Dauer",   farbe: .indigo)
                Divider().frame(height: 40)
                statPill("\(avgQualitaetDiese)%",               label: "Ø Qualität", farbe: qualFarbe(avgQualitaetDiese))
                Divider().frame(height: 40)
                statPill("\(Int(avgTiefDiese)) min",            label: "Ø Tiefschlaf", farbe: .purple)
            }

            // Phase breakdown bar
            if !sessions.isEmpty {
                let totalSleep = sessions.map { $0.totalDuration }.reduce(0, +)
                let deep  = sessions.map { $0.deepSleepDuration  }.reduce(0, +)
                let rem   = sessions.map { $0.remSleepDuration   }.reduce(0, +)
                let light = sessions.map { $0.lightSleepDuration }.reduce(0, +)
                let awake = sessions.map { $0.awakeDuration      }.reduce(0, +)
                let safe  = max(totalSleep, 1)

                VStack(spacing: 6) {
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            ForEach([
                                (SleepPhaseType.deep,  deep),
                                (.rem,   rem),
                                (.light, light),
                                (.awake, awake),
                            ], id: \.0) { phase, dur in
                                if dur > 0 {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(phase.color)
                                        .frame(width: geo.size.width * CGFloat(dur / safe))
                                }
                            }
                        }
                    }
                    .frame(height: 10)
                    .clipShape(Capsule())

                    HStack(spacing: 10) {
                        ForEach([
                            (SleepPhaseType.deep,  deep,  "Tief"),
                            (.rem,   rem,   "REM"),
                            (.light, light, "Leicht"),
                            (.awake, awake, "Wach"),
                        ], id: \.0) { phase, dur, name in
                            if dur > 0 {
                                HStack(spacing: 4) {
                                    Circle().fill(phase.color).frame(width: 6, height: 6)
                                    Text("\(name) \(Int(dur / safe * 100))%")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer()
                    }
                }
            }

            // Chart: Balken für 7T/30T, Linie+Punkte für 3M/6M/Alle
            let calUnit: Calendar.Component = useWeeklyAggregation ? .weekOfYear : .day
            let nonEmpty = chartDaten.filter { $0.stunden > 0 }

            Chart {
                if useWeeklyAggregation {
                    // Linienchart mit Qualitäts-Farbpunkten
                    ForEach(nonEmpty) { tag in
                        LineMark(
                            x: .value("Tag", tag.datum, unit: calUnit),
                            y: .value("Stunden", tag.stunden)
                        )
                        .foregroundStyle(Color.indigo.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.catmullRom)

                        PointMark(
                            x: .value("Tag", tag.datum, unit: calUnit),
                            y: .value("Stunden", tag.stunden)
                        )
                        .foregroundStyle(balkenFarbe(tag.qualitaet))
                        .symbolSize(60)
                    }
                } else {
                    ForEach(chartDaten) { tag in
                        BarMark(
                            x: .value("Tag", tag.datum, unit: calUnit),
                            y: .value("Stunden", max(tag.stunden, tag.stunden == 0 ? 0.15 : 0))
                        )
                        .foregroundStyle(balkenFarbe(tag.qualitaet))
                        .cornerRadius(4)

                        if let sel = ausgewaehltTag, cal.isDate(tag.datum, inSameDayAs: sel) {
                            RuleMark(x: .value("Sel", sel, unit: calUnit))
                                .foregroundStyle(Color.indigo.opacity(0.25))
                                .lineStyle(StrokeStyle(lineWidth: 24, lineCap: .round))
                        }
                    }
                }

                RuleMark(y: .value("Ziel", schlafZielStunden))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4]))
                    .foregroundStyle(Color.indigo.opacity(0.5))
            }
            .chartOverlay { proxy in
                GeometryReader { _ in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture { loc in balkenTippen(proxy: proxy, location: loc) }
                }
            }
            .chartYAxis {
                AxisMarks(values: [0, schlafZielStunden]) { val in
                    if let h = val.as(Double.self), h == schlafZielStunden {
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 1.5, dash: [4]))
                            .foregroundStyle(Color.indigo.opacity(0.5))
                        AxisValueLabel { Text("\(Int(schlafZielStunden))h Ziel").font(.caption2).foregroundStyle(.indigo) }
                    } else {
                        AxisGridLine()
                    }
                }
            }
            .chartXAxis {
                if useWeeklyAggregation {
                    AxisMarks(values: .stride(by: .month)) { val in
                        if val.as(Date.self) != nil {
                            AxisValueLabel(format: .dateTime.month(.abbreviated))
                                .font(.caption2)
                        }
                    }
                } else {
                    AxisMarks(values: .stride(by: .day)) { val in
                        if val.as(Date.self) != nil {
                            AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                                .font(.caption2)
                        }
                    }
                }
            }
            .frame(height: useWeeklyAggregation ? 130 : 100)

            // Tooltip
            if let tag = ausgewaehltTag,
               let punkt = chartDaten.first(where: { cal.isDate($0.datum, inSameDayAs: tag) }) {
                HStack(spacing: 6) {
                    Text(tag, format: .dateTime.weekday(.abbreviated).day().month())
                        .font(.caption2.bold()).foregroundStyle(.secondary)
                    if punkt.stunden > 0 {
                        Text(String(format: "%.1fh · %d%%", punkt.stunden, punkt.qualitaet))
                            .font(.caption2).foregroundStyle(balkenFarbe(punkt.qualitaet))
                    } else {
                        Text("Kein Eintrag").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: ausgewaehltTag)
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
    }

    @ViewBuilder private var trendBadge: some View {
        if !vorherigeSessionen.isEmpty && avgQualitaetDiese > 0 {
            let diff = trend
            HStack(spacing: 4) {
                Image(systemName: diff > 2 ? "arrow.up" : diff < -2 ? "arrow.down" : "minus")
                    .font(.caption2.bold())
                Text(diff > 2 ? "+\(Int(diff))%" : diff < -2 ? "\(Int(diff))%" : "Stabil")
                    .font(.caption2.bold())
            }
            .foregroundStyle(diff > 2 ? .green : diff < -2 ? .red : .secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background((diff > 2 ? Color.green : diff < -2 ? Color.red : Color.secondary).opacity(0.12))
            .clipShape(Capsule())
        }
    }

    private func statPill(_ wert: String, label: String, farbe: Color) -> some View {
        VStack(spacing: 4) {
            Text(wert).font(.title3.bold()).foregroundStyle(farbe)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func qualFarbe(_ q: Int) -> Color {
        switch q {
        case 75...: return .green
        case 50..<75: return .yellow
        default: return .orange
        }
    }

    private func balkenTippen(proxy: ChartProxy, location: CGPoint) {
        guard let date: Date = proxy.value(atX: location.x, as: Date.self) else { return }
        let snapped = chartDaten.min(by: {
            abs($0.datum.timeIntervalSince(date)) < abs($1.datum.timeIntervalSince(date))
        })?.datum
        guard let snapped else { return }
        withAnimation { ausgewaehltTag = snapped }
        versteckTask?.cancel()
        versteckTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await MainActor.run { withAnimation { ausgewaehltTag = nil } }
        }
    }
}

// MARK: - Session Row

struct SleepSessionRow: View {
    let session: SleepSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(session.startDate, style: .date)
                    .font(.headline)
                Spacer()
                if session.subjectiveQuality > 0 {
                    Text(bewertungEmoji(session.subjectiveQuality))
                        .font(.caption)
                }
                QualityBadge(score: Double(SchlafindexView.score(for: session)))
            }

            HStack(spacing: 16) {
                Label(session.totalDuration.formattedDuration, systemImage: "clock")
                Label(session.deepSleepDuration.formattedDuration, systemImage: "moon.fill")
                if session.snoringEventCount > 0 {
                    Label("\(session.snoringEventCount)×", systemImage: "waveform")
                        .foregroundStyle(.orange)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if !session.phasesArray.isEmpty {
                SleepPhaseBarView(phases: session.phasesArray, totalDuration: session.totalDuration)
                    .frame(height: 8)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 4)
    }

    private func bewertungEmoji(_ q: Int) -> String {
        switch q {
        case 1: return "😴"
        case 2: return "🙁"
        case 3: return "😐"
        case 4: return "🙂"
        case 5: return "😄"
        default: return ""
        }
    }
}

// MARK: - Quality Badge

struct QualityBadge: View {
    let score: Double

    var color: Color {
        switch score {
        case 75...: return .green
        case 50..<75: return .yellow
        default: return .orange
        }
    }

    var body: some View {
        Text("\(Int(score))%")
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
