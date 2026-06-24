# SleepBuddy — Design & Code Standard

Dieses Dokument ist der verbindliche Standard für alle UI-Arbeiten in diesem Projekt.
Jede neue View, jedes neue Feature und jede Änderung muss diesen Regeln folgen.

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

## Schlafphasen-Farben (bindend)

> **Alle Views verwenden ausschliesslich `SleepPhaseType.color` — niemals hardcodierte Farben für Schlafphasen.**

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

| Phase | Farbe | Hex (ca.) |
|-------|-------|-----------|
| Wach | Orange | `#FF8C00` |
| Leichtschlaf | Hellblau | `#66A6FF` |
| Tiefschlaf | Violett | `#8050E6` |
| REM | Pink | `#F25AA6` |

**Gilt für:** Hypnogramm-Balken, Legende, stat-Cards, Charts, Phase-Badges, Tracking-Screen.

---

## Visueller Stil (bindend)

- **Tint**: `.indigo` global (Tab Bar, Buttons, Slider, Toggle)
- **Hintergrund Screen**: `Color(.systemGroupedBackground)`
- **Karten-Hintergrund**: `Color(.secondarySystemGroupedBackground)` — niemals `.secondarySystemBackground`
- **Karten-Radius**: `RoundedRectangle(cornerRadius: 16)`
- **Karten-Padding**: 16 pt innen
- **Karten-Shadow**: `.shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)`
- **Padding**: 16 pt horizontal, 8–12 pt vertikal als Basis
- **Animationen**: `.spring(response: 0.4, dampingFraction: 0.7)` für interaktive Elemente
- **Typografie**: SF Pro, `.largeTitle` für Hauptüberschriften, `.headline` für Karten-Header

### Karten-Muster (Standard)

```swift
VStack(alignment: .leading, spacing: 12) {
    // Inhalt
}
.padding()
.background(Color(.secondarySystemGroupedBackground))
.clipShape(RoundedRectangle(cornerRadius: 16))
.shadow(color: Color.primary.opacity(0.06), radius: 10, x: 0, y: 2)
```

---

## Navigation (bindend)

SleepBuddy nutzt **natives `TabView`** mit einem **zentrierten Overlay-Button** für den Tracker — identisch zu PainDiarys Navigationsmuster.

