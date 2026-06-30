# SleepBuddy — Design & Code Standard

Dieses Dokument ist der verbindliche Standard für alle Arbeiten in diesem Projekt.
Jede neue View, jedes neue Feature und jede Änderung muss diesen Regeln folgen.

---

## Tech Stack

| Layer | Technologie |
|-------|-------------|
| UI | SwiftUI |
| Datenpersistenz | SwiftData + CloudKit (immer aktiv) |
| Audio | AVAudioEngine (Background Audio Entitlement) |
| Geräuscherkennung | `SoundAnalysis.SNClassifySoundRequest` (iOS 15+) |
| Beschleunigungssensor | `CoreMotion.CMMotionManager` (50 Hz) |
| ML-Klassifikator | ShutEye-Zyklus-Modell (live) + Online k-NN (Datensammlung) |
| Apple Intelligence | `FoundationModels.LanguageModelSession` (iOS 26+) |
| Gesundheitsdaten | HealthKit |
| iCloud Settings Sync | `NSUbiquitousKeyValueStore` via `ICloudSettingsSync` |
| iCloud Audio Clips | iCloud Documents (`iCloud.DG-Software-Solution.PainDiary/SleepSounds/`) |
| App Group | `group.com.doemu0992.sleepbuddy` |
| Minimum iOS | iOS 17.0 |
| Tint-Farbe | `.indigo` |

---

## Git-Workflow (bindend)

> **Immer auf `main` pushen.** Zusätzlich auf den Feature-Branch.

```bash
git push origin main-local:main
git push origin main-local:claude/zealous-goldberg-fnhmsu
```

Lokaler Branch: `main-local`

---

## Schlafphasen-Farben (bindend)

> **Single Source of Truth: `SleepPhaseType.color` — niemals Farben für Schlafphasen hardcodieren.**

```swift
// Models/SleepPhaseType.swift
var color: Color {
    switch self {
    case .awake: return .orange
    case .light: return Color(red: 0.40, green: 0.65, blue: 1.0)   // Hellblau
    case .deep:  return Color(red: 0.50, green: 0.30, blue: 0.90)  // Violett
    case .rem:   return Color(red: 0.95, green: 0.35, blue: 0.65)  // Pink
    }
}
```

| Phase | Farbe | Verwendung |
|-------|-------|------------|
| Wach | Orange | Hypnogramm, Legende, Badge |
| Leichtschlaf | Hellblau | Hypnogramm, Legende, stat-Card |
| Tiefschlaf | Violett | Hypnogramm, Legende, stat-Card, Chart-Gradient |
| REM | Pink | Hypnogramm, Legende, stat-Card, Chart-Gradient |

**Gilt ausnahmslos für:** Hypnogramm-Balken, Legende, stat-Cards (Statistik + Detail), Verlaufs-Chart-Gradient, Phase-Badges im Tracking-Screen.

---

## Visueller Stil (bindend)

- **Tint**: `.indigo` global (Tab Bar, Buttons, Slider, Toggle, Links)
- **Screen-Hintergrund**: `Color(.systemGroupedBackground)`
- **Karten-Hintergrund**: `Color(.secondarySystemGroupedBackground)` — **niemals** `.secondarySystemBackground`
- **Karten-Radius**: `RoundedRectangle(cornerRadius: 16)`
- **Karten-Padding**: 16 pt innen
- **Karten-Shadow**: `.shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)`
- **Padding**: 16 pt horizontal, 8–12 pt vertikal als Basis
- **Animationen**: `.spring(response: 0.4, dampingFraction: 0.7)` für interaktive Elemente
- **Typografie**: SF Pro, `.largeTitle` für Hauptüberschriften, `.headline` für Karten-Header

### Karten-Muster

```swift
VStack(alignment: .leading, spacing: 12) { /* Inhalt */ }
    .padding()
    .background(Color(.secondarySystemGroupedBackground))
    .clipShape(RoundedRectangle(cornerRadius: 16))
    .shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
```

---

## Navigation (bindend)

Natives `TabView` + zentrierter **54pt Kreis-Overlay-Button** für den Tracker.

```swift
TabView(selection: $selectedTab) {
    NavigationStack { HomeView() }
        .tabItem { Label("Home", systemImage: "house.fill") }.tag(0)
    NavigationStack { StatistikView() }
        .tabItem { Label("Statistik", systemImage: "chart.bar.fill") }.tag(1)
    Color.clear
        .tabItem { Label(" ", systemImage: "moon.stars.fill") }.tag(2)
    NavigationStack { SleepHistoryView() }
        .tabItem { Label("Verlauf", systemImage: "clock.arrow.circlepath") }.tag(3)
    NavigationStack { ProfilView() }
        .tabItem { Label("Profil", systemImage: "person.fill") }.tag(4)
}
.tint(.indigo)
.overlay(alignment: .bottom) {
    Button { showTracking = true } label: {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 54, height: 54)
                .shadow(color: .indigo.opacity(0.5), radius: 8, x: 0, y: 4)
            Image(systemName: isTracking ? "waveform" : "moon.stars.fill")
                .font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
        }
    }
    .padding(.bottom, 4)
}
.onChange(of: selectedTab) { _, tab in
    if tab == 2 { showTracking = true; selectedTab = 0 }
}
```

**Regeln:**
- Kein custom `safeAreaInset` Tab Bar — immer natives `TabView`
- Reihenfolge: Home (0), Statistik (1), Tracker-Dummy (2), Verlauf (3), Profil (4)
- **5 Tab-Items mit dem Tracker-Dummy exakt in der Mitte (Index 2)** — der zentrale Kreis-Button sitzt nur bei ungerader Tab-Anzahl korrekt über dem mittleren Item. Niemals auf eine gerade Anzahl wechseln (Button wird sonst versetzt dargestellt).
- Tab 2 ist Dummy (`Color.clear`) und öffnet den Tracker via `onChange`
- `HomeView` ist der Landing-Tab (zeigt u.a. `MorgenBewertungCard`)
- Safe Area wird vom System verwaltet

---

## Analyse-Views — Aufbau & Funktionen

### StatistikView

**Datei:** `Views/StatistikView.swift`

```
NavigationStack
└── ZStack(alignment: .bottom)
    ├── Color(.systemGroupedBackground)
    └── ScrollView
        ├── weekStrip          → 7-Tage-Auswahl (heute vorausgewählt)
        └── sleepContent(session) oder emptyState
            ├── hypnogramCard  → Balken-Hypnogramm + Legende
            ├── statsRow       → 3 stat-Cards: Tiefschlaf / REM / Schnarchen
            ├── extraStatsCard → Einschlafen / Gesamt / Effizienz (nur wenn Latenz > 0)
            ├── SchlafapnoeRisikoView
            └── NavigationLink "Nacht im Detail" → SleepDetailView
```

**Wichtige Funktionen:**

| Funktion | Beschreibung |
|----------|-------------|
| `weekDays` | Letzte 7 Tage als `[Date]` |
| `sessionForSelected` | Erste abgeschlossene Session die `selectedDate` überschneidet |
| `hypnoBars(for:)` | Konvertiert `phasesArray` in `[HypnoBar]` mit `depth` (0.15/0.45/0.70/1.00) |
| `hypnogramCard(session:)` | Balken-Chart mit GeometryReader, X-Achse, Legende |
| `barColor(_ phase:)` | Delegiert an `phase.color` |
| `statsRow(session:)` | 3 `statCard`-Views nebeneinander |
| `extraStatsCard(session:latency:)` | Einschlafen / Gesamt / Effizienz mit Divider |
| `deepSleepLabel(_:)` | "Gut ✓" / Prozent / "Kurz" je nach Tiefschlafanteil |

**Hypnogramm-Balken:**
- Breite proportional zur Phasendauer: `geo.size.width * CGFloat(bar.duration / totalDur) - 2`
- Höhe proportional zur Tiefe: `geo.size.height * CGFloat(bar.depth)`
- Ausrichtung: `.bottom` (Balken wachsen nach oben)
- Farbe: `barColor(bar.phase)` → `phase.color`

### SleepDetailView

**Datei:** `Views/SleepDetailView.swift`

