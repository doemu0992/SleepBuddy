import SwiftUI
import SwiftData

struct MorgenBewertungCard: View {
    let session: SleepSession
    @Environment(\.modelContext) private var modelContext

    @State private var selectedQuality: Int = 0
    @State private var selectedRecording: Int = 0
    @State private var feedbackMask: Int = 0

    private let qualityOptions: [(emoji: String, label: String)] = [
        ("😴", "Schlecht"), ("🙁", "Mäßig"), ("😐", "OK"), ("🙂", "Gut"), ("😄", "Super")
    ]

    private let recordingOptions: [(icon: String, label: String, color: Color)] = [
        ("hand.thumbsdown.fill", "Ungenau", .red),
        ("minus.circle.fill",   "OK",      .secondary),
        ("hand.thumbsup.fill",  "Präzise", .green)
    ]

    // Bitmask-Werte für die 4 Feedback-Optionen
    private struct FeedbackOption {
        let bit: Int
        let icon: String
        let text: String
    }
    private let feedbackOptions: [FeedbackOption] = [
        FeedbackOption(bit: 1, icon: "eye.fill",           text: "Ich war öfter wach als angezeigt"),
        FeedbackOption(bit: 2, icon: "moon.stars.fill",    text: "Ich hatte lebhafte Träume — aber kein REM war markiert"),
        FeedbackOption(bit: 4, icon: "moon.zzz.fill",      text: "Ich bin früher/später eingeschlafen als angezeigt"),
        FeedbackOption(bit: 8, icon: "alarm.fill",         text: "Ich bin früher/später aufgewacht als angezeigt"),
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
                            session.subjectiveQuality = stufe
                            try? modelContext.save()
                            FeedbackCalibrationService.shared.calibrate(context: modelContext)
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
            VStack(alignment: .leading, spacing: 10) {
                Text("Wie gut hat die App deine Nacht erkannt?")
                    .font(.subheadline.weight(.medium))

                HStack(spacing: 8) {
                    ForEach(1...3, id: \.self) { stufe in
                        let opt = recordingOptions[stufe - 1]
                        let isSelected = selectedRecording == stufe
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                                selectedRecording = stufe
                                if stufe != 1 { feedbackMask = 0 }
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

                // Expandierendes Feedback bei "Ungenau"
                if selectedRecording == 1 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Was war ungenau?")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)

                        ForEach(feedbackOptions, id: \.bit) { opt in
                            let isOn = (feedbackMask & opt.bit) != 0
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    feedbackMask ^= opt.bit
                                }
                                session.recordingFeedbackMask = feedbackMask
                                try? modelContext.save()
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: isOn ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(isOn ? .indigo : .secondary)
                                        .font(.body)
                                    Image(systemName: opt.icon)
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                        .frame(width: 16)
                                    Text(opt.text)
                                        .font(.caption)
                                        .foregroundStyle(.primary)
                                        .multilineTextAlignment(.leading)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(
                                    isOn ? Color.indigo.opacity(0.07) : Color.secondary.opacity(0.04),
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                            }
                            .buttonStyle(.plain)
                            .animation(.easeInOut(duration: 0.15), value: isOn)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
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
            feedbackMask = session.recordingFeedbackMask
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: selectedRecording)
    }

    private func saveRecording(_ stufe: Int) {
        session.recordingQuality = stufe
        if stufe != 1 {
            session.recordingFeedbackMask = 0
            feedbackMask = 0
        }
        try? modelContext.save()
        FeedbackCalibrationService.shared.calibrate(context: modelContext)
    }
}
