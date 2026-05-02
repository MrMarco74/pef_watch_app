// Config.swift
// WatchLogger — Universal Apple Watch Sensor Logger
//
// Defines the complete JSON configuration schema that controls all
// runtime behavior of the app — endpoint, auth, buttons, sensors.
//
// The app has zero hardcoded backend logic. Everything is driven by
// WatchConfig, which is loaded via QR code or WatchConnectivity.
//
// JSON Schema example (minimal):
// {
//   "endpoint_url": "https://api.example.com/api/logs",
//   "auth_header": "Authorization",
//   "auth_token": "Bearer abc123",
//   "buttons": [
//     { "id": "my_event", "label": "My Event", "icon": "waveform", "color": "#FF4444" }
//   ]
// }

import Foundation
import SwiftUI

// MARK: - WatchConfig

/// Root configuration object. Serialized to/from JSON and stored in Keychain.
public struct WatchConfig: Codable, Equatable {

    // MARK: Network

    /// Full URL of the REST endpoint that receives log events.
    /// Example: "https://parkinson.example.com/api/logs"
    public let endpointURL: String

    /// HTTP header name used for authentication.
    /// Example: "Authorization"
    public let authHeader: String

    /// Value for the auth header.
    /// Example: "Bearer eyJ0eXAiOiJKV1Qi..."
    public let authToken: String

    // MARK: Buttons

    /// Up to 4 configurable manual-input buttons shown in the main grid.
    /// Fewer than 4 is valid; more than 4 will be truncated to 4.
    public let buttons: [ButtonConfig]

    // MARK: Sensors

    /// Which automatic sensor streams to enable. Defaults to all on.
    public let sensors: SensorConfig

    // MARK: Sync

    /// How many events to batch per POST request. Default: 10.
    public let batchSize: Int

    /// Seconds between sync retries on failure. Uses exponential backoff
    /// starting from this base value. Default: 30.
    public let retryBaseSeconds: Int

    // MARK: Display

    /// App title shown at top of MainView. Default: "WatchLogger"
    public let appTitle: String

    // MARK: - CodingKeys

    enum CodingKeys: String, CodingKey {
        case endpointURL     = "endpoint_url"
        case authHeader      = "auth_header"
        case authToken       = "auth_token"
        case buttons
        case sensors
        case batchSize       = "batch_size"
        case retryBaseSeconds = "retry_base_seconds"
        case appTitle        = "app_title"
    }

    // MARK: - Init with defaults

    public init(
        endpointURL: String,
        authHeader: String = "Authorization",
        authToken: String,
        buttons: [ButtonConfig],
        sensors: SensorConfig = .defaultConfig,
        batchSize: Int = 10,
        retryBaseSeconds: Int = 30,
        appTitle: String = "WatchLogger"
    ) {
        self.endpointURL = endpointURL
        self.authHeader = authHeader
        self.authToken = authToken
        self.buttons = Array(buttons.prefix(4))
        self.sensors = sensors
        self.batchSize = batchSize
        self.retryBaseSeconds = retryBaseSeconds
        self.appTitle = appTitle
    }
}

// MARK: - ButtonConfig

/// Configures one of the four manual-input buttons.
public struct ButtonConfig: Codable, Equatable, Identifiable {

    /// Stable identifier included in every log event payload.
    /// Example: "medication", "off_phase", "stress"
    public let id: String

    /// Text shown below the icon on the Watch face.
    public let label: String

    /// SF Symbol name. See https://developer.apple.com/sf-symbols/
    /// Example: "pills.fill", "waveform.path.ecg", "bolt.fill", "moon.zzz.fill"
    public let icon: String

    /// Hex color string for the button accent. Example: "#FF4444"
    public let color: String

    /// Haptic feedback style when button is tapped.
    public let haptic: HapticStyle

    /// Resolved SwiftUI Color from the hex string.
    /// Returns `.accentColor` if the hex cannot be parsed.
    public var swiftUIColor: Color {
        Color(hex: color) ?? .accentColor
    }

    enum CodingKeys: String, CodingKey {
        case id, label, icon, color, haptic
    }

    public init(id: String, label: String, icon: String,
                color: String = "#58A6FF", haptic: HapticStyle = .click) {
        self.id = id
        self.label = label
        self.icon = icon
        self.color = color
        self.haptic = haptic
    }
}

