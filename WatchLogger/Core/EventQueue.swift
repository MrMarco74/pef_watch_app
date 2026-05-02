// EventQueue.swift
// WatchLogger — Universal Apple Watch Sensor Logger
//
// Offline-first event queue. All events are written to SwiftData before
// any network attempt. SyncEngine reads from this queue and updates
// sync status as delivery succeeds or fails.
//
// Write path:  UI/Sensor → enqueue() → SwiftData (status: .pending)
// Read path:   SyncEngine → pendingEvents() → POST → markSent() / markFailed()

import Foundation
import SwiftData
import Observation

// MARK: - EventQueue

@Observable
public final class EventQueue {

    // MARK: - State

    /// Total number of events currently waiting to be sent.
    public private(set) var pendingCount: Int = 0

    /// Total events successfully delivered this session.
    public private(set) var sentCount: Int = 0

    private var modelContext: ModelContext?

    // MARK: - Setup

    /// Called by WatchLoggerApp after modelContainer is ready.
    public func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        refreshCounts()
    }

    // MARK: - Enqueue

    /// Creates a new LogEvent and persists it immediately.
    /// Returns the new event's UUID for tracking.
    @discardableResult
    public func enqueue(type: String, payload: [String: Any] = [:]) -> UUID {
        let event = LogEvent(type: type, payload: payload)
        modelContext?.insert(event)
        try? modelContext?.save()
        refreshCounts()
        return event.id
    }

    /// Convenience: enqueue a button tap event.
    public func enqueueButtonTap(buttonID: String, inputMethod: InputMethod = .touch,
                                  sensorSnapshot: SensorReading? = nil) {
        var payload: [String: Any] = [
            "button_id":    buttonID,
            "active":       true,
            "input_method": inputMethod.rawValue,
        ]
        if let s = sensorSnapshot {
            payload["heart_rate"]  = s.heartRate
            payload["hrv"]         = s.hrv
            payload["tremor_score"] = s.tremorScore
        }
        enqueue(type: "button", payload: payload)
    }

    /// Convenience: enqueue an automatically detected tremor event.
    public func enqueueTremorEvent(_ event: TremorEvent) {
        enqueue(type: "tremor_detected", payload: [
            "tremor_score":          event.score,
            "tremor_type":           event.type.rawValue,
            "dominant_frequency_hz": event.dominantFrequency,
            "parkinson_band_power":  event.parkinsonBandPower,
            "essential_band_power":  event.essentialBandPower,
        ])
    }

    // MARK: - SyncEngine Interface

    /// Returns up to `limit` events that are ready to be sent.
    /// Marks them as .syncing to prevent double-sending.
    public func pendingEvents(limit: Int = 10) -> [LogEvent] {
        guard let ctx = modelContext else { return [] }
        let descriptor = FetchDescriptor<LogEvent>(
            predicate: #Predicate { $0.syncStatus == .pending || $0.syncStatus == .failed },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        var fetch = descriptor
        fetch.fetchLimit = limit
        let events = (try? ctx.fetch(fetch)) ?? []
        events.forEach { $0.syncStatus = .syncing }
        try? ctx.save()
        return events
    }

    /// Mark events as successfully delivered and delete them.
    public func markSent(_ events: [LogEvent]) {
        guard let ctx = modelContext else { return }
        events.forEach { ctx.delete($0) }
        try? ctx.save()
        sentCount += events.count
        refreshCounts()
    }

    /// Mark events as failed with HTTP status and increment retry counter.
    public func markFailed(_ events: [LogEvent], httpStatus: Int? = nil) {
        events.forEach {
            $0.syncStatus = .failed
            $0.retryCount += 1
            $0.lastAttemptAt = Date()
            $0.lastHTTPStatus = httpStatus
        }
        try? modelContext?.save()
        refreshCounts()
    }

    // MARK: - Private

    private func refreshCounts() {
        guard let ctx = modelContext else { return }
        let descriptor = FetchDescriptor<LogEvent>(
            predicate: #Predicate { $0.syncStatus == .pending || $0.syncStatus == .failed || $0.syncStatus == .syncing }
        )
        pendingCount = (try? ctx.fetchCount(descriptor)) ?? 0
    }
}

// MARK: - InputMethod

public enum InputMethod: String {
    case touch
    case voice
    case doubleTap = "double_tap"
    case automatic
}
