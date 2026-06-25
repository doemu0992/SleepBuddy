import SwiftUI
import SwiftData

struct MorgenBewertungCard: View {
    let session: SleepSession
    @Environment(\.modelContext) private var modelContext
    @State private var selected: Int = 0

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

            Text("Deine Bewertung beeinflusst das KI-Training: Top-Nächte werden stärker gewichtet, schlechte ausgeschlossen.")
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 0) {
                ForEach(1...5, id: \.self) { stufe in
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                            selected = stufe
                        }
                        bewerten(stufe: stufe)
                    } label: {
                        VStack(spacing: 5) {
                            Text(bewertungen[stufe - 1].emoji)
                                .font(.title2)
                                .scaleEffect(selected == stufe ? 1.3 : 1.0)
                            Text(bewertungen[stufe - 1].label)
                                .font(.caption2)
                                .foregroundStyle(selected == stufe ? .indigo : .secondary)
                                .fontWeight(selected == stufe ? .bold : .regular)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            selected == stufe
                                ? Color.indigo.opacity(0.1)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if selected > 0 {
                let msg = selected >= 4
                    ? "Diese Nacht wird stärker gewichtet — die KI lernt mehr aus ihr."
                    : selected == 1
                    ? "Diese Nacht wird aus dem Training ausgeschlossen."
                    : "Bewertung gespeichert."
                Label(msg, systemImage: selected == 1 ? "xmark.circle" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(selected >= 4 ? .green : selected == 1 ? .red : .secondary)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
        .onAppear { selected = session.subjectiveQuality }
        .animation(.easeInOut(duration: 0.2), value: selected)
    }

    private func bewerten(stufe: Int) {
        session.subjectiveQuality = stufe
        try? modelContext.save()
    }
}
