// MainView.swift
// WatchLogger — Universal Apple Watch Sensor Logger
//
// Root view shown after successful pairing. Two tabs:
//   Page 1: ButtonGridView — manual symptom entry
//   Page 2: SensorStatusView — live biometric readout

import SwiftUI

// MARK: - MainView

struct MainView: View {

    @EnvironmentObject var configStore: ConfigStore
    @EnvironmentObject var eventQueue: EventQueue
    @EnvironmentObject var syncEngine: SyncEngine
    @EnvironmentObject var sensorManager: SensorManager
    @EnvironmentObject var healthKitService: HealthKitService

    var body: some View {
        TabView {
            ButtonGridView()
                .tag(0)

            SensorStatusView()
                .tag(1)
        }
        .tabViewStyle(.page)
        .onAppear {
            sensorManager.start()
            syncEngine.start()

            // Wire tremor auto-logging
            sensorManager.onTremorDetected = { [weak eventQueue] event in
                eventQueue?.enqueueTremorEvent(event)
            }

            Task { await healthKitService.requestAuthorization() }
        }
        .onDisappear {
            sensorManager.stop()
            syncEngine.stop()
        }
    }
}
