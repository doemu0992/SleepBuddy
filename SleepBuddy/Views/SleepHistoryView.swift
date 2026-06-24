import SwiftUI
import SwiftData
import Charts

struct SleepHistoryView: View {
    @Query(sort: \SleepSession.startDate, order: .reverse) private var sessions: [SleepSession]
    @Environment(\.modelContext) private var modelContext
    @AppStorage("schlafZielStunden") private var schlafZielStunden = 8.0

    private var abgeschlossene: [SleepSession] { sessions.filter { !$0.isActive } }

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
                    Section {
                        WochenSummaryCard(sessions: abgeschlossene, schlafZielStunden: schlafZielStunden)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)

                    ForEach(abgeschlossene) { session in
                        NavigationLink(destination: SleepDetailView(session: session)) {
                            SleepSessionRow(session: session)
                        }
                    }
                    .onDelete(perform: delete)
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
            let session = abgeschlossene[index]
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

    @State private var ausgewaehltTag: Date? = nil
    @State private var versteckTask: Task<Void, Never>? = nil

    private let cal = Calendar.current

    private var dieseWoche: [SleepSession] {
        let cutoff = cal.date(byAdding: .day, value: -7, to: Date())!
        return sessions.filter { ($0.endDate ?? .distantPast) >= cutoff }
    }

    private var letzteWoche: [SleepSession] {
        let start = cal.date(byAdding: .day, value: -14, to: Date())!
        let end   = cal.date(byAdding: .day, value: -7,  to: Date())!
        return sessions.filter {
            let d = $0.endDate ?? .distantPast
            return d >= start && d < end
        }
    }

    // 7 days: today back to 6 days ago
    private var chartTage: [Date] {
        (0..<7).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: cal.startOfDay(for: Date())) }
    }

    private struct TagDaten: Identifiable {
        let datum: Date
        let stunden: Double   // 0 if no session
        let qualitaet: Int    // 0 if no session
        var id: Date { datum }
    }

    private var chartDaten: [TagDaten] {
        chartTage.map { tag in
            let s = dieseWoche.first { cal.isDate($0.endDate ?? .distantPast, inSameDayAs: tag) }
            return TagDaten(datum: tag, stunden: (s?.totalDuration ?? 0) / 3600, qualitaet: s.map { SchlafindexView.score(for: $0) } ?? 0)
        }
    }

    private var avgDauerDiese: Double {
        guard !dieseWoche.isEmpty else { return 0 }
        return dieseWoche.map { $0.totalDuration / 3600 }.reduce(0, +) / Double(dieseWoche.count)
    }

    private var avgQualitaetDiese: Int {
        guard !dieseWoche.isEmpty else { return 0 }
        return dieseWoche.map { SchlafindexView.score(for: $0) }.reduce(0, +) / dieseWoche.count
    }

    private var avgTiefDiese: Double {
        guard !dieseWoche.isEmpty else { return 0 }
        return dieseWoche.map { $0.deepSleepDuration / 60 }.reduce(0, +) / Double(dieseWoche.count)
    }

    private var avgQualitaetLetzte: Int {
        guard !letzteWoche.isEmpty else { return 0 }
        return letzteWoche.map { SchlafindexView.score(for: $0) }.reduce(0, +) / letzteWoche.count
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
                Label("Diese Woche", systemImage: "chart.bar.fill")
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

            // Bar chart
            Chart(chartDaten) { tag in
                BarMark(
                    x: .value("Tag", tag.datum, unit: .day),
                    y: .value("Stunden", max(tag.stunden, tag.stunden == 0 ? 0.15 : 0))
                )
                .foregroundStyle(balkenFarbe(tag.qualitaet))
                .cornerRadius(4)

                if let sel = ausgewaehltTag, cal.isDate(tag.datum, inSameDayAs: sel) {
                    RuleMark(x: .value("Sel", sel, unit: .day))
                        .foregroundStyle(Color.indigo.opacity(0.25))
                        .lineStyle(StrokeStyle(lineWidth: 24, lineCap: .round))
                }
            }
            .chartOverlay { proxy in
                GeometryReader { _ in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture { loc in balkenTippen(proxy: proxy, location: loc) }
                }
            }
            // Schlafziel as dashed line
            .chartForegroundStyleScale(["Schlafziel": Color.indigo])
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
                AxisMarks(values: .stride(by: .day)) { val in
                    if val.as(Date.self) != nil {
                        AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                            .font(.caption2)
                    }
                }
            }
            .frame(height: 100)

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
        if !letzteWoche.isEmpty && avgQualitaetDiese > 0 {
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
