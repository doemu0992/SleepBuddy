import SwiftUI
import SwiftData
import Charts
import AVFoundation

private let iCloudContainerID = "iCloud.DG-Software-Solution.PainDiary"
private let soundsFolder = "SleepSounds"

struct SleepDetailView: View {
    let session: SleepSession
    @State private var insightService = SleepInsightService()
    @State private var correctingPhase: SleepPhase?
    @State private var audioPlayer: AVAudioPlayer?
    @State private var playingEventID: Date?
    @State private var downloadingEventID: Date?
    @State private var spo2Percent: Double? = nil
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    private func resolveAudioURL(for fileName: String) -> URL? {
        if fileName.hasPrefix("local://") {
            let name = String(fileName.dropFirst("local://".count))
            return FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent(soundsFolder)
                .appendingPathComponent(name)
        }
        return FileManager.default
            .url(forUbiquityContainerIdentifier: iCloudContainerID)?
            .appendingPathComponent("Documents")
            .appendingPathComponent(soundsFolder)
            .appendingPathComponent(fileName)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                heroHeader
                schlafindexButton
                statsGrid
                let bruxismCount = session.soundEventsArray.filter { $0.type == .bruxism }.count
                let coughCount = session.soundEventsArray.filter { $0.type == .coughing }.count
                if session.sleepOnsetLatency != nil || session.snoringEventCount > 0 || session.alarmFiredDate != nil || bruxismCount > 0 || coughCount > 0 {
                    extraStatsRow
                }
                phaseBarCard
                hypnogramCard
                spo2Card
                if !session.noiseSamples.isEmpty {
                    ambientNoiseCard
                }
                if !session.heartRateSamples.filter({ $0 > 0 }).isEmpty {
                    heartRateCard
                }
                aiInsightCard
                let sleepEvents = session.soundEventsArray.filter { !$0.type.isExternal }
                let externalEvents = session.soundEventsArray.filter { $0.type.isExternal }
                if !sleepEvents.isEmpty {
                    soundEventsCard(events: sleepEvents, title: "Schlafgeräusche", icon: "waveform.badge.mic")
                }
                if !externalEvents.isEmpty {
                    soundEventsCard(events: externalEvents, title: "Umgebungsgeräusche", icon: "ear.fill")
                }
                snoringIntensityCard
                phaseTimelineCard
            }
            .padding()
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(session.startDate.formatted(date: .long, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let hk = HealthKitService()
            if let end = session.endDate {
                spo2Percent = await hk.averageSpO2(from: session.startDate, to: end)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) { deleteSession() } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .sheet(item: $correctingPhase) { phase in
            PhaseCorrectionSheet(phase: phase) { newType in
                applyCorrection(phase: phase, newType: newType)
            }
        }
    }

    // MARK: - Schlafindex Button

    private var schlafindexButton: some View {
        NavigationLink(destination: SchlafindexView(session: session)) {
            HStack {
                Label("Schlafindex anzeigen", systemImage: "chart.pie.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                Spacer()
                HStack(spacing: 4) {
                    Text("\(SchlafindexView.score(for: session))")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.indigo, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Hero Header

    private var heroHeader: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                .clipShape(RoundedRectangle(cornerRadius: 20))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(session.startDate.formatted(date: .omitted, time: .shortened))
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                    Image(systemName: "arrow.right")
                        .font(.caption2).foregroundStyle(.white.opacity(0.5))
                    Text(session.endDate?.formatted(date: .omitted, time: .shortened) ?? "–")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    QualityBadge(score: Double(SchlafindexView.score(for: session)))
                }
                Text(session.totalDuration.formattedDuration)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Gesamtschlafdauer")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.7))
            }
            .padding(20)
        }
        .frame(height: 140)
    }

    // MARK: - Stats Grid

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            statCard("Tiefschlaf", value: session.deepSleepDuration.formattedDuration, icon: "moon.fill", color: SleepPhaseType.deep.color,
                     percent: pct(session.deepSleepDuration))
            statCard("REM", value: session.remSleepDuration.formattedDuration, icon: "sparkles", color: SleepPhaseType.rem.color,
                     percent: pct(session.remSleepDuration))
            statCard("Leichtschlaf", value: session.lightSleepDuration.formattedDuration, icon: "moon", color: SleepPhaseType.light.color,
                     percent: pct(session.lightSleepDuration))
        }
    }

