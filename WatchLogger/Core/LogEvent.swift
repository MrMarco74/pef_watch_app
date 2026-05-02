// LogEvent.swift
// WatchLogger — Universal Apple Watch Sensor Logger
//
// SwiftData model for a single log event. Events are written locally first,
// then picked up by SyncEngine for delivery to the REST endpoint.
// This ensures zero data loss even with no network connectivity.

import Foundation
import SwiftData

// MARK: - LogEvent (SwiftData model)

/// One discrete health event, either user-triggered (button press, voice)
/// or automatically detected (tremor, HRV anomaly).
///
/// Lifecycle: .pending → .syncing → .sent (deleted after success)
///                              ↘ .failed (retried by SyncEngine)
@Model
public final class LogEvent {

    // MARK: Identity

    /// Stable UUID — used for deduplication on the server side.
    /// The server should treat this as idempotency key.
    @Attribute(.unique) public var id: UUID

    // MARK: Content

    /// Event type — corresponds to ButtonConfig.id for manual events,
    /// or "tremor_detected", "hrv_alert" for automatic events.
    public var type: String

    /// ISO 8601 timestamp when the event occurred on the watch.
    public var timestamp: Date

    /// Arbitrary key-value payload serialized as JSON string.
    /// Decoded on read via `decodedPayload`.
    public var payloadJSON: String

    // MARK: Sync state

    /// Current sync status.
    public var syncStatus: SyncStatus

    /// How many times SyncEngine has attempted to send this event.
    public var retryCount: Int

    /// Timestamp of the last send attempt (nil if never attempted).
    public var lastAttemptAt: Date?

    /// HTTP status code from the last attempt (nil if never attempted).
    public var lastHTTPStatus: Int?

    // MARK: - Init

    public init(
        id: UUID = UUID(),
        type: String,
        timestamp: Date = Date(),
        payload: [String: Any] = [:],
        syncStatus: SyncStatus = .pending,
        retryCount: Int = 0
    ) {
        self.id = id
        self.type = type
        self.timestamp = timestamp
        self.payloadJSON = Self.encode(payload)
        self.syncStatus = syncStatus
        self.retryCount = retryCount
    }

    // MARK: - Payload helpers

    /// Decoded payload dictionary. Returns empty dict if JSON is malformed.
    public var decodedPayload: [String: Any] {
        guard let data = payloadJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return dict
    }

    /// Returns the event as the JSON body to POST to the REST endpoint.
    /// Shape:
    /// {
    ///   "id": "uuid",
    ///   "type": "off_phase",
    ///   "timestamp": "2026-05-02T08:00:00Z",
    ///   "payload": { ... }
    /// }
    public func asRequestBody() throws -> Data {
        var body: [String: Any] = [
            "id":        id.uuidString,
            "type":      type,
            "timestamp": ISO8601DateFormatter().string(from: timestamp),
        ]
        // Merge payload fields directly into the top-level body
        decodedPayload.forEach { body[$0.key] = $0.value }
        return try JSONSerialization.data(withJSONObject: body)
    }

    // MARK: - Private helpers

    private static func encode(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8)
        else { return "{}" }
        return str
    }
}

// MARK: - SyncStatus

public enum SyncStatus: String, Codable {
    /// Not yet attempted.
    case pending
    /// Currently being sent by SyncEngine.
    case syncing
    /// Successfully delivered — will be deleted after confirmation.
    case sent
    /// Last attempt failed. Will be retried with exponential backoff.
    case failed
}

// MARK: - PersistedConfig (SwiftData model)

/// Stores the current WatchConfig as JSON in SwiftData so it survives app restarts.
/// Only one row exists at a time (keyed by the constant `configKey`).
@Model
public final class PersistedConfig {
    @Attribute(.unique) public var configKey: String
    public var configJSON: String
    public var updatedAt: Date

    public init(configJSON: String) {
        self.configKey = "active"
        self.configJSON = configJSON
        self.updatedAt = Date()
    }
}