// MARK: - HapticStyle

/// Maps to WKHapticType on the watch.
public enum HapticStyle: String, Codable {
    case click      // WKHapticType.click
    case success    // WKHapticType.success
    case failure    // WKHapticType.failure
    case retry      // WKHapticType.retry
    case start      // WKHapticType.start
    case stop       // WKHapticType.stop
    case notification // WKHapticType.notification
}

// MARK: - SensorConfig

/// Toggles for each automatic sensor stream.
public struct SensorConfig: Codable, Equatable {

    /// Enable 100 Hz accelerometer + gyroscope via CoreMotion.
    /// Required for tremor detection.
    public let motionEnabled: Bool

    /// Enable passive HRV monitoring via HealthKit HKObserverQuery.
    public let hrvEnabled: Bool

    /// Enable SpO2 background reads (Series 6+).
    public let spo2Enabled: Bool

    /// Enable step count reads via HealthKit.
    public let stepsEnabled: Bool

    /// Enable automated FFT-based tremor detection.
    /// Requires motionEnabled = true.
    public let tremorDetectionEnabled: Bool

    /// Minimum tremor score (0–1) to auto-log a tremor event without user confirmation.
    /// Below this threshold, a confirmation prompt is shown.
    /// Default: 0.7
    public let tremorAutoLogThreshold: Double

    enum CodingKeys: String, CodingKey {
        case motionEnabled          = "motion_enabled"
        case hrvEnabled             = "hrv_enabled"
        case spo2Enabled            = "spo2_enabled"
        case stepsEnabled           = "steps_enabled"
        case tremorDetectionEnabled = "tremor_detection_enabled"
        case tremorAutoLogThreshold = "tremor_auto_log_threshold"
    }

    public static let defaultConfig = SensorConfig(
        motionEnabled: true,
        hrvEnabled: true,
        spo2Enabled: true,
        stepsEnabled: true,
        tremorDetectionEnabled: true,
        tremorAutoLogThreshold: 0.7
    )

    public init(motionEnabled: Bool = true, hrvEnabled: Bool = true,
                spo2Enabled: Bool = true, stepsEnabled: Bool = true,
                tremorDetectionEnabled: Bool = true, tremorAutoLogThreshold: Double = 0.7) {
        self.motionEnabled = motionEnabled
        self.hrvEnabled = hrvEnabled
        self.spo2Enabled = spo2Enabled
        self.stepsEnabled = stepsEnabled
        self.tremorDetectionEnabled = tremorDetectionEnabled
        self.tremorAutoLogThreshold = tremorAutoLogThreshold
    }
}

// MARK: - PEF Default Config

extension WatchConfig {
    /// Pre-built config for the PEF (Parkinson Erfassungs-Frontend) backend.
    /// Replace `endpoint_url` and `auth_token` with real values.
    public static func pefDefault(endpointURL: String, token: String) -> WatchConfig {
        WatchConfig(
            endpointURL: endpointURL,
            authHeader: "Authorization",
            authToken: "Bearer \(token)",
            buttons: [
                ButtonConfig(id: "off_phase",   label: "Off-Phase",  icon: "waveform.path.ecg", color: "#FF4444", haptic: .notification),
                ButtonConfig(id: "medication",  label: "Medikament", icon: "pills.fill",         color: "#3FB950", haptic: .success),
                ButtonConfig(id: "stress",      label: "Stress",     icon: "bolt.fill",           color: "#F0883E", haptic: .click),
                ButtonConfig(id: "fatigue",     label: "Müdigkeit",  icon: "moon.zzz.fill",       color: "#BC8CFF", haptic: .click),
            ],
            appTitle: "Parkinson Tracker"
        )
    }
}

// MARK: - Color Hex Extension

extension Color {
    /// Parses a CSS hex color string (#RGB, #RRGGBB, #RRGGBBAA).
    init?(hex: String) {
        var str = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.hasPrefix("#") { str.removeFirst() }
        guard str.count == 6 || str.count == 8 else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: str).scanHexInt64(&value) else { return nil }
        let r, g, b, a: Double
        if str.count == 6 {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >>  8) & 0xFF) / 255
            b = Double( value        & 0xFF) / 255
            a = 1.0
        } else {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >>  8) & 0xFF) / 255
            a = Double( value        & 0xFF) / 255
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