    private func statCard(_ label: String, value: String, icon: String, color: Color, percent: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon).foregroundStyle(color).font(.caption)
                Spacer()
                Text("\(percent)%").font(.caption2.bold()).foregroundStyle(color)
            }
            Text(value).font(.title3.bold())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
    }

    private func pct(_ dur: TimeInterval) -> Int {
        guard session.totalDuration > 0 else { return 0 }
        return Int((dur / session.totalDuration) * 100)
    }

    // MARK: - Extra Stats

    private var extraStatsRow: some View {
        let bruxismCount = session.soundEventsArray.filter { $0.type == .bruxism }.count
        let coughCount = session.soundEventsArray.filter { $0.type == .coughing }.count
        return HStack(spacing: 0) {
            if let latency = session.sleepOnsetLatency {
                extraStat(formatMinutes(latency), icon: "zzz", color: .indigo, label: "Einschlafen")
            }
            if session.snoringEventCount > 0 {
                Divider().frame(height: 40)
                extraStat("\(session.snoringEventCount)×", icon: "waveform", color: .orange, label: "Schnarchen")
            }
            if bruxismCount > 0 {
                Divider().frame(height: 40)
                extraStat("\(bruxismCount)×", icon: "mouth.fill", color: .pink, label: "Zähneknirschen")
            }
            if coughCount > 0 {
                Divider().frame(height: 40)
                extraStat("\(coughCount)×", icon: "lungs.fill", color: .teal, label: "Husten")
            }
            if let alarmDate = session.alarmFiredDate {
                Divider().frame(height: 40)
                extraStat(alarmDate.formatted(date: .omitted, time: .shortened), icon: "alarm.fill", color: .green, label: "Smart Alarm")
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
    }

    private func extraStat(_ value: String, icon: String, color: Color, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(color).font(.subheadline)
            Text(value).font(.subheadline.bold())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Phase Bar

    private var phaseBarCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Schlafphasen", systemImage: "bed.double.fill")
                .font(.headline)

            if !session.phasesArray.isEmpty {
                SleepPhaseBarView(phases: session.phasesArray, totalDuration: session.totalDuration)
                    .frame(height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                HStack(spacing: 16) {
                    ForEach(SleepPhaseType.allCases, id: \.self) { type in
                        let dur = session.phasesArray.filter { $0.phaseType == type }.reduce(0) { $0 + $1.duration }
                        if dur > 0 {
                            HStack(spacing: 4) {
                                Circle().fill(type.color).frame(width: 8, height: 8)
                                Text(type.rawValue).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                Text("Keine Phasendaten verfügbar").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
    }

    // MARK: - Hypnogram

    private struct HypnoPoint: Identifiable {
        let id = UUID()
        let time: Date
        let depth: Double  // 0=wach, 1=leicht, 2=rem, 3=tief
        let phase: SleepPhaseType
    }

    private var hypnoData: [HypnoPoint] {
        let sorted = session.phasesArray.sorted { $0.startDate < $1.startDate }
        var points: [HypnoPoint] = []
        for phase in sorted {
            let depth: Double = switch phase.phaseType {
            case .awake: 0
            case .light: 1
            case .rem:   2
            case .deep:  3
            }
            points.append(HypnoPoint(time: phase.startDate, depth: depth, phase: phase.phaseType))
            points.append(HypnoPoint(time: phase.endDate,   depth: depth, phase: phase.phaseType))
        }
        return points
    }

    @ViewBuilder
    private var hypnogramCard: some View {
        if !session.phasesArray.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label("Schlafverlauf", systemImage: "waveform.path.ecg")
                    .font(.headline)

                Chart(hypnoData) { point in
                    LineMark(
                        x: .value("Zeit", point.time),
                        y: .value("Tiefe", point.depth)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [SleepPhaseType.deep.color.opacity(0.7), SleepPhaseType.rem.color.opacity(0.7)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.stepStart)

                    AreaMark(
                        x: .value("Zeit", point.time),
                        yStart: .value("Boden", -0.1),
                        yEnd: .value("Tiefe", point.depth)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [SleepPhaseType.deep.color.opacity(0.25), SleepPhaseType.deep.color.opacity(0.05)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.stepStart)
                }
                .chartYScale(domain: -0.1...3.3)
                .chartYAxis {
                    AxisMarks(values: [0, 1, 2, 3]) { val in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4]))
                            .foregroundStyle(Color.secondary.opacity(0.3))
                        AxisValueLabel {
                            switch val.as(Int.self) {
                            case 0: Text("Wach").font(.caption2).foregroundStyle(SleepPhaseType.awake.color)
                            case 1: Text("Leicht").font(.caption2).foregroundStyle(SleepPhaseType.light.color)
                            case 2: Text("REM").font(.caption2).foregroundStyle(SleepPhaseType.rem.color)
                            case 3: Text("Tief").font(.caption2).foregroundStyle(SleepPhaseType.deep.color)
                            default: EmptyView()
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4]))
                            .foregroundStyle(Color.secondary.opacity(0.2))
                        AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                            .font(.caption2)
                    }
                }
                .frame(height: 130)
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
        }
    }

    // MARK: - SpO₂ Card

    @ViewBuilder
    private var spo2Card: some View {
        if let spo2 = spo2Percent {
            let pct = Int(spo2 * 100)
            let color: Color = pct >= 95 ? .green : pct >= 90 ? .yellow : .red
            let label: String = pct >= 95 ? "Normal" : pct >= 90 ? "Leicht reduziert" : "Reduziert"

            VStack(alignment: .leading, spacing: 12) {
                Label("Blutsauerstoff (SpO₂)", systemImage: "drop.fill")
                    .font(.headline)

                HStack(spacing: 20) {
                    ZStack {
                        Circle()
                            .stroke(color.opacity(0.15), lineWidth: 10)
                        Circle()
                            .trim(from: 0, to: CGFloat(pct) / 100)
                            .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 2) {
                            Text("\(pct)%")
                                .font(.title2.bold())
                                .foregroundStyle(color)
                            Text("SpO₂")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 80, height: 80)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(label)
                            .font(.subheadline.bold())
                            .foregroundStyle(color)
                        Text("Ø über die gesamte Nacht, gemessen via Apple Watch.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if pct < 90 {
                            Label("Konsultiere einen Arzt bei anhaltend niedrigem SpO₂.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
        }
    }

    // MARK: - AI Insight Card

    private var aiInsightCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.indigo)
                Text("Analyse").font(.headline)
                Spacer()
                if insightService.isGenerating {
                    ProgressView().scaleEffect(0.75)
                }
            }

            if insightService.isGenerating {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Wird analysiert…").font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else if insightService.summary == nil && insightService.error == nil {
                Button {
                    Task { await insightService.generateInsights(for: session) }
                } label: {
                    Label("Analyse starten", systemImage: "sparkles")
                        .font(.subheadline.bold()).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color.indigo, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            } else if let summary = insightService.summary {
                Text(summary)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)

                if !insightService.recommendations.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(insightService.recommendations.enumerated()), id: \.offset) { i, rec in
                            HStack(alignment: .top, spacing: 10) {
                                ZStack {
                                    Circle().fill(Color.indigo.opacity(0.15)).frame(width: 24, height: 24)
                                    Text("\(i + 1)").font(.caption.bold()).foregroundStyle(.indigo)
                                }
                                Text(rec).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            } else if let error = insightService.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
    }

    // MARK: - Ambient Noise Chart

    private struct NoiseSample: Identifiable {
        let id: Int
        let time: Date
        let db: Double
    }

    private var noiseData: [NoiseSample] {
        session.noiseSamples.enumerated().map { i, db in
            NoiseSample(id: i, time: session.startDate.addingTimeInterval(Double(i) * 60), db: db)
        }
    }

    private func noiseColor(_ db: Double) -> Color {
        db < 35 ? .green : db < 50 ? .orange : .red
    }

    private var ambientNoiseCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Umgebungslautstärke", systemImage: "waveform.and.mic").font(.headline)

            Chart(noiseData) { sample in
                // Colored area fill: three stacked areas for thresholds
                AreaMark(
                    x: .value("Zeit", sample.time),
                    yStart: .value("Boden", 20.0),
                    yEnd: .value("dB", min(sample.db, 35.0))
                )
                .foregroundStyle(Color.green.opacity(0.18))
                .interpolationMethod(.catmullRom)

                AreaMark(
                    x: .value("Zeit", sample.time),
                    yStart: .value("Boden", min(sample.db, 35.0)),
                    yEnd: .value("dB", min(sample.db, 50.0))
                )
                .foregroundStyle(Color.orange.opacity(0.20))
                .interpolationMethod(.catmullRom)

                AreaMark(
                    x: .value("Zeit", sample.time),
                    yStart: .value("Boden", min(sample.db, 50.0)),
                    yEnd: .value("dB", sample.db)
                )
                .foregroundStyle(Color.red.opacity(0.22))
                .interpolationMethod(.catmullRom)

                // Wave line colored by current dB level
                LineMark(
                    x: .value("Zeit", sample.time),
                    y: .value("dB", sample.db)
                )
                .foregroundStyle(noiseColor(sample.db))
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.catmullRom)
            }
            .chartYScale(domain: 20...90)
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                }
            }
            .chartYAxis {
                AxisMarks(values: [35, 50, 70]) { val in
                    AxisGridLine().foregroundStyle(
                        val.as(Int.self) == 35 ? Color.green.opacity(0.4)
                        : val.as(Int.self) == 50 ? Color.orange.opacity(0.4)
                        : Color.red.opacity(0.4)
                    )
                    AxisValueLabel { Text("\(val.as(Int.self) ?? 0) dB").font(.caption2) }
                }
            }
            .frame(height: 110)

            // Legend
            HStack(spacing: 16) {
                legendDot(.green,  "< 35 dB  Sehr ruhig")
                legendDot(.orange, "35–50 dB  Normal")
                legendDot(.red,    "> 50 dB  Laut")
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Heart Rate Chart

    private struct HRSample: Identifiable {
        let id: Int
        let time: Date
        let bpm: Double
    }

    private var heartRateData: [HRSample] {
        session.heartRateSamples.enumerated().compactMap { i, bpm in
            guard bpm > 0 else { return nil }
            return HRSample(id: i, time: session.startDate.addingTimeInterval(Double(i) * 60), bpm: bpm)
        }
    }

    private var heartRateCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Herzfrequenz", systemImage: "heart.fill").font(.headline).foregroundStyle(.pink)

            let data = heartRateData
            let minBPM = (data.map(\.bpm).min() ?? 40) - 5
            let maxBPM = (data.map(\.bpm).max() ?? 100) + 5

            Chart(data) { sample in
                LineMark(
                    x: .value("Zeit", sample.time),
                    y: .value("BPM", sample.bpm)
                )
                .foregroundStyle(.pink)
                .interpolationMethod(.catmullRom)
                AreaMark(
                    x: .value("Zeit", sample.time),
                    yStart: .value("Boden", minBPM),
                    yEnd: .value("BPM", sample.bpm)
                )
                .foregroundStyle(LinearGradient(
                    colors: [.pink.opacity(0.25), .pink.opacity(0.05)],
                    startPoint: .top, endPoint: .bottom
                ))
                .interpolationMethod(.catmullRom)
            }
            .chartYScale(domain: minBPM...maxBPM)
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { val in
                    AxisGridLine().foregroundStyle(Color.pink.opacity(0.2))
                    AxisValueLabel { Text("\(val.as(Int.self) ?? 0)").font(.caption2) }
                }
            }
            .frame(height: 100)

            Text("Quelle: Ballistokardiographie (Beschleunigungssensor) oder Apple Watch")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
    }

    // MARK: - Sound Events

    private func soundEventsCard(events: [SleepSoundEvent], title: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon).foregroundStyle(.indigo)
                Text(title).font(.headline)
                Spacer()
                Text("\(events.count) Ereignisse")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ForEach(events.sorted { $0.timestamp < $1.timestamp }, id: \.timestamp) { event in
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(event.type.color.opacity(0.15)).frame(width: 36, height: 36)
                        Image(systemName: event.type.icon).foregroundStyle(event.type.color).font(.caption)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.type.rawValue).font(.subheadline.bold())
                        Text(event.timestamp.formatted(date: .omitted, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(formatEventDuration(event.durationSeconds))
                            .font(.caption).foregroundStyle(.secondary)
                        if event.decibelLevel > 0 {
                            Text("\(Int(event.decibelLevel)) dB")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }

                    if let fileName = event.iCloudFileName {
                        Button { togglePlayback(event: event, fileName: fileName) } label: {
                            if downloadingEventID == event.timestamp {
                                ProgressView().tint(.indigo).frame(width: 28, height: 28)
                            } else {
                                Image(systemName: playingEventID == event.timestamp ? "stop.circle.fill" : "play.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(playingEventID == event.timestamp ? .orange : .indigo)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(downloadingEventID == event.timestamp)
                    } else {
                        Image(systemName: "waveform.slash").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
    }

    // MARK: - Snoring Intensity Card

    @ViewBuilder
    private var snoringIntensityCard: some View {
        let snoringEvents = session.soundEventsArray
            .filter { $0.type == .snoring && $0.decibelLevel > 0 }
            .sorted { $0.timestamp < $1.timestamp }
        if !snoringEvents.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label("Schnarch-Intensität", systemImage: "waveform")
                    .font(.headline).foregroundStyle(.indigo)

                ForEach(snoringEvents, id: \.timestamp) { event in
                    let db = event.decibelLevel
                    let dbColor: Color = db < 50 ? .green : (db < 65 ? .yellow : .red)
                    HStack(spacing: 12) {
                        Text(event.timestamp.formatted(date: .omitted, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .leading)
                        GeometryReader { geo in
                            Capsule()
                                .fill(dbColor.opacity(0.2))
                                .overlay(alignment: .leading) {
                                    Capsule()
                                        .fill(dbColor)
                                        .frame(width: geo.size.width * min(db / 100.0, 1.0))
                                }
                        }
                        .frame(height: 8)
                        Text("\(Int(db)) dB")
                            .font(.caption.bold()).foregroundStyle(dbColor)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
        }
    }

    private func formatEventDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s < 60 ? "\(s)s" : "\(s/60)m \(s%60)s"
    }

    private func togglePlayback(event: SleepSoundEvent, fileName: String) {
        if playingEventID == event.timestamp {
            audioPlayer?.stop()
            audioPlayer = nil
            playingEventID = nil
            return
        }

        guard let url = resolveAudioURL(for: fileName) else { return }

        // Check if file needs to be downloaded from iCloud first
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        let status = values?.ubiquitousItemDownloadingStatus
        if status == .notDownloaded {
            downloadingEventID = event.timestamp
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            Task {
                for _ in 0..<30 {
                    try? await Task.sleep(for: .seconds(1))
                    let v = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                    if v?.ubiquitousItemDownloadingStatus == .current {
                        await MainActor.run { downloadingEventID = nil }
                        playFile(at: url, event: event)
                        return
                    }
                }
                await MainActor.run { downloadingEventID = nil }
            }
            return
        }

        playFile(at: url, event: event)
    }

    private func playFile(at url: URL, event: SleepSoundEvent) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback)
        try? session.setActive(true)

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.play()
            audioPlayer = player
            playingEventID = event.timestamp

            Task {
                try? await Task.sleep(for: .seconds(player.duration + 0.5))
                await MainActor.run {
                    if self.playingEventID == event.timestamp {
                        self.playingEventID = nil
                        self.audioPlayer = nil
                        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, options: [.defaultToSpeaker])
                    }
                }
            }
        } catch {
            playingEventID = nil
        }
    }

    // MARK: - Phase Timeline

    private var phaseTimelineCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Verlauf").font(.headline)
                Spacer()
                Text("Tippe zum Korrigieren").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.bottom, 12)

            let sorted = session.phasesArray.sorted { $0.startDate < $1.startDate }
            ForEach(Array(sorted.enumerated()), id: \.element.startDate) { i, phase in
                VStack(spacing: 0) {
                    Button { correctingPhase = phase } label: {
                        HStack(spacing: 12) {
                            // Timeline dot + line
                            VStack(spacing: 0) {
                                Circle()
                                    .fill(phase.phaseType.color)
                                    .frame(width: 10, height: 10)
                                if i < sorted.count - 1 {
                                    Rectangle()
                                        .fill(Color.secondary.opacity(0.2))
                                        .frame(width: 2, height: 32)
                                }
                            }
                            .frame(width: 16)

                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(phase.phaseType.rawValue)
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.primary)
                                    Text("\(phase.startDate.formatted(date: .omitted, time: .shortened)) – \(phase.endDate.formatted(date: .omitted, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(phase.duration.formattedDuration)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.bottom, i < sorted.count - 1 ? 20 : 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
    }

    // MARK: - Actions

    private func applyCorrection(phase: SleepPhase, newType: SleepPhaseType) {
        let classifier = MLSleepClassifier()
        classifier.loadSamples(from: modelContext)
        classifier.correctSamples(from: phase.startDate, to: phase.endDate, correctPhase: newType, context: modelContext)
        phase.phaseType = newType
        try? modelContext.save()
    }

    private func deleteSession() {
        for phase in session.phasesArray { modelContext.delete(phase) }
        modelContext.delete(session)
        try? modelContext.save()
        dismiss()
    }

    private func formatMinutes(_ interval: TimeInterval) -> String {
        let m = Int(interval / 60)
        return m < 60 ? "\(m)m" : "\(m / 60)h \(m % 60)m"
    }
}

// MARK: - Phase Correction Sheet

struct PhaseCorrectionSheet: View {
    let phase: SleepPhase
    let onCorrect: (SleepPhaseType) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(SleepPhaseType.allCases, id: \.self) { type in
                        Button {
                            onCorrect(type)
                            dismiss()
                        } label: {
                            HStack(spacing: 14) {
                                ZStack {
                                    Circle().fill(type.color.opacity(0.15)).frame(width: 36, height: 36)
                                    Image(systemName: type.icon).foregroundStyle(type.color)
                                }
                                Text(type.rawValue).foregroundStyle(.primary)
                                Spacer()
                                if type == phase.phaseType {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.indigo)
                                }
                            }
                        }
                    }
                } header: {
                    Text("\(phase.startDate.formatted(date: .omitted, time: .shortened)) – \(phase.endDate.formatted(date: .omitted, time: .shortened))")
                } footer: {
                    Text("Korrekturen werden gespeichert und verbessern die KI dauerhaft.")
                }
            }
            .navigationTitle("Phase korrigieren")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
    }
}
