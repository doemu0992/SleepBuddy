# SleepBuddy — Design & Architecture Standard

## Projektübersicht

SleepBuddy ist eine iOS-Schlaf-Tracking App (ähnlich Sleep Cycle), die Schlafphasen automatisch via Mikrofon-Analyse erkennt — ohne Apple Watch. Es wird kein Audio gespeichert; nur die Phasen-Klassifikation (Tief/Leicht/REM/Wach) wird persistiert.

Später wird die App mit **PainDiary** (doemu0992/paindiary) über eine App Group verknüpft.

---

## Tech Stack

| Layer | Technologie |
|-------|-------------|
| UI | SwiftUI |
| Datenpersistenz | SwiftData |
| Audio | AVAudioEngine (Background Audio Entitlement) |
| Gesundheitsdaten | HealthKit |
| App-übergreifend | App Group (`group.com.doemu0992.sleepbuddy`) |
| Minimum iOS | iOS 17.0 |
| Tint-Farbe | `.indigo` |

---

## Design-Prinzipien

### Visueller Stil
- **Tint**: `.indigo` global (`accentColor`)
- **Hintergrund**: systemBackground / systemGroupedBackground
- **Typografie**: SF Pro, `.largeTitle` für Hauptüberschriften
- **Karten**: `RoundedRectangle(cornerRadius: 16)` mit `.fill(.secondarySystemGroupedBackground)`
- **Padding**: 16pt horizontal, 12pt vertikal als Basis
- **Animationen**: `.spring(response: 0.4, dampingFraction: 0.7)` für interaktive Elemente

### Schlafphasen-Farbpalette
```swift
extension SleepPhaseType {
    var color: Color {
        switch self {
        case .deep:  return Color.indigo
        case .rem:   return Color.purple
        case .light: return Color.blue
        case .awake: return Color.orange
        }
    }
}
```

### Audio-Speicherung (opt-in)
**Standard**: Rohdaten des Mikrofons verlassen niemals den RAM für die Klassifikation. Nur aggregierte Feature-Vektoren (Amplitude, Spektralbänder) fließen in den Klassifikator.

**Opt-in iCloud-Clips**: Der Nutzer kann in Einstellungen > Schlafgeräusche kurze Audioclips (~30s) aktivieren. Bei erkannten Ereignissen (Schnarchen, Sprechen, Geräusche) speichert `SoundEventService` einen Clip als `.m4a` in iCloud Documents (`iCloud.com.doemu0992.SleepBuddy/SleepSounds/`). Ohne Aktivierung bleibt die ursprüngliche Invariante erhalten.

---

## Projektstruktur

```
SleepBuddy/
├── SleepBuddyApp.swift          # App Entry Point, SwiftData Container
├── ContentView.swift            # Root Navigation
├── Models/
│   ├── SleepSession.swift       # @Model: eine Schlafnacht
│   ├── SleepPhase.swift         # @Model: Phase innerhalb einer Nacht
│   └── SleepPhaseType.swift     # Enum: deep/light/rem/awake
├── Views/
│   ├── HomeView.swift           # Startseite, "Schlafen starten"
│   ├── SleepTrackingView.swift  # Aktive Aufzeichnung
│   ├── SleepHistoryView.swift   # Liste vergangener Nächte
│   └── SleepDetailView.swift    # Detail einer Schlafnacht
├── ViewModels/
│   ├── HomeViewModel.swift
│   └── SleepTrackingViewModel.swift
└── Services/
    ├── AudioAnalysisService.swift    # AVAudioEngine, Feature-Extraktion
    ├── SleepPhaseClassifier.swift    # Regelbasierte Klassifikation
    └── HealthKitService.swift        # HealthKit-Integration
```

---

## Architektur-Regeln

1. **MVVM**: Views haben keine Business-Logik. ViewModels koordinieren Services.
2. **Services sind `@Observable`** (iOS 17 Observation framework).
3. **SwiftData**: Kein manueller Core Data Stack. `@Model`, `@Query`, `modelContainer`.
4. **Audio läuft im Hintergrund**: Background Audio Mode in `Info.plist` + Entitlement.
5. **HealthKit**: Nur schreiben (HKCategoryTypeIdentifier.sleepAnalysis). Berechtigung beim ersten Start anfragen.
6. **App Group**: `group.com.doemu0992.sleepbuddy` — für spätere Daten-Synchronisation mit PainDiary.

---

## Naming Conventions

- Views: `*View.swift`
- ViewModels: `*ViewModel.swift`
- Models: Substantiv (`SleepSession`, `SleepPhase`)
- Services: `*Service.swift`
- Enums: Singular (`SleepPhaseType`)

---

## Entitlements & Capabilities

```
com.apple.security.application-groups = group.com.doemu0992.sleepbuddy
com.apple.developer.healthkit = true
```

`Info.plist`:
- `NSMicrophoneUsageDescription`: "SleepBuddy analysiert deine Atemgeräusche, um Schlafphasen zu erkennen. Audio wird nicht gespeichert."
- `NSHealthUpdateUsageDescription`: "SleepBuddy schreibt deine Schlafdaten in Apple Health."
- `UIBackgroundModes`: `audio`

---

## Verknüpfung mit PainDiary

Geplante Datenstruktur in App Group:
```swift
// Shared UserDefaults via App Group
let defaults = UserDefaults(suiteName: "group.com.doemu0992.sleepbuddy")
defaults?.set(sleepQualityScore, forKey: "lastNightSleepQuality")
```

Schmerz-Schlaf-Korrelation: PainDiary liest `lastNightSleepQuality` und zeigt Korrelation mit Schmerzeinträgen.
