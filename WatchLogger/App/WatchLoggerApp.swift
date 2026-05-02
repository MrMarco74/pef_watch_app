// WatchLoggerApp.swift
// WatchLogger — Universal Apple Watch Sensor Logger
//
// Entry point. Sets up the SwiftData model container and injects
// shared services into the environment so all views can access them
// without manual dependency passing.
//
// HOW TO USE:
//   1. Create a new Xcode project: watchOS → App → SwiftUI
//   2. Replace the generated App file with this one
//   3. Add all files from WatchLogger/ to the Watch App target
//   4. Enable capabilities: HealthKit, Background Modes (Workout processing, Background fetch)

import SwiftUI
import SwiftData

@main
struct WatchLoggerApp: App {

    // MARK: - Shared Services

    /// Central config store — reads/writes to Keychain + SwiftData.
    @StateObject private var configStore = ConfigStore()

    /// Offline-first event queue backed by SwiftData.
    @StateObject private var eventQueue: EventQueue

    /// Handles URLSession background sync with exponential backoff.
    @StateObject private var syncEngine: SyncEngine

    /// Reads CoreMotion at 100 Hz, runs FFT for tremor detection.
    @StateObject private var sensorManager: SensorManager

    /// HealthKit observer — passive HRV, SpO2, step count.
    @StateObject private var healthKitService = HealthKitService()

    // MARK: - SwiftData Container

    /// Shared model container for LogEvent and WatchConfig persistence.
    let modelContainer: ModelContainer = {
        let schema = Schema([LogEvent.self, PersistedConfig.self])
        let config = ModelConfiguration("WatchLoggerDB", schema: schema)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Non-recoverable — crash loudly so developer sees it immediately.
            fatalError("Failed to create SwiftData container: \(error)")
        }
    }()

    // MARK: - Init

    init() {
        let store = ConfigStore()
        let queue = EventQueue()
        let engine = SyncEngine(configStore: store, eventQueue: queue)
        let sensor = SensorManager()

        _configStore = StateObject(wrappedValue: store)
        _eventQueue = StateObject(wrappedValue: queue)
        _syncEngine = StateObject(wrappedValue: engine)
        _sensorManager = StateObject(wrappedValue: sensor)
    }

    // MARK: - Scene

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(configStore)
                .environmentObject(eventQueue)
                .environmentObject(syncEngine)
                .environmentObject(sensorManager)
                .environmentObject(healthKitService)
        }
        .modelContainer(modelContainer)
    }
}

// MARK: - Root View (pairing gate)

/// Shows PairingView until a valid config+token exists, then MainView.
private struct RootView: View {
    @EnvironmentObject var configStore: ConfigStore

    var body: some View {
        if configStore.isConfigured {
            MainView()
        } else {
            PairingView()
        }
    }
}
