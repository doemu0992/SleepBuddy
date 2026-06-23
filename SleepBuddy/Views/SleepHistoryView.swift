import SwiftUI
import SwiftData

struct SleepHistoryView: View {
    @Query(sort: \SleepSession.startDate, order: .reverse) private var sessions: [SleepSession]
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Group {
            if sessions.filter({ !$0.isActive }).isEmpty {
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
                    ForEach(sessions.filter { !$0.isActive }) { session in
                        NavigationLink(destination: SleepDetailView(session: session)) {
                            SleepSessionRow(session: session)
                        }
                    }
                    .onDelete(perform: delete)
                }
                .listStyle(.insetGrouped)
                .toolbar {
                    EditButton()
                }
            }
        }
        .navigationTitle("Verlauf")
        .navigationBarTitleDisplayMode(.large)
    }

    private func delete(at offsets: IndexSet) {
        let visible = sessions.filter { !$0.isActive }
        for index in offsets {
            let session = visible[index]
            for phase in session.phases { modelContext.delete(phase) }
            modelContext.delete(session)
        }
        try? modelContext.save()
    }
}

private struct SleepSessionRow: View {
    let session: SleepSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(session.startDate, style: .date)
                    .font(.headline)
                Spacer()
                QualityBadge(score: session.computedQualityScore)
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

            if !session.phases.isEmpty {
                SleepPhaseBarView(phases: session.phases, totalDuration: session.totalDuration)
                    .frame(height: 8)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 4)
    }
}

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
