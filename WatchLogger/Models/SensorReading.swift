// SensorReading.swift
// WatchLogger — Universal Apple Watch Sensor Logger
//
// Immutable snapshot of all sensor values at a point in time.
// Used to attach current biometric context to manually triggered events.

import Foundation

// MARK: - SensorReading

/// A point-in-time snapshot of all active sensor streams.
/// Passed as context when a user taps a button or logs a voice event.
public struct SensorReading {

    /// Heart rate in bpm. nil if not yet available from HealthKit.
    public let heartRate: Double?

    /// Heart Rate Variability (SDNN, ms). nil if not yet available.
    public let hrv: Double?

    /// Blood oxygen saturation (%). nil if not available (Series 6+ only).
    public let spo2: Double?

    /// Step count today.
    public let stepCount: Int?

    /// Current tremor score from TremorDetector (0–1).
    public let tremorScore: Double

    /// Current detected tremor type.
    public let tremorType: TremorType

    /// When this snapshot was taken.
    public let capturedAt: Date

    // MARK: - Init

    public init(
        heartRate: Double? = nil,
        hrv: Double? = nil,
        spo2: Double? = nil,
        stepCount: Int? = nil,
        tremorScore: Double = 0,
        tremorType: TremorType = .none,
        capturedAt: Date = Date()
    ) {
        self.heartRate = heartRate
        self.hrv = hrv
        self.spo2 = spo2
        self.stepCount = stepCount
        self.tremorScore = tremorScore
        self.tremorType = tremorType
        self.capturedAt = capturedAt
    }

    /// Converts to a dictionary suitable for inclusion in a LogEvent payload.
    public func asDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "tremor_score": tremorScore,
            "tremor_type":  tremorType.rawValue,
        ]
        if let hr  = heartRate  { dict["heart_rate"]  = hr }
        if let hrv = hrv        { dict["hrv_ms"]      = hrv }
        if let o2  = spo2       { dict["spo2_pct"]    = o2 }
        if let s   = stepCount  { dict["step_count"]  = s }
        return dict
    }

    /// Empty reading — used as initial state before sensors produce data.
    public static let empty = SensorReading()
}
