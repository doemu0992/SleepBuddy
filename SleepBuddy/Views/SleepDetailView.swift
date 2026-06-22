import SwiftUI
import SwiftData

struct SleepDetailView: View {
    let session: SleepSession
    @State private var insightService = SleepInsightService()
    @State private var correctingPhase: SleepPhase?
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerCard
                aiInsightCard
                phaseBreakdownCard
                phaseTimelineCard
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(session.startDate.formatted(date: .abbreviated, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
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

    // MARK: - AI Insight Card

    private var aiInsightCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Apple Intelligence", systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(.indigo)
                Spacer()
                if insightService.isGenerating {
                    ProgressView().scaleEffect(0.8)
                }
            }

            if insightService.isGenerating {
                Text("Analyse wird erstellt…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if let summary = insightService.summary {
                Text(summary)
                    .font(.subheadline)

                if !insightService.recommendations.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Empfehlungen")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        ForEach(insightService.recommendations, id: \.self) { rec in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.indigo)
                                    .font(.caption)
                                    .padding(.top, 2)
                                Text(rec).font(.subheadline)
                            }
                        }
                    }
                }
            } else if let error = insightService.error {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Header Card

    private var headerCard: some View {
        VStack(spacing: 16) {
            HStack(spacing: 0) {
                statColumn("Schlafdauer", value: session.totalDuration.formattedDuration, icon: "clock.fill", color: .indigo)
                Divider().frame(height: 50)
                statColumn("Qualität", value: "\(Int(session.computedQualityScore))%", icon: "star.fill", color: .purple)
            }
            HStack(spacing: 0) {
                statColumn("Tiefschlaf", value: session.deepSleepDuration.formattedDuration, icon: "moon.fill", color: .indigo)
                Divider().frame(height: 50)
                statColumn("REM", value: session.remSleepDuration.formattedDuration, icon: "sparkles", color: .purple)
                Divider().frame(height: 50)
                statColumn("Leicht", value: session.lightSleepDuration.formattedDuration, icon: "moon", color: .blue)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func statColumn(_ label: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(color)
            Text(value).font(.title3.bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - Phase Breakdown

    private var phaseBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Schlafphasen-Verteilung")
                .font(.headline)

            if !session.phases.isEmpty {
                SleepPhaseBarView(phases: session.phases, totalDuration: session.totalDuration)
                    .frame(height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                ForEach(SleepPhaseType.allCases, id: \.self) { type in
                    let duration = session.phases.filter { $0.phaseType == type }.reduce(0) { $0 + $1.duration }
                    if duration > 0 {
                        HStack {
                            Circle().fill(type.color).frame(width: 10, height: 10)
                            Text(type.rawValue)
                            Spacer()
                            Text(duration.formattedDuration).foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }
                }
            } else {
                Text("Keine Phasendaten verfügbar")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Phase Timeline (with correction)

    private var phaseTimelineCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Zeitverlauf")
                    .font(.headline)
                Spacer()
                Text("Tippe zum Korrigieren")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(session.phases, id: \.startDate) { phase in
                Button {
                    correctingPhase = phase
                } label: {
                    HStack {
                        Image(systemName: phase.phaseType.icon)
                            .foregroundStyle(phase.phaseType.color)
                            .frame(width: 24)
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

    // MARK: - Correction

    private func applyCorrection(phase: SleepPhase, newType: SleepPhaseType) {
        let classifier = MLSleepClassifier()
        classifier.loadSamples(from: modelContext)
        classifier.correctSamples(from: phase.startDate, to: phase.endDate, correctPhase: newType, context: modelContext)
        phase.phaseType = newType
        try? modelContext.save()
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
                    Text("Welche Schlafphase war das wirklich?")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("\(phase.startDate.formatted(date: .omitted, time: .shortened)) – \(phase.endDate.formatted(date: .omitted, time: .shortened))")
                }

                Section("Phase wählen") {
                    ForEach(SleepPhaseType.allCases, id: \.self) { type in
                        Button {
                            onCorrect(type)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: type.icon)
                                    .foregroundStyle(type.color)
                                    .frame(width: 28)
                                Text(type.rawValue)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if type == phase.phaseType {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.indigo)
                                }
                            }
                        }
                    }
                }

                Section {
                    Text("Korrekturen verbessern den Klassifikator dauerhaft — je mehr du korrigierst, desto genauer wird die App.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
