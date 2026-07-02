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
    @State private var correctingEvent: SleepSoundEvent?
    @State private var phaseTimelineExpanded = false
    // Aufklapp-Zustand der Sound-Listen (Schlafgeräusche/Umgebungsgeräusche, per Titel)
    // und der Geräusch-Intensität — gleiches Muster wie phaseTimelineExpanded.
    @State private var expandedSoundSections: Set<String> = []
    @State private var intensityExpanded = false
    @State private var spo2Percent: Double? = nil
    @State private var spo2Loaded = false
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    private func resolveAudioURL(for fileName: String) -> URL? {
        let local = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(soundsFolder)
        let iCloud = FileManager.default
            .url(forUbiquityContainerIdentifier: iCloudContainerID)?
            .appendingPathComponent("Documents")
            .appendingPathComponent(soundsFolder)

        let bareName = fileName.hasPrefix("local://")
            ? String(fileName.dropFirst("local://".count))
            : fileName
        let preferICloud = !fileName.hasPrefix("local://")

        // Primary location based on the stored prefix, with a fallback to the
        // other location — the file may have been saved before iCloud was ready.
        let primary = (preferICloud ? iCloud : local)?.appendingPathComponent(bareName)
        let fallback = (preferICloud ? local : iCloud)?.appendingPathComponent(bareName)

        if let p = primary, FileManager.default.fileExists(atPath: p.path) { return p }
        if let f = fallback, FileManager.default.fileExists(atPath: f.path) { return f }
        // Neither exists locally yet — return the iCloud URL so the download
        // path in togglePlayback can try to materialise it.
        return primary ?? fallback
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                heroHeader
                summaryCard

                // ── Schlafphasen ──
                if !session.phasesArray.isEmpty {
                    sectionHeader("Schlafphasen")
                    phasenCard
                    phaseTimelineCard
                }

                // ── Geräusche ──
                let sleepEvents = session.soundEventsArray.filter { !$0.type.isExternal }
                let externalEvents = session.soundEventsArray.filter { $0.type.isExternal }
                let hasNoise = !session.noiseSamples.isEmpty
                if !sleepEvents.isEmpty || !externalEvents.isEmpty || hasNoise {
                    sectionHeader("Geräusche")
                    if !sleepEvents.isEmpty {
                        schlafgeraeuscheCard
                    }
                    if !externalEvents.isEmpty || hasNoise {
                        umgebungCard
                    }
                }

                // ── Vitalwerte ──
                let hasHR = !session.heartRateSamples.filter({ $0 > 0 }).isEmpty
                let hasSpO2 = spo2Percent != nil && (spo2Percent ?? 0) > 0
                if hasHR || hasSpO2 {
                    sectionHeader("Vitalwerte")
                    if hasHR { heartRateCard }
                    if hasSpO2 { spo2Card }
                }

                // ── KI-Analyse ──
                sectionHeader("KI-Analyse")
                aiInsightCard
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
            spo2Loaded = true
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
        .sheet(item: $correctingEvent) { event in
            SoundCorrectionSheet(event: event) { confirmed, newType, specificLabel in
                applySoundCorrection(event: event, confirmed: confirmed, newType: newType, specificLabel: specificLabel)
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
        .padding(.top, 8)
        .padding(.horizontal, 4)
    }

    // MARK: - Hero Header

    private var heroHeader: some View {
        NavigationLink(destination: SchlafindexView(session: session)) {
            ZStack {
                LinearGradient(colors: [Color(red: 0.15, green: 0.15, blue: 0.42), .indigo, .purple],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .clipShape(RoundedRectangle(cornerRadius: 24))

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 5) {
                            Text(session.startDate.formatted(date: .omitted, time: .shortened))
                                .font(.caption).foregroundStyle(.white.opacity(0.7))
                            Image(systemName: "arrow.right")
                                .font(.caption2).foregroundStyle(.white.opacity(0.5))
                            Text(session.endDate?.formatted(date: .omitted, time: .shortened) ?? "–")
                                .font(.caption).foregroundStyle(.white.opacity(0.7))
                        }
                        Text(session.sleepDuration.formattedDuration)
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        if session.sleepDuration < session.totalDuration {
                            Label("Zeit im Bett \(session.totalDuration.formattedDuration)", systemImage: "bed.double.fill")
                                .font(.caption).foregroundStyle(.white.opacity(0.75))
                        }
                        HStack(spacing: 4) {
                            Text("Schlafindex ansehen")
                                .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                            Image(systemName: "chevron.right")
                                .font(.caption2.bold()).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    Spacer()
                    detailScoreRing(SchlafindexView.score(for: session))
                }
                .padding(20)
            }
            .frame(height: 150)
            .shadow(color: .indigo.opacity(0.3), radius: 12, x: 0, y: 6)
        }
        .buttonStyle(.plain)
    }

    private func detailScoreRing(_ score: Int) -> some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.2), lineWidth: 8)
            Circle().trim(from: 0, to: CGFloat(min(max(score, 0), 100)) / 100)
                .stroke(detailScoreColor(score), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(score)").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                Text("Index").font(.caption2).foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(width: 80, height: 80)
    }

    private func detailScoreColor(_ s: Int) -> Color {
        switch s { case ..<40: return .red; case ..<70: return .orange; case ..<85: return .yellow; default: return .green }
    }

    // MARK: - Summary Card (Phasen + Extra-Stats kombiniert)

    private var summaryCard: some View {
        let bruxismCount = session.soundEventsArray.filter { $0.type == .bruxism }.count
        let coughCount = session.soundEventsArray.filter { $0.type == .coughing }.count
        let hasExtra = session.sleepOnsetLatency != nil || session.snoringEventCount > 0
            || session.alarmFiredDate != nil || bruxismCount > 0 || coughCount > 0
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                statColumn("Tiefschlaf", value: session.deepSleepDuration.formattedDuration, icon: "moon.fill", color: SleepPhaseType.deep.color,
                           percent: pct(session.deepSleepDuration))
                Divider().frame(height: 52)
                statColumn("REM", value: session.remSleepDuration.formattedDuration, icon: "sparkles", color: SleepPhaseType.rem.color,
                           percent: pct(session.remSleepDuration))
                Divider().frame(height: 52)
                statColumn("Leichtschlaf", value: session.lightSleepDuration.formattedDuration, icon: "moon", color: SleepPhaseType.light.color,
                           percent: pct(session.lightSleepDuration))
            }

            if hasExtra {
                Divider().padding(.vertical, 14)
                HStack(spacing: 0) {
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
                        extraStat(alarmDate.formatted(date: .omitted, time: .shortened), icon: "alarm.fill", color: .green, label: "Geweckt")
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
    }

    private func statColumn(_ label: String, value: String, icon: String, color: Color, percent: Int) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon).foregroundStyle(color).font(.caption)
                Text("\(percent)%").font(.caption2.bold()).foregroundStyle(color)
            }
            Text(value).font(.title3.bold())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func pct(_ dur: TimeInterval) -> Int {
        guard session.totalDuration > 0 else { return 0 }
        return Int((dur / session.totalDuration) * 100)
    }

    // MARK: - Extra Stats

    private func extraStat(_ value: String, icon: String, color: Color, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(color).font(.subheadline)
            Text(value).font(.subheadline.bold())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Phase Bar

    // MARK: - Phasen-Karte (Balken + Verlauf-Chart kombiniert)

    private var phasenCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Phasen-Balken + Legende
            Label("Schlafphasen", systemImage: "bed.double.fill")
                .font(.headline)
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

            Divider().padding(.vertical, 2)

            // Verlauf-Chart
            Label("Verlauf", systemImage: "waveform.path.ecg")
                .font(.subheadline.bold()).foregroundStyle(.secondary)
            hypnogramChart
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
    }

    // MARK: - Hypnogram

    private struct HypnoPoint: Identifiable {
        let id: Date
        let time: Date
        let depth: Double  // 0.15=wach, 1=leicht, 2=rem, 3=tief
    }

    private func hypnoDepth(_ type: SleepPhaseType) -> Double {
        switch type {
        case .awake: return 0.0   // absolute bottom — same visual for start and end
        case .light: return 1.0
        case .rem:   return 2.0
        case .deep:  return 3.0
        }
    }

    private var hypnoData: [HypnoPoint] {
        let sorted = session.phasesArray.sorted { $0.startDate < $1.startDate }
        var points: [HypnoPoint] = []
        for phase in sorted {
            // Start of phase
            points.append(HypnoPoint(id: phase.startDate, time: phase.startDate, depth: hypnoDepth(phase.phaseType)))
            // End of phase — needed so SwiftCharts draws the full segment width
            // Use a UUID-based id offset so it doesn't collide with the next phase's startDate
            let endID = phase.endDate.addingTimeInterval(-0.001)
            points.append(HypnoPoint(id: endID, time: phase.endDate, depth: hypnoDepth(phase.phaseType)))
        }
        return points
    }

    // Gradient colors the wave line by Y position: orange(awake=0) → lightblue(light=1) → pink(rem=2) → purple(deep=3)
    // Y domain -0.15...3.3 (total span 3.45): thresholds at light=1/3.45≈0.29, rem=2/3.45≈0.58, deep=3/3.45≈0.87
    private var hypnoLineGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: SleepPhaseType.awake.color.opacity(0.9), location: 0.0),
                .init(color: SleepPhaseType.awake.color.opacity(0.9), location: 0.04),
                .init(color: SleepPhaseType.light.color.opacity(0.9), location: 0.29),
                .init(color: SleepPhaseType.rem.color.opacity(0.9),   location: 0.58),
                .init(color: SleepPhaseType.deep.color.opacity(0.9),  location: 0.87),
                .init(color: SleepPhaseType.deep.color.opacity(0.9),  location: 1.0),
            ],
            startPoint: .bottom,
            endPoint: .top
        )
    }

    private var chartTimeFmt: DateFormatter {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }

    @ViewBuilder
    private var trackerTimeRow: some View {
        HStack {
            Label(chartTimeFmt.string(from: session.startDate), systemImage: "play.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.indigo)
            Spacer()
            if let end = session.endDate {
                Label(chartTimeFmt.string(from: end), systemImage: "stop.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.indigo)
                    .environment(\.layoutDirection, .rightToLeft)
            }
        }
    }

    @ViewBuilder
    private var hypnogramChart: some View {
        if !session.phasesArray.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                trackerTimeRow

                Chart(hypnoData) { point in
                    AreaMark(
                        x: .value("Zeit", point.time),
                        yStart: .value("Boden", -0.15),
                        yEnd: .value("Tiefe", point.depth)
                    )
                    .interpolationMethod(.stepStart)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [SleepPhaseType.deep.color.opacity(0.25), SleepPhaseType.deep.color.opacity(0.05)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("Zeit", point.time),
                        y: .value("Tiefe", point.depth)
                    )
                    .interpolationMethod(.stepStart)
                    .foregroundStyle(hypnoLineGradient)
                    .lineStyle(StrokeStyle(lineWidth: 2))

                    RuleMark(x: .value("Start", session.startDate))
                        .foregroundStyle(Color.indigo.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))

                    if let end = session.endDate {
                        RuleMark(x: .value("Ende", end))
                            .foregroundStyle(Color.indigo.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                }
                .chartYScale(domain: -0.15...3.3)
                .chartYAxis {
                    AxisMarks(values: [0.0, 1.0, 2.0, 3.0]) { val in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4]))
                            .foregroundStyle(Color.secondary.opacity(0.3))
                        AxisValueLabel {
                            let v = val.as(Double.self) ?? -1
                            if v < 0.5 {
                                Text("Wach").font(.caption2).foregroundStyle(SleepPhaseType.awake.color)
                            } else if v < 1.5 {
                                Text("Leicht").font(.caption2).foregroundStyle(SleepPhaseType.light.color)
                            } else if v < 2.5 {
                                Text("REM").font(.caption2).foregroundStyle(SleepPhaseType.rem.color)
                            } else {
                                Text("Tief").font(.caption2).foregroundStyle(SleepPhaseType.deep.color)
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
                .chartXScale(domain: session.startDate...(session.endDate ?? Date()))
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: 3 * 3600)
                .frame(height: 130)
            }
        }
    }

    // MARK: - SpO₂ Card

    @ViewBuilder
    private var spo2Card: some View {
        if let spo2 = spo2Percent, spo2 > 0 {
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
        session.noiseSamples.enumerated().compactMap { i, db in
            guard db > 1.0 else { return nil }  // skip unrecorded minutes
            return NoiseSample(
                id: i,
                time: session.startDate.addingTimeInterval(Double(i + 1) * 60),
                db: max(15.0, min(90.0, db))
            )
        }
    }

    // Adaptive Y domain: zoom to actual data range so quiet nights aren't squashed
    private var noiseYDomain: ClosedRange<Double> {
        guard !noiseData.isEmpty else { return 20...90 }
        let lo = max(15.0, (noiseData.map(\.db).min()! - 5).rounded(.down))
        let hi = min(92.0, (noiseData.map(\.db).max()! + 8).rounded(.up))
        return lo...hi
    }

    private func noiseStops(domain: ClosedRange<Double>) -> [Gradient.Stop] {
        let span = domain.upperBound - domain.lowerBound
        let s35 = max(0, min(1, (35 - domain.lowerBound) / span))
        let s70 = max(0, min(1, (70 - domain.lowerBound) / span))
        return [
            .init(color: .green,  location: 0.0),
            .init(color: .green,  location: s35),
            .init(color: .orange, location: s35),
            .init(color: .orange, location: s70),
            .init(color: .red,    location: s70),
            .init(color: .red,    location: 1.0),
        ]
    }

    private func noiseLineGrad(domain: ClosedRange<Double>) -> LinearGradient {
        LinearGradient(stops: noiseStops(domain: domain), startPoint: .bottom, endPoint: .top)
    }

    private func noiseAreaGrad(domain: ClosedRange<Double>) -> LinearGradient {
        let stops = noiseStops(domain: domain).map {
            Gradient.Stop(color: $0.color.opacity(0.35), location: $0.location)
        }
        return LinearGradient(stops: stops, startPoint: .bottom, endPoint: .top)
    }

    private var ambientNoiseSection: some View {
        let domain = noiseYDomain
        let lineGrad = noiseLineGrad(domain: domain)
        let areaGrad = noiseAreaGrad(domain: domain)
        let data = noiseData
        let events = session.soundEventsArray.filter { $0.decibelLevel > 0 }

        return VStack(alignment: .leading, spacing: 12) {
            Label("Umgebungslautstärke", systemImage: "waveform.and.mic").font(.headline)

            trackerTimeRow

            Chart {
                ForEach(data) { sample in
                    AreaMark(
                        x: .value("Zeit", sample.time),
                        yStart: .value("Boden", domain.lowerBound),
                        yEnd: .value("dB", sample.db)
                    )
                    .foregroundStyle(areaGrad)
                    .interpolationMethod(.monotone)

                    LineMark(
                        x: .value("Zeit", sample.time),
                        y: .value("dB", sample.db)
                    )
                    .foregroundStyle(lineGrad)
                    .lineStyle(StrokeStyle(lineWidth: 2.2))
                    .interpolationMethod(.monotone)
                }

                if domain.contains(35) {
                    RuleMark(y: .value("35 dB", 35.0))
                        .foregroundStyle(Color.green.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                }
                if domain.contains(70) {
                    RuleMark(y: .value("70 dB", 70.0))
                        .foregroundStyle(Color.red.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                }

                RuleMark(x: .value("Start", session.startDate))
                    .foregroundStyle(Color.indigo.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))

                if let end = session.endDate {
                    RuleMark(x: .value("Ende", end))
                        .foregroundStyle(Color.indigo.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }

                // Event markers (ShutEye-Stil): farbige Punkte an Event-Timestamps
                ForEach(events, id: \.timestamp) { event in
                    let yPos = min(max(event.decibelLevel, domain.lowerBound + 2), domain.upperBound - 1)
                    PointMark(
                        x: .value("Zeit", event.timestamp),
                        y: .value("dB", yPos)
                    )
                    .foregroundStyle(event.type.color)
                    .symbolSize(55)
                    .symbol(.circle)
                }
            }
            .chartYScale(domain: domain)
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { val in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                    AxisValueLabel {
                        if let v = val.as(Double.self) {
                            Text("\(Int(v)) dB").font(.caption2)
                        }
                    }
                }
            }
            .chartXScale(domain: session.startDate...(session.endDate ?? Date()))
            .chartScrollableAxes(.horizontal)
            .chartXVisibleDomain(length: 3 * 3600)
            .chartPlotStyle { $0.padding(.trailing, 4) }
            .frame(height: 180)

            HStack(spacing: 12) {
                legendDot(.green,  "< 35 dB Ruhig")
                legendDot(.orange, "35–70 dB Normal")
                legendDot(.red,    "> 70 dB Laut")
                if !events.isEmpty {
                    HStack(spacing: 4) {
                        Circle().fill(Color.secondary).frame(width: 8, height: 8)
                        Text("Ereignis").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Heart Rate Chart

    private struct HRPoint: Identifiable {
        let id: Int
        let time: Date
        let bpm: Double
        let estimated: Bool   // true = held value (BCG signal was unreliable here)
        let segment: Int      // contiguous run id (for dashed-overlay grouping)
    }

    private static func hrMedian(_ a: [Double]) -> Double {
        let s = a.sorted(); return s.isEmpty ? 0 : s[s.count / 2]
    }

    /// Robust HR series: plausibility range + median-of-5 smoothing + delta
    /// limiting (reject jumps > 12 BPM/min), then Variante B — fill gaps by
    /// holding the last good value, flagged `estimated` for dashed display.
    private var heartRatePoints: [HRPoint] {
        let raw = session.heartRateSamples
        guard !raw.isEmpty else { return [] }

        // 1. plausibility mask (40–110 BPM during sleep)
        let vals: [Double?] = raw.map { ($0 >= 40 && $0 <= 110) ? $0 : nil }

        // 2. median-of-5 smoothing over available neighbours
        var smoothed: [Double?] = Array(repeating: nil, count: vals.count)
        for i in vals.indices where vals[i] != nil {
            var win: [Double] = []
            for j in max(0, i - 2)...min(vals.count - 1, i + 2) { if let x = vals[j] { win.append(x) } }
            smoothed[i] = win.isEmpty ? vals[i] : Self.hrMedian(win)
        }

        // 3. delta-limit: reject jumps > 12 BPM from last accepted value;
        //    3 consecutive rejects = genuine level shift → adopt their median.
        var accepted: [Double?] = Array(repeating: nil, count: smoothed.count)
        var last: Double? = nil
        var rejectRun: [Double] = []
        for i in smoothed.indices {
            guard let v = smoothed[i] else { continue }
            if let l = last {
                if abs(v - l) <= 12 {
                    accepted[i] = v; last = v; rejectRun.removeAll()
                } else {
                    rejectRun.append(v)
                    if rejectRun.count >= 3 {
                        let m = Self.hrMedian(rejectRun); accepted[i] = m; last = m; rejectRun.removeAll()
                    }
                }
            } else {
                accepted[i] = v; last = v
            }
        }

        guard let firstIdx = accepted.firstIndex(where: { $0 != nil }),
              let lastIdx = accepted.lastIndex(where: { $0 != nil }) else { return [] }

        // 4. Variante B: hold last good value across gaps, flag as estimated.
        var points: [HRPoint] = []
        var hold = accepted[firstIdx]!
        var seg = 0
        var prevEstimated: Bool? = nil
        for i in firstIdx...lastIdx {
            let measured = accepted[i]
            let estimated = measured == nil
            let bpm = measured ?? hold
            if let m = measured { hold = m }
            if prevEstimated != estimated { seg += 1; prevEstimated = estimated }
            points.append(HRPoint(id: i,
                                  time: session.startDate.addingTimeInterval(Double(i) * 60),
                                  bpm: bpm, estimated: estimated, segment: seg))
        }
        return points
    }

    private var heartRateCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Herzfrequenz", systemImage: "heart.fill").font(.headline).foregroundStyle(.pink)

            trackerTimeRow

            let data = heartRatePoints
            let minBPM = (data.map(\.bpm).min() ?? 40) - 5
            let maxBPM = (data.map(\.bpm).max() ?? 100) + 5

            Chart {
                // Resting HR reference zone: dashed boundary lines at 50 and 70 BPM
                if maxBPM > 50 {
                    RuleMark(y: .value("Ruhepuls min", 50.0))
                        .foregroundStyle(Color.gray.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                if maxBPM > 70 {
                    RuleMark(y: .value("Ruhepuls max", 70.0))
                        .foregroundStyle(Color.gray.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }

                // Continuous smoothed line + area (measured + held values)
                ForEach(data) { p in
                    LineMark(x: .value("Zeit", p.time), y: .value("BPM", p.bpm))
                        .foregroundStyle(.pink)
                        .interpolationMethod(.catmullRom)
                    AreaMark(x: .value("Zeit", p.time),
                             yStart: .value("Boden", minBPM),
                             yEnd: .value("BPM", p.bpm))
                        .foregroundStyle(LinearGradient(
                            colors: [.pink.opacity(0.25), .pink.opacity(0.05)],
                            startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.catmullRom)
                }

                // Grey dashed overlay on estimated (held) spans — grouped per run
                ForEach(data.filter { $0.estimated }) { p in
                    LineMark(x: .value("Zeit", p.time), y: .value("BPM", p.bpm),
                             series: .value("Segment", p.segment))
                        .foregroundStyle(Color.gray.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                        .interpolationMethod(.catmullRom)
                }

                RuleMark(x: .value("Start", session.startDate))
                    .foregroundStyle(Color.indigo.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))

                if let end = session.endDate {
                    RuleMark(x: .value("Ende", end))
                        .foregroundStyle(Color.indigo.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
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
            .chartXScale(domain: session.startDate...(session.endDate ?? Date()))
            .chartScrollableAxes(.horizontal)
            .chartXVisibleDomain(length: 3 * 3600)
            .frame(height: 120)
            .clipped()

            HStack(spacing: 6) {
                Rectangle()
                    .fill(Color.gray.opacity(0.40))
                    .frame(width: 16, height: 1)
                Text("Ruhepuls-Zone (50–70 BPM)")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("┄ geschätzt")
                    .font(.caption2).foregroundStyle(Color.gray.opacity(0.8))
            }

            Text("Quelle: Ballistokardiographie (Beschleunigungssensor) oder Apple Watch. Unzuverlässige Abschnitte werden geglättet und als „geschätzt“ markiert.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
    }

    // MARK: - Sound Events

    private func soundGroup(events: [SleepSoundEvent], title: String, icon: String) -> some View {
        // Aufklappbar wie „Phasen im Detail": erst 4 Ereignisse, „Alle X anzeigen".
        let sorted = events.sorted { $0.timestamp < $1.timestamp }
        let expanded = expandedSoundSections.contains(title)
        let visible = expanded ? sorted : Array(sorted.prefix(4))
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon).foregroundStyle(.indigo)
                Text(title).font(.headline)
                Spacer()
                Text("\(events.count) Ereignisse")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ForEach(visible, id: \.timestamp) { event in
                soundEventRow(event)
            }

            if sorted.count > 4 {
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                        if expanded { expandedSoundSections.remove(title) }
                        else { expandedSoundSections.insert(title) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(expanded ? "Weniger anzeigen" : "Alle \(sorted.count) Ereignisse anzeigen")
                            .font(.caption.bold())
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.bold())
                    }
                    .foregroundStyle(.indigo)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func soundEventRow(_ event: SleepSoundEvent) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(event.type.color.opacity(0.15)).frame(width: 36, height: 36)
                Image(systemName: event.type.icon).foregroundStyle(event.type.color).font(.caption)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(event.displayName).font(.subheadline.bold())
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

            Button { correctingEvent = event } label: {
                Image(systemName: event.isUserCorrected ? "checkmark.circle.fill" : "pencil.circle")
                    .font(.title3)
                    .foregroundStyle(event.isUserCorrected ? .green : .secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Schlafgeräusche-Karte (Events + Schnarch-Intensität)

    // Alle Schlafgeräusche (nicht nur Schnarchen) mit messbarem dB-Wert.
    private var sleepIntensityEvents: [SleepSoundEvent] {
        session.soundEventsArray
            .filter { !$0.type.isExternal && $0.decibelLevel > 0 }
            .sorted { $0.timestamp < $1.timestamp }
    }

    @ViewBuilder
    private var schlafgeraeuscheCard: some View {
        let sleep = session.soundEventsArray.filter { !$0.type.isExternal }
        let intensity = sleepIntensityEvents
        VStack(alignment: .leading, spacing: 14) {
            if !sleep.isEmpty {
                soundGroup(events: sleep, title: "Schlafgeräusche", icon: "waveform.badge.mic")
            }
            if !sleep.isEmpty && !intensity.isEmpty {
                Divider()
            }
            if !intensity.isEmpty {
                soundIntensitySection(intensity)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
    }

    private func soundIntensitySection(_ events: [SleepSoundEvent]) -> some View {
        // Aufklappbar wie „Phasen im Detail": erst 4 Balken, „Alle X anzeigen".
        let visible = intensityExpanded ? events : Array(events.prefix(4))
        return VStack(alignment: .leading, spacing: 12) {
            Label("Geräusch-Intensität", systemImage: "waveform")
                .font(.headline).foregroundStyle(.indigo)

            ForEach(visible, id: \.timestamp) { event in
                let db = event.decibelLevel
                let dbColor: Color = db < 50 ? .green : (db < 65 ? .yellow : .red)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.displayName)
                            .font(.caption.bold()).foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(event.timestamp.formatted(date: .omitted, time: .shortened))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(width: 88, alignment: .leading)
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

            if events.count > 4 {
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                        intensityExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(intensityExpanded ? "Weniger anzeigen" : "Alle \(events.count) anzeigen")
                            .font(.caption.bold())
                        Image(systemName: intensityExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.bold())
                    }
                    .foregroundStyle(.indigo)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Umgebungs-Karte (Lautstärke + externe Geräusche)

    @ViewBuilder
    private var umgebungCard: some View {
        let external = session.soundEventsArray.filter { $0.type.isExternal }
        let hasNoise = !session.noiseSamples.isEmpty
        VStack(alignment: .leading, spacing: 14) {
            if !external.isEmpty {
                soundGroup(events: external, title: "Umgebungsgeräusche", icon: "ear.fill")
            }
            if hasNoise && !external.isEmpty {
                Divider()
            }
            if hasNoise {
                ambientNoiseSection
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
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
                        await MainActor.run {
                            downloadingEventID = nil
                            playFile(at: url, event: event)
                        }
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
        // Stop any currently playing clip first so we never overlap / lose the handle.
        audioPlayer?.stop()
        audioPlayer = nil
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("⚠️ Audio playback: file not found at \(url.path)")
            playingEventID = nil
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            print("⚠️ Audio playback: session error \(error)")
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            player.volume = 1.0
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
            print("⚠️ Audio playback: AVAudioPlayer error \(error)")
            playingEventID = nil
        }
    }

    // MARK: - Phase Timeline

    // Sortiert, ohne Null-Dauer-Phasen und ohne doppelte Startzeiten — verhindert
    // „2× Wach mit gleicher Zeit" und doppelte ForEach-IDs.
    private var cleanedPhases: [SleepPhase] {
        let sorted = session.phasesArray
            .filter { $0.endDate > $0.startDate }
            .sorted { $0.startDate < $1.startDate }
        var result: [SleepPhase] = []
        for phase in sorted {
            if let last = result.last, last.startDate == phase.startDate { continue }
            result.append(phase)
        }
        return result
    }

    private var phaseTimelineCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Phasen im Detail").font(.headline)
                Spacer()
                Text("Tippe zum Korrigieren").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.bottom, 12)

            let sorted = cleanedPhases
            let collapsedCount = 4
            let visible = phaseTimelineExpanded ? sorted : Array(sorted.prefix(collapsedCount))
            ForEach(Array(visible.enumerated()), id: \.element.startDate) { i, phase in
                let isLast = i == visible.count - 1
                VStack(spacing: 0) {
                    Button { correctingPhase = phase } label: {
                        HStack(spacing: 12) {
                            // Timeline dot + line
                            VStack(spacing: 0) {
                                Circle()
                                    .fill(phase.phaseType.color)
                                    .frame(width: 10, height: 10)
                                if !isLast {
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
                            .padding(.bottom, !isLast ? 20 : 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            if sorted.count > collapsedCount {
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                        phaseTimelineExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(phaseTimelineExpanded ? "Weniger anzeigen" : "Alle \(sorted.count) Phasen anzeigen")
                            .font(.caption.bold())
                        Image(systemName: phaseTimelineExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.bold())
                    }
                    .foregroundStyle(.indigo)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 14)
                }
                .buttonStyle(.plain)
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

    private func applySoundCorrection(event: SleepSoundEvent, confirmed: Bool, newType: SoundEventType?, specificLabel: String? = nil) {
        let ud = UserDefaults.standard
        if confirmed {
            ud.set(ud.integer(forKey: "soundFeedback.\(event.type.rawValue).confirmed") + 1,
                   forKey: "soundFeedback.\(event.type.rawValue).confirmed")
            event.isUserCorrected = true
        } else if let specificLabel {
            // Relabel to a specific Apple class → stored as ambient with the precise name.
            ud.set(ud.integer(forKey: "soundFeedback.\(event.type.rawValue).rejected") + 1,
                   forKey: "soundFeedback.\(event.type.rawValue).rejected")
            if event.originalTypeRaw == nil { event.originalTypeRaw = event.typeRaw }
            event.typeRaw = SoundEventType.ambient.rawValue
            event.mlLabel = specificLabel
            event.isUserCorrected = true
        } else if let newType {
            let orig = event.type
            ud.set(ud.integer(forKey: "soundFeedback.\(orig.rawValue).rejected") + 1,
                   forKey: "soundFeedback.\(orig.rawValue).rejected")
            ud.set(ud.integer(forKey: "soundFeedback.\(newType.rawValue).missed") + 1,
                   forKey: "soundFeedback.\(newType.rawValue).missed")
            if event.originalTypeRaw == nil { event.originalTypeRaw = event.typeRaw }
            event.typeRaw = newType.rawValue
            event.mlLabel = nil      // a named category overrides any specific catch-all label
            event.isUserCorrected = true
        }
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

// MARK: - Sound Correction Sheet

struct SoundCorrectionSheet: View {
    let event: SleepSoundEvent
    /// (confirmed, newType, specificAppleLabel). specificAppleLabel is set only when the user
    /// picks a precise Apple class from the full list → stored as .ambient with that name.
    let onDone: (Bool, SoundEventType?, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var audioPlayer: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var zeigeAlleKlassen = false

    private var sleepTypes: [SoundEventType] { SoundEventType.allCases.filter { !$0.isExternal } }
    private var externalTypes: [SoundEventType] { SoundEventType.allCases.filter { $0.isExternal } }

    var body: some View {
        NavigationStack {
            List {
                // Audio preview section
                if let fileName = event.iCloudFileName {
                    Section {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Aufnahme anhören")
                                    .font(.subheadline.bold())
                                Text(event.timestamp.formatted(date: .omitted, time: .shortened) + " · " + formatDuration(event.durationSeconds))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { togglePlay(fileName: fileName) } label: {
                                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                                    .font(.largeTitle)
                                    .foregroundStyle(isPlaying ? .orange : .indigo)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Current detection
                Section {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(event.type.color.opacity(0.15)).frame(width: 40, height: 40)
                            Image(systemName: event.type.icon).foregroundStyle(event.type.color)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Erkannt als: \(event.displayName)")
                                .font(.subheadline.bold())
                            if let orig = event.originalType, orig != event.type {
                                Text("Ursprünglich: \(orig.rawValue)").font(.caption).foregroundStyle(.secondary)
                            }
                            if event.confidenceScore > 0 {
                                Text("Konfidenz: \(Int(event.confidenceScore * 100))%")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if !event.isUserCorrected {
                            Button {
                                onDone(true, nil, nil)
                                dismiss()
                            } label: {
                                Label("Korrekt", systemImage: "checkmark.circle.fill")
                                    .font(.caption.bold())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.green, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                } header: {
                    Text("Erkennung")
                }

                // Reassign — personal sounds
                Section {
                    ForEach(sleepTypes, id: \.self) { type in
                        Button {
                            onDone(false, type, nil)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle().fill(type.color.opacity(0.15)).frame(width: 36, height: 36)
                                    Image(systemName: type.icon).foregroundStyle(type.color).font(.caption)
                                }
                                Text(type.rawValue).foregroundStyle(.primary)
                                Spacer()
                                if type == event.type {
                                    Image(systemName: "checkmark").foregroundStyle(.indigo)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Als Schlafgeräusch zuordnen")
                }

                // Reassign — external sounds
                Section {
                    ForEach(externalTypes, id: \.self) { type in
                        Button {
                            onDone(false, type, nil)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle().fill(type.color.opacity(0.15)).frame(width: 36, height: 36)
                                    Image(systemName: type.icon).foregroundStyle(type.color).font(.caption)
                                }
                                Text(type.rawValue).foregroundStyle(.primary)
                                Spacer()
                                if type == event.type {
                                    Image(systemName: "checkmark").foregroundStyle(.indigo)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Als Umgebungsgeräusch zuordnen")
                } footer: {
                    Text("Korrekturen werden gespeichert und verbessern die Erkennung dauerhaft.")
                }

                // Full Apple taxonomy (~300 classes) — precise relabelling
                Section {
                    Button {
                        zeigeAlleKlassen = true
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(Color.indigo.opacity(0.15)).frame(width: 36, height: 36)
                                Image(systemName: "magnifyingglass").foregroundStyle(.indigo).font(.caption)
                            }
                            Text("Weiteres Geräusch wählen …").foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption2.bold()).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Alle von Apple erkennbaren Geräuschklassen — für eine genaue Zuordnung.")
                }
            }
            .navigationTitle("Geräusch korrigieren")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .onDisappear { audioPlayer?.stop() }
        .sheet(isPresented: $zeigeAlleKlassen) {
            AppleClassPickerView { germanName in
                onDone(false, nil, germanName)   // relabel to specific Apple class
                dismiss()
            }
        }
    }

    private func togglePlay(fileName: String) {
        if isPlaying {
            audioPlayer?.stop()
            audioPlayer = nil
            isPlaying = false
            return
        }
        let url: URL?
        if fileName.hasPrefix("local://") {
            let name = String(fileName.dropFirst("local://".count))
            url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent("SleepSounds").appendingPathComponent(name)
        } else {
            url = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.DG-Software-Solution.PainDiary")?
                .appendingPathComponent("Documents/SleepSounds/\(fileName)")
        }
        guard let url else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        if let player = try? AVAudioPlayer(contentsOf: url) {
            player.play()
            audioPlayer = player
            isPlaying = true
            Task {
                try? await Task.sleep(for: .seconds(player.duration + 0.5))
                await MainActor.run { isPlaying = false; audioPlayer = nil }
            }
        }
    }

    private func formatDuration(_ s: TimeInterval) -> String {
        let i = Int(s); return i < 60 ? "\(i)s" : "\(i/60)m \(i%60)s"
    }
}

// MARK: - Full Apple class picker (searchable ~300 classes)

/// Searchable list of every Apple .version1 sound class (German names) for precise relabelling.
struct AppleClassPickerView: View {
    let onPick: (String) -> Void          // passes the chosen German class name
    @Environment(\.dismiss) private var dismiss
    @State private var suche = ""
    @State private var alle: [(id: String, german: String)] = []

    private var gefiltert: [(id: String, german: String)] {
        guard !suche.isEmpty else { return alle }
        return alle.filter { $0.german.localizedCaseInsensitiveContains(suche) }
    }

    var body: some View {
        NavigationStack {
            List(gefiltert, id: \.id) { item in
                Button {
                    onPick(item.german)
                    dismiss()
                } label: {
                    Text(item.german).foregroundStyle(.primary)
                }
            }
            .searchable(text: $suche, prompt: "Geräusch suchen")
            .navigationTitle("Alle Geräusche")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
            }
            .onAppear {
                if alle.isEmpty, #available(iOS 15, *) {
                    alle = SoundClassificationService.allClasses()
                }
            }
        }
        .presentationDetents([.large])
    }
}