```swift
TabView(selection: $selectedTab) {
    NavigationStack { StatistikView() }
        .tabItem { Label("Statistik", systemImage: "chart.bar.fill") }
        .tag(0)

    Color.clear
        .tabItem { Label(" ", systemImage: "moon.stars.fill") }
        .tag(1)   // Dummy-Tab — triggert Tracker via onChange

    NavigationStack { ProfilView() }
        .tabItem { Label("Profil", systemImage: "person.fill") }
        .tag(2)
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
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
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
- Der Tracker-Kreis sitzt mit `.padding(.bottom, 4)` über dem Home Indicator
- Safe Area wird automatisch vom System verwaltet

---

## Tracking-Screen (Dark Navy)

Der aktive Tracking-Screen (`SleepTrackingView`) hat ein **dunkles Navy-Design**:

```swift
private let navy = Color(red: 0.04, green: 0.06, blue: 0.16)
```

- Hintergrund: `navy.ignoresSafeArea()`
- Uhrzeit: `Text(Date(), style: .time)` — 72pt, thin, monospaced
- Phase-Badge: Capsule mit Phase-Farbe und Phase-Icon
- "Aufwachen"-Button: `LinearGradient([.indigo.opacity(0.6), .purple.opacity(0.5)])`, `cornerRadius: 20`
- Ambient Glow: `Circle().fill(phase.color.opacity(0.08)).blur(radius: 80)`

---

## Einstellungen-Struktur (bindend)

Einstellungen sind **zweigeteilt**:

| Ort | Inhalt |
|-----|--------|
| **Profil → Schlaf** | Schlafziel, Smart Alarm, Schlafenszeit-Erinnerung |
| **Profil → App-Einstellungen** | Aufzeichnung (Geräusche, Partnermodus), Daten (Sync, Löschen), App (Versionsverlauf, Onboarding-Reset) |

> **Kein Duplikat:** Jede Einstellung erscheint an genau einem Ort.

### EinstellungenView-Struktur

```
List
├── Section "Aufzeichnung"   → Schlafgeräusche Toggle, Partnermodus Toggle
├── Section "Partnermodus"   → Position-Picker (nur wenn Partnermodus aktiv)
├── Section "Daten"          → Sync-Button, Alle Daten löschen (destructive + confirmationDialog)
└── Section "App"            → Versionsverlauf, Onboarding-Reset (.orange), Version
```

---

## Profil-Struktur (bindend)

```
List
├── Section (Profilkarte)    → NavigationLink → ProfilBearbeitenView
├── Section "Schlaf"         → Schlafziel, Smart Alarm, Erinnerung-Toggle + Uhrzeit-Picker
├── Section "Verknüpfungen"  → PainDiary verbinden, Apple Health
├── Section "App"            → App-Einstellungen
```

---

## Schlafapnoe-Risiko-Karte (bindend)

`SchlafapnoeRisikoView` wird in `StatistikView` nach den stat-Cards eingeblendet.

- Berechnung: `snoringEvents / stunden` gemittelt über letzte 7 Nächte (≥ 1h)
- 4 Stufen: Niedrig (<25/h), Mild (<50/h), Mittel (<75/h), Erhöht (≥75/h)
- Gradient-Balken: grün → gelb → orange → rot mit Triangle-Marker
- Farben: `.green`, `.yellow`, `.orange`, `.red`

---

## Audio-Datenschutz (Invariante)

> **Rohdaten des Mikrofons verlassen niemals den RAM.** Nur aggregierte Feature-Vektoren (Amplitude, Spektralbänder) fließen in den Klassifikator.

**AVAudioSession-Konfiguration:**
```swift
try session.setCategory(.record, mode: .measurement, options: [.mixWithOthers, .allowBluetoothHFP])
try session.setActive(true, options: .notifyOthersOnDeactivation)
```

**Opt-in iCloud-Clips:** Nur wenn in Einstellungen aktiviert — kurze `.m4a`-Clips bei Geräuschereignissen in iCloud Documents.

---

## Architektur-Regeln

1. **MVVM**: Views haben keine Business-Logik. ViewModels koordinieren Services.
2. **Services sind `@Observable`** (iOS 17 Observation framework). `Task<Void, Never>?`-Properties brauchen `@ObservationIgnored`.
3. **SwiftData**: Kein manueller Core Data Stack. `@Model`, `@Query`, `modelContainer`. **CloudKit muss immer aktiviert bleiben.**
4. **Audio läuft im Hintergrund**: Background Audio Mode in `Info.plist` + Entitlement.
5. **HealthKit**: `HKStatisticsQueryDescriptor` mit `HKSamplePredicate<HKQuantitySample>` (nicht `quantitySamples:`).
6. **App Group**: `group.com.doemu0992.sleepbuddy` — für Daten-Synchronisation mit PainDiary.

---

## Naming Conventions

- Views: `*View.swift`
- ViewModels: `*ViewModel.swift`
- Models: Substantiv (`SleepSession`, `SleepPhase`)
- Services: `*Service.swift`
- Enums: Singular (`SleepPhaseType`)

---

## Projektstruktur

```
SleepBuddy/
├── SleepBuddyApp.swift
├── ContentView.swift               # TabView + Overlay-Button
├── Models/
│   ├── SleepSession.swift
│   ├── SleepPhase.swift
│   └── SleepPhaseType.swift        # Enum mit .color (Single Source of Truth)
├── Views/
│   ├── StatistikView.swift         # Wochenstreifen + Hypnogramm + Karten
│   ├── SleepTrackingView.swift     # Dark Navy Tracking-Screen
│   ├── SleepDetailView.swift       # Detail einer Schlafnacht
│   ├── SleepHistoryView.swift      # Liste vergangener Nächte
│   ├── ProfilView.swift            # Profil + Schlaf-Settings + Verknüpfungen
│   ├── EinstellungenView.swift     # App-Einstellungen
│   ├── OnboardingView.swift        # 7-Step Onboarding (ShutEye-Stil)
│   └── SchlafapnoeRisikoView.swift # Apnoe-Risiko-Karte
├── ViewModels/
│   └── SleepTrackingViewModel.swift
└── Services/
    ├── AudioAnalysisService.swift
    ├── SleepPhaseClassifier.swift
    ├── HealthKitService.swift
    └── NotificationManager.swift
```

---

## Entitlements & Info.plist

```
com.apple.security.application-groups = group.com.doemu0992.sleepbuddy
com.apple.developer.healthkit = true
```

`Info.plist`:
- `NSMicrophoneUsageDescription`: "SleepBuddy analysiert deine Atemgeräusche, um Schlafphasen zu erkennen. Audio wird nicht gespeichert."
- `NSHealthUpdateUsageDescription`: "SleepBuddy schreibt deine Schlafdaten in Apple Health."
- `UIBackgroundModes`: `audio`

---

## Git-Workflow (bindend)

- Lokaler Branch: `main-local`
- Immer auf **beide** Remote-Branches pushen:
  ```
  git push origin main-local:main
  git push origin main-local:claude/zealous-goldberg-fnhmsu
  ```
- CloudKit darf **niemals** aus dem ModelContainer entfernt werden.

---

## Neue Features — Checkliste

- [ ] Schlafphasen-Farben aus `SleepPhaseType.color` (kein Hardcode)
- [ ] Karten-Hintergrund `secondarySystemGroupedBackground`
- [ ] Tint `.indigo` für alle interaktiven Elemente
- [ ] Kein Duplicate: Einstellung erscheint an genau einem Ort (Profil oder App-Einstellungen)
- [ ] Navigation via natives `TabView` (kein custom safeAreaInset)
- [ ] AVAudioSession: `.record` + `.allowBluetoothHFP` (nicht `.allowBluetooth`)
- [ ] `@ObservationIgnored` bei `Task<Void, Never>?` in `@Observable`-Klassen
- [ ] CloudKit im ModelContainer aktiv lassen
