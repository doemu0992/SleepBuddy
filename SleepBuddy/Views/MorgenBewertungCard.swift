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

// MARK: - FeedbackCalibrationService
// Defined here (not in a separate file) to avoid Xcode build-target registration issues.
// Automatically adjusts the sleep phase classifier based on accumulated morning feedback.
// Stage 1 (<10 nights): collect only. Stage 2 (10–20): threshold calibration. Stage 3 (20+): label correction.
final class FeedbackCalibrationService {

    static let shared = FeedbackCalibrationService()

    private let ud = UserDefaults.standard

    var currentStage: Int { ud.integer(forKey: "calibration.stage") }

    func calibrate(context: ModelContext) {
        let sessions = fetchRatedSessions(context: context)
        let ratedCount = sessions.count
        ud.set(ratedCount, forKey: "calibration.ratedNightCount")

        let stage = stageFor(ratedCount)
        ud.set(stage, forKey: "calibration.stage")

        switch stage {
        case 1:
            break
        case 2:
            applyStage2(sessions: sessions)
        default:
            applyStage2(sessions: sessions)
            applyStage3(sessions: sessions, context: context)
        }
    }

    private func stageFor(_ ratedCount: Int) -> Int {
        switch ratedCount {
        case 0..<10:  return 1
        case 10..<20: return 2
        default:      return 3
        }
    }

    private func applyStage2(sessions: [SleepSession]) {
        let inaccurate = sessions.filter { $0.recordingQuality == 1 }.suffix(20)
        guard !inaccurate.isEmpty else { return }
        let total = Double(inaccurate.count)

        let wachRatio = Double(inaccurate.filter { $0.recordingFeedbackMask & 1 != 0 }.count) / total
        ud.set(-wachRatio * 0.10,  forKey: "calibration.awakeMotionOffset")
        ud.set(-wachRatio * 0.010, forKey: "calibration.awakeAmplitudeOffset")

        let remRatio = Double(inaccurate.filter { $0.recordingFeedbackMask & 2 != 0 }.count) / total
        ud.set(remRatio * 0.08, forKey: "calibration.remConfBoost")
    }

    private func applyStage3(sessions: [SleepSession], context: ModelContext) {
        let toCorrect = sessions.filter { $0.recordingQuality == 1 && $0.recordingFeedbackMask != 0 }
        guard !toCorrect.isEmpty else { return }
        var didChange = false

        for session in toCorrect {
            let mask = session.recordingFeedbackMask
            let start = session.startDate
            let end   = session.endDate ?? Date()
            let samples = fetchSamples(in: start...end, context: context)
            guard !samples.isEmpty else { continue }

            if mask & 1 != 0 {
                for s in samples where s.phase != .awake && s.movementIntensity > 0.12 {
                    s.label = SleepPhaseType.awake.rawValue
                    s.isUserCorrected = true
                    didChange = true
                }
            }
            if mask & 2 != 0 {
                for s in samples where s.phase == .light {
                    let cyclePos = s.elapsedMinutesSinceOnset.truncatingRemainder(dividingBy: 90)
                    if cyclePos >= 60 && s.breathingRegularity < 0.50 {
                        s.label = SleepPhaseType.rem.rawValue
                        s.isUserCorrected = true
                        didChange = true
                    }
                }
            }
        }
        if didChange { try? context.save() }
    }

    private func fetchRatedSessions(context: ModelContext) -> [SleepSession] {
        let desc = FetchDescriptor<SleepSession>(
            predicate: #Predicate { $0.recordingQuality > 0 },
            sortBy: [SortDescriptor(\.startDate)]
        )
        return (try? context.fetch(desc)) ?? []
    }

    private func fetchSamples(in range: ClosedRange<Date>, context: ModelContext) -> [TrainingSample] {
        let start = range.lowerBound
        let end   = range.upperBound
        let desc = FetchDescriptor<TrainingSample>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp <= end }
        )
        return (try? context.fetch(desc)) ?? []
    }
}
