import SwiftUI
import SwiftData

struct MorgenBewertungCard: View {
    let session: SleepSession
    @Environment(\.modelContext) private var modelContext

    private let bewertungen: [(emoji: String, label: String)] = [
        ("😴", "Schlecht"),
        ("🙁", "Mäßig"),
        ("😐", "OK"),
        ("🙂", "Gut"),
        ("😄", "Super")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Wie hast du dich gefühlt?", systemImage: "face.smiling")
                .font(.headline).foregroundStyle(.indigo)

            Text("Deine Bewertung hilft der KI, deine Schlafphasen besser zu erkennen.")
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 0) {
                ForEach(1...5, id: \.self) { stufe in
                    Button {
                        bewerten(stufe: stufe)
                    } label: {
                        VStack(spacing: 5) {
                            Text(bewertungen[stufe - 1].emoji).font(.title2)
                            Text(bewertungen[stufe - 1].label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
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

    private func bewerten(stufe: Int) {
        session.subjectiveQuality = stufe
        // Bad rating (1-2): mark all samples of this session as user-corrected
        // so k-NN gives them higher weight and learns from the mismatch faster.
        if stufe <= 2, let start = session.sleepOnsetDate ?? Optional(session.startDate),
           let end = session.endDate {
            let desc = FetchDescriptor<TrainingSample>(
                predicate: #Predicate { $0.timestamp >= start && $0.timestamp <= end }
            )
            if let samples = try? modelContext.fetch(desc) {
                for s in samples { s.isUserCorrected = true }
            }
        }
        try? modelContext.save()
    }
}