> **Dashboard-Stil mit Abschnitten (bindend):** SleepDetailView ist wie HomeView in **Abschnitte mit Überschriften** (`sectionHeader`, uppercase caption) gegliedert — kein loser Karten-Stapel. **Karten ohne Daten werden nicht gezeigt** (kein „Nicht verfügbar"-Platzhalter, z.B. SpO₂). Reihenfolge fix:

```
NavigationStack (via NavigationLink aus StatistikView)
└── ScrollView
    ├── heroHeader         → Nacht-Hero (Indigo→Violett): Zeitraum, Dauer, Schlaf-Index-Ring;
    │                        ganze Karte ist NavigationLink → SchlafindexView (kein separater Button)
    ├── summaryCard        → EINE Karte: oben 3 Phasen-Spalten (Tief/REM/Leicht),
    │                        darunter (Divider) Extra-Stats Einschlafen/Schnarchen/…/Smart Alarm
    │ ── SCHLAFPHASEN ──   (nur wenn Phasen vorhanden)
    ├── phasenCard         → EINE Karte: Phasen-Balken + Legende, Divider, Verlauf-Chart (Step-Hypnogramm)
    ├── phaseTimelineCard  → „Phasen im Detail", ausklappbar (zeigt erst 4, „Alle X anzeigen");
    │                        nutzt `cleanedPhases` (Null-Dauer raus, doppelte Startzeit raus)
    │ ── GERÄUSCHE ──      (nur wenn Sound-Events ODER Noise-Daten)
    ├── soundEventsCard ×2 → Schlafgeräusche / Umgebungsgeräusche (Play + Korrektur)
    ├── snoringIntensityCard → nur wenn Schnarch-Events
    ├── ambientNoiseCard   → Umgebungslautstärke-Wellen-Chart (nur wenn noiseSamples)
    │ ── VITALWERTE ──     (nur wenn HR ODER SpO₂ vorhanden)
    ├── heartRateCard      → Herzfrequenz-Verlauf (Variante B: gehaltene Lücken als „geschätzt")
    ├── spo2Card           → SpO₂-Ring (nur wenn echter Wert > 0 — kein Platzhalter)
    │ ── KI-ANALYSE ──
    └── aiInsightCard      → „Analyse starten" (SleepInsightService)
```

**Sound-Korrektur-System (`SoundCorrectionSheet`):**

Jedes Sound-Event hat einen ✎-Button der `SoundCorrectionSheet` öffnet:
- Play/Stop-Button für Audio-Vorschau
- „Korrekt ✓"-Button (bestätigt Typ, grün)
- Zwei Sektionen: „Als Schlafgeräusch zuordnen" + „Als Umgebungsgeräusch zuordnen" (die 24 Kategorien)
- **„Weiteres Geräusch wählen …"** → `AppleClassPickerView`: durchsuchbare Liste **aller ~300 Apple-Klassen** (deutsch). Auswahl speichert das Event als `.ambient` mit exaktem `mlLabel` (Erkennung 300 ↔ Korrektur 300). `onDone`-Closure ist `(Bool, SoundEventType?, String?)` — das dritte Feld trägt den spezifischen Apple-Namen.
- Checkmark auf aktuellem Typ; Antippen setzt neuen Typ (eine benannte Kategorie löscht `mlLabel`)
- Footer: „Korrekturen werden gespeichert und verbessern die Erkennung dauerhaft."
- `.presentationDetents([.large])`

```swift
// Feedback wird inline in UserDefaults gespeichert (kein externer Service nötig):
// soundFeedback.<rawValue>.confirmed / .rejected / .missed
// → SoundClassificationService.adjustedThreshold() liest diese Keys
// → Thresholds angepasst ±10% nach ≥ 5 Samples
private func applySoundCorrection(event: SleepSoundEvent, confirmed: Bool, newType: SoundEventType?) {
    let ud = UserDefaults.standard
    if confirmed {
        ud.set(ud.integer(forKey: "soundFeedback.\(event.type.rawValue).confirmed") + 1,
               forKey: "soundFeedback.\(event.type.rawValue).confirmed")
        event.isUserCorrected = true
    } else if let newType {
        // rejected für alten Typ, missed für neuen Typ
        ud.set(..., forKey: "soundFeedback.\(orig.rawValue).rejected")
        ud.set(..., forKey: "soundFeedback.\(newType.rawValue).missed")
        if event.originalTypeRaw == nil { event.originalTypeRaw = event.typeRaw }
        event.typeRaw = newType.rawValue
        event.isUserCorrected = true
    }
    try? modelContext.save()
}
```

> **Kein `SoundFeedbackService` als separater Service** — Feedback-Logik ist inline in `SleepDetailView` und `SoundClassificationService` um Xcode-Target-Abhängigkeiten zu vermeiden (neue Swift-Dateien müssen manuell zum Build-Target hinzugefügt werden).

**Wichtige Funktionen:**

| Funktion | Beschreibung |
|----------|-------------|
| `pct(_:)` | Prozentwert einer Phase an Gesamtdauer |
| `hypnoDepth(_:)` | Tiefenwert pro Phase: awake=0, light=1, rem=2, deep=3 |
| `hypnoData` | Array von `HypnoPoint(id, time, depth)` — **zwei Punkte pro Phase** (Start + Ende) |
| `statsGrid` | `LazyVGrid` mit 3 `statCard`-Views |
| `statCard(_:value:icon:color:percent:)` | Karten-View mit Icon, Wert, Beschriftung, Prozentbalken |

**Schlafverlauf-Chart — Regeln (bindend):**

```swift
// Tiefenwerte: awake=0 (absoluter Boden), light=1, rem=2, deep=3
// Y-Domain: -0.15...3.3 (Boden etwas tiefer als 0 für Wach-Sichtbarkeit)
// AreaMark yStart: -0.15 (nicht 0 — damit Wach einen sichtbaren Streifen hat)
// Interpolation: .stepStart (Stufenfunktion, kein Smooth zwischen Phasen)
```

> **Kritisch — zwei Punkte pro Phase:** Mit `.stepStart` hält ein Punkt seinen Wert bis zum nächsten Punkt. Ohne expliziten Endpunkt würde die Phase zu früh enden. Immer Start- UND Endpunkt für jede Phase emittieren:

```swift
private var hypnoData: [HypnoPoint] {
    let sorted = session.phasesArray.sorted { $0.startDate < $1.startDate }
    var points: [HypnoPoint] = []
    for phase in sorted {
        points.append(HypnoPoint(id: phase.startDate,                      time: phase.startDate, depth: hypnoDepth(phase.phaseType)))
        points.append(HypnoPoint(id: phase.endDate.addingTimeInterval(-0.001), time: phase.endDate,   depth: hypnoDepth(phase.phaseType)))
    }
    return points
}
```

**Liniengradient — nach Y-Position (nicht per Punkt):**

> SwiftCharts unterstützt **kein** per-Punkt `foregroundStyle` auf einem einzelnen `LineMark` — die gesamte Serie bekommt eine Farbe (die letzte gewinnt). Lösung: `LinearGradient` mit Stops die exakt auf die Y-Domain-Schwellen gemappt sind.

```swift
// Y-Domain -0.15...3.3 (Span = 3.45). Wach bei 0 → 4% von unten.
LinearGradient(
    stops: [
        .init(color: SleepPhaseType.awake.color.opacity(0.9), location: 0.0),
        .init(color: SleepPhaseType.awake.color.opacity(0.9), location: 0.04),
        .init(color: SleepPhaseType.light.color.opacity(0.9), location: 0.29),
        .init(color: SleepPhaseType.rem.color.opacity(0.9),   location: 0.58),
        .init(color: SleepPhaseType.deep.color.opacity(0.9),  location: 0.87),
        .init(color: SleepPhaseType.deep.color.opacity(0.9),  location: 1.0),
    ],
    startPoint: .bottom, endPoint: .top
)
```

**Charts scrollbar (bindend für alle Zeitverlauf-Charts in SleepDetailView):**

```swift
// Alle Charts (Schlafverlauf, Umgebungslautstärke, Herzfrequenz) sind scrollbar.
// X-Domain exakt auf Session-Zeitraum fixieren — verhindert SwiftCharts-Puffer vor Startzeit.
// X-Labels jede Stunde, sichtbares Fenster 3h — funktioniert für jede Schlafdauer.
.chartXScale(domain: session.startDate...(session.endDate ?? Date()))
.chartScrollableAxes(.horizontal)
.chartXVisibleDomain(length: 3 * 3600)
```

> Warum scrollbar: fixes Frame komprimiert eine 8h-Nacht auf ~360px → Labels überlappen, kurze Phasen unsichtbar. Mit 3h-Fenster sind Labels immer gut lesbar und Wach-Phasen am Anfang/Ende klar sichtbar.

> **`chartXScale(domain:)` ist Pflicht:** Ohne explizite Domain fügt SwiftCharts automatisch einen Puffer vor dem ersten Datenpunkt ein — die Achse beginnt z.B. bei 22:00 obwohl die Session um 22:30 startet.

**Tracker Start/Ende — Zeitanzeige über jedem Chart (bindend):**

> SwiftCharts-Annotationen auf `RuleMark` (`.annotation(position: .top)`) werden vom Chart-Frame abgeschnitten und sind nicht sichtbar. Lösung: Zeiten als separaten `HStack` **über** dem Chart anzeigen.

```swift
// Shared computed property in SleepDetailView (kein @ViewBuilder — kein View):
private var chartTimeFmt: DateFormatter {
    let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
}

// @ViewBuilder wegen if let ohne else:
@ViewBuilder
private var trackerTimeRow: some View {
    HStack {
        Label(chartTimeFmt.string(from: session.startDate), systemImage: "play.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.indigo)
        Spacer()
        if let end = session.endDate {
            Label(chartTimeFmt.string(from: end), systemImage: "stop.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.indigo)
                .environment(\.layoutDirection, .rightToLeft)
        }
    }
}
```

Zusätzlich gestrichelte `RuleMark`-Linien im Chart als visuelle Ankerpunkte (ohne `.annotation`):

```swift
RuleMark(x: .value("Start", session.startDate))
    .foregroundStyle(Color.indigo.opacity(0.5))
    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
if let end = session.endDate {
    RuleMark(x: .value("Ende", end))
        .foregroundStyle(Color.indigo.opacity(0.5))
        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
}
```

Alle drei Charts (Schlafverlauf, Umgebungslautstärke, Herzfrequenz) enthalten `trackerTimeRow` + RuleMarks.

**`@ViewBuilder` auf computed View-Properties (bindend):**

> Eine `var foo: some View` mit einem `if`- oder `if let`-Branch **ohne** `else` braucht `@ViewBuilder` — sonst Compiler-Fehler "result builder disabled by explicit return" und "no return statements to infer type".

```swift
// FALSCH — kein @ViewBuilder, if ohne else → Compilerfehler
private var hypnogramCard: some View {
    if !session.phasesArray.isEmpty { VStack { ... } }
}

// RICHTIG
@ViewBuilder
private var hypnogramCard: some View {
    if !session.phasesArray.isEmpty { VStack { ... } }
}
```

> `@ViewBuilder` **nicht** auf Nicht-View-Properties setzen (z.B. `DateFormatter`-Computed-Var) — das erzeugt ebenfalls einen Compilerfehler.

**Flächen-Gradient:**
```swift
LinearGradient(
    colors: [SleepPhaseType.deep.color.opacity(0.25), SleepPhaseType.deep.color.opacity(0.05)],
    startPoint: .top, endPoint: .bottom
)
```

### SchlafindexView

**Datei:** `Views/SchlafindexView.swift`

Score 0–100, zusammengesetzt aus:

| Komponente | Max | Berechnung |
|-----------|-----|-----------|
| Dauer | 50 | `actualSleep / zielStunden * 50` (capped) |
| Effizienz | 30 | `(efficiency - 0.50) / 0.40 * 30` (ab 50% linear bis 90%) |
| Unterbrechungen | 20 | `(1 - min(postOnsetAwakeMin / 45, 1)) * 20` |

```swift
// Statische Methode — von überall aufrufbar
static func score(for session: SleepSession) -> Int
```

**Score-Farben:** < 40 → `.red`, 40–69 → `.orange`, 70–84 → `.yellow`, 85+ → `.green`

### SchlafapnoeRisikoView

**Datei:** `Views/SchlafapnoeRisikoView.swift`

```swift
// Berechnung: Schnarchen-Ereignisse pro Stunde, Durchschnitt letzte 7 Nächte (≥ 1h)
private func risikoWert(sessions: [SleepSession]) -> Double
```

| Wert | Stufe | Farbe |
|------|-------|-------|
| < 25/h | Niedrig | `.green` |
| < 50/h | Mild | `.yellow` |
| < 75/h | Mittel | `.orange` |
| ≥ 75/h | Erhöht | `.red` |

Darstellung: Gradient-Balken (grün→rot) + dreieckiger Positionsmarker (`Triangle: Shape`).

> **`Triangle().fill(Color.primary)`** — niemals `Color.white` verwenden. `Color.primary` passt sich automatisch an Light/Dark Mode an (schwarz im Light Mode, weiß im Dark Mode).

### SleepHistoryView

**Datei:** `Views/SleepHistoryView.swift`

```
NavigationStack
└── List
    ├── WochenSummaryCard  → Wochendurchschnitt + Balken-Chart (Schlafziel als gestrichelte Linie)
    └── ForEach(sessions)  → SleepSessionRow pro Nacht
```

`WochenSummaryCard` nutzt `@AppStorage("schlafZielStunden")` für die Ziellinie im Chart.

**`SleepSessionRow`** (struct in `SleepHistoryView.swift`, nicht `private`):
- Datum (Wochentag + Datum), `SleepPhaseBarView` als Mini-Balken, Dauer, `QualityBadge`
- Subjektives Bewertungs-Emoji (😴/🙁/😐/🙂/😄) wenn `subjectiveQuality > 0`

**`QualityBadge`** (struct in `SleepHistoryView.swift`):
```swift
// Farbe nach Score:
75+  → .green
50–74 → .yellow
<50  → .orange
// Format: "X%" in Capsule mit opacity(0.2) Hintergrund
```

---

## Datenmodell (SleepSession)

**Datei:** `Models/SleepSession.swift`

```swift
@Model final class SleepSession {
    var startDate: Date
    var endDate: Date?                    // nil = aktiv
    var phases: [SleepPhase]?             // cascade delete
    var sleepQualityScore: Double?
    var healthKitSampleID: String?
    var sleepOnsetDate: Date?             // Erste nicht-Wach-Phase (für Anzeige)
    var alarmEarliestTime: Date?
    var alarmLatestTime: Date?
    var alarmFiredDate: Date?
    var soundEvents: [SleepSoundEvent]?   // cascade delete
    var noiseSamples: [Double] = []       // dB/Minute
    var heartRateSamples: [Double] = []   // HR/Minute (0 = kein Wert)
    var subjectiveQuality: Int = 0        // 0=nicht bewertet, 1–5
}
```

> **`snoringEventCount` ist computed** (kein stored Int mehr) — verhindert CloudKit-Duplikatfehler:
> ```swift
> var snoringEventCount: Int { soundEventsArray.filter { $0.type == .snoring }.count }
> ```
> Analog: `bruxismEventCount` und `coughingEventCount` ebenfalls computed.

**Berechnete Properties:**

| Property | Typ | Beschreibung |
|----------|-----|-------------|
| `totalDuration` | `TimeInterval` | end - start (oder jetzt wenn aktiv) |
| `sleepOnsetLatency` | `TimeInterval?` | Zeit bis Einschlafen |
| `isActive` | `Bool` | `endDate == nil` |
| `phasesArray` | `[SleepPhase]` | `phases ?? []` |
| `soundEventsArray` | `[SleepSoundEvent]` | `soundEvents ?? []` |
| `snoringEventCount` | `Int` | computed: Anzahl `.snoring`-Events |
| `bruxismEventCount` | `Int` | computed: Anzahl `.bruxism`-Events |
| `coughingEventCount` | `Int` | computed: Anzahl `.coughing`-Events |
| `deepSleepDuration` | `TimeInterval` | Summe aller `.deep`-Phasen |
| `remSleepDuration` | `TimeInterval` | Summe aller `.rem`-Phasen |
| `lightSleepDuration` | `TimeInterval` | Summe aller `.light`-Phasen |
| `awakeDuration` | `TimeInterval` | Summe aller `.awake`-Phasen |
| `computedQualityScore` | `Double` | 0–100, restorativer Schlaf + Abzüge |

**`computedQualityScore`-Formel:**
```swift
// Basis: (Tiefschlaf + REM) / Gesamtdauer × 200 (capped at 100)
var score = min((restorative / total) * 200, 100)
// Einschlafen > 20 min: −0.5 Pkt/min, max −10
score -= min(max(latencyMin - 20, 0) * 0.5, 10)
// Schnarchen: −0.5 Pkt/Event, max −15
score -= min(Double(snoringEventCount) * 0.5, 15)
// Bruxismus: −0.3 Pkt/Event, max −5
score -= min(Double(bruxismEventCount) * 0.3, 5)
```

> `computedQualityScore` ist der **direkte Session-Score** (verwendet in MorgenBerichtCard). `SchlafindexView.score(for:)` ist der **Schlaf-Index** (verwendet in StatistikView, SleepHistoryView) — beide koexistieren mit unterschiedlichen Algorithmen.

> **CloudKit-Pflicht:** Alle Attribute müssen optional sein oder Default-Werte haben. Beziehungen brauchen `inverse`. Niemals CloudKit aus dem `modelContainer` entfernen.

---

## iCloud-Sync (bindend)

### 1. SwiftData + CloudKit

Der `modelContainer` in `SleepBuddyApp.swift` **muss immer** mit CloudKit-Config gebaut werden:

```swift
let schema = Schema([SleepSession.self, SleepPhase.self, SleepSoundEvent.self])
let config = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
let container = try ModelContainer(for: schema, configurations: config)
```

> **Niemals `cloudKitDatabase: .none` verwenden.** CloudKit-Sync darf niemals deaktiviert werden.

### 2. Settings-Sync (NSUbiquitousKeyValueStore)

**Datei:** `Services/ICloudSettingsSync.swift`

`ICloudSettingsSync.shared.start()` wird einmalig in `SleepBuddyApp.init()` aufgerufen.

Synced Keys (Standard UserDefaults):
- `einst_erinnerung_aktiv`, `einst_erinnerung_zeit`
- `soundEvents_enabled`, `partnerModus_aktiv`, `partnerModus_stufe`
- `profil_paindiary_verknuepft`, `profil_schlafziel`
- `onboardingAbgeschlossen`

Synced Keys (App Group, Präfix `ag_`):
- `shared_vorname`, `shared_nachname`, `shared_geburtsdatum`, `shared_geschlecht`

**Neuen Key hinzufügen:**
1. Key in `standardKeys` oder `appGroupKeys` Array eintragen
2. Fertig — Push/Pull passiert automatisch

### 3. Audio-Clips (iCloud Documents, opt-in)

**Datei:** `Services/SoundEventService.swift`

- Container: `iCloud.DG-Software-Solution.PainDiary`
- Ordner: `SleepSounds/`
- Format: `.m4a`, 30 Sekunden pro Clip
- Trigger: Schnarchen, Sprechen, Husten, Bruxismus, Sonstiges
- **Standard: deaktiviert.** Nur aktiv wenn `soundEvents_enabled = true`

```swift
// iCloud URL ermitteln
FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.DG-Software-Solution.PainDiary")?
    .appendingPathComponent("Documents/SleepSounds/")
```

**Ring-Buffer:** 35 Sekunden Rohaudio im RAM (35s bei nativer Sample Rate). Bei Ereignis: letzten 30s als Clip speichern → RAM löschen.

> **Clip-Normalisierung (bindend):** Aufnahme läuft im `.measurement`-Modus (AGC aus) + auf der Matratze gedämpft → sehr leiser Pegel. `AVAudioPlayer` kann nicht über das Original hinaus verstärken, daher wäre der Clip bei voller Lautstärke kaum hörbar. `saveToICloud` normalisiert deshalb vor dem AAC-Encoding via `normalized(_:)` (vDSP: Peak ermitteln, auf Ziel-Peak 0.9 skalieren, Gain auf max 60× begrenzt, auf [-1,1] geclippt). Gilt für iCloud- **und** lokalen Speicherpfad (gemeinsame tmp-Datei).

> **Rückwirkende Normalisierung:** `normalizeExistingClips()` (Button „Aufnahmen lauter machen" in EinstellungenView) liest bereits gespeicherte, leise Clips neu ein, normalisiert sie und überschreibt sie (lokal + iCloud-Ordner). Idempotent — Clips mit Peak ≥ 0.7 werden übersprungen. AAC-Schreiben ist im Helper `writeAAC(samples:sampleRate:to:)` gekapselt (genutzt von Live-Save **und** Migration).

**Schwellenwert:** Adaptiv — die ersten 60 s kalibrieren den Geräuschboden, danach Schwelle knapp darüber (siehe „Adaptive Kalibrierung" unten). Partner-Modus erhöht zusätzlich (× 1.6 / × 2.4).

---

## Umgebungsgeräusch-System

### Amplitude-Schwelle (ShutEye-Stil, fest)

**Datei:** `Services/SoundEventService.swift`

**Adaptive Kalibrierung (bindend):** Die ersten **60 Sekunden** des Trackings messen den **tatsächlichen Geräuschboden** dieser Umgebung/Platzierung/Mikrofon. Die Event-Schwelle wird dann knapp über diesen gemessenen Boden gesetzt — alles, was klar lauter ist, gilt als Event. Das passt sich automatisch an Matratze vs. Nachttisch, leise vs. laute Räume und die relative (unkalibrierte) dB-Skala des Geräts an.

```swift
private let calibrationDuration: TimeInterval = 60
private var calibratedThreshold: Float?   // nil bis erste 60 s vorbei

// In tick(): während der ersten 60 s nur sammeln, keine Event-Erkennung.
private func finishCalibration() {
    let sorted = calibrationSamples.sorted()
    // 95. Perzentil = robuster "lautester Normalwert" (ignoriert einen einzelnen
    // Stoß beim Ablegen), dann +5 dB Marge (×1.8) für ein klares Event.
    let ceiling = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    calibratedThreshold = max(ceiling * 1.8, 0.004)   // nie unter ≈ 42 dB
}

// amplitudeThreshold: nutzt calibratedThreshold (× Partner-Faktor 1.6/2.4),
// vor Kalibrierung Fallback 0.006 (Matratze) / 0.010 (Nachttisch).
```

| Phase | Schwelle |
|-------|----------|
| Erste 60 s (Kalibrierung) | Fallback 0.006/0.010, **keine** Erkennung |
| Nach Kalibrierung | `max(ambientCeiling95 × 1.8, 0.004)` |
| + Partner Stufe 1 / 2 | × 1.6 / × 2.4 |

**Rollende Nachkalibrierung (bindend, beidseitig adaptiv):** Die Schwelle passt sich über die Nacht an wechselnde Bedingungen an (Heizung, Straßenlärm, etc.). Alle **2 Minuten** wird aus den letzten ~5 Minuten **aller Nicht-Event-Samples** (`eventStartDate == nil`) der **Median** als robuster Boden berechnet und per EMA eingemischt.

> **Warum Median statt „nur unter der Schwelle + p95" (bindend):** Die frühere Version sammelte nur Samples *unter* der aktuellen Schwelle. Folge: Stieg der Geräuschboden mitten in der Nacht **über** die Schwelle (Heizung/Regen/Verkehr), wurden die lauteren Samples ausgefiltert → die Schwelle konnte **nicht nach oben** adaptieren → Event-/Clip-Spam, der sich nicht selbst korrigierte. Jetzt zählen **alle** Nicht-Event-Samples, und der **Median** ist robust gegen die laute Minderheit (Events sind per `eventStartDate`-Gate ohnehin ausgeschlossen) — so adaptiert die Schwelle **hoch UND runter**, ohne dass Events den Boden hochziehen.

```swift
private func recalibrateRolling() {
    guard rollingAmbient.count >= 240 else { return }   // ≥ ~30 s Nicht-Event-Daten
    let median = /* Median von rollingAmbient */
    let candidate = max(median * thresholdOverMedian, 0.004)
    calibratedThreshold = calibratedThreshold! * 0.6 + candidate * 0.4   // sanfte Mischung
}
```

> **`thresholdOverMedian`:** In `finishCalibration` als `threshold / median` der 60-s-Kalibrierung gemessen (geklemmt 2…12, Fallback 4.0). So nutzt die rollende Phase den robusten Median, reproduziert aber die ×1.8-Schwellenskala der Erstkalibrierung.

> **`reset()` muss Kalibrierung UND Rolling-State zurücksetzen** (`calibrationSamples`, `calibrationDeadline`, `calibratedThreshold`, `thresholdOverMedian`, `rollingAmbient`, `lastRecal`) — jede Nacht neu kalibrieren.

> **ML bleibt primärer Trigger** (amplitudenunabhängig, gain-verstärkt). Die kalibrierte Amplitude ist das Gate für nicht-ML-Sounds.

> **Spektral-Schnarchen-Trigger ENTFERNT (bindend, datenbelegt):** Früher löste `tick()` ein Schnarch-Event aus, wenn `snoringScore > 0.55 && instantAmplitude > 0.0008`. Eine Validierung gegen echte gelabelte Audios (ESC-50, 2000 Clips) zeigte: Das 80–500-Hz-Maß (`snoringIntensity`) ist ein **unspezifischer Tieffrequenz-Detektor** (AUC ~0.73, mit Modulation nur ~0.78) — es feuert auf Zug, Ventilator, Verkehr, Feuerwerk genauso stark wie auf Schnarchen und blähte die Schnarch-Statistik mit Fehlalarmen auf. **Schnarchen wird daher ausschließlich über Apples ML-`snoring`-Klasse erkannt** (zweckmäßig trainiert, spezifisch). Auch der Amplitude-Fallback (`classifyEvent`) labelt **nicht** mehr per `snoringScore` als `.snoring`. Niemals den Spektral-Schnarch-Trigger reaktivieren ohne neue Datenvalidierung.

---

### Umgebungslautstärke-Messung (dB/Minute)

**Gemessen in:** `SleepTrackingViewModel.handleFeatures()`  
**Gespeichert in:** `SleepSession.noiseSamples: [Double]` (ein Wert pro Minute)

```swift
// Umrechnung Amplitude → dB SPL (approximiert, 0–120 dB Skala)
let db = max(0, min(120, 20.0 * log10(max(Double(avg), 1e-6)) + 90.0))
session.noiseSamples.append(db)
```

**Prozess:**
1. Jeder `AudioFeatures`-Update (alle ~125ms) → `noiseAccumulator.append(audio.averageAmplitude)`
2. Alle 60 Sekunden: Durchschnitt berechnen → dB-Wert → `noiseSamples`
3. Accumulator leeren → nächste Minute

**Darstellung in `SleepDetailView`:** `ambientNoiseCard` — **Wellen-Chart** (`LineMark` + `AreaMark`) mit Catmull-Rom-Interpolation. Farbkodierung:
- Fläche: drei überlagerte `AreaMark`-Schichten (grün/orange/rot) bis jeweiligem Schwellenwert
- Y-Achse: 20–90 dB, Gitterlinien bei 35/50/70 dB in Schwellenwertfarbe
- Chart scrollbar: `.chartScrollableAxes(.horizontal)` + `.chartXVisibleDomain(length: 3 * 3600)`
- **Kein `BarMark` verwenden** — war durch Balken-Stil ersetzt worden (inzwischen revertiert).

> **Linie Farbgradient:** SwiftCharts erlaubt kein per-Punkt `foregroundStyle` auf `LineMark`. Lösung: `LinearGradient` mit scharfen Stops exakt an den dB-Schwellen (Y-Domain 20…90 = 70 Einheiten):
> ```swift
> // 35 dB: (35-20)/70 = 0.21 — 50 dB: (50-20)/70 = 0.43
> LinearGradient(stops: [
>     .init(color: .green,  location: 0.0),
>     .init(color: .green,  location: 0.21),
>     .init(color: .orange, location: 0.21),
>     .init(color: .orange, location: 0.43),
>     .init(color: .red,    location: 0.43),
>     .init(color: .red,    location: 1.0),
> ], startPoint: .bottom, endPoint: .top)
> ```

### Geräuschkurve — Testdaten (`generateNoiseCurve`)

**Datei:** `Services/SampleDataService.swift`

`generateNoiseCurve(minutes:baseDB:)` erzeugt ein `[Double]`-Array mit einem dB-Wert pro Minute — entspricht dem Format von `SleepSession.noiseSamples`.

```swift
// Flache Basiskurve: baseDB ± 3 dB (zufälliges Rauschen)
private func generateNoiseCurve(minutes: Int, baseDB: Double) -> [Double] {
    (0..<minutes).map { _ in baseDB + Double.random(in: -3...3) }
}
```

> **Kritisch:** `generateNoiseCurve` alleine erzeugt eine **flache Linie** ohne Ereignis-Peaks — sieht unrealistisch aus und zeigt keine Korrelation mit den Sound-Events.

**Pflicht: Event-Spitzen überlagern (bindend für alle Testnächte):**

Nach `generateNoiseCurve` immer einen Spike-Injection-Pass über alle Events fahren:

```swift
var noise = generateNoiseCurve(minutes: mins, baseDB: 27)
for (_, offsetH, durSec, db, _) in events {
    let center = Int(offsetH * 60)          // Minute des Events
    let halfW  = max(1, Int(durSec / 60) + 1)  // halbe Fensterbreite in Minuten
    for i in max(0, center - halfW)...min(mins - 1, center + halfW) {
        noise[i] = min(90, max(noise[i], db - 4 + Double.random(in: -2...2)))
    }
}
session.noiseSamples = noise
```

| Parameter | Formel | Bedeutung |
|-----------|--------|-----------|
| `center` | `offsetH * 60` | Minute an der das Event stattfindet |
| `halfW` | `max(1, durSec/60 + 1)` | Breite des Peaks (mindestens 2 Minuten) |
| Peak-Höhe | `db - 4 ± 2` | Leicht unter dem Event-dB-Wert + Zufallsvariation |

**Resultat:** Noise-Chart zeigt deutliche Peaks genau dort, wo Sound-Events aufgezeichnet wurden — konsistent mit dem Geräusch-Events-Abschnitt in `SleepDetailView`.

---

### Sound Event Detection

**Datei:** `Services/SoundEventService.swift`

**Event-Erkennungs-Pipeline (ShutEye-Stil):**

```
SoundClassificationService (ML) → hintMLDetection(type:confidence:)
    → confidence >= minConf (0.45 persönlich / 0.55 extern) → eventStartDate sofort
    → classifyEvent() → ML-Typ übernehmen

AudioFeatures (8 Hz) → tick(instantAmplitude:snoringScore:speechLikelihood:)
    → isLoud = instantAmplitude > amplitudeThreshold       ← Fallback ohne ML-Hint
       (Spektral-Schnarchen ENTFERNT — ESC-50-validiert zu unspezifisch)
    → 4 aufeinanderfolgende laute Ticks (0.5s) → eventStartDate setzen
    → classifyEvent() → speechLikelihood / .other (Schnarchen nur via ML)
    → 8 aufeinanderfolgende ruhige Ticks (1s) → finaliseEvent()
    → minDuration prüfen
    → circularBuffer → saveToICloud() oder lokal
    → onEventCaptured(timestamp, type, duration, fileName, decibelLevel, confidence)
```

**Timing-Parameter:**

| Parameter | Wert | Beschreibung |
|-----------|------|-------------|
| `loudTicksToStart` | 4 (0.5 s) | Konsekutive laute Ticks (Amplitude-Fallback) um Event zu starten |
| `quietTicksToEnd` | 8 (1.0s) | Konsekutive ruhige Ticks um Event zu beenden |
| `cooldownAfterEventSeconds` | 4.0s | Pause nach Event (verhindert Doppelerkennung) |
| `maxEventDuration` | 30.0s | Dauergeräusch (z.B. Hundegebell) wird in ≤30s-Events zerschnitten → mehrere Clips statt einem 2h-Event |
| `clipDuration` | 30s | Länge des gespeicherten Audio-Clips |
| Ring-Buffer Größe | 35s × Samplerate | Genug Vorlauf für vollständigen Clip |

**Mindestdauer pro Typ:**

| Typ | Mindestdauer |
|-----|-------------|
| Husten, Keuchen | 0.5s |
| Zähneknirschen (Bruxismus), Lachen | 0.8s |
| Niesen, Klopfen, Glasbruch | 0.3s |
| Türklingel, Telefon, Hundebellen, Katze, Vogel | 0.5s |
| Alarm, Babyweinen | 0.8s |
| Donner/Regen, Verkehr, Wind | 1.0s |
| Stimmengewirr, Wasser | 1.5s |
| Alle anderen | 2.0s |

**Event-Klassifikation (ShutEye-Stil):**
1. ML-Hint vorhanden (< 3s alt) → ML-Typ direkt übernehmen
2. Sonst → `.other` (Klassifikation ist ML-only: weder `snoringScore` noch `speechLikelihood` weisen einen Typ zu — beide sind unspezifische Band-Maße. Amplitude-getriggerte Events ohne ML-Hint sind ehrlich „Geräusch")

**ML-Primär-Trigger:** `hintMLDetection()` löst Events für **alle** Typen aus (persönlich + extern) wenn Konfidenz ≥ Schwelle — kein `isMLPrimary`-Filter mehr.

> **Identifier müssen exakt zu Apples Taxonomie passen (bindend):** Die Mapping-Strings in `SoundClassificationService.mappings` müssen **wörtlich** einer Klasse aus `SNClassifySoundRequest(.version1).knownClassifications` (303 Klassen) entsprechen — sonst gibt `classification(forIdentifier:)` `nil` zurück und die Klasse **feuert nie**. Ein Audit (Einstellungen → „Geräusch-Klassen prüfen" → `SoundClassificationService.auditText()`) listet tote Identifier + alle echten Apple-Klassen. **Ein früherer Abgleich ergab, dass 41 von 82 Identifiern tot waren** (z.B. `dog_barking`, `baby_cry`, `glass_break`, `sneezing`, `coughing`, `meow`, `purring`, `wind_noise`) — alle auf die echten Namen korrigiert (`dog_bark`/`dog_bow_wow`, `baby_crying`, `glass_breaking`, `sneeze`, `cough`, `cat_meow`, `cat_purr`, `wind_noise_microphone`, …). Nach jeder Mapping-Änderung erneut auditieren.
>
> **Bruxismus hat keine Apple-Klasse (bindend):** In Apples `.version1`-Taxonomie existiert **kein** Identifier für Zähneknirschen (`teeth_grinding`/`teeth_chattering` sind nicht vorhanden, `chewing`/`biting` sind ungeeignet). Bruxismus kann daher **nicht** per ML erkannt werden — nur über manuelle Nutzer-Korrektur. Niemals erfundene teeth-Identifier ins Mapping aufnehmen.
>
> **Catch-all → `.ambient` mit echtem Namen (alle ~300 Klassen aktiv, bindend):** Über die ~94 explizit gemappten Klassen hinaus wird **jede weitere** erkannte Apple-Klasse als `.ambient` („Umgebungsgeräusch", `isExternal = true`) erfasst, wenn sie das Top-Ergebnis über `catchAllThreshold` (0.55) ist (`catchAllEnabled`). **Nicht als `.other`** — das wäre irreführend. Der spezifische erkannte Name wird via `germanName(for:)` übersetzt und in `SleepSoundEvent.mlLabel` gespeichert; die UI zeigt `event.displayName` (mlLabel ?? type.rawValue). So sind effektiv alle Apple-Klassen aktiv und korrekt als Umgebungsgeräusch mit echtem Namen benannt. **Ausnahme `catchAllExcluded`:** Dauer-/Rauschgeräusche (`air_conditioner`, `mechanical_fan`, `clock`/`tick_tock`, `ocean`, `fire`, `vacuum_cleaner`, Werkzeuge, `engine_idling` …) sind ausgeschlossen — sie laufen minutenlang und würden sonst die ganze Nacht Events + 30s-Clips spammen. Explizit gemappte IDs (`mappedIDs`) überspringt der Catch-all (deren eigene Schwellen gelten). `catchAllEnabled = false` schaltet zurück auf nur die kuratierten Mappings.
>
> **Priorität — Catch-all darf benannte Geräusche NIE blockieren (bindend):** Es gibt nur **eine** Event-Pipeline (ein Event gleichzeitig, 4 s Cooldown, max 30 s/Event). Würde der Catch-all gleichberechtigt Events auslösen, belegen beliebige Umgebungsgeräusche den Slot + Cooldown und **unterdrücken z.B. Schnarchen** (real beobachtet: 16 → 3 Schnarch-Events). Daher in `hintMLDetection`: `.ambient` startet nur bei **komplett freier** Pipeline; ein **benanntes** Geräusch darf dagegen (a) während des Cooldowns eines vorherigen Ambient-Events starten (`lastEventWasAmbient`) und (b) ein **laufendes** Ambient-Event **übernehmen** (`currentEventIsAmbient` → Typ upgraden). `catchAllThreshold` zudem auf 0.62 (konservativ). So bleibt die bewährte Schnarch-/Benannt-Erkennung voll erhalten, der Catch-all füllt nur die Lücken.

---

### Apple ML Sound Classification

**Datei:** `Services/SoundClassificationService.swift`

Nutzt `SoundAnalysis.SNClassifySoundRequest` (iOS 15+) mit Apple's eingebautem `classifierIdentifier: .version1`.

**Einstellungen:**
```swift
request.windowDuration = CMTimeMakeWithSeconds(1.5, preferredTimescale: 44100)
request.overlapFactor = 0.75  // mehr Overlap = häufigere Ergebnisse = weniger verpasste Events
// Jeder Buffer wird analysiert (analyzeEveryN = 1) für maximale Nacht-Erkennungsrate
```

> **Software-Gain für den ML-Pfad (bindend):** Die AVAudioSession läuft im `.measurement`-Modus (AGC aus) für eine saubere Atemanalyse → sehr niedriger Eingangspegel. Auf der Matratze zusätzlich gedämpft. Ohne Verstärkung erreicht `SNClassifySoundRequest` für **keine** Klasse die Konfidenz → es werden **gar keine** Geräusche erkannt (auch keine externen, da diese rein ML-getriggert sind). Daher wird in `analyze(buffer:time:)` eine **gain-verstärkte Kopie** (Faktor 8, hart auf [-1,1] geclippt via `vDSP_vsmul`/`vDSP_vclip`) an den Analyzer gegeben. Das rohe Signal bleibt für die Atem-/Amplitudenanalyse unberührt. Gain ggf. anhand echter Nächte nachjustieren.

**Erkannte Klassen und Mindest-Konfidenz (90+ ML-Identifier → 24 Typen, Best-Match-Logik):**

| ML-Identifier (Auswahl) | `SoundEventType` | Min. Konfidenz | Kategorie |
|--------------------------|-----------------|----------------|-----------|
| `snoring`, `snoring_breathing` | `.snoring` | 0.40 | Persönlich |
| `speech` | `.talking` | 0.45 | Persönlich |
| `cough`, `coughing` | `.coughing` | 0.40 | Persönlich |
| `teeth_chattering`, `teeth_grinding` | `.bruxism` | 0.35 | Persönlich |
| `sneezing`, `sneeze` | `.sneezing` | 0.45 | Persönlich |
| `breathing_heavily`, `gasping`, `choking` | `.gasping` | 0.40–0.50 | Persönlich |
| `laughing`, `laughter`, `giggling` | `.laughing` | 0.45–0.50 | Persönlich |
| `dog`, `dog_bark`, `bark`, `barking` | `.dogBarking` | 0.30 | Extern |
| `cat`, `meow`, `purring` | `.cat` | 0.40–0.45 | Extern |
| `bird`, `bird_song`, `chirping` | `.bird` | 0.45 | Extern |
| `music`, `musical_instrument`, `singing` | `.music` | **0.65** (AC-Schutz) | Extern |
| `alarm_clock`, `siren`, `smoke_detector` | `.alarm` | 0.50 | Extern |
| `doorbell`, `chime` | `.doorbell` | 0.45–0.50 | Extern |
| `telephone`, `phone_ringing`, `ringtone` | `.phone` | 0.50 | Extern |
| `car_horn`, `honking`, `vehicle`, `engine` | `.traffic` | 0.50–0.60 | Extern |
| `baby_cry`, `crying`, `infant_cry` | `.baby` | 0.45 | Extern |
| `thunder`, `thunderstorm`, `rain` | `.thunder` | 0.50–0.55 | Extern |
| `wind`, `wind_noise`, `gust_of_wind` | `.wind` | 0.50 | Extern |
| `knock`, `door_knock`, `door` | `.knock` | 0.40–0.50 | Extern |
| `glass_breaking`, `glass_break`, `shatter` | `.glassBreak` | 0.35–0.45 | Extern |
| `crowd`, `applause`, `chatter` | `.crowd` | 0.50–0.55 | Extern |
| `water`, `running_water`, `toilet_flush` | `.water` | 0.50 | Extern |

> **AC/Klimaanlage-Schutz:** Musik-Threshold auf 0.65 — verhindert Fehlklassifikation von Dauergeräuschen als Musik.

> **Best-Match-Logik:** Alle Identifier werden ausgewertet, der höchste Konfidenz-Treffer über Threshold gewinnt — kein First-Match.

> **Adaptive Thresholds:** `adjustedThreshold(for:base:)` liest UserDefaults-Feedback (confirmed/rejected/missed) und passt Schwellen ±10% an (ab 5 Samples, min 0.20, max 0.90).

> **Globaler Empfindlichkeits-Offset (bindend):** `sensitivityOffset` (aktuell 0.12) wird von **jeder** Pro-Klasse-Schwelle abgezogen (Floor 0.25) — eine zentrale Stellschraube für mehr/weniger Erkennungen. **Ausnahme `.snoring`** (kein Offset — funktioniert bereits gut, soll nicht über-triggern). `hintMLDetection`-Sanity-Floor entsprechend 0.25.

**ML als primärer Trigger (ShutEye-Stil, alle Typen):**

`SoundClassificationService.onSoundDetected` → `SoundEventService.hintMLDetection()` — ML-Konfidenz ist das primäre Gate für persönliche **und** externe Typen. Kein `isMLPrimary`-Filter.

```swift
// SoundEventService.hintMLDetection — die Pro-Klasse-Schwellen in
// SoundClassificationService sind das maßgebliche Gate (Hund 0.30, Musik 0.65).
// hintMLDetection darf KEIN höheres Floor draufsetzen (sonst werden leise/ferne
// externe Sounds wie Hundegebell unterdrückt) — nur ein minimales Sanity-Floor:
if confidence >= 0.30 && eventStartDate == nil && !isInCooldown {
    eventStartDate = Date()
    pendingEventType = type
}
```

> **Kein doppeltes Gate (bindend):** Früher hatte `hintMLDetection` ein zweites, höheres Floor (extern 0.50) das die niedrigeren Pro-Klasse-Schwellen überstimmte → ferne/leise externe Geräusche (Hundegebell) wurden nie erfasst. Empfindlichkeit wird **nur** über die Pro-Klasse-Schwellen in `SoundClassificationService` gesteuert.

**ML-Hint-Alter:** Max. 3 Sekunden — ältere Hints werden ignoriert.

---

### SoundEventType — Datenmodell

**Datei:** `Models/SleepSoundEvent.swift`

24 Typen in zwei Kategorien:

| Typ | Icon | Farbe | `isExternal` |
|-----|------|-------|--------------|
| `.snoring` | `waveform` | `.orange` | false |
| `.talking` | `bubble.left.fill` | `.blue` | false |
| `.coughing` | `lungs.fill` | `.teal` | false |
| `.bruxism` | `mouth.fill` | `.pink` | false |
| `.sneezing` | `allergens` | `.yellow` | false |
| `.gasping` | `waveform.path.ecg` | `.purple` | false |
| `.laughing` | `face.smiling.fill` | `.green` | false |
| `.other` | `speaker.wave.2.fill` | `.secondary` | false |
| `.dogBarking` | `pawprint.fill` | `.brown` | **true** |
| `.cat` | `pawprint` | `.orange` | **true** |
| `.bird` | `bird.fill` | `.teal` | **true** |
| `.music` | `music.note` | `.indigo` | **true** |
| `.alarm` | `bell.fill` | `.red` | **true** |
| `.doorbell` | `bell.and.waves.left.and.right.fill` | `.yellow` | **true** |
| `.phone` | `phone.fill` | `.green` | **true** |
| `.traffic` | `car.fill` | `.gray` | **true** |
| `.baby` | `figure.and.child.holdinghands` | `.mint` | **true** |
| `.thunder` | `cloud.bolt.fill` | `.blue` | **true** |
| `.wind` | `wind` | `.cyan` | **true** |
| `.knock` | `hand.raised.fill` | `.brown` | **true** |
| `.glassBreak` | `sparkles` | `.red` | **true** |
| `.crowd` | `person.3.fill` | `.purple` | **true** |
| `.water` | `drop.fill` | `.blue` | **true** |

**SwiftData-Modell `SleepSoundEvent`:**

| Property | Typ | Beschreibung |
|----------|-----|-------------|
| `timestamp` | `Date` | Ereignis-Startzeit |
| `typeRaw` | `String` | `SoundEventType.rawValue` (CloudKit-safe) |
| `durationSeconds` | `Double` | Ereignis-Dauer |
| `iCloudFileName` | `String?` | Dateiname in `SleepSounds/` (nil wenn deaktiviert) |
| `decibelLevel` | `Double` | Mittlere dB-Lautstärke des Events (0–120) |
| `confidenceScore` | `Double` | ML-Konfidenz (0.0 = regelbasiert) |
| `isUserCorrected` | `Bool` | `true` nach manueller Korrektur durch Nutzer |
| `originalTypeRaw` | `String?` | Ursprünglicher Typ vor Nutzer-Korrektur |
| `session` | `SleepSession?` | Inverse Relation (cascade delete) |

**iCloud-Fallback:** Wenn iCloud nicht verfügbar → lokal in `Documents/SleepSounds/`, Dateiname mit Präfix `local://`.

---

### Phase-Smoothing im TrackingViewModel

**Datei:** `ViewModels/SleepTrackingViewModel.swift`

Phasenwechsel werden **stabilisiert** bevor sie in SwiftData geschrieben werden.

**Pflicht: `pendingPhase` und `pendingPhaseStartDate` als private Properties deklarieren** (werden in `handleFeatures`, `startTracking` und `stopTracking` benötigt):

```swift
private var pendingPhase: SleepPhaseType = .awake
private var pendingPhaseStartDate = Date()
```

```swift
// Kandidatenphase muss stabil bleiben für minPhaseDuration (immer 60s, fix)
private let minPhaseDuration: TimeInterval = 60

// Phasenwechsel: erst wenn Kandidat >= 60s gehalten hat
if result.phase != pendingPhase {
    pendingPhase = result.phase
    pendingPhaseStartDate = now
} else if result.phase != currentPhase,
          now.timeIntervalSince(pendingPhaseStartDate) >= minPhaseDuration {
    finalizeCurrentPhase(endDate: now, session: session)
    currentPhase = result.phase
}
```

**Pending Awake beim Session-Stop:**
Wenn beim Beenden eine Wachphase noch im Pending war (z.B. Morgen-Aufwachen), wird sie explizit committet:

```swift
if pendingPhase == .awake && pendingPhaseStartDate > currentPhaseStartDate {
    finalizeCurrentPhase(endDate: pendingPhaseStartDate, session: session)
    currentPhaseStartDate = pendingPhaseStartDate
    currentPhase = .awake
}
finalizeCurrentPhase(endDate: .now, session: session)
```

### Herzrate-Sampling im ViewModel

Ein Herzrate-Wert pro Minute wird in `session.heartRateSamples` gespeichert.
Priorität: Apple Watch HR → BCG (Akkelerometer) → 0 (kein Wert).

> **Source-Gate (bindend):** Nur physiologisch plausible Werte (40–110 BPM im Schlaf) werden gespeichert. Implausible BCG-Artefakte (z.B. Spikes auf 140) werden als **0** abgelegt — sie sollen die gespeicherte Reihe nicht verschmutzen. Der Display-Filter hält dann den letzten guten Wert (Variante B, siehe `heartRateCard`).

> **Frische-Gate (bindend):** `liveBCGHeartRateBPM` darf für das Live-Badge den letzten Wert **halten** (kein Flackern). Die **gespeicherte** Minuten-Reihe darf den BCG-Wert aber **nur nutzen, wenn er frisch ist** (`lastBCGUpdate` < 90 s). Sonst wird 0 gespeichert. Ohne dieses Gate fror der zuletzt berechnete Wert ein und wurde jede Minute als **echter Messwert** gespeichert → durchgezogene **falsche Flachlinie** (z.B. exakt 70) über Stunden, statt einer ehrlichen „geschätzt"-Lücke. `lastBCGUpdate` wird nur im gültigen BCG-Zweig gesetzt und in `startTracking()` auf `.distantPast` zurückgesetzt.

```swift
// Private State (muss als Property deklariert sein):
private var lastBCGSampleDate = Date.distantPast

// In handleFeatures() — alle 60 Sekunden:
if Date().timeIntervalSince(lastBCGSampleDate) >= 60, let session = currentSession {
    let watchHR = liveHeartRateBPM
    let bcgHR = Double(liveBCGHeartRateBPM)
    let hr: Double
    if watchHR >= 40 && watchHR <= 110 { hr = watchHR }       // Watch ist autoritativ
    else if bcgHR >= 40 && bcgHR <= 110 { hr = bcgHR }         // plausibles BCG
    else { hr = 0 }                                            // implausibel / kein Wert
    session.heartRateSamples.append(hr)
    lastBCGSampleDate = Date()
}
```

`lastBCGSampleDate` muss in `startTracking()` auf `.distantPast` zurückgesetzt werden.

**Display-Filter + Variante B (`SleepDetailView.heartRatePoints`, bindend):**

> Die rohe `heartRateSamples`-Reihe wird **nicht** direkt gezeichnet. Stattdessen ein robuster Filter (kein LLM):
> 1. **Plausibilitätsbereich** 40–110 BPM (sonst fehlend).
> 2. **Median-of-5-Glättung** über vorhandene Nachbarn.
> 3. **Delta-Limit:** Sprünge > 12 BPM/min werden verworfen; 3 aufeinanderfolgende Verwürfe = echter Niveau-Wechsel → deren Median wird übernommen.
> 4. **Variante B:** Lücken werden mit dem letzten guten Wert **gehalten** und als `estimated` markiert.
>
> Darstellung: durchgehende pinke Catmull-Rom-Linie (gemessen + gehalten) + **graue gestrichelte Overlay-Linie** auf den `estimated`-Abschnitten (gruppiert per `segment`). Legende: „┄ geschätzt". So bleibt die Kurve glatt und plausibel, kennzeichnet aber ehrlich, wo geschätzt wurde.

**Post-hoc HR-Phasenkorrektur (`applyHeartRatePhaseCorrection`, bindend):**

> Die bereinigte Herzfrequenz korrigiert nicht nur die Anzeige, sondern auch die **Phasen**. In `stopTracking()` läuft `applyHeartRatePhaseCorrection(to:)` **vor** `applyPlausibilityCorrection`. Sie nutzt dieselbe bereinigte Reihe (`cleanedHeartRate`, spiegelt `SleepDetailView.heartRatePoints`) und korrigiert pro Phase nur **klare Widersprüche**, und nur wenn echte **gemessene** HR ≥ 50 % der Phase abdeckt (geschätzte/gehaltene Abschnitte werden ignoriert):
> - **Absoluter Puls als Tiefschlaf-Signal abgewertet (bindend, PSG-validiert):** Eine Validierung gegen echte Labordaten (Walch et al., PhysioNet, n=20) hat gezeigt, dass der **absolute Puls die Schlafphasen kaum unterscheidet**: Tiefschlaf-Puls liegt im Schnitt auf **p60** der Nacht (also leicht *über* dem Median) und ist praktisch identisch mit REM (Offsets nur ±1.4 BPM). Die Baseline-Validierung lag bei κ≈0.07 (Zufallsniveau). Konsequenz: Die frühere Regel „`.light` mit niedrigem Puls → `.deep`" ist **entfernt** — niedriger Puls ist real **nicht** überwiegend Tiefschlaf. Tiefschlaf wird durch **Bewegung + Atemregularität + Zyklusstruktur** bestimmt, nicht durch das Puls-**Niveau**.
> - **Relative Schwelle (Ganznacht-Kontext, bindend):** nur noch `deepCeil` wird gebraucht — aus der Puls-Verteilung der Nacht (`deepCeil = clamp(p50+4, 60…70)`), Fallback 65 bei < 10 Messwerten. (`deepFloor`/`remFloor` entfallen.)
> - **Multi-Nacht-Personalisierung (bindend):** Die Nacht-Perzentile werden mit der über Nächte gelernten persönlichen Baseline (`PersonalCalibrationService`, EMA α=0.3) **50/50 geblendet**. Die Baseline wird weiterhin gelernt (auch `deepFloor` für andere Nutzer). Gilt analog für die Atem-Baseline (`brSlowRate`/`brRegHigh`/`brRegLow`).
> - `.deep` mit Median ≥ `deepCeil` → `.light` (nicht REM — vermeidet REM-Hüpfer). **Diese Demotion bleibt** — ein klar *hoher* Puls ist real kein Tiefschlaf (konservativ, plausibel).
> - **`.rem` wird NIE per Puls zu `.deep`** — REM-Puls ähnelt Leicht/Tief, das BCG unterschätzt zusätzlich; die alte Regel löschte fast alles REM.
> - `.awake` wird nie überschrieben (bewegungsbasiert, zuverlässiger)
>
> So sind die Phasen nicht nur optisch plausibel, sondern folgen dort, wo verlässliche HR vorliegt, der echten Herzfrequenz — statt dem reinen Zyklusmuster.

**Datengetriebene Zyklus-Länge (`detectCycleLength` / `applyCycleRemRefinement`, bindend):**

> Statt fixer 90 min wird die **tatsächliche ultradiane Zyklus-Länge der Nacht** per Autokorrelation eines Tiefe-Proxys (niedriger Puls = tief) im Bereich **70–120 min** geschätzt (**Fallback 100 min** = realer PSG-Median aus Walch et al., n=31: Median 101, IQR 78–112; früher 90/110). Suchbereich auf 120 erweitert, weil reale Zyklen die alte 110-Grenze regelmäßig überschreiten. Genutzt für die REM-Fenster in der Tiefschlaf-Umverteilung + Atem-Verfeinerung. `applyCycleRemRefinement` degradiert nur **ganz frühes** REM (< 20 min nach Einschlafen) zu `.light` (das erste REM kommt physiologisch erst ~70–90 min nach Onset). **Nicht** mehr per Zyklus-Position — das kollidierte mit der Live-90-min-Platzierung und löschte legitimes REM.

**Tiefschlaf-Umverteilung (`applyDeepRedistribution`, bindend):**

> Das 90-min-Zyklusmodell + BCG-Bias überallokieren **Tief UND REM** (eine Nacht zeigte z.B. Tief 36 % / REM 38 % / Leicht 16 %). `applyDeepRedistribution` erzwingt daher ein **physiologisches Budget**: Tief ≤ 22 %, REM ≤ 25 % der Schlafzeit; der Überschuss geht an **Leichtschlaf** (sonst zu niedrig). Demotiert wird der **späteste Tiefschlaf zuerst** (Tief clustert früh) und das **früheste REM zuerst** (REM nimmt gegen Morgen zu) → was bleibt, ist auch korrekt platziert. Läuft **nach** der Atem-Verfeinerung. (HR-basierte „Tief behalten wenn Puls niedrig" wurde verworfen — BCG liest zu niedrig, ließ fast alles als Tief durchgehen.)

**Atem-Verfeinerung (`applyBreathingRefinement`, bindend):**

> Nutzt Pro-Minute-Atemrate + -Regularität (TrainingSamples) **relativ zur Nacht** (Perzentile): `.light` mit langsamer (≤ p25) + sehr regelmäßiger (≥ p70) Atmung → `.deep` (Tiefschlaf-Bestätigung); `.light` mit unregelmäßiger Atmung (≤ p35) **im REM-Fenster** des erkannten Zyklus (≥ 60 %) → `.rem` (REM über Variabilität). Konservativ — nur Upgrades von `.light`, wo die Sensoren klar übereinstimmen.

**Aktigraphie (Cole-Kripke-inspiriert, in `applyMovementWake`, bindend):**

> Die Bewegung wird vor der Wach-Erkennung **nachbar-gewichtet** geglättet (Fenster [-2…+2], Gewichte 0.25/0.5/1/0.5/0.25), damit ein Bewegungs-Event über seine Umgebung zählt statt nur in einem Bin. Schwellen sind **relativ** zur Bewegungsverteilung der Nacht (Median × 2.5 / p90).
>
> **PSG-validiert (Walch et al., n=31):** Wach-Bewegung liegt real bei **4,5× Nacht-Median**, Schlaf bei **1,0×**, p90 bei **2,8×**. Die Schwelle `Median × 2.5` sitzt damit genau zwischen Schlaf und Wach (≈ p90) — bestätigt, keine Anpassung nötig.

**Edge-Wake-Erkennung (`applyEdgeWakeCorrection`, bindend):**

> Wachliegen (abends einschlafen, morgens aufwachen) zeigt wenig Bewegung, aber **klar erhöhte Herzfrequenz**. In `stopTracking()` (nach der HR-Phasenkorrektur) markiert `applyEdgeWakeCorrection` mit der bereinigten **gemessenen** HR die Ränder:
> - Schwelle **adaptiv**: Detektion `awakeHR = clamp(Schlaf-Median + 8, 62…78)`, Rückwärts-Erweiterung mit niedrigerer `extendThreshold = max(Schlaf-Median + 3, 60)` — so wird der ganze allmähliche Anstieg erfasst, nicht nur die 1 Spitzenminute.
> - **Abend:** erhöhte HR in den ersten 5 min detektiert, dann vorwärts mit `extendThreshold` erweitert → Einschlaf-Latenz = `.awake`. **Fallback:** liegt der Nutzer ruhig (niedriger Puls), wird die bekannte Einschlaf-Latenz (`sleepOnsetDate`, identisch zur „Einschlafen X min"-Anzeige) trotzdem als Abend-Wachphase eingezeichnet.
> - **Morgen:** Wake erkannt, wenn die letzten Minuten erhöhte HR zeigen **oder** das BCG-Signal in den letzten ≥ 2 min abreißt (= aufgestanden/bewegt). Dann rückwärts erweitern (HR ≥ `extendThreshold`, Signalverlust zählt als wach), gedeckelt auf 30 min. Bei manuellem Stopp mind. ~8 min.
> - **`markAwake` splittet Phasen** an der Wach-Grenze (kein Mittelpunkt-Retyping) — sonst würde eine lange letzte Phase nie eine kurze Morgen-Wachphase erzeugen. Greift nur bei gemessener HR / Signalverlust; ohne alles bleibt die Terminal-Awake-Regel (15 min) als Fallback.

**Nächtliche Wachphasen aus Bewegung (`applyMovementWake`, bindend):**

> Bewegung ist das **zuverlässigste** Wach-Signal (Umdrehen, Aufstehen, Unruhe). `applyMovementWake` nutzt die Pro-Minute-`movementIntensity` aus den TrainingSamples: anhaltend erhöhte Bewegung (> 0.30 für ≥ 2 min) **oder** ein starker Einzel-Spike (> 0.55, z.B. Aufstehen) → `.awake` (via `markAwake`-Splitting). **Bewusst KEIN BCG-Null-Heuristik** (die markierte fälschlich ruhigen Schlaf als wach). Völlig ruhiges Wachliegen bleibt prinzipbedingt unerkennbar. Läuft in `stopTracking` und im „neu berechnen"-Batch. Die Plausibilitäts-Korrektur **merged `.awake` nie weg**.
> - **`mergeAdjacentSamePhases`** (am Ende von `applyPlausibilityCorrection`) verschmilzt aufeinanderfolgende gleichtypige Phasen zu einer — sonst zeigt das Splitting mehrere benachbarte `.awake`-Segmente als getrennte Einträge im Verlauf.

---

## Sensor-System

Die gesamte Schlafphasenerkennung basiert auf zwei parallelen Sensordaten-Streams: **Audio** (Mikrofon) und **Motion** (Beschleunigungssensor). Beide werden kombiniert und an den Klassifikator weitergegeben.

### Sensor-Pipeline (Überblick)

```
Mikrofon → AudioAnalysisService
    → installTap (1024 Samples)
    → onBufferReady → SoundEventService (Ring-Buffer, opt-in Clips)
    → analysisQueue → processBuffer()
        → FFT (vDSP, 4096 Punkte)
        → AudioFeatures (Amplitude, Atemrate, Schnarchen, Sprache)
        → SleepPhaseClassifier.classify(audio:motion:)

Beschleunigungssensor → MotionAnalysisService
    → CMMotionManager, 50 Hz
    → Bewegungsintensität (30s Fenster)
    → Atemrate via Autokorrelation (10 Hz, downsampled)
    → BCG-Herzrate via z-Achse (50 Hz, nur wenn Telefon auf Matratze)
    → MotionFeatures
    → SleepPhaseClassifier.classify(audio:motion:)

Apple Watch → HealthKitService
    → HKStatisticsQueryDescriptor (alle 5 min)
    → HR + HRV → SleepPhaseClassifier.currentHRBPM / .currentHRVms
```

---

## Audio-System

**Datei:** `Services/AudioAnalysisService.swift`

```swift
// Session-Konfiguration (bindend)
try session.setCategory(.record, mode: .measurement, options: [.mixWithOthers, .allowBluetoothHFP])
try session.setActive(true, options: .notifyOthersOnDeactivation)
```

> `.allowBluetooth` (deprecated) NICHT verwenden — immer `.allowBluetoothHFP`.

**Datenschutz-Invariante:** Rohdaten verlassen niemals den RAM. Nur Feature-Vektoren (Amplitude, Spektralbänder) fließen in den Klassifikator. Kein Audio wird ohne explizite User-Aktivierung gespeichert.

**Feature-Extraktion:**

| Feature | Methode | Beschreibung |
|---------|---------|-------------|
| `averageAmplitude` | RMS über 30s-Envelope-Buffer | Lautstärkepegel |
| `amplitudeVariance` | Varianz des demeaned Envelopes | Unregelmäßigkeit |
| `breathingRateBPM` | Autokorrelation (8 Hz Envelope, 9–30 BPM Range) | Atemfrequenz aus Audio |
| `breathingRegularity` | 1 / (1 + diffVar×1000) | 0=unregelmäßig, 1=perfekt |
| `snoringIntensity` | FFT-Spektralband 80–500 Hz / Gesamtenergie | Schnarchen-Score 0–1 |
| `speechLikelihood` | FFT-Spektralband 300–3500 Hz (minus Schnarchen-Anteil) | Sprach-Score 0–1 |

**Verarbeitungs-Pipeline:**
```
Mikrofon → AVAudioEngine.inputNode
    → installTap (1024 Samples)
    → onBufferReady (für SoundEventService Ring-Buffer)
    → analysisQueue.async → processBuffer()
        → FFT (vDSP, 4096 Punkte, Hann-Fenster)
        → Feature-Vektor → onFeaturesUpdated
```

---

## Motion-System

**Datei:** `Services/MotionAnalysisService.swift`

Liest Beschleunigungssensor via `CMMotionManager` bei **50 Hz**. Erkennt:

| Feature | Methode | Beschreibung |
|---------|---------|-------------|
| `movementIntensity` | RMS-Varianz der Magnitude (30s, 1500 Samples) | 0=still, 1=wach/bewegt |
| `breathingRateBPM` | Autokorrelation (10 Hz, 9–30 BPM) | Atemfrequenz aus Mattress-Vibration |
| `breathingRegularity` | ACF-Peak-Stärke | Zuverlässigkeit der Atemmessung |
| `isOnMattress` | `rms > 0.0003` (ACF-Schwelle, gesenkt) | Telefon liegt auf Matratze |
| `bcgHeartRateBPM` | BCG via z-Achse, Autokorrelation (50 Hz, 48–150 BPM) | Herzrate via Ballistokardiographie |

**Sample-Rates:**
- Rohsignal: 50 Hz (Magnitude, z-Achse)
- Atemrate: 10 Hz (jeder 5. Sample, `downsampleCounter`)
- BCG: 50 Hz z-Achse (Bandpass: HP 1.5s MA + LP 3-Sample MA)

**Feature-Emit-Rate (kritisch):**
Features werden alle **30 Sekunden** emittiert, **nicht** bei jedem Sample. Dafür `emitCounter`:

```swift
private var emitCounter = 0   // in Buffers-Section als Property deklarieren

emitCounter += 1
if emitCounter >= windowSize {   // windowSize = 1500 (30s × 50Hz)
    emitCounter = 0
    let features = extract()
    DispatchQueue.main.async { self?.onFeaturesUpdated?(features) }
}
```

> **Nie** `if rawSamples.count == windowSize` verwenden — das ist nach dem ersten Füllen des Buffers immer true und würde Features mit 50 Hz emittieren (3000 Autokorrelationen/min statt 2).

**BCG-Algorithmus (angepasste Schwellenwerte):**
1. High-Pass: 1.0s gleitender Mittelwert subtrahieren (entfernt DC + Atemfrequenz; 1.0s statt 1.5s für bessere Atemunterdrückung, CEBSDB-validiert)
2. Low-Pass: 3-Sample MA (unterdrückt Sensor-Rauschen > ~8 Hz)
3. Autokorrelation im Lag-Bereich 48–150 BPM
4. Peak-Stärke > **0.22** (war 0.28/0.35 — **gegen echte SCG+EKG-Daten validiert**, CEBSDB: Lock-Rate 44 % → 67 % ohne Genauigkeitsverlust, MAE 0.8 BPM. 0.28 war zu streng und verwarf gute Erkennungen)
5. BCG-RMS-Mindest-Schwelle: **0.00003** (war 0.00008 — gesenkt)
6. BCG nur aktiv wenn `isOnMattress == true`

> **Kein Atem-Oberwellen-Ausschluss (bindend, datenbelegt):** Ein Ausschluss der Atem-Oberwellen-Lags wurde getestet und **wieder entfernt** — die Validierung gegen echte SCG+EKG-Daten (CEBSDB, 54 Fenster) zeigte, dass er die Lock-Rate **halbiert** (44 % → 26 %): Der Ruhepuls ist oft ein **ganzzahliges Vielfaches der Atemfrequenz**, sodass der Ausschluss den **echten** Herzschlag-Peak mitlöscht. Stattdessen unterdrückt der **stärkere Hochpass (1.0 s)** die Atmung. Hochpass-Fenster ist daher 1.0 s (war 1.5 s).

> **BCG-Entrauschung im Klassifikator (bindend):** Das rohe BCG-Signal springt zwischen Samples stark (Artefakte bis ~145 BPM). `SleepPhaseClassifier` darf **niemals** den rohen Momentanwert für Phasen-Entscheidungen verwenden — sonst wird das Signal als unzuverlässig verworfen und der Klassifikator fällt auf das reine 90-min-Zyklusmodell zurück (identisches Muster jede Nacht). Stattdessen:
> - **Median** über `bcgHRHistory` (Fenster 6) als `bcgMedian` — unterdrückt Einzel-Ausreißer.
> - **Zuverlässigkeit per IQR** (mittlere 50 %): `bcgReliable = (hi - lo) < 22` statt voller `(max - min) < 20` — ein einzelner Ausreißer markiert nicht mehr das ganze Fenster als unbrauchbar.
> - `effectiveHR` nutzt `bcgMedian`, nicht `motion.bcgHeartRateBPM`.

> **BCG-Degradation → Unruhe-Bias (bindend):** Sobald einmal ein sauberer BCG-Lock bestand (`bcgWasReliable` latcht auf `true`) und das Signal später kippt (`!bcgReliable`, weiterhin `isOnMattress`, kein Watch-HR), deutet das meist auf **Unruhe/Bewegung** hin — Bewegung zerstört das BCG-Signal. Bei zusätzlich leichter Bewegung (`mov > awakeMotionThreshold * 0.25`) gibt der Klassifikator **`.light` (0.58)** zurück, statt das ruhige Tief-/REM-Zyklusmodell weiterzuzeichnen. So bildet die zweite Nachthälfte echte Unruhe ab, statt einen sauberen Verlauf zu „malen". Bei völliger Ruhe (keine Bewegung) bleibt das Zyklusmodell aktiv (BCG-Aussetzer könnte auch ein reiner Sensor-Glitch sein).

**Breathing-Erkennungsschwelle:**
- `rms > 0.0003` (war 0.0008 — gesenkt für bessere Matratzen-Erkennung)

**`stop()` und `reset()` müssen `emitCounter = 0` setzen.**

---

## SleepPhaseClassifier

**Datei:** `Services/SleepPhaseClassifier.swift`

Regelbasierter Klassifikator — kombiniert Audio + Motion + HR/HRV + Schlafzyklus-Timing (ShutEye-Stil).

**Eingaben:**

| Quelle | Property | Priorität |
|--------|----------|-----------|
| Apple Watch (HealthKit) | `currentHRBPM`, `currentHRVms` | Höchste — alle 5 min |
| BCG (Beschleunigungssensor) | `motion.bcgHeartRateBPM` | Fallback wenn kein Watch — `hrConfidenceScale = 0.6` |
| Akkelerometer | `motion.breathingRateBPM` | Wenn `isOnMattress == true` — `breathScale = 1.0` |
| Mikrofon | `audio.breathingRateBPM` | Fallback Nachttisch — `breathScale = 0.70` |

**Klassifikations-Architektur (`rawClassify`) — 3 Schritte + Zonen-Verfeinerungen:**

### Schritt 0 — Feature-Extraktion (Atemrate)

```swift
let useMotionBreath = motion.isOnMattress
                      && motion.breathingRateBPM > 0
                      && motion.breathingRegularity > 0.25
let breathBPM:   Float  = useMotionBreath ? motion.breathingRateBPM   : audio.breathingRateBPM
let breathReg:   Float  = useMotionBreath ? motion.breathingRegularity : audio.breathingRegularity
let breathValid          = breathBPM > 5 && breathBPM < 35 && breathReg > 0.25
let breathScale: Double  = useMotionBreath ? 1.0 : 0.70
let breathDeep = breathValid && breathBPM < 13 && breathReg > 0.60
let breathREM  = breathValid && breathReg  < 0.45 && breathBPM > 11
```

### Schritt 1 — Wach-Erkennung

- Bewegung > `awakeMotionThreshold` ODER Amplitude > `awakeAmplitudeThreshold` → `.awake`
- HR > 80 BPM (Watch, außerhalb REM-Fenster) → `.awake`

### Schritt 2 — HR-Override (ShutEye-Primärpfad, nur wenn `hasHR`)

HR gewinnt über Zyklus-Position wenn das Signal klar ist:

```swift
if hasHR {
    let deepThresh: Double = usingBCG ? 60.0 : 56.0
    if effectiveHR < deepThresh && !inREMCycle {
        let depthBonus = min((deepThresh - effectiveHR) * 0.012, 0.10)
        let base: Double = usingBCG ? 0.64 : 0.76
        let cap:  Double = usingBCG ? 0.74 : 0.88
        return (.deep, min(base + depthBonus, cap))
    }
    if hrREM && inREMCycle && !hrvHigh {
        let hrvBonus: Double = (hrvFalling && !usingBCG) ? 0.07 : 0.0
        let base: Double = usingBCG ? 0.60 : 0.72
        let cap:  Double = usingBCG ? 0.70 : 0.84
        return (.rem, min(base + hrvBonus, cap))
    }
}
```

**Schwellenwerte HR-Override:**

| Signal | Deep-Threshold | Konfidenz-Basis | Konfidenz-Cap |
|--------|---------------|-----------------|---------------|
| Apple Watch | < 56 BPM | 0.76 | 0.88 |
| BCG | < 60 BPM | 0.64 | 0.74 |
| REM (Watch) | 60–78 BPM + REM-Fenster | 0.72 | 0.84 |
| REM (BCG) | 60–78 BPM + REM-Fenster | 0.60 | 0.70 |

### Schritt 2b — Atem-Override (nur wenn `!hasHR`)

Atemrate als primäres Signal wenn keine HR verfügbar:

```swift
if breathValid && !hasHR {
    if breathDeep && !inREMCycle {
        let regBonus = Double(max(breathReg - 0.60, 0)) * 0.28
        let base: Double = useMotionBreath ? 0.64 : 0.52
        let cap:  Double = useMotionBreath ? 0.76 : 0.63
        return (.deep, min(base + regBonus, cap))
    }
    if breathREM && inREMCycle {
        let irregBonus = Double(max(0.45 - breathReg, 0)) * 0.32
        let base: Double = useMotionBreath ? 0.60 : 0.50
        let cap:  Double = useMotionBreath ? 0.70 : 0.60
        return (.rem, min(base + irregBonus, cap))
    }
}
```

> `breathDeep` = BPM < 13 UND Regularität > 0.60 — sehr langsam + regelmäßig → Tiefschlaf  
> `breathREM` = Regularität < 0.45 UND BPM > 11 — unregelmäßig → REM

### Schritt 3 — Zyklus-Zonen + Boost-System (ShutEye 90-min-Modell)

Falls weder HR-Override noch Atem-Override ausgelöst haben:

**Zone A (0–20 min nach Onset):** → `.light`, Konfidenz 0.55–0.65

> **Zyklus = Rückgrat, Sensoren adaptieren (bindend, ShutEye-Stil):** Das 90-min-Zyklusmuster ist das **Gerüst** (garantiert eine plausible Nacht-Architektur). Die robuste **Atmung** überschreibt die Zyklus-Vorgabe **nur, wenn das Signal anhält** — `breathOverrideMin = 3` aufeinanderfolgende Messungen (`breathDeepStreak`/`breathREMStreak`). Ein einzelner verrauschter Messwert kippt die Phase **nicht**:
> - **Zone B (Default Tief):** `breathREMSustained` (unregelmäßige Atmung ≥ 3×) → `.light` (Arousal).
> - **Zone C (Default REM):** `breathDeepSustained` (langsam+regelmäßig ≥ 3×) → `.deep`.
> - Step 2b (kein HR): Atem-Override ebenfalls nur `…Sustained`.
> - Streaks werden in `reset()` genullt. Atmung ist robuster als BCG; der Restless-Bias greift nur, wenn **weder** HR **noch** gültige Atmung vorliegt.
> - So bleibt die Kurve plausibel (Muster als Skelett) und wird nur dort verfeinert, wo die Sensoren **sicher** sind — kein zappeliges Sensor-Chaos.

**Zone B (20–65 min) — Tiefschlaf-Wahrscheinlichkeit:**
```swift
// Sensor-Override zuerst:
if breathValid && breathREM { return (.light, min(0.60 + irregBonus, 0.74)) }
// sonst Tief mit Boosts:
let breathBoost: Double = breathDeep ? 0.08 * breathScale : 0.0
let conf = min(0.70 + hrBoost + hrPenalty + hrvBoost + firstCycleBoost + snoringBoost + breathBoost, 0.92)
return (.deep, conf)
```

**Zone C (65–90 min) — REM-Wahrscheinlichkeit:**
```swift
// Sensor-Override zuerst:
if breathValid && breathDeep { return (.deep, min(0.60 + regBonus, 0.76)) }
// sonst REM mit Boosts:
let breathREMBoost: Double = breathREM ? 0.08 * breathScale : 0.0
let conf = min(0.68 + hrREMBoost + hrvREMBoost + lateNightBoost + breathREMBoost + userREMBoost, 0.90)
return (.rem, conf)
```

**REM-Fenster-Erkennung:**
```swift
// Erstes REM ~70 min nach Onset, dann alle 90 min
// Letzten 25 min jedes 90-min-Zyklus = REM wahrscheinlich
let cycle = elapsedMin.truncatingRemainder(dividingBy: 90)
return cycle >= 65
```

**Angepasste Schwellenwerte:**

| Parameter | Wert | Beschreibung |
|-----------|------|-------------|
| `awakeMotionThreshold` (normal) | 0.35 | Bewegungsgrenze für Wach |
| `awakeAmplitudeThreshold` (normal) | 0.035 | Lautstärkegrenze für Wach |
| `sleepAmplitudeMax` | 0.028 | Maximal-Amplitude für Schlaf |
| Deep-Threshold Watch | 56 BPM | HR-Override Tiefschlaf |
| Deep-Threshold BCG | 60 BPM | HR-Override Tiefschlaf (erhöht) |
| `breathDeep` BPM-Schwelle | < 13 BPM | Tiefschlaf-Atemfrequenz |
| `breathREM` Regularitäts-Schwelle | < 0.45 | Unregelmäßige Atmung → REM |
| `breathValid` Qualitäts-Gate | reg > 0.25 | Mindest-Signalqualität (gesenkt für Atem-Fallback) |

**Partner-Modus-Anpassungen:**

| Stufe | `awakeMotionThreshold` | `awakeAmplitudeThreshold` | `deepRegularityMin` |
|-------|----------------------|--------------------------|---------------------|
| Aus | 0.35 | 0.035 | 0.65 |
| 1 (zwischen Partnern) | 0.50 | 0.062 | 0.52 |
| 2 (Partner näher) | 0.65 | 0.095 | 0.45 |

**History-Smoothing:** Letzte 3 Messungen — Mehrheitsvotum nach gewichteter Konfidenz.

---

## SleepOnsetDetector

**Datei:** `Services/SleepOnsetDetector.swift`

Erkennt den Zeitpunkt des Einschlafens. Zwei Modi:

| Modus | Bedingung | Fenster für Onset |
|-------|-----------|-------------------|
| **Matratze** | `motion.isOnMattress == true` (Atemrhythmus via Beschleunigungssensor) | 5 × 30s = 2.5 min |
| **Nachttisch** | Keine Atemrate via Sensor | 10 × 30s = 5 min (Audio-Stille + Bewegungslosigkeit) |

Wacht-Erkennung: 3 aufeinanderfolgende aktive Fenster → `isAsleep = false`.

**Onset-Datum — zwei verschiedene Verwendungen (kritisch):**

| Verwendung | Quelle | Beschreibung |
|-----------|--------|-------------|
| **Einschlaf-Anzeige** (`session.sleepOnsetDate`) | Erste nicht-Wach-Phase | Für "Einschlafen in X min" Anzeige in Statistik |
| **REM-Fenster-Berechnung** (`classifier.sleepOnsetDate`) | Onset-Detektor (früher) | Muss früh gesetzt sein damit REM-Fenster rechtzeitig öffnen |

```swift
// In stopTracking() — IMMER Phasen bevorzugen für Anzeige:
session.sleepOnsetDate = session.phasesArray.first(where: { $0.phaseType != .awake })?.startDate
    ?? onsetDetector.sleepOnset

// In handleFeatures() — Onset-Detektor OHNE Klassifikator-Abgleich:
if !isSleepOnsetDetected && onsetDetector.update(audio: audio, motion: motion) {
    isSleepOnsetDetected = true
    classifier.sleepOnsetDate = onsetDetector.sleepOnset
    // Kein classifier.phase-Check mehr — das verhinderte das Setzen (Chicken-and-Egg)
}
```

> **Niemals** `classifier.sleepOnsetDate` als Anzeigewert für Einschlaflatenz verwenden — dieser Wert ist bewusst früher gesetzt als der tatsächliche Schlafbeginn.

---

## SmartAlarmService

**Datei:** `Services/SmartAlarmService.swift`

Weckt in der Leichtschlaf- oder Wach-Phase innerhalb eines Zeitfensters.

> **Garantiertes Klingeln (bindend):** Der Alarm muss zuverlässig auslösen. `checkPhase(_:)` (aus `SleepTrackingViewModel.handleFeatures`, jeder Update) hat eine **harte Deadline**: sobald `isPastLatest(now)` (spätestes Weckfenster erreicht), löst der Alarm **unabhängig von der Phase** aus — auch wenn das Zyklusmodell im Fenster nie `.light`/`.awake` meldet (z.B. Nacht geht direkt von REM → Wach). Innerhalb des Fensters davor: Smart-Wake beim ersten `.light`/`.awake`. `isPastLatest` behandelt den Über-Mitternacht-Fall (frühmorgens-Zeit gehört zum nächsten Kalendertag).
>
> **Failsafe-Burst statt Einzel-Notification (bindend):** Wenn die App im Hintergrund beendet/suspendiert wurde, kann der In-App-Ton (AVAudioEngine) nicht spielen. `scheduleFailsafeNotification()` plant deshalb einen **Burst** von Notifications (am Deadline, dann alle 30 s über 5 min, IDs `\(notificationID).0…10`) — eine einzelne Notification spielt ihren Sound nur kurz und wird leicht verschlafen. **Niemals `.defaultCritical`** als Sound — das braucht Apples Critical-Alerts-Entitlement (nicht vorhanden) und fällt sonst auf **stumm** zurück; immer `.default` + `interruptionLevel = .timeSensitive`. `arm()` fordert defensiv die Notification-Permission an. `disarm()`/`triggerAlarm()` entfernen alle Burst-IDs (`failsafeIDs`).

**Keys (UserDefaults):**

| Key | Typ | Beschreibung |
|-----|-----|-------------|
| `smartAlarm.isEnabled` | `Bool` | Alarm aktiv |
| `smartAlarm.earliestHour/Minute` | `Int` | Frühestes Weckfenster |
| `smartAlarm.latestHour/Minute` | `Int` | Spätestes Weckfenster (Failsafe-Notification) |
| `smartAlarm.alarmTon` | `String` | `AlarmTon.rawValue` |
| `smartAlarm.lautstaerke` | `Float` | 0.0–1.0, Standard 0.8 |

**Snooze:** Max. 3×, je 5 Minuten. `snoozeCount` wird über `Task` gesteuert.

**Alarm-Töne (AVAudioEngine-Synthese):**

| Ton | Beschreibung | Gap |
|-----|-------------|-----|
| `.sanft` | C4+G4+C5 Akkord, langsames Crescendo | 1.8s |
| `.natur` | 3 FM-Vogel-Pfiffe (1200→1600, 1500→1900, 1800→2200 Hz) | 1.4s |
| `.klassisch` | C5→E5→G5→C6 Arpeggio, Piano-Decay | 1.0s |
| `.signal` | Alternierend 880/660 Hz, 3 Paare | 0.6s |
| `.digital` | Quadratischer Sweep 440→1320 Hz | 0.8s |

**AVAudioSession beim Alarm:**
```swift
// Alarm: Lautsprecher erzwingen, Aufnahme läuft weiter (microphone INPUT unberührt)
try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .duckOthers, .allowBluetoothHFP])
try session.overrideOutputAudioPort(.speaker)

// Nach Alarm: zurück zur Aufnahme-Session
try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .allowBluetoothHFP])
try session.overrideOutputAudioPort(.none)
```

**Failsafe:** Burst aus `UNCalendarNotificationTrigger` ab `latestWakeTime` (alle 30 s / 5 min) mit `.default`-Sound als Absicherung — siehe Hinweis oben.

---

## Profil & Einstellungen — Struktur (bindend)

### Profil (ProfilView)

```
List
├── Section              → Profilkarte → ProfilBearbeitenView
├── Section "Schlaf"     → Schlafziel, Smart Alarm, Erinnerung-Toggle + Uhrzeit
├── Section "Verknüpfungen" → PainDiary verbinden, Apple Health
└── Section "App"        → EinstellungenView
```

### App-Einstellungen (EinstellungenView)

```
List
├── Section "Aufzeichnung"  → Schlafgeräusche Toggle, Partnermodus Toggle
├── Section "Partnermodus"  → Position-Picker (nur wenn aktiv)
├── Section "Daten"
│   ├── Mit PainDiary & Health synchronisieren
│   ├── Schlafdaten als CSV exportieren
│   └── Alle Schlafdaten löschen          (confirmationDialog, trash)
└── Section "App"           → Versionsverlauf, Entwickleroptionen, Onboarding-Reset (.orange), Version
```

> **Entwickleroptionen ausgelagert (bindend):** Alle Test-/Debug-Werkzeuge liegen in **`EntwickleroptionenView`** (`Views/EntwickleroptionenView.swift`), erreichbar über Einstellungen → App → „Entwickleroptionen". Inhalt: Mikrofon testen, iCloud-Speicher testen, „Geräusch-Klassen prüfen" (`SoundClassificationService.auditText`), „Aufnahmen lauter machen" (`normalizeExistingClips`), „Schlafphasen neu berechnen" (`reapplyPhaseCorrections`), Beispielnacht/Alle 3/Langzeit-Testdaten (`SampleDataService`), „Alle Testdaten löschen". Die normalen Einstellungen bleiben nutzerfrei von Debug-Funktionen.

> **Kein Duplikat:** Jede Einstellung erscheint an genau einem Ort.

### AppStorage-Keys (vollständige Liste)

| Key | Typ | Ort |
|-----|-----|-----|
| `schlafZielStunden` | `Double` | Profil → Schlafziel |
| `einst_erinnerung_aktiv` | `Bool` | Profil → Erinnerung |
| `einst_erinnerung_zeit` | `Double` | Profil → Erinnerung |
| `soundEvents_enabled` | `Bool` | Einstellungen → Aufzeichnung |
| `partnerModus_aktiv` | `Bool` | Einstellungen → Aufzeichnung |
| `partnerModus_stufe` | `Int` | Einstellungen → Partnermodus |
| `profil_paindiary_verknuepft` | `Bool` | Profil → Verknüpfungen |
| `onboarding_complete` | `Bool` | SleepBuddyApp (Gate) |

---

## Tracking-Screen (Dark Navy)

**Datei:** `Views/SleepTrackingView.swift`

```swift
private let navy = Color(red: 0.04, green: 0.06, blue: 0.16)
// Hintergrund ist ein sanfter Nacht-Verlauf (oben indigoer → navy), nicht flach:
private var nightGradient: LinearGradient {
    LinearGradient(colors: [Color(red: 0.09, green: 0.10, blue: 0.26), navy], startPoint: .top, endPoint: .bottom)
}
```

> **Stil (bindend):** Hintergrund aller drei States = `nightGradient` (einmal im Body, nicht pro State doppeln). Mond-Symbole haben einen weichen Glow (blur-Circle dahinter) + Indigo→Violett-Verlauf. Primär-Buttons („Jetzt schlafen", „Aufwachen") nutzen den Indigo→Violett-Verlauf **mit Glow-Schatten** (konsistent zum Dashboard-Hero).

| State | Inhalt |
|-------|--------|
| Start | Mond mit Glow + "Jetzt schlafen"-Button (Verlauf + Glow) |
| Aktiv | Uhrzeit 72pt thin monospaced, Phase-Badge, Herz-Rate-Badge, Schnarchen-Badge, "Aufwachen"-Button |
| Alarm | Alarm-Animation, "Aufwachen" + "Snooze"-Button (max. 3×) |

**"Aufwachen"-Button:**
```swift
LinearGradient(colors: [.indigo.opacity(0.6), .purple.opacity(0.5)], startPoint: .leading, endPoint: .trailing)
// cornerRadius: 20, strokeBorder: .white.opacity(0.2)
```

**Mikrofon-Berechtigung:**
```swift
AVAudioApplication.requestRecordPermission { granted in ... }
// Nicht AVAudioSession.sharedInstance().requestRecordPermission (deprecated iOS 17)
```

---

## Onboarding

**Datei:** `Views/OnboardingView.swift`

7 Schritte, Dark Navy (`Color(red: 0.05, green: 0.07, blue: 0.18)`), ShutEye-Stil.

Gate in `SleepBuddyApp`:
```swift
@AppStorage("onboarding_complete") private var onboardingComplete = false
// ...
if onboardingComplete { ContentView() } else { OnboardingView { onboardingComplete = true } }
```

Reset: `UserDefaults.standard.set(false, forKey: "onboarding_complete")`

---

## HealthKit-Integration

**Datei:** `Services/HealthKitService.swift`

- Schreiben: `HKCategoryTypeIdentifier.sleepAnalysis`
- Lesen: Herzrate via `HKStatisticsQueryDescriptor`

```swift
// Korrekte API (nicht quantitySamples:)
let samplePred = HKSamplePredicate<HKQuantitySample>.quantitySample(type: hrType, predicate: predicate)
let descriptor = HKStatisticsQueryDescriptor(predicate: samplePred, options: .discreteAverage)
```

**Units:**
```swift
HKUnit.count().unitDivided(by: HKUnit.minute())  // BPM
HKUnit.secondUnit(with: .milli)                  // ms (HRV)
HKUnit.percent()                                 // SpO2
```

`@Observable`-Klasse: `Task<Void, Never>?` braucht `@ObservationIgnored`.

---

## NotificationManager

**Datei:** `Services/NotificationManager.swift`

Singleton — verwaltet ausschließlich die tägliche Schlaf-Erinnerung.

```swift
NotificationManager.shared.planeSchlafErinnerung(stunde: 22, minute: 0)
NotificationManager.shared.loescheSchlafErinnerung()
```

| Funktion | Beschreibung |
|----------|-------------|
| `berechtigungAnfordern()` | Fragt UNUserNotificationCenter-Berechtigung an (nur wenn nicht bereits `.authorized`) |
| `planeSchlafErinnerung(stunde:minute:)` | Löscht vorherige Erinnerung, plant neue `UNCalendarNotificationTrigger` täglich wiederkehrend |
| `loescheSchlafErinnerung()` | Entfernt alle ausstehenden Requests mit `schlafErinnerungID` |

**Notification-ID:** `"sleepbuddy.schlaf.erinnerung"` (Konstante im Service)

**Aufgerufen aus:** `ProfilView.planeErinnerung()` — bei Toggle-Änderung oder DatePicker-Änderung.

> `SmartAlarmService` hat eine **eigene** Notification-ID (`"com.sleepbuddy.smartalarm"`) — niemals die IDs verwechseln.

---

## Extensions

### `TimeInterval.formattedDuration`

**Datei:** `Extensions/TimeInterval+Formatted.swift`

```swift
// Verwendet überall für Schlafdauer-Anzeige
session.totalDuration.formattedDuration  // → "7h 23m" oder "45m"
```

Format: `Xh Ym` wenn ≥ 1h, sonst `Ym`. Wird in StatistikView, SleepDetailView, SleepHistoryView, SleepTrackingView genutzt — **niemals manuell formatieren**.

---

## PainDiary-Verknüpfung

App Group `group.com.doemu0992.sleepbuddy` — `SleepNightSummary` wird nach jeder abgeschlossenen Nacht (≥ 30 min) exportiert.

```swift
// ContentView: Auto-Sync bei neuen Sessions
private func autoSyncPainDiaryIfNeeded() {
    guard UserDefaults.standard.bool(forKey: "profil_paindiary_verknuepft") else { return }
    let existing = SleepNightSummary.laden()
    let finished = sessions.filter { !$0.isActive && $0.totalDuration >= 1800 }
    guard finished.count > existing.count else { return }
    for session in finished { PainDiaryVerknuepfungView.exportiereSession(session) }
}
```

---

## ML-Klassifikator-Stack

Die Schlafphasenerkennung verwendet **ShutEye-Stil** — 90-Minuten-Zyklus-Modell läuft immer:

```
Live-Klassifikation (immer):
  SleepPhaseClassifier (ShutEye 90-min-Zyklusmodell)
  → Zone A (0–20 min): Leichtschlaf
  → Zone B (20–65 min): Tiefschlaf
  → Zone C (65–90 min): REM
  → Bewegung / Lautstärke → Wach (primäres Signal)

Datensammlung (parallel, beeinflusst live-Klassifikation NICHT):
  OnlineSleepClassifier (k-NN)
  → Speichert TrainingSamples mit ShutEye-Label
  → Klassifiziert intern — Ergebnis wird verworfen
  → Ab ≥ 40 Samples: k-NN-Ergebnis wird als sessionBuffer gespeichert
```

**Einstiegspunkt:** `MLSleepClassifier` — delegiert live immer an `SleepPhaseClassifier`, ruft `onlineClassifier.recordSample()` für Datensammlung auf. Kein CoreML im Live-Pfad.

### TrainingSample (SwiftData-Modell)

**Datei:** `Models/TrainingSample.swift`

6-dimensionaler Feature-Vektor + Ground-Truth-Label, persistent in SwiftData:

| Feature | Normalisierung (Divisor) |
|---------|------------------------|
| `averageAmplitude` | 0.05 |
| `amplitudeVariance` | 0.001 |
| `breathingRateBPM` | 20.0 |
| `breathingRegularity` | 1.0 |
| `movementIntensity` | 1.0 |
| `snoringIntensity` | 1.0 |

```swift
// Euklidische Distanz im normalisierten 6D-Raum
func distance(to audio: AudioFeatures, motion: MotionFeatures) -> Float
```

**User-Korrekturen:** `isUserCorrected = true` → 3× Gewichtung im k-NN (`correctedWeight = 3.0`).

### OnlineSleepClassifier (k-NN)

**Datei:** `Services/OnlineSleepClassifier.swift`

| Parameter | Wert | Beschreibung |
|-----------|------|-------------|
| `k` | 7 | Nächste Nachbarn |
| `minSamplesForKNN` | 40 | Mindestanzahl für k-NN-Aktivierung |
| `correctedWeight` | 3.0 | Gewicht für manuell korrigierte Samples |
| `historySize` | 3 | Smoothing-Fenster (identisch zu Regelklassifikator) |

**Session-Buffer:** Während der Nacht werden alle Messungen im RAM gehalten (`sessionBuffer`). Erst beim Beenden der Nacht (`flushSessionBuffer`) → SwiftData-Insert.

**User-Korrektur:** `correctSamples(from:to:correctPhase:context:)` — setzt Label + `isUserCorrected = true` für alle Samples im Zeitraum → sofortiger `context.save()`.

**Konfidenz-Formel k-NN:**
```swift
// Gewicht = 1/Distanz × correctedWeight (falls korrigiert)
// Konfidenz = 0.4 + (Siegervotes / Gesamtvotes) × 0.55
Double(0.4 + (winner.value / max(total, 1e-6)) * 0.55)
```

### MLSleepClassifier — Architektur

**Datei:** `Services/MLSleepClassifier.swift`

```swift
// Immer: ShutEye live
func classify(audio:motion:) -> (phase, confidence) {
    let result = shutEyeClassifier.classify(audio: audio, motion: motion)
    onlineClassifier.recordSample(audio: audio, motion: motion, phase: result.phase)
    return result
}
```

> Kein CoreML im Live-Pfad. `SleepModelTrainingService` und `SleepPhaseClassifier.mlmodelc` sind inaktiv — kein Import, kein Laden, kein Laden-Fallback nötig.

---

## HomeView

**Datei:** `Views/HomeView.swift` — **Landing-Tab** (tag 0 in `ContentView`).

```
NavigationStack
└── ScrollView   (Dashboard, in Zeit-Abschnitte gegliedert)
    │ ── Letzte Nacht ──
    ├── heroCard(session)        → Nacht-Hero: Indigo→Violett-Verlauf, Begrüßung+Datum (weiß),
    │                              Schlaf-Index-Ring + Dauer + comparisonChips (vs. gestern /
    │                              Ø 7 T) + Phasen-Balken; ganze Karte → SleepDetailView
    ├── phaseCard(session)       → Schlafphasen-Donut + Legende (%/Dauer) + Fußzeile
    │                              Einschlafen · Schnarchen · Ø Puls
    ├── MorgenBewertungCard      → Doppel-Bewertung, Anzeige via @State eingefroren
    ├── MorgenBerichtCard        → KI-Morgen-Report (nur wenn letzte Session heute/gestern)
    │ ── Verlauf ── (nur ≥ 2 Nächte; deckt 7-Tage-Trend UND mehrwöchige Musteranalyse ab)
    ├── weekTrendCard            → 7-Tage-Balkenchart (Dauer) + gestrichelte Schlafziel-Linie
    ├── WochenMusterKarte        → KI-Schlafmuster (nur ≥ 3 Nächte)
    │ ── Heute Nacht ──
    └── smartAlarmCard           → Smart-Alarm + empfohlene Schlafenszeit (frühestes Fenster − Schlafziel)
```

> **Dashboard-Stil (bindend):** Home ist ein **Dashboard**, kein Karten-Stapel. Der **Nacht-Hero** (dunkler Indigo→Violett-Verlauf mit Schlaf-Index-Ring) ist der Blickfang und gibt der sonst hellen App das Schlaf-/Nacht-Feeling; darunter helle Stat-Kacheln. **Kein großer „Schlafen starten"-Button** im Normal-Zustand — der Tracker wird über den zentralen TabBar-Kreis gestartet (nur der Erst-Start-`emptyState` zeigt einen Start-CTA). `scoreColor`: <40 rot, <70 orange, <85 gelb, sonst grün. Phasen-Kacheln nutzen `SleepPhaseType.color`.

> **`MorgenBewertungCard`-Sichtbarkeit eingefroren (bindend):** Die Karte setzt beim Antippen `recordingQuality`/`subjectiveQuality` auf der Session. Würde die Sichtbarkeit direkt reaktiv aus diesen Werten berechnet, verschwände die Karte mitten in der Bewertung (z.B. beim Aufklappen von „Ungenau"). Daher steuert ein `@State zeigeBewertung`, das nur in `onAppear` und `onChange(of: lastSession)` via `aktualisiereBewertung()` neu gesetzt wird. Ein „Fertig"-Button (`onFertig`-Closure) schließt die Karte explizit.

> **Kein `learningStatusCard`/`@Query trainingSamples` in HomeView** — das Laden aller `TrainingSample`-Objekte (potenziell zehntausende) nur für eine Zählung verursachte spürbares Scroll-Ruckeln. Entfernt.

**Bedingungen für Morgen-Cards:**
```swift
// MorgenBewertungCard: subjectiveQuality == 0 UND Session ≤ 7 Tage alt (isBewertungRelevant)
// MorgenBerichtCard: Session heute oder gestern (isMorgenBerichtRelevant)
// Bewusst getrennt: Bewertung kann nachgeholt werden, Morgenbericht nur frisch sinnvoll
private func isMorgenBerichtRelevant(_ session: SleepSession) -> Bool
private func isBewertungRelevant(_ session: SleepSession) -> Bool  // ≤ 7 Tage
```

---

## Morgen-Report (Apple Intelligence)

**Datei:** `Views/MorgenBerichtView.swift`

Generiert einen personalisierten Morgen-Report via `FoundationModels.LanguageModelSession` (iOS 26+). Auf älteren iOS-Versionen: Template-basierter Fallback.

**Daten im Prompt:**
- Schlafqualität (Score 0–100), Gesamtdauer, Tiefschlaf, REM, Schnarchen-Ereignisse, Zähneknirschen, Husten
- Vortag-Score (falls vorhanden) → Vergleich
- 7-Tage-Schnitt Qualität + Dauer (falls ≥ 2 Nächte)

**Vergleich (bindend):** Die visuelle Vergleichs-Zeile (`vs. Gestern` / `Ø 7 Tage`) wurde aus der MorgenBerichtCard **entfernt** — der Vergleich sitzt jetzt als `comparisonChips` im HomeView-Hero (Doppelung vermeiden). Die Vergleichswerte fließen weiterhin in den **KI-Prompt** ein (Vortag/7-Tage im `vergleichsText`), nur die UI-Badge ist weg.

**Prompt-Format:**
```
Erstelle einen kurzen, freundlichen Morgen-Report auf Deutsch (3–4 Sätze).
Vergleiche diese Nacht mit dem Vortag und dem Wochendurchschnitt wenn vorhanden.
Keine Diagnosen, nur Beobachtungen und einen Tipp für den Tag.
```

**Reload-Button** erscheint nach Generierung — setzt `bericht = nil` und `hasGenerated = false`.

**Template-Fallback (iOS < 26):** Regelbasierte Satzgenerierung aus den gleichen Datenpunkten — kein leerer Zustand.

---

## SleepInsightService (Apple Intelligence)

**Datei:** `Services/SleepInsightService.swift`

Strukturierter KI-Analyse-Service für `SleepDetailView` — **anderer Zweck als MorgenBerichtCard**.

| | MorgenBerichtCard | SleepInsightService |
|--|--|--|
| Ort | HomeView | SleepDetailView |
| Format | Freitext (3–4 Sätze) | Strukturiert: Zusammenfassung + 3 Empfehlungen |
| Parsing | Kein Parsing | `ZUSAMMENFASSUNG:` + `EMPFEHLUNG_1/2/3:` Tags |
| Reload | Ja (Button) | Ja (`reset()`) |

**Output-Properties:**
```swift
private(set) var summary: String?           // Hauptzusammenfassung
private(set) var recommendations: [String]  // Max. 3 personalisierte Empfehlungen
private(set) var isGenerating: Bool
private(set) var error: String?
```

**iOS-Gate:**
```swift
guard #available(iOS 26.0, *) else { error = "Apple Intelligence erfordert iOS 26."; return }
guard SystemLanguageModel.default.isAvailable else { error = "...nicht verfügbar."; return }
```

> **Niemals** `FoundationModels` ohne `#available(iOS 26, *)` Guard und `SystemLanguageModel.default.isAvailable` Check aufrufen.

---

## Shared UI-Komponenten

### MorgenBewertungCard

**Datei:** `Views/MorgenBewertungCard.swift`

Subjektive Schlafbewertung 1–5 (😴/🙁/😐/🙂/😄). Erscheint in `HomeView` solange `session.subjectiveQuality == 0`.

**ML-Feedback-Loop:** Schlechte Bewertung (1–2) → alle `TrainingSample`s der Session werden auf `isUserCorrected = true` gesetzt → k-NN gewichtet sie 3× höher → Klassifikator lernt schneller aus der falschen Nacht.

```swift
if stufe <= 2 {
    // alle TrainingSamples dieser Session als korrigiert markieren
    for s in samples { s.isUserCorrected = true }
}
session.subjectiveQuality = stufe
```

> Niemals `MorgenBewertungCard` anzeigen wenn `subjectiveQuality > 0` — sonst erscheint sie jede Nacht erneut.

---

### SleepPhaseBarView

**Datei:** `Views/SleepPhaseBarView.swift`

Horizontaler Phasen-Balken — proportionale Farbblöcke für alle Phasen.

```swift
SleepPhaseBarView(phases: session.phasesArray, totalDuration: session.totalDuration)
// Jede Phase: Rectangle().fill(phase.phaseType.color), Breite ∝ duration/total
```

> **Sortierung bindend:** SwiftData liefert Beziehungen in **keiner** garantierten Reihenfolge. `SleepPhaseBarView` sortiert intern nach `startDate` — Wach-Phasen am Anfang/Ende erscheinen sonst an falscher Stelle:
> ```swift
> ForEach(phases.sorted { $0.startDate < $1.startDate }, id: \.startDate) { phase in ... }
> ```
> Gleiches gilt für alle Views die `phasesArray` iterieren ohne expliziten Sort.

Wird in `SleepSessionRow` (SleepHistoryView) und `lastNightCard` (HomeView) verwendet.

### PhaseCorrectionSheet

**Datei:** `Views/SleepDetailView.swift` (struct am Ende der Datei)

Öffnet sich beim Antippen einer Phase in `phaseListSection`. Zeigt alle `SleepPhaseType`-Cases als auswählbare Liste — aktuelle Phase mit Checkmark.

**ML-Feedback-Loop:**
```swift
// SleepDetailView — nach Auswahl der Korrektur:
classifier.correctSamples(from: phase.startDate, to: phase.endDate,
                           correctPhase: newType, context: modelContext)
// → setzt isUserCorrected = true für alle TrainingSamples im Zeitraum
// → k-NN gewichtet diese 3× höher bei künftigen Nächten
```

> Footer im Sheet: "Korrekturen werden gespeichert und verbessern die KI dauerhaft." — dieser Text muss immer sichtbar bleiben (erklärt dem Nutzer den Zweck).

### SoundCorrectionSheet

**Datei:** `Views/SleepDetailView.swift` (struct am Ende der Datei)

Öffnet sich über den ✎-Button neben jedem Sound-Event in `soundEventsSection`. Dient dem Nutzer-Feedback für die ML-Geräuscherkennung.

**Inhalt:**
- Play/Stop-Button für Audio-Vorschau des Clips
- „Korrekt ✓"-Button (grüne Capsule) — bestätigt aktuellen Typ
- Section „Als Schlafgeräusch zuordnen" — alle `isExternal == false` Typen
- Section „Als Umgebungsgeräusch zuordnen" — alle `isExternal == true` Typen
- Checkmark auf aktuellem Typ; korrigierter Typ wird sofort gespeichert
- `.presentationDetents([.large])`

> Footer: „Korrekturen werden gespeichert und verbessern die Erkennung dauerhaft." — immer sichtbar lassen.

**Feedback-Speicherung:** UserDefaults-Keys `soundFeedback.<rawValue>.confirmed/rejected/missed` — inline in `applySoundCorrection()`, kein separater Service.

---

### SharedProfil

**Datei:** `Services/SharedProfil.swift`

Singleton — liest/schreibt Profil-Daten aus dem App Group UserDefaults (`group.com.doemu0992.sleepbuddy`), damit PainDiary dieselben Profildaten lesen kann.

| Property | App-Group-Key |
|----------|--------------|
| `vorname` | `shared_vorname` |
| `nachname` | `shared_nachname` |
| `geburtsdatum` | `shared_geburtsdatum` (als `Double` TimeInterval) |
| `geschlecht` | `shared_geschlecht` |
| `anzeigeName` | computed: `"\(vorname) \(nachname)"` |

> `ICloudSettingsSync` synchronisiert diese Keys mit `ag_`-Präfix über iCloud. `SharedProfil` liest/schreibt immer direkt ohne Präfix.

---

## SampleDataService

**Datei:** `Services/SampleDataService.swift`

Erzeugt realistische Testdaten — ausschließlich für Debug/Entwicklung, nie in Production-Flows aufrufen.

### Öffentliche Einstiegspunkte

| Funktion | Beschreibung |
|----------|-------------|
| `insertSampleNight(into:)` | Fügt eine Nacht ein, cycling Night 1→2→3 nach existierender Session-Anzahl |
| `insertSampleHistory(into:)` | ~60 Nächte über 6 Monate (`stride(from: 180, through: 1, by: -3)`) für 30T/3M/6M-Filter |

### Drei Themed Nights

| Nacht | Inhalt | offsetDays |
|-------|--------|------------|
| Night 1 | Persönliche Schlafgeräusche (Schnarchen ×6, Sprechen, Husten, Bruxismus, Keuchen, Niesen, Lachen) | -2 |
| Night 2 | Externe Umgebungsgeräusche (alle externen Typen, Lautstärke-Spitzen im Noise-Chart) | -1 |
| Night 3 | Alle 24 Typen je einmal, gleichmäßig verteilt | -3 |

### Kritische Regeln (bindend)

> **`endDate` immer aus `archTotal()` ableiten** — niemals hardcoden. Sonst entstehen Lücken oder Überläufe im Schlafverlauf-Chart.

```swift
let arch: [(SleepPhaseType, Double)] = [(.awake, 12), (.light, 35), ...]
let start = makeDate(today: today, offsetDays: -2, hour: 23, minute: 0)
let end   = start.addingTimeInterval(archTotal(arch) * 60)  // IMMER so
```

> **Noise-Spitzen aus Events ableiten** — `generateNoiseCurve` erzeugt eine flache Basiskurve. Alle drei Nächte fügen danach Peaks an den Event-Timestamps ein:

```swift
for (_, offsetH, durSec, db, _) in events {
    let center = Int(offsetH * 60)
    let halfW  = max(1, Int(durSec / 60) + 1)
    for i in max(0, center - halfW)...min(mins - 1, center + halfW) {
        noise[i] = min(90, max(noise[i], db - 4 + Double.random(in: -2...2)))
    }
}
```

### Audio-Clips (WAV-Synthese)

Testdaten erzeugen echte WAV-Dateien mit typ-spezifischen Frequenzen/Harmonics für den Play-Button in `SleepDetailView`. History-Nächte haben keine Audio-Clips (`generateAudio: []`) — schnellere Insertion.

---

## Architektur-Regeln (Ergänzung)

7. **ML-Stack**: `SleepPhaseClassifier` (ShutEye) läuft immer für Live-Klassifikation. k-NN sammelt nur Daten — niemals für Live-Ausgabe verwenden.
8. **Apple Intelligence**: Immer `#available(iOS 26, *)` + `SystemLanguageModel.default.isAvailable` prüfen.
9. **TrainingSamples**: Session-Buffer erst beim Nacht-Ende flushen — nicht während der Aufnahme in SwiftData schreiben.

---

## Naming Conventions

- Views: `*View.swift`
- ViewModels: `*ViewModel.swift`
- Models: Substantiv (`SleepSession`, `SleepPhase`)
- Services: `*Service.swift`
- Enums: Singular (`SleepPhaseType`)

---

## Neue Features — Checkliste

- [ ] Schlafphasen-Farben aus `SleepPhaseType.color` (kein Hardcode)
- [ ] Karten-Hintergrund `secondarySystemGroupedBackground`
- [ ] Tint `.indigo` für alle interaktiven Elemente
- [ ] Kein Duplikat (Einstellung an genau einem Ort)
- [ ] Navigation via natives `TabView` (kein custom safeAreaInset)
- [ ] AVAudioSession: `.record` + `.allowBluetoothHFP`
- [ ] `@ObservationIgnored` bei `Task<Void, Never>?` in `@Observable`-Klassen
- [ ] CloudKit im `modelContainer` aktiv (niemals `.none`)
- [ ] Neuer iCloud-Sync-Key → in `ICloudSettingsSync.standardKeys` eintragen
- [ ] Neues AppStorage-Key → in Key-Tabelle oben dokumentieren
- [ ] Git: `git push origin main-local:main` UND `main-local:claude/zealous-goldberg-fnhmsu`
