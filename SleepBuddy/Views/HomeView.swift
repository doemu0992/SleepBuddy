import SwiftUI
import SwiftData
import Charts
import FoundationModels

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SleepSession.startDate, order: .reverse) private var sessions: [SleepSession]
    @AppStorage("schlafZielStunden") private var schlafZiel: Double = 8

    /// Abgeschlossene Nächte, neueste zuerst.
    private var doneSessions: [SleepSession] { sessions.filter { !$0.isActive } }

    @State private var viewModel = HomeViewModel()
    @State private var trackingViewModel = SleepTrackingViewModel()
    @State private var showAlarmSetup = false
    @State private var profil = SharedProfil.shared
    @State private var zeigeBewertung = false

    private var lastSession: SleepSession? { sessions.first(where: { !$0.isActive }) }

    /// Tageszeitabhängige Begrüßung, optional mit Vornamen aus dem Profil.
    private var begruessung: String {
        let stunde = Calendar.current.component(.hour, from: Date())
        let gruss: String
        switch stunde {
        case 5..<11:  gruss = "Guten Morgen"
        case 11..<17: gruss = "Hallo"
        case 17..<22: gruss = "Guten Abend"
        default:      gruss = "Gute Nacht"
        }
        let vorname = profil.vorname.trimmingCharacters(in: .whitespaces)
        return vorname.isEmpty ? gruss : "\(gruss), \(vorname)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if sessions.isEmpty {
                        greetingHeader
                        emptyState
                    } else if let session = lastSession {
                        // ── Letzte Nacht ──
                        heroCard(session)
                        phaseCard(session)
                        if zeigeBewertung {
                            MorgenBewertungCard(session: session) {
                                withAnimation { zeigeBewertung = false }
                            }
                        }
                        if isMorgenBerichtRelevant(session) {
                            MorgenBerichtCard(session: session)
                        }

                        // ── Verlauf (7-Tage-Trend + mehrwöchige Musteranalyse) ──
                        if doneSessions.count >= 2 {
                            sectionHeader("Verlauf")
                            weekTrendCard
                            if doneSessions.count >= 3 {
                                WochenMusterKarte(sessions: Array(doneSessions.prefix(14)))
                            }
                        }

                        // ── Heute Nacht ──
                        sectionHeader("Heute Nacht")
                        smartAlarmCard
                    } else {
                        greetingHeader
                        smartAlarmCard
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $viewModel.showTrackingSheet) {
                SleepTrackingView(viewModel: trackingViewModel)
            }
            .sheet(isPresented: $showAlarmSetup) {
                AlarmSetupSheet(alarm: trackingViewModel.smartAlarm)
            }
            .onAppear {
                trackingViewModel.configure(modelContext: modelContext)
                aktualisiereBewertung()
            }
            .onChange(of: lastSession?.persistentModelID) { _, _ in
                aktualisiereBewertung()
            }
            .task {
                await trackingViewModel.requestAlarmPermission()
            }
        }
    }

    /// Friert ein, ob die Morgen-Bewertungskarte angezeigt wird — verhindert,
    /// dass die Karte mitten in der Bewertung verschwindet, wenn sich
    /// `recordingQuality`/`subjectiveQuality` ändern.
    private func aktualisiereBewertung() {
        guard let s = lastSession, isBewertungRelevant(s),
              (s.subjectiveQuality == 0 || s.recordingQuality == 0) else {
            zeigeBewertung = false
            return
        }
        zeigeBewertung = true
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 24) {
            sleepButton

            VStack(spacing: 16) {
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))

                Text("Willkommen bei SleepBuddy")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                Text("Lege dein iPhone heute Nacht aufs Bett — SleepBuddy erkennt deine Schlafphasen automatisch.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
            .padding(24)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)

            VStack(spacing: 12) {
                tipRow(icon: "iphone", color: .indigo, text: "iPhone neben dem Kopfkissen auf die Matratze legen")
                tipRow(icon: "cable.connector", color: .purple, text: "Ladekabel anschließen — Tracking läuft die ganze Nacht")
                tipRow(icon: "alarm.fill", color: .orange, text: "Optional: Smart Alarm für sanftes Aufwachen einrichten")
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)

            smartAlarmCard
        }
    }

    private func tipRow(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(color.opacity(0.12)).frame(width: 36, height: 36)
                Image(systemName: icon).foregroundStyle(color).font(.caption)
            }
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    // MARK: - Sleep button

    private var sleepButton: some View {
        Button { viewModel.startSleep() } label: {
            VStack(spacing: 12) {
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.white)
                Text("Schlafen starten")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text("Schlafphasen werden automatisch erkannt")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                if trackingViewModel.smartAlarm.isEnabled {
                    Label(alarmTimeLabel, systemImage: "alarm.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(.white.opacity(0.2))
                        .clipShape(Capsule())
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity)
            .background(LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .shadow(color: .indigo.opacity(0.35), radius: 14, x: 0, y: 8)
        }
        .buttonStyle(.plain)
    }

    private var alarmTimeLabel: String {
        let alarm = trackingViewModel.smartAlarm
        let fmt = DateFormatter()
        fmt.timeStyle = .short
        return "Smart Alarm \(fmt.string(from: alarm.earliestWakeTime))–\(fmt.string(from: alarm.latestWakeTime))"
    }

    // MARK: - Smart Alarm card

    private var smartAlarmCard: some View {
        let alarm = trackingViewModel.smartAlarm
        return Button { showAlarmSetup = true } label: {
            VStack(spacing: 12) {
                HStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(alarm.isEnabled ? Color.indigo.opacity(0.15) : Color.secondary.opacity(0.1))
                            .frame(width: 44, height: 44)
                        Image(systemName: alarm.isEnabled ? "alarm.fill" : "alarm")
                            .foregroundStyle(alarm.isEnabled ? .indigo : .secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Smart Alarm")
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                        Text(alarm.isEnabled ? alarmTimeLabel : "Weckt dich in der Leichtschlafphase")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Bindable(alarm).isEnabled)
                        .labelsHidden()
                        .tint(.indigo)
                }
                if alarm.isEnabled {
                    Divider()
                    HStack(spacing: 6) {
                        Image(systemName: "bed.double.fill").font(.caption).foregroundStyle(.indigo)
                        Text("Für \(Int(schlafZiel)) h Schlaf: ab \(bedtimeString(alarm)) ins Bett")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }

    /// Empfohlene Schlafenszeit = frühestes Weckfenster − Schlafziel.
    private func bedtimeString(_ alarm: SmartAlarmService) -> String {
        let bedtime = alarm.earliestWakeTime.addingTimeInterval(-schlafZiel * 3600)
        let fmt = DateFormatter(); fmt.timeStyle = .short
        return fmt.string(from: bedtime)
    }

    // MARK: - Greeting header (empty / no-session states)

    private var greetingHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(begruessung).font(.largeTitle.bold())
            Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Night hero (last night, tappable → detail)

    private func heroCard(_ session: SleepSession) -> some View {
        NavigationLink(destination: SleepDetailView(session: session)) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(begruessung).font(.title2.bold()).foregroundStyle(.white)
                        Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                            .font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                    if session.subjectiveQuality > 0 {
                        Text(["😴","🙁","😐","🙂","😄"][session.subjectiveQuality - 1]).font(.title3)
                    } else {
                        Image(systemName: "moon.stars.fill").font(.title3).foregroundStyle(.white.opacity(0.85))
                    }
                }
                HStack(spacing: 20) {
                    scoreRing(SchlafindexView.score(for: session))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.totalDuration.formattedDuration)
                            .font(.system(size: 30, weight: .bold)).foregroundStyle(.white)
                        Text("Letzte Nacht").font(.caption).foregroundStyle(.white.opacity(0.7))
                        if let lat = session.sleepOnsetLatency {
                            Label("Einschlafen \(formatMinutes(lat))", systemImage: "zzz")
                                .font(.caption2).foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    Spacer()
                }

                comparisonChips(session)

                if !session.phasesArray.isEmpty {
                    SleepPhaseBarView(phases: session.phasesArray, totalDuration: session.totalDuration)
                        .frame(height: 14).clipShape(Capsule())
                }
                HStack(spacing: 4) {
                    Spacer()
                    Text("Details ansehen").font(.caption2.bold())
                    Image(systemName: "chevron.right").font(.caption2.bold())
                }
                .foregroundStyle(.white.opacity(0.8))
            }
            .padding(20)
            .background(
                LinearGradient(colors: [Color(red: 0.15, green: 0.15, blue: 0.42), .indigo, .purple],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .shadow(color: .indigo.opacity(0.35), radius: 14, x: 0, y: 8)
        }
        .buttonStyle(.plain)
    }

    private func scoreRing(_ score: Int) -> some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.2), lineWidth: 9)
            Circle().trim(from: 0, to: CGFloat(min(max(score, 0), 100)) / 100)
                .stroke(scoreColor(score), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(score)").font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
                Text("Index").font(.caption2).foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(width: 92, height: 92)
    }

    private func scoreColor(_ s: Int) -> Color {
        switch s { case ..<40: return .red; case ..<70: return .orange; case ..<85: return .yellow; default: return .green }
    }

    // Vergleichs-Chips im Hero: vs. gestern (Punkte) + Ø 7 Tage
    @ViewBuilder
    private func comparisonChips(_ session: SleepSession) -> some View {
        let cur = SchlafindexView.score(for: session)
        let prev = doneSessions.dropFirst().first.map { SchlafindexView.score(for: $0) }
        let recent = doneSessions.prefix(7).map { SchlafindexView.score(for: $0) }
        let avg7 = recent.isEmpty ? nil : Int(Double(recent.reduce(0, +)) / Double(recent.count))
        if prev != nil || avg7 != nil {
            HStack(spacing: 8) {
                if let prev {
                    let d = cur - prev
                    heroChip("\(d >= 0 ? "+" : "")\(d) vs. gestern",
                             bg: (d >= 0 ? Color.green : Color.red).opacity(0.35))
                }
                if let avg7 { heroChip("Ø 7 T: \(avg7)", bg: .white.opacity(0.18)) }
                Spacer()
            }
        }
    }

    private func heroChip(_ text: String, bg: Color) -> some View {
        Text(text)
            .font(.caption2.bold()).foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(bg, in: Capsule())
    }

    // MARK: - Section header

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.bold()).textCase(.uppercase)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }

    // MARK: - 7-day trend chart

    private var weekTrendCard: some View {
        let bars: [NightBar] = doneSessions.prefix(7).reversed().map {
            NightBar(date: $0.startDate, hours: $0.totalDuration / 3600)
        }
        let avg = bars.isEmpty ? 0 : bars.map(\.hours).reduce(0, +) / Double(bars.count)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("7-Tage-Trend", systemImage: "chart.bar.fill")
                    .font(.headline).foregroundStyle(.indigo)
                Spacer()
                Text("Ø \(String(format: "%.1f", avg)) h")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Chart {
                ForEach(bars) { b in
                    BarMark(x: .value("Tag", b.date, unit: .day),
                            y: .value("Stunden", b.hours))
                        .foregroundStyle(Color.indigo.gradient)
                        .cornerRadius(5)
                }
                RuleMark(y: .value("Ziel", schlafZiel))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("Ziel \(Int(schlafZiel)) h").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
            .frame(height: 130)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
    }

    // MARK: - Combined sleep-phases card (donut + legend + footer)

    private func phaseCard(_ session: SleepSession) -> some View {
        let total = max(session.totalDuration, 1)
        let segs: [(name: String, type: SleepPhaseType, dur: TimeInterval)] = [
            ("Tiefschlaf",  .deep,  session.deepSleepDuration),
            ("REM",         .rem,   session.remSleepDuration),
            ("Leichtschlaf", .light, session.lightSleepDuration),
            ("Wach",        .awake, session.awakeDuration),
        ]
        var cum = 0.0
        var arcs: [(type: SleepPhaseType, start: Double, end: Double)] = []
        for s in segs { let f = s.dur / total; arcs.append((s.type, cum, cum + f)); cum += f }
        let hrs = session.heartRateSamples.filter { $0 >= 40 && $0 <= 110 }
        let avgHR = hrs.isEmpty ? nil : Int(hrs.reduce(0, +) / Double(hrs.count))

        return VStack(alignment: .leading, spacing: 16) {
            Label("Schlafphasen", systemImage: "moon.zzz.fill")
                .font(.headline).foregroundStyle(.indigo)

            HStack(spacing: 20) {
                ZStack {
                    ForEach(arcs.indices, id: \.self) { i in
                        Circle().trim(from: arcs[i].start, to: arcs[i].end)
                            .stroke(arcs[i].type.color, style: StrokeStyle(lineWidth: 16, lineCap: .butt))
                            .rotationEffect(.degrees(-90))
                    }
                    VStack(spacing: 0) {
                        Text(session.totalDuration.formattedDuration).font(.subheadline.bold())
                        Text("gesamt").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 104, height: 104)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(segs, id: \.name) { s in
                        if s.dur > 0 {
                            HStack(spacing: 8) {
                                Circle().fill(s.type.color).frame(width: 9, height: 9)
                                Text(s.name).font(.caption)
                                Spacer()
                                Text("\(Int(s.dur / total * 100))% · \(s.dur.formattedDuration)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 0) {
                footItem("zzz", session.sleepOnsetLatency.map { formatMinutes($0) } ?? "–", "Einschlafen")
                Divider().frame(height: 34)
                footItem("waveform", "\(session.snoringEventCount)×", "Schnarchen")
                Divider().frame(height: 34)
                footItem("heart.fill", avgHR.map { "\($0)" } ?? "–", "Ø Puls")
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
    }

    private func footItem(_ icon: String, _ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.caption).foregroundStyle(.indigo)
            Text(value).font(.subheadline.bold())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func formatMinutes(_ interval: TimeInterval) -> String {
        let m = Int(interval / 60)
        return m < 60 ? "\(m) min" : "\(m / 60)h \(m % 60)min"
    }

    private func isMorgenBerichtRelevant(_ session: SleepSession) -> Bool {
        Calendar.current.isDateInToday(session.endDate ?? .distantPast) ||
        Calendar.current.isDateInYesterday(session.endDate ?? .distantPast)
    }

    private func isBewertungRelevant(_ session: SleepSession) -> Bool {
        guard let end = session.endDate else { return false }
        return Date().timeIntervalSince(end) < 7 * 24 * 3600
    }
}

// MARK: - Trend-Datenpunkt

private struct NightBar: Identifiable {
    let id = UUID()
    let date: Date
    let hours: Double
}

// MARK: - WochenMusterKarte

struct WochenMusterKarte: View {
    let sessions: [SleepSession]

    @State private var showContent = false
    @State private var generatedText: String?
    @State private var isGenerating = false
    @State private var genError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Schlafmuster KI-Analyse", systemImage: "sparkles")
                    .font(.headline).foregroundStyle(.indigo)
                Spacer()
                if #available(iOS 26.0, *) {
                    if isGenerating {
                        ProgressView().scaleEffect(0.8)
                    } else if generatedText != nil {
                        Button {
                            generatedText = nil
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption).foregroundStyle(.indigo)
                        }
                    }
                }
            }

            if #available(iOS 26.0, *) {
                if let text = generatedText {
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let err = genError {
                    Text(err).font(.caption).foregroundStyle(.secondary)
                } else if isGenerating {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(0..<3, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.15))
                                .frame(height: 14)
                        }
                    }
                } else {
                    Button {
                        Task { await runAnalysis() }
                    } label: {
                        Label("Muster der letzten \(sessions.count) Nächte analysieren", systemImage: "waveform")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.indigo, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("Apple Intelligence-Analyse erfordert iOS 26.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
    }

    @available(iOS 26.0, *)
    private func runAnalysis() async {
        guard SystemLanguageModel.default.isAvailable else {
            genError = "Apple Intelligence ist auf diesem Gerät nicht verfügbar."
            return
        }
        isGenerating = true
        genError = nil
        generatedText = nil

        let prompt = buildPrompt()
        let session = LanguageModelSession()
        do {
            let result = try await session.respond(to: prompt)
            generatedText = result.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            genError = error.localizedDescription
        }
        isGenerating = false
    }

    private func buildPrompt() -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .none

        var lines = sessions.map { s -> String in
            let dur = Int(s.totalDuration / 60)
            let deep = Int(s.deepSleepDuration / s.totalDuration * 100)
            let rem = Int(s.remSleepDuration / s.totalDuration * 100)
            let score = SchlafindexView.score(for: s)
            let snoring = s.snoringEventCount
            return "\(fmt.string(from: s.startDate)): \(dur)min, Qualität \(score)%, Tief \(deep)%, REM \(rem)%, Schnarchen \(snoring)×"
        }.joined(separator: "\n")

        // PainDiary correlation (if available)
        let painData = SleepNightSummary.laden()
        let cutoff = Date().addingTimeInterval(-14 * 86400)
        let recentPain = painData.filter { Date(timeIntervalSince1970: $0.datum) >= cutoff }
        if !recentPain.isEmpty {
            let avgSnore = recentPain.map { Double($0.schnarchenAnzahl) }.reduce(0, +) / Double(recentPain.count)
            lines += "\n\nPainDiary-Anbindung: Ø \(String(format: "%.1f", avgSnore)) Schnarch-Events/Nacht laut PainDiary-Export."
        }

        return """
        Du bist ein freundlicher Schlaf-Assistent. Analysiere die folgenden Schlafdaten der letzten \(sessions.count) Nächte auf Deutsch.
        Gib 3–4 Sätze: erkenne Muster (z.B. wochentags vs. Wochenende, Trends bei Tiefschlaf/REM, Schnarchen-Häufigkeit, Lageänderungen).
        Keine Diagnosen. Keine Aufzählungslisten. Fließtext. Schließe mit einem konkreten Tipp.

        Daten:
        \(lines)
        """
    }
}

// MARK: - AlarmSetupSheet

struct AlarmSetupSheet: View {
    @Bindable var alarm: SmartAlarmService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 8) {
                        Image(systemName: "alarm.fill")
                            .font(.system(size: 32)).foregroundStyle(.indigo)
                        Text("Smart Alarm")
                            .font(.title3.bold())
                        Text("Weckt dich im optimalen Leichtschlafmoment innerhalb deines Zeitfensters.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.bottom, 4)

                    VStack(spacing: 0) {
                        Toggle("Smart Alarm aktivieren", isOn: $alarm.isEnabled)
                            .tint(.indigo)
                            .font(.subheadline)
                            .padding(16)
                    }
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))

                    if alarm.isEnabled {
                        VStack(spacing: 0) {
                            DatePicker("Frühestens", selection: $alarm.earliestWakeTime, displayedComponents: .hourAndMinute)
                                .font(.subheadline).padding(16)
                            Divider().padding(.leading, 16)
                            DatePicker("Spätestens", selection: $alarm.latestWakeTime, displayedComponents: .hourAndMinute)
                                .font(.subheadline).padding(16)
                        }
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))

                        HStack(spacing: 10) {
                            Image(systemName: "info.circle").foregroundStyle(.indigo)
                            Text("Der Alarm klingelt, sobald im Fenster eine Leichtschlafphase erkannt wird — spätestens zur eingestellten „Spätestens\"-Zeit.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(.horizontal).padding(.vertical, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Smart Alarm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }
}
