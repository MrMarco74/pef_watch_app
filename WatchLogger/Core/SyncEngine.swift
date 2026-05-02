// SyncEngine.swift
// WatchLogger — Universal Apple Watch Sensor Logger
//
// Reads pending events from EventQueue and POSTs them to the configured
// REST endpoint. Uses exponential backoff on failure.
//
// Retry strategy:
//   Attempt 1: immediate
//   Attempt 2: base * 2^1
//   Attempt 3: base * 2^2
//   ...
//   Max backoff: 3600s (1 hour)
//
// The engine triggers automatically when:
//   - The app comes to foreground
//   - Network connectivity is restored (NWPathMonitor)
//   - A new event is enqueued (via triggerSync())
//   - The periodic timer fires (every 30s while active)

import Foundation
import Network
import Observation

// MARK: - SyncEngine

@Observable
public final class SyncEngine {

    // MARK: - State

    /// Whether a sync is currently in progress.
    public private(set) var isSyncing = false

    /// Result of the most recent sync attempt.
    public private(set) var lastSyncResult: SyncResult?

    /// Network path status from NWPathMonitor.
    public private(set) var isNetworkAvailable = false

    // MARK: - Dependencies

    private let configStore: ConfigStore
    private let eventQueue: EventQueue
    private let session: URLSession

    // MARK: - Internal timers

    private var periodicTimer: Timer?
    private var networkMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "de.watchlogger.network-monitor")

    // MARK: - Init

    public init(configStore: ConfigStore, eventQueue: EventQueue,
                session: URLSession = .shared) {
        self.configStore = configStore
        self.eventQueue = eventQueue
        self.session = session
    }

    // MARK: - Lifecycle

    /// Call from the app scene phase handler when moving to .active.
    public func start() {
        startNetworkMonitor()
        startPeriodicTimer()
        triggerSync()
    }

    /// Call from the app scene phase handler when moving to .background.
    public func stop() {
        periodicTimer?.invalidate()
        periodicTimer = nil
        networkMonitor?.cancel()
        networkMonitor = nil
    }

    // MARK: - Sync Trigger

    /// Triggers a sync pass if not already running and network is available.
    /// Safe to call from any thread.
    public func triggerSync() {
        guard !isSyncing, isNetworkAvailable else { return }
        guard let config = configStore.currentConfig else { return }

        Task { @MainActor in
            await performSync(config: config)
        }
    }

    // MARK: - Core Sync

    @MainActor
    private func performSync(config: WatchConfig) async {
        isSyncing = true
        defer { isSyncing = false }

        let events = eventQueue.pendingEvents(limit: config.batchSize)
        guard !events.isEmpty else { return }

        var succeeded: [LogEvent] = []
        var failed: [LogEvent] = []

        for event in events {
            do {
                let request = try buildRequest(event: event, config: config)
                let (_, response) = try await session.data(for: request)
                let httpResponse = response as? HTTPURLResponse

                if httpResponse?.statusCode == 200 || httpResponse?.statusCode == 201 {
                    succeeded.append(event)
                } else {
                    // 4xx errors (except 429) are permanent failures — still mark failed
                    // so they show up in the queue but don't block other events.
                    failed.append(event)
                    event.lastHTTPStatus = httpResponse?.statusCode
                }
            } catch {
                failed.append(event)
            }
        }

        eventQueue.markSent(succeeded)
        eventQueue.markFailed(failed)

        lastSyncResult = SyncResult(
            timestamp: Date(),
            sent: succeeded.count,
            failed: failed.count
        )
    }

    // MARK: - Request Builder

    private func buildRequest(event: LogEvent, config: WatchConfig) throws -> URLRequest {
        guard let url = URL(string: config.endpointURL) else {
            throw SyncError.invalidEndpointURL(config.endpointURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.authToken, forHTTPHeaderField: config.authHeader)
        request.httpBody = try event.asRequestBody()
        request.timeoutInterval = 15

        return request
    }

    // MARK: - Network Monitor

    private func startNetworkMonitor() {
        networkMonitor = NWPathMonitor()
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                let wasAvailable = self?.isNetworkAvailable ?? false
                self?.isNetworkAvailable = path.status == .satisfied
                // Trigger sync when network comes back
                if !wasAvailable && self?.isNetworkAvailable == true {
                    self?.triggerSync()
                }
            }
        }
        networkMonitor?.start(queue: monitorQueue)
    }

    // MARK: - Periodic Timer

    private func startPeriodicTimer() {
        periodicTimer?.invalidate()
        let interval = TimeInterval(configStore.currentConfig?.retryBaseSeconds ?? 30)
        periodicTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.triggerSync()
        }
    }
}

// MARK: - Supporting types

public struct SyncResult {
    public let timestamp: Date
    public let sent: Int
    public let failed: Int
}

public enum SyncError: LocalizedError {
    case invalidEndpointURL(String)
    case noConfig

    public var errorDescription: String? {
        switch self {
        case .invalidEndpointURL(let url): return "Invalid endpoint URL: \(url)"
        case .noConfig: return "No configuration loaded"
        }
    }
}
