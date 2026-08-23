# PEF Apple Watch Native App — Anforderungsdokument

![License](https://img.shields.io/badge/license-MIT-blue.svg) ![Language](https://img.shields.io/badge/language-Swift-informational.svg) ![AI generated](https://img.shields.io/badge/AI-generated-8A2BE2.svg)

**Projekt:** WatchLogger — Universeller Apple Watch Sensor-Logger  
**Version:** 1.0  
**Datum:** 2026-05-02  
**Autor:** Marco Frischkorn  
**Lizenz:** MIT (nach Veröffentlichung)  
**Entwicklungsstatus:** Privates Repository — geplante Open-Source-Veröffentlichung nach MVP  
**Kontext:** Dieses Dokument beschreibt eine native watchOS-App die ursprünglich für das PEF-Projekt (Parkinson Erfassungs-Frontend) entwickelt wurde. Die App wird **bewusst so gebaut, dass sie jeden beliebigen REST-Endpoint ansprechen kann** — Endpoint-URL, Auth-Header und Metrik-Mapping sind vollständig per JSON-Config steuerbar, kein PEF erforderlich. Jeder der einen REST-Endpoint betreibt kann die App als Sensor-Frontend nutzen.

---

## 1. Projektkontext & Motivation

### 1.1 Ausgangssituation

Das PEF-Projekt ist eine Webanwendung zur Erfassung von Parkinson-Symptomen. Es besteht aus einem FastAPI-Backend, einer Vanilla-JS-Frontend-Webanwendung und einer PostgreSQL-Datenbank. Für die Erfassung von Symptomen direkt am Handgelenk existiert derzeit eine Progressive Web App (PWA) unter `/watch/`, die im iPhone-Browser als Home-Screen-App installiert werden kann.

**Limitierungen der PWA:**
- Kein nativer Zugriff auf CoreMotion (Accelerometer, Gyroscope mit voller Auflösung)
- Kein HealthKit-Zugriff
- Keine Background-Tasks (App muss geöffnet sein)
- Keine Watch-Face-Complications
- Kein Vibration-Feedback mit Patterns
- Safari auf watchOS existiert nicht — die PWA läuft nur auf dem iPhone

### 1.2 Ziel

Eine native watchOS-App bauen, die:

1. **Symptome passiv erkennt** (Tremor, Gangbild, Herzratenvariabilität) ohne Nutzerinteraktion
2. **Manuelle Eingaben** per Sprache oder Touch ermöglicht
3. **Vollständig konfigurierbar** ist — Endpoint-URL, Auth-Header, Metrik-Auswahl, Button-Labels
4. **PEF-unabhängig** ist — als generischer Sensor-Logger für beliebige REST-Backends nutzbar
5. **Offline-fähig** ist — Daten werden lokal gepuffert und bei Verbindung synchronisiert
6. **Open Source** wird — nach MVP-Fertigstellung als Community-Projekt unter MIT-Lizenz veröffentlicht (aktuell private Entwicklung)

### 1.3 Zielgruppe

- Primär: Parkinson-Patienten und deren Angehörige/Betreuer
- Sekundär: Entwickler die einen konfigurierbaren Watch-Sensor-Logger brauchen
- Tertiär: Forscher/Kliniker die Bewegungsdaten ohne proprietäre Plattform erfassen wollen

---

## 2. Architektur-Überblick

```
┌─────────────────────────────────────┐
│           Apple Watch               │
│                                     │
│  ┌─────────┐  ┌──────────────────┐  │
│  │ SwiftUI │  │   CoreMotion     │  │
│  │   UI    │  │   HealthKit      │  │
│  │         │  │ SFSpeechRec.     │  │
│  └────┬────┘  └────────┬─────────┘  │
│       │               │            │
│  ┌────▼───────────────▼─────────┐  │
│  │     WatchLogger Core         │  │
│  │  - SensorManager             │  │
│  │  - EventQueue (SwiftData)    │  │
│  │  - ConfigStore               │  │
│  │  - TremorDetector (DSP/ML)   │  │
│  └────────────────┬─────────────┘  │
│                   │                │
│  ┌────────────────▼─────────────┐  │
│  │     SyncEngine               │  │
│  │  - URLSession (Background)   │  │
│  │  - RetryQueue                │  │
│  │  - OfflineBuffer             │  │
│  └──────────────────────────────┘  │
└─────────────────────────────────────┘
           │  WatchConnectivity
           ▼
┌─────────────────────────────────────┐
│           iPhone (Companion)        │
│  - AltStore PAL (Signing)          │
│  - Konfiguration via QR-Code       │
│  - Config-Transfer zur Watch       │
└──────────────────┬──────────────────┘
                   │  HTTPS/REST
                   ▼
┌─────────────────────────────────────┐
│         REST Backend                │
│  z.B. PEF: POST /api/health/webhook│
│  oder beliebiger anderer Endpoint  │
└─────────────────────────────────────┘
```

---

## 3. Technische Anforderungen

### 3.1 Plattform

| Eigenschaft | Wert |
|---|---|
| Ziel-Plattform | watchOS 10.0+ |
| Companion-App | iOS 17.0+ (für Konfiguration) |
| Entwicklungssprache | Swift 5.9+ |
| UI-Framework | SwiftUI |
| Datenpersistenz | SwiftData |
| Build-System | Xcode 15+ / GitHub Actions macOS-14 Runner |
| Signing | Apple Developer Account (kostenlos für Sideloading via AltStore PAL) |
| Mindest-Hardware Watch | Apple Watch Series 4 (für CoreMotion-Vollzugriff) |
| Empfohlen | Apple Watch Series 6+ (SpO2), Series 9 / Ultra 2 (Double-Tap Gesture) |

### 3.2 Frameworks & APIs

| Framework | Verwendung |
|---|---|
| `CoreMotion` | Accelerometer (100Hz), Gyroscope, CMPedometer |
| `HealthKit` | HRV, Ruhepuls, SpO2, Schlafdaten lesen |
| `SFSpeechRecognizer` | On-device Spracherkennung (watchOS 10+) |
| `AVFoundation` | Audio-Session für Spracheingabe |
| `WatchConnectivity` | Konfiguration vom iPhone zur Watch übertragen |
| `UserNotifications` | Lokale Reminder (Medikamente, fehlende Logs) |
| `URLSession` | Background URL Sessions für Datentransfer |
| `SwiftData` | Lokale Offline-Queue, Config-Persistenz |
| `ClockKit` / `WidgetKit` | Watch-Face Complications |
| `CoreLocation` | Optional: Standort-Kontext (z.B. Außenaktivität) |

---

## 4. Funktionale Anforderungen

### 4.1 Konfiguration (Config-System)

Die App ist vollständig über eine JSON-Konfiguration steuerbar. Kein Hard-Coding von Endpoints oder Credentials.

#### 4.1.1 Config-Schema

```json
{
  "version": 1,
  "app_name": "PEF Logger",
  "endpoint": {
    "url": "https://parkinson.familie-frischkorn.de/api/logs/watch",
    "method": "POST",
    "headers": {
      "X-Health-Token": "abc123",
      "Content-Type": "application/json"
    },
    "timeout_s": 15,
    "retry_max": 5,
    "retry_backoff_s": 30
  },
  "sensors": {
    "tremor_detection": true,
    "gait_analysis": true,
    "hrv_passive": true,
    "heart_rate_continuous": false,
    "spo2_on_demand": true,
    "pedometer": true,
    "background_sampling_interval_s": 300
  },
  "ui": {
    "buttons": [
      {
        "id": "offtime",
        "label": "Off-Phase",
        "icon": "waveform.path.ecg",
        "color": "#FF4D4D",
        "haptic": "notification"
      },
      {
        "id": "medication",
        "label": "Medikament",
        "icon": "pills.fill",
        "color": "#4D94FF",
        "haptic": "success"
      },
      {
        "id": "stress",
        "label": "Stress",
        "icon": "bolt.fill",
        "color": "#FFB84D",
        "haptic": "warning"
      },
      {
        "id": "fatigue",
        "label": "Müdigkeit",
        "icon": "moon.zzz.fill",
        "color": "#9B59B6",
        "haptic": "click"
      }
    ],
    "speech_enabled": true,
    "speech_commands": {
      "offtime": ["off phase", "offtime", "tremor"],
      "medication": ["medikament", "pille", "medication"],
      "stress": ["stress"],
      "fatigue": ["müde", "müdigkeit", "fatigue"]
    },
    "quick_confirm_timeout_s": 3,
    "theme": "dark"
  },
  "privacy": {
    "store_raw_motion": false,
    "anonymize_location": true,
    "local_only_mode": false
  }
}
```

#### 4.1.2 Config-Übertragung

Die Konfiguration kann auf drei Wegen zur Watch übertragen werden:

1. **QR-Code scannen** (bevorzugt): Die Companion-iPhone-App scannt einen QR-Code der die Config-URL oder Base64-encoded JSON enthält
2. **WatchConnectivity**: Direkte Übertragung vom iPhone zur Watch via `WCSession.transferUserInfo()`
3. **Manuelle Eingabe**: URL + Token können direkt auf der Watch per Diktat eingegeben werden (Fallback)

#### 4.1.3 Config-Pairing (kompatibel mit PEF)

Das bestehende PEF Pairing-System (`/api/auth/pairing/request-nonce`) soll unterstützt werden:

1. Watch zeigt 8-stelligen Nonce-Code an
2. Nutzer gibt Code im PEF-Webinterface ein
3. PEF-Backend gibt JWT zurück, Watch speichert ihn als Bearer-Token
4. Alle folgenden Requests nutzen `Authorization: Bearer <token>`

---

### 4.2 Sensor-Datenerfassung

#### 4.2.1 Tremor-Erkennung

**Ziel:** Automatische Erkennung von Parkinson-typischem Ruhetremor (4–6 Hz) ohne Nutzerinteraktion.

**Implementierung:**

```
CoreMotion → Accelerometer (100Hz) → Ringpuffer (5s) →
FFT (256 Punkte) → Frequenzband-Analyse →
  Peak bei 4–6 Hz AND Amplitude > Schwellwert →
    Tremor-Event mit Confidence-Score
```

**Datenfluss:**
- `CMMotionManager.startAccelerometerUpdates(to:withHandler:)` mit 100Hz Sampling Rate
- Ringpuffer: 512 Samples (ca. 5 Sekunden)
- FFT: Accelerator Framework (`vDSP_fft_zrip`)
- Frequenzband: 3–8 Hz (Parkinson-Tremor), 8–12 Hz (Essentieller Tremor unterscheidbar)
- Schwellwert: konfigurierbar, Default 0.15g Peak-Amplitude im Zielband
- Hysterese: Tremor-Start wenn 3 consecutive FFT-Frames > Schwellwert; Tremor-Ende wenn 5 Frames < Schwellwert

**Output-Event:**
```json
{
  "type": "tremor_detected",
  "started_at": "2026-05-02T10:15:30Z",
  "ended_at": "2026-05-02T10:15:45Z",
  "duration_s": 15,
  "dominant_frequency_hz": 4.8,
  "mean_amplitude": 0.23,
  "confidence": 0.87,
  "limb": "wrist_left"
}
```

**ML-Erweiterung (optional, Phase 2):**
- Create ML `MLActivityClassifier` mit labeled Trainingsdaten
- On-device Inferenz ohne Internet
- Klassifizierung: `rest_tremor`, `action_tremor`, `no_tremor`, `walking`, `other_motion`

#### 4.2.2 Gang-Analyse

**Ziel:** Kontinuierliche Erfassung von Parkinson-relevanten Gangparametern.

**Datenquellen:**
- `CMPedometer` für Schrittanzahl, Schrittfrequenz, Distanz
- `CMMotionActivity` für Aktivitätsklassifizierung (gehen, laufen, stehen, Auto)
- `CMDeviceMotion` (Attitude + Gravity) für Körperhaltung

**Erfasste Metriken (analog zu Apple Health / PEF DB):**

| Metrik | Quelle | Entspricht DB-Feld |
|---|---|---|
| Schrittlänge | CMPedometer | `hkq_walkingsteplength` |
| Gehgeschwindigkeit | CMPedometer | `hkq_walkingspeed` |
| Asymmetrie % | CMDeviceMotion (laterale Beschleunigung) | `hkq_walkingasymmetrypercentage` |
| Doppelstand-Zeit % | CMDeviceMotion (Schritt-Timing) | `hkq_walkingdoublesupportpercentage` |
| Treppensteigen | CMPedometer | `hkq_stairascentspeed` / `hkq_stairdescentspeed` |
| Steadiness | CMDeviceMotion (Jerk-Magnitude) | `hkq_applewalkingsteadiness` |

**Sampling:** Aggregation alle 60 Sekunden während erkannter Gehaktivität.

#### 4.2.3 Herzratenvariabilität (HRV)

**Passiv (HealthKit):**
- `HKObserverQuery` für `HKQuantityTypeIdentifier.heartRateVariabilitySDNN`
- Background Delivery aktiviert — Watch weckt App wenn Apple Watch neue HRV-Messung abgeschlossen hat (typisch nachts)

**Aktiv auf Anfrage:**
- `HKWorkoutSession` starten (5-Minuten-Messung) für on-demand HRV
- Nutzer-triggerbar per Button oder Complication

#### 4.2.4 SpO2 (Sauerstoffsättigung)

- Nur auf Series 6+ verfügbar
- On-demand via `HKQuantityTypeIdentifier.oxygenSaturation`
- Erfordert `HKWorkoutSession` für Echtzeit-Messung
- Background-Delivery für bereits von Apple Watch gemessene Werte

#### 4.2.5 Passive Hintergrundsensoren

Alle 5 Minuten (konfigurierbar) werden folgende Werte erfasst und in die lokale Queue geschrieben:

- Ruhepuls (HealthKit)
- Aktivitätsklasse (CMMotionActivity)
- Umgebungsgeräuschpegel (wenn aktiv)
- Aktueller Tremor-Score (0.0–1.0)
- Schritte letzte Stunde (CMPedometer)

---

### 4.3 Manuelle Eingabe

#### 4.3.1 Touch-Interface

Adaptives Grid-Layout (2×2 Standard, 1×N für wenige Buttons):

```
┌──────────┬──────────┐
│          │          │
│ 🌊 Off-  │ 💊 Medi- │
│  Phase   │  kament  │
│          │          │
├──────────┼──────────┤
│          │          │
│ ⚡ Stress │ 🌙 Müdig-│
│          │  keit    │
│          │          │
└──────────┴──────────┘
│  [  Absenden  ] [×] │
└─────────────────────┘
```

- Buttons: Toggle-Verhalten (aktiv/inaktiv), visuelles + haptisches Feedback
- Absenden: sendet aktuellen Button-State + alle Sensor-Snapshots als ein Event
- Schließen: App in Background, Sensor-Erfassung läuft weiter
- **Double-Tap** (Series 9 / Ultra 2): Schnellerfassung des zuletzt verwendeten Buttons

#### 4.3.2 Spracheingabe

**Technologie:** `SFSpeechRecognizer` mit `on-device` Recognition (kein Internet-Requirement)

**Ablauf:**
1. Nutzer hebt Handgelenk → Siri-ähnliches Mikrofon-Icon erscheint (optional, konfigurierbar)
2. Nutzer spricht: "Medikament genommen" / "Offtime" / "Stress hoch"
3. On-device Transkription (Latenz < 500ms)
4. Intent-Matching gegen konfigurierbare Keyword-Listen
5. Visuelles Feedback: erkanntes Keyword hervorgehoben
6. 3-Sekunden-Bestätigungs-Fenster bevor automatisch gesendet wird (mit Cancel-Option)

**Fallback:** Bei unbekanntem Intent → zeigt Transkription an, Nutzer wählt manuell

**Sprachen:** Konfigurierbar (Default: `de-DE`, Support für `en-US`, `fr-FR`, `es-ES`)

---

### 4.4 Daten-Payload & REST-Integration

#### 4.4.1 Standard-Payload Format

```json
{
  "schema_version": "1.0",
  "source": "watchlogger",
  "device": {
    "model": "Apple Watch Series 9",
    "os": "watchOS 10.3",
    "app_version": "1.0.0"
  },
  "session_id": "550e8400-e29b-41d4-a716-446655440000",
  "captured_at": "2026-05-02T10:15:30Z",
  "timezone": "Europe/Berlin",
  "events": [
    {
      "id": "evt_001",
      "type": "button",
      "timestamp": "2026-05-02T10:15:30Z",
      "payload": {
        "button_id": "medication",
        "active": true,
        "input_method": "touch"
      }
    },
    {
      "id": "evt_002",
      "type": "tremor_detected",
      "timestamp": "2026-05-02T10:14:00Z",
      "payload": {
        "duration_s": 22,
        "dominant_frequency_hz": 5.1,
        "confidence": 0.91,
        "mean_amplitude": 0.28
      }
    },
    {
      "id": "evt_003",
      "type": "speech",
      "timestamp": "2026-05-02T10:15:28Z",
      "payload": {
        "transcript": "Medikament genommen",
        "matched_intent": "medication",
        "confidence": 0.96
      }
    }
  ],
  "metrics_snapshot": {
    "heart_rate_bpm": 68,
    "hrv_sdnn_ms": 42.3,
    "spo2_pct": 97.0,
    "steps_last_hour": 412,
    "tremor_score": 0.12,
    "activity": "stationary",
    "walking_speed_kmh": null,
    "walking_asymmetry_pct": null
  }
}
```

#### 4.4.2 PEF-Kompatibilitäts-Modus

Wenn Endpoint als PEF erkannt wird (konfigurierbar via Flag), sendet die App das native Health Auto Export Format:

```json
{
  "data": {
    "metrics": [
      {
        "name": "step_count",
        "units": "count",
        "data": [{"date": "2026-05-02 10:00:00 +0200", "qty": 412, "source": "WatchLogger"}]
      }
    ]
  }
}
```

Symptom-Events gehen weiterhin an `POST /api/logs` mit Bearer-Token-Auth.

#### 4.4.3 Offline-Queue

- Alle Events werden zuerst lokal in SwiftData gespeichert
- Sync-Versuch sofort wenn Netzwerk verfügbar
- Retry-Logik: exponentielles Backoff (30s, 60s, 120s, 300s, 600s)
- Maximale Queue-Größe: 10.000 Events (konfigurierbar)
- Bei vollem Speicher: Älteste Events werden verworfen (FIFO)
- Sync-Status sichtbar in Complication und App-Status-Bar

---

### 4.5 Watch-Face Complications

#### 4.5.1 Verfügbare Complication-Typen

| Typ | Inhalt | Slot |
|---|---|---|
| Corner | Letzter Symptom-Log Zeitstempel | Corner |
| Modular Small | Tremor-Score als Gauge | Modular |
| Circular Small | App-Icon + ungesendete Events Badge | Circular |
| Graphic Corner | Tremor-Score + Tages-Schritte | Graphic Corner |
| Graphic Bezel | Statuszeile: "Kein Tremor · 4.231 Schritte" | Graphic Bezel |

#### 4.5.2 Smart Stack Widget (watchOS 10)

- Zeigt: Letzter Log-Zeitpunkt, heutiger Tremor-Score, Schritte, Medication-Status
- Relevance-Hint: erhöhte Priorität zur üblichen Medikamentenzeit (konfigurierbar)

---

### 4.6 Benachrichtigungen & Reminder

| Trigger | Notification |
|---|---|
| Medikamentenzeit (konfigurierbar) | "💊 Medikament fällig" → Tap öffnet App mit Medication-Button vorselektiert |
| Tremor > 30s erkannt | Stille Hintergrunderfassung, kein Alert |
| Tremor > 120s ohne Bestätigung | Optionaler Alert "Tremor-Episode erkannt. Alles ok?" |
| Kein Log seit 8h (Wachzeit) | "Kein Symptom-Log heute" |
| Offline-Queue > 50 Events | "Keine Verbindung — 50 Events ausstehend" |

---

### 4.7 Datenschutz & Sicherheit

- **Alle Sensordaten verlassen das Gerät nur** wenn explizit konfigurierter Endpoint erreichbar ist
- **`privacy.local_only_mode: true`** speichert ausschließlich lokal, kein Remote-Send
- **`privacy.store_raw_motion: false`** (Default): nur aggregierte Metriken, keine Roh-Accelerometer-Daten
- Konfiguration (inkl. Token) wird im **watchOS Keychain** gespeichert, nicht in UserDefaults
- TLS 1.2+ erzwungen, Certificate Pinning optional konfigurierbar
- Keine Third-Party-SDKs, keine Analytics, keine Crash-Reporter die Daten senden
- HealthKit-Berechtigungen granular: nur angeforderte Typen, immer mit Begründung im Permission-Dialog
- DSGVO-konform: kein Nutzer-Tracking, keine persistente Geräte-ID die über App-Reinstallation hinaus gilt

---

## 5. UI/UX Anforderungen

### 5.1 Hauptscreen (nach Pairing)

```
┌─────────────────────────┐
│ [Status: ✓ Verbunden]   │  ← Status-Bar (nur wenn relevant)
├──────────┬──────────────┤
│          │              │
│  🌊      │    💊        │
│ Off-Phase│  Medikament  │
│          │              │
├──────────┼──────────────┤
│          │              │
│  ⚡       │    🌙        │
│  Stress  │   Müdigkeit  │
│          │              │
├──────────┴──────────────┤
│  [  Absenden  ]  [ × ]  │
└─────────────────────────┘
```

- Schwarz/Dark-Mode first (OLED Watch-Display, Akku-Ersparnis)
- Schrift: SF Pro Rounded (System-Font watchOS)
- Touch-Targets: mindestens 44×44pt (HIG-Konform)
- Aktive Buttons: roter Rahmen + Glow-Effekt + Icon-Wechsel
- Haptik: `.WKHapticType.click` beim Toggle, `.success` beim Senden

### 5.2 Pairing-Screen

```
┌─────────────────────────┐
│  Code eingeben unter    │
│  Einstellungen > App    │
│                         │
│     ╔═══════════╗       │
│     ║  A3F7B2   ║       │
│     ╚═══════════╝       │
│                         │
│  Warte auf Kopplung...  │
│      (4:32)             │
│                         │
│  [Code neu generieren]  │
└─────────────────────────┘
```

### 5.3 Sensor-Status-Screen (erreichbar per Digital Crown Scroll)

```
┌─────────────────────────┐
│  Sensor-Status          │
│  ─────────────────────  │
│  🫀 HF: 68 bpm          │
│  📊 HRV: 42ms           │
│  🩸 SpO2: 97%           │
│  👣 Heute: 4.231        │
│  〰 Tremor: Keiner      │
│                         │
│  Queue: 0 ausstehend    │
│  Sync: vor 2 Min        │
└─────────────────────────┘
```

### 5.4 Spracheingabe-Screen

```
┌─────────────────────────┐
│                         │
│         🎙              │
│                         │
│  "Medikament genommen"  │
│                         │
│  → 💊 Medikament        │
│                         │
│  [ Bestätigen ] [  ×  ] │
│       (3s)              │
└─────────────────────────┘
```

---

## 6. Build & Deployment

### 6.1 Projektstruktur

```
WatchLogger/
├── WatchLogger.xcodeproj
├── WatchLoggerApp/              ← iOS Companion App
│   ├── App.swift
│   ├── Views/
│   │   ├── ConfigView.swift     ← QR-Scanner, manuelle Eingabe
│   │   └── StatusView.swift     ← Sync-Status, Queue-Übersicht
│   └── Services/
│       ├── WatchConnectivityService.swift
│       └── QRCodeParser.swift
├── WatchLoggerWatch/            ← watchOS Extension
│   ├── App.swift
│   ├── Views/
│   │   ├── MainView.swift       ← 2×2 Grid
│   │   ├── PairingView.swift
│   │   ├── SensorStatusView.swift
│   │   └── SpeechInputView.swift
│   ├── Core/
│   │   ├── SensorManager.swift  ← CoreMotion + HealthKit
│   │   ├── TremorDetector.swift ← FFT-basierte Erkennung
│   │   ├── GaitAnalyzer.swift
│   │   ├── SpeechManager.swift
│   │   ├── EventQueue.swift     ← SwiftData
│   │   └── SyncEngine.swift     ← URLSession Background
│   ├── Config/
│   │   ├── ConfigStore.swift    ← Keychain + SwiftData
│   │   └── ConfigSchema.swift   ← Codable Typen
│   ├── Complications/
│   │   └── WatchLoggerComplication.swift
│   └── Models/
│       ├── Event.swift
│       ├── MetricsSnapshot.swift
│       └── SyncPayload.swift
├── Shared/
│   └── PayloadSchema.swift      ← Geteilt zwischen iOS + watchOS
└── .github/
    └── workflows/
        └── build.yml            ← GitHub Actions Build
```

### 6.2 GitHub Actions Workflow

```yaml
# .github/workflows/build.yml
name: Build WatchLogger IPA

on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  build:
    runs-on: macos-14
    
    steps:
      - uses: actions/checkout@v4
      
      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_15.4.app
      
      - name: Import Signing Certificate
        env:
          CERTIFICATE_BASE64: ${{ secrets.CERTIFICATE_BASE64 }}
          CERTIFICATE_PASSWORD: ${{ secrets.CERTIFICATE_PASSWORD }}
          KEYCHAIN_PASSWORD: ${{ secrets.KEYCHAIN_PASSWORD }}
        run: |
          security create-keychain -p "$KEYCHAIN_PASSWORD" build.keychain
          security default-keychain -s build.keychain
          security unlock-keychain -p "$KEYCHAIN_PASSWORD" build.keychain
          echo "$CERTIFICATE_BASE64" | base64 --decode > certificate.p12
          security import certificate.p12 -k build.keychain \
            -P "$CERTIFICATE_PASSWORD" -T /usr/bin/codesign
          security set-key-partition-list -S apple-tool:,apple: \
            -s -k "$KEYCHAIN_PASSWORD" build.keychain
      
      - name: Build Archive
        run: |
          xcodebuild archive \
            -project WatchLogger.xcodeproj \
            -scheme WatchLogger \
            -sdk watchsimulator \
            -archivePath build/WatchLogger.xcarchive \
            CODE_SIGN_STYLE=Manual \
            DEVELOPMENT_TEAM=${{ secrets.APPLE_TEAM_ID }} \
            CODE_SIGN_IDENTITY="Apple Development"
      
      - name: Export IPA
        run: |
          xcodebuild -exportArchive \
            -archivePath build/WatchLogger.xcarchive \
            -exportPath build/ \
            -exportOptionsPlist ExportOptions.plist
      
      - name: Upload Artifact
        uses: actions/upload-artifact@v4
        with:
          name: WatchLogger-IPA
          path: build/*.ipa
          retention-days: 30
```

### 6.3 Installation via AltStore PAL (EU)

1. AltStore PAL aus dem App Store installieren (kostenlos in der EU seit DMA 2024)
2. AltServer auf einem Windows-PC oder Mac installieren (einmalig)
3. IPA-Artifact von GitHub Actions herunterladen
4. In AltStore PAL: "+" → IPA auswählen → Installieren
5. AltStore erneuert das Signing-Zertifikat automatisch solange AltServer im WLAN läuft

**Alternative ohne AltServer:** Sideloadly (Windows-App) — erfordert manuelle Erneuerung alle 7 Tage.

---

## 7. Backend-Integration (PEF-spezifisch)

### 7.1 Bestehende Endpoints

Die PEF-Instanz unter `https://parkinson.familie-frischkorn.de` stellt folgende Endpoints bereit:

| Endpoint | Method | Auth | Beschreibung |
|---|---|---|---|
| `/api/auth/pairing/request-nonce` | GET | — | Generiert 8-stelligen Pairing-Code |
| `/api/auth/pairing/status?nonce=X` | GET | — | Polling auf Pairing-Abschluss |
| `/api/auth/pairing/link-token` | POST | JWT | Nutzer bestätigt Pairing im Web |
| `/api/logs` | POST | Bearer | Symptom-Log senden |
| `/api/health/webhook` | POST | X-Health-Token | Health Auto Export kompatibles Push-Format |
| `/api/status` | GET | Bearer | Session-Validierung |

### 7.2 Neuer Watch-spezifischer Endpoint (zu implementieren)

```
POST /api/logs/watch
Authorization: Bearer <token>
Content-Type: application/json

Body: WatchLogger Standard-Payload (siehe 4.4.1)
```

Dieser Endpoint soll:
- Symptom-Events in `health.symptom_logs` schreiben
- Tremor-Events in neue Tabelle `health.tremor_events`
- Metriken-Snapshots in die entsprechenden `health.hkq_*` Tabellen
- `200 OK` mit `{"status": "ok", "events_accepted": N}` zurückgeben

### 7.3 Datenbank-Erweiterung (PEF)

Neue Tabelle `health.tremor_events`:

```sql
CREATE TABLE health.tremor_events (
    id              SERIAL PRIMARY KEY,
    started_at      TIMESTAMPTZ NOT NULL,
    ended_at        TIMESTAMPTZ,
    duration_s      FLOAT,
    dominant_freq_hz FLOAT,
    mean_amplitude  FLOAT,
    confidence      FLOAT,
    source          TEXT DEFAULT 'watchlogger',
    raw_payload     JSONB
);
CREATE INDEX ON health.tremor_events (started_at);
```

---

## 8. Entwicklungs-Roadmap

### Phase 1 — MVP (4–6 Wochen)

- [ ] Xcode-Projektstruktur aufsetzen
- [ ] SwiftUI UI: Pairing-Screen + 4-Button-Grid
- [ ] PEF Pairing-Flow implementieren (Nonce → JWT)
- [ ] `POST /api/logs` mit Bearer-Token
- [ ] Offline-Queue (SwiftData)
- [ ] GitHub Actions Build-Pipeline
- [ ] AltStore-kompatible IPA

### Phase 2 — Sensor-Integration (4–6 Wochen)

- [ ] CoreMotion Tremor-Erkennung (FFT)
- [ ] CMPedometer Gang-Metriken
- [ ] HealthKit passive Daten (HRV, Puls)
- [ ] Background Sensor Sampling (alle 5 Min)
- [ ] Watch-Payload Format + neuer Backend-Endpoint

### Phase 3 — UX & Features (3–4 Wochen)

- [ ] Spracheingabe (SFSpeechRecognizer)
- [ ] Watch-Face Complications (WidgetKit)
- [ ] Smart Stack Widget
- [ ] Konfiguration via QR-Code
- [ ] Notification / Reminder System
- [ ] Sensor-Status-Screen

### Phase 4 — Generalisierung (2–3 Wochen)

- [ ] Config-Schema finalisieren
- [ ] PEF-spezifischen Code hinter Config-Flag abstrahieren
- [ ] Dokumentation für eigene Backend-Integration
- [ ] Open-Source-Vorbereitung (Lizenz, Contributing-Guide, README)

### Phase 5 — Optional / ML

- [ ] Create ML Modell für Tremor-Klassifizierung
- [ ] Bradykinese-Erkennung
- [ ] SpO2 on-demand
- [ ] iOS Companion-App mit Konfigurationsinterface

---

## 9. Nicht-Ziele (explizit ausgeschlossen)

- Keine Apple-Watch-App-Store-Veröffentlichung (erfordert 99€/Jahr Developer Account)
- Kein CloudKit / iCloud-Sync
- Keine Watch-zu-Watch-Kommunikation
- Keine Diagnose-Funktion — die App ist ein Logging-Tool, kein Medizinprodukt
- Keine Drittanbieter-Analytics oder Crash-Reporter

---

## 10. Offene Fragen / Community-Input erwünscht

1. **Tremor-Schwellwerte**: Welche Amplitude und Frequenz-Grenzwerte sind klinisch validiert für Parkinson vs. physiologischem Tremor?
2. **Batterie-Impact**: Wie stark belastet 100Hz Accelerometer-Sampling die Watch-Batterie? Gibt es community-Erfahrungswerte?
3. **AltStore PAL vs. TestFlight**: Gibt es einen Weg TestFlight ohne Store-Einreichung zu nutzen (Ad-hoc Distribution)?
4. **watchOS ML**: Erfahrungen mit `CoreML` on-device Inferenz auf älteren Watch-Generationen (Series 4/5)?
5. **Backend-Abstraktionsschicht**: Würde ein Plugin-System (ähnlich Health Auto Export) Sinn machen — also vorbereitete "Presets" für bekannte Backends?

---

## 11. Kontakt & Ressourcen

- **Projekt-Repository (geplant):** wird nach MVP-Fertigstellung auf GitHub veröffentlicht
- **PEF Backend (Referenz-Implementation):** `https://parkinson.familie-frischkorn.de`
- **Webhook-Endpoint Dokumentation:** `/api/health/webhook` — akzeptiert Health Auto Export JSON Format
- **Pairing-API:** `/api/auth/pairing/request-nonce` + `/api/auth/pairing/status`
- **Autor:** Marco Frischkorn

---

*Dieses Dokument ist eine lebende Spezifikation. Feedback, Korrekturen und Beiträge sind erwünscht.*

---

## Entwicklungshinweis

Der bisherige Code-Skeleton in diesem Repository wurde im Vibe-Coding-Stil zusammen mit
[Claude](https://claude.ai) (Anthropic) erstellt. Das bedeutet: Die Architektur, Struktur
und Implementierungsideen stammen aus dem Dialog zwischen Autor und KI — kein blinder
Copy-Paste, sondern iteratives Entwickeln mit KI-Unterstützung.

Der Code ist als **Ausgangspunkt und Diskussionsgrundlage** gedacht, nicht als
produktionsreifer Stand. Reviewe, verbessere und teste alles gründlich bevor du
es auf echter Hardware einsetzt.

