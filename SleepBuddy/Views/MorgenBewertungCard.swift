import SwiftUI
import SwiftData

struct MorgenBewertungCard: View {
    let session: SleepSession
    @Environment(\.modelContext) private var modelContext
    @Query private var trainingSamples: [TrainingSample]

    @State private var selectedQuality: Int = 0
    @State private var selectedRecording: Int = 0

    private let qualityOptions: [(emoji: String, label: String)] = [
        ("😴", "Schlecht"), ("🙁", "Mäßig"), ("😐", "OK"), ("🙂", "Gut"), ("😄", "Super")
    ]

    private let recordingOptions: [(icon: String, label: String, color: Color)] = [
        ("hand.thumbsdown.fill", "Ungenau", .red),
        ("minus.circle.fill",   "OK",      .secondary),
        ("hand.thumbsup.fill",  "Präzise", .green)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Morgen-Bewertung", systemImage: "sun.horizon.fill")
                .font(.headline).foregroundStyle(.indigo)

            // MARK: Schlaf-Qualität
            VStack(alignment: .leading, spacing: 8) {
                Text("Wie hast du geschlafen?")
                    .font(.subheadline.weight(.medium))

                HStack(spacing: 0) {
                    ForEach(1...5, id: \.self) { stufe in
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                selectedQuality = stufe
                            }
                            saveQuality(stufe)
                        } label: {
                            VStack(spacing: 4) {
                                Text(qualityOptions[stufe - 1].emoji)
                                    .font(.title2)
                                    .scaleEffect(selectedQuality == stufe ? 1.25 : 1.0)
                                Text(qualityOptions[stufe - 1].label)
                                    .font(.caption2)
                                    .foregroundStyle(selectedQuality == stufe ? .indigo : .secondary)
                                    .fontWeight(selectedQuality == stufe ? .bold : .regular)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                selectedQuality == stufe ? Color.indigo.opacity(0.1) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                        }
                        .buttonStyle(.plain)
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: selectedQuality)
                    }
                }
            }

            Divider()

            // MARK: Aufzeichnungs-Qualität
            VStack(alignment: .leading, spacing: 8) {
                Text("Wie gut hat die App deine Nacht erkannt?")
                    .font(.subheadline.weight(.medium))

                HStack(spacing: 8) {
                    ForEach(1...3, id: \.self) { stufe in
                        let opt = recordingOptions[stufe - 1]
                        let isSelected = selectedRecording == stufe
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                selectedRecording = stufe
                            }
                            saveRecording(stufe)
                        } label: {
                            VStack(spacing: 5) {
                                Image(systemName: opt.icon)
                                    .font(.title3)
                                    .foregroundStyle(isSelected ? opt.color : .secondary)
                                    .scaleEffect(isSelected ? 1.2 : 1.0)
                                Text(opt.label)
                                    .font(.caption2)
                                    .foregroundStyle(isSelected ? opt.color : .secondary)
                                    .fontWeight(isSelected ? .bold : .regular)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                isSelected ? opt.color.opacity(0.12) : Color.secondary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                        }
                        .buttonStyle(.plain)
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: selectedRecording)
                    }
                }

            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
        .onAppear {
            selectedQuality = session.subjectiveQuality
            selectedRecording = session.recordingQuality
        }
    }

    private func saveQuality(_ stufe: Int) {
        session.subjectiveQuality = stufe
        try? modelContext.save()
    }

    private func saveRecording(_ stufe: Int) {
        session.recordingQuality = stufe
        try? modelContext.save()

        // Aufzeichnung ungenau → TrainingSamples dieser Nacht als unzuverlässig markieren
        if stufe == 1 {
            let sessionStart = session.startDate
            let sessionEnd = session.endDate ?? Date()
            let affected = trainingSamples.filter {
                $0.timestamp >= sessionStart && $0.timestamp <= sessionEnd
            }
            for s in affected { s.isUserCorrected = true }
            try? modelContext.save()
        }
    }
}
