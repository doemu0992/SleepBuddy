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
    NavigationStack { StatistikView() }
        .tabItem { Label("Statistik", systemImage: "chart.bar.fill") }.tag(0)
    Color.clear
        .tabItem { Label(" ", systemImage: "moon.stars.fill") }.tag(1)
    NavigationStack { ProfilView() }
        .tabItem { Label("Profil", systemImage: "person.fill") }.tag(2)
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
    if tab == 1 { showTracking = true; selectedTab = 0 }
}
```

**Regeln:**
- Kein custom `safeAreaInset` Tab Bar — immer natives `TabView`
- Tab 1 ist Dummy (`Color.clear`) und öffnet den Tracker via `onChange`
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

```
NavigationStack (via NavigationLink aus StatistikView)
└── ScrollView
    ├── statsGrid          → 3 stat-Cards: Tiefschlaf / REM / Leichtschlaf
    ├── SchlafindexView    → Score-Badge + Erklärung
    ├── hypnogramSection   → Balken-Hypnogramm (identisch zu StatistikView)
    ├── verlaufChart       → Linechart mit AreaMark + Gradient
    ├── soundEventsSection → Geräusch-Ereignisse mit Typ und Uhrzeit
    ├── noiseSection       → Umgebungslautstärke als Linechart
    ├── phaseListSection   → Alle Phasen als Timeline-Liste
    └── morgenBewertung    → Subj. Qualitäts-Rating 1–5
```

**Wichtige Funktionen:**

| Funktion | Beschreibung |
|----------|-------------|
| `pct(_:)` | Prozentwert einer Phase an Gesamtdauer |
| `hypnoData` | `[(time, depth)]` für Verlaufs-Chart |
| `statsGrid` | `LazyVGrid` mit 3 `statCard`-Views |
| `statCard(_:value:icon:color:percent:)` | Karten-View mit Icon, Wert, Beschriftung, Prozentbalken |
| `verlaufChart` | SwiftCharts `LineMark` + `AreaMark` mit Phasen-Gradient |

**Verlaufs-Chart Gradient:**
```swift
LinearGradient(
    colors: [SleepPhaseType.deep.color.opacity(0.7), SleepPhaseType.rem.color.opacity(0.7)],
    startPoint: .top, endPoint: .bottom
)
```

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

### SleepHistoryView

**Datei:** `Views/SleepHistoryView.swift`

```
NavigationStack
└── List
    ├── WochenSummaryCard  → Wochendurchschnitt + Balken-Chart (Schlafziel als gestrichelte Linie)
    └── ForEach(sessions)  → Zeilen mit Datum, Dauer, Score-Badge
```

`WochenSummaryCard` nutzt `@AppStorage("schlafZielStunden")` für die Ziellinie im Chart.

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
    var sleepOnsetDate: Date?             // Auto-detected
    var snoringEventCount: Int
    var alarmEarliestTime: Date?
    var alarmLatestTime: Date?
    var alarmFiredDate: Date?
    var soundEvents: [SleepSoundEvent]?   // cascade delete
    var noiseSamples: [Double]            // dB/Minute
    var subjectiveQuality: Int            // 0=nicht bewertet, 1–5
}
```

**Berechnete Properties:**

| Property | Typ | Beschreibung |
|----------|-----|-------------|
| `totalDuration` | `TimeInterval` | end - start (oder jetzt wenn aktiv) |
| `sleepOnsetLatency` | `TimeInterval?` | Zeit bis Einschlafen |
| `isActive` | `Bool` | `endDate == nil` |
| `phasesArray` | `[SleepPhase]` | `phases ?? []` |
| `soundEventsArray` | `[SleepSoundEvent]` | `soundEvents ?? []` |
| `deepSleepDuration` | `TimeInterval` | Summe aller `.deep`-Phasen |
| `remSleepDuration` | `TimeInterval` | Summe aller `.rem`-Phasen |
| `lightSleepDuration` | `TimeInterval` | Summe aller `.light`-Phasen |
| `awakeDuration` | `TimeInterval` | Summe aller `.awake`-Phasen |

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

**Noise Floor:** Adaptiver EMA (exponential moving average) — passt sich über die Nacht an Raumgeräusche an.

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
| `isOnMattress` | `rms > 0.0008` (ACF-Schwelle) | Telefon liegt auf Matratze |
| `bcgHeartRateBPM` | BCG via z-Achse, Autokorrelation (50 Hz, 48–150 BPM) | Herzrate via Ballistokardiographie |

