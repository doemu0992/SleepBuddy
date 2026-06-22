import SwiftUI

struct SleepDetailView: View {
    let session: SleepSession

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerCard
                phaseBreakdownCard
                phaseTimelineCard
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(session.startDate.formatted(date: .abbreviated, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
    }

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
                            Text(duration.formattedDuration)
                                .foregroundStyle(.secondary)
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

    private var phaseTimelineCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Zeitverlauf")
                .font(.headline)

            ForEach(session.phases, id: \.startDate) { phase in
                HStack {
                    Image(systemName: phase.phaseType.icon)
                        .foregroundStyle(phase.phaseType.color)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(phase.phaseType.rawValue).font(.subheadline.bold())
                        Text("\(phase.startDate.formatted(date: .omitted, time: .shortened)) – \(phase.endDate.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(phase.duration.formattedDuration)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
