import SwiftUI
import SwiftData
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
                statsGrid
                if session.sleepOnsetLatency != nil || session.snoringEventCount > 0 || session.alarmFiredDate != nil {
                    extraStatsRow
                }
                phaseBarCard
                aiInsightCard
                if !session.soundEvents.isEmpty {
                    soundEventsCard
                }
                phaseTimelineCard
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(session.startDate.formatted(date: .long, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) { deleteSession() } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .task {
            if insightService.summary == nil && !insightService.isGenerating {
                await insightService.generateInsights(for: session)
            }
        }
        .sheet(item: $correctingPhase) { phase in
            PhaseCorrectionSheet(phase: phase) { newType in
                applyCorrection(phase: phase, newType: newType)
            }
        }
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
                    QualityBadge(score: session.computedQualityScore)
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
            statCard("Tiefschlaf", value: session.deepSleepDuration.formattedDuration, icon: "moon.fill", color: .indigo,
                     percent: pct(session.deepSleepDuration))
            statCard("REM", value: session.remSleepDuration.formattedDuration, icon: "sparkles", color: .purple,
                     percent: pct(session.remSleepDuration))
            statCard("Leichtschlaf", value: session.lightSleepDuration.formattedDuration, icon: "moon", color: .blue,
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
    }

    private func pct(_ dur: TimeInterval) -> Int {
        guard session.totalDuration > 0 else { return 0 }
        return Int((dur / session.totalDuration) * 100)
    }

    // MARK: - Extra Stats

    private var extraStatsRow: some View {
        HStack(spacing: 0) {
            if let latency = session.sleepOnsetLatency {
                extraStat(formatMinutes(latency), icon: "zzz", color: .indigo, label: "Einschlafen")
            }
            if session.snoringEventCount > 0 {
                Divider().frame(height: 40)
                extraStat("\(session.snoringEventCount)×", icon: "waveform", color: .orange, label: "Schnarchen")
            }
            if let alarmDate = session.alarmFiredDate {
                Divider().frame(height: 40)
                extraStat(alarmDate.formatted(date: .omitted, time: .shortened), icon: "alarm.fill", color: .green, label: "Smart Alarm")
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
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
            Text("Schlafphasen")
                .font(.headline)

            if !session.phases.isEmpty {
                SleepPhaseBarView(phases: session.phases, totalDuration: session.totalDuration)
                    .frame(height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                HStack(spacing: 16) {
                    ForEach(SleepPhaseType.allCases, id: \.self) { type in
                        let dur = session.phases.filter { $0.phaseType == type }.reduce(0) { $0 + $1.duration }
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
    }

    // MARK: - Sound Events

    private var soundEventsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "waveform.badge.mic").foregroundStyle(.indigo)
                Text("Schlafgeräusche").font(.headline)
                Spacer()
                Text("\(session.soundEvents.count) Ereignisse")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ForEach(session.soundEvents.sorted { $0.timestamp < $1.timestamp }, id: \.timestamp) { event in
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

                    Text(formatEventDuration(event.durationSeconds))
                        .font(.caption).foregroundStyle(.secondary)

                    if let fileName = event.iCloudFileName {
                        Button {
                            togglePlayback(event: event, fileName: fileName)
                        } label: {
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
                        Image(systemName: "waveform.slash")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
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

            ForEach(Array(session.phases.enumerated()), id: \.element.startDate) { i, phase in
                VStack(spacing: 0) {
                    Button { correctingPhase = phase } label: {
                        HStack(spacing: 12) {
                            // Timeline dot + line
                            VStack(spacing: 0) {
                                Circle()
                                    .fill(phase.phaseType.color)
                                    .frame(width: 10, height: 10)
                                if i < session.phases.count - 1 {
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
                            .padding(.bottom, i < session.phases.count - 1 ? 20 : 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
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
        for phase in session.phases { modelContext.delete(phase) }
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