**Sample-Rates:**
- Rohsignal: 50 Hz (Magnitude, z-Achse)
- Atemrate: 10 Hz (jeder 5. Sample, `downsampleCounter`)
- BCG: 50 Hz z-Achse (Bandpass: HP 1.5s MA + LP 3-Sample MA)

**BCG-Algorithmus:**
1. High-Pass: 1.5s gleitender Mittelwert subtrahieren (entfernt DC + Atemfrequenz < 0.7 Hz)
2. Low-Pass: 3-Sample MA (unterdrückt Sensor-Rauschen > ~8 Hz)
3. Autokorrelation im Lag-Bereich 48–150 BPM
4. Peak-Stärke > 0.35 erforderlich (noisier als Audio)
5. BCG nur aktiv wenn `isOnMattress == true`

---

## SleepPhaseClassifier

**Datei:** `Services/SleepPhaseClassifier.swift`

Regelbasierter Klassifikator — kombiniert Audio + Motion + HR/HRV + Schlafzyklus-Timing.

**Eingaben:**

| Quelle | Property | Priorität |
|--------|----------|-----------|
| Apple Watch (HealthKit) | `currentHRBPM`, `currentHRVms` | Höchste — alle 5 min |
| BCG (Beschleunigungssensor) | `motion.bcgHeartRateBPM` | Fallback wenn kein Watch — `hrConfidenceScale = 0.6` |
| Akkelerometer | `motion.breathingRateBPM` | Wenn `isOnMattress == true` (direkter) |
| Mikrofon | `audio.breathingRateBPM` | Fallback wenn Nightstand |

**Klassifikations-Logik (Reihenfolge):**

1. **Bewegung/Lautstärke** → `.awake` (stärkste Signal)
2. **HR > 80 BPM** (außerhalb REM-Fenster, kein BCG) → `.awake`
3. **Schnarchen** → `.deep` (langsam + regelmäßig) oder `.light`
4. **Keine Atemrate erkennbar** → HR-basiert oder `.light`/`.awake` je nach Amplitude
5. **Tief**: langsam (9–15 BPM) + regelmäßig + leise + außerhalb REM-Fenster
6. **REM**: unregelmäßig (reg < 0.50), leise, im REM-Fenster
7. **HR-REM**: Watch-HR im REM-Bereich (60–78), kein BCG → `.rem` (Conf. 0.70)
8. **Leicht**: 14–19 BPM oder Restfall

**REM-Fenster-Erkennung:**
```swift
// Erstes REM ~70 min nach Onset, dann alle 90 min
// Letzten 25 min jedes 90-min-Zyklus = REM wahrscheinlich
let cycle = elapsedMin.truncatingRemainder(dividingBy: 90)
return cycle >= 65
```

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

Setzt `SleepSession.sleepOnsetDate` bei Bestätigung. Wacht-Erkennung: 3 aufeinanderfolgende aktive Fenster → `isAsleep = false`.

---

## SmartAlarmService

**Datei:** `Services/SmartAlarmService.swift`

Weckt in der Leichtschlaf- oder Wach-Phase innerhalb eines Zeitfensters.

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

**Failsafe:** `UNCalendarNotificationTrigger` auf `latestWakeTime` als Absicherung.

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
├── Section "Daten"         → Sync-Button, Alle Daten löschen (confirmationDialog)
└── Section "App"           → Versionsverlauf, Onboarding-Reset (.orange), Version
```

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
```

| State | Inhalt |
|-------|--------|
| Start | Illustration + "Jetzt schlafen"-Button |
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

## Architektur-Regeln

1. **MVVM**: Views haben keine Business-Logik. ViewModels koordinieren Services.
2. **`@Observable`**: Services nutzen iOS 17 Observation. `Task<Void, Never>?` → `@ObservationIgnored`.
3. **SwiftData + CloudKit**: Niemals `cloudKitDatabase: .none`. Alle Model-Attribute optional oder mit Default.
4. **Audio Background**: `UIBackgroundModes: audio` in Info.plist + Entitlement.
5. **Farben**: Schlafphasen immer via `SleepPhaseType.color`. Kein Hardcode.
6. **Keine Duplikate**: Jede Einstellung an genau einem Ort.

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
