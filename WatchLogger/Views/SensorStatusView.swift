// SensorStatusView.swift
// WatchLogger — Universal Apple Watch Sensor Logger
//
// Second tab — shows live biometric readings and sync queue status.

import SwiftUI

// MARK: - SensorStatusView

struct SensorStatusView: View {

    @EnvironmentObject var healthKitService: HealthKitService
    @EnvironmentObject var sensorManager: SensorManager
    @EnvironmentObject var eventQueue: EventQueue
    @EnvironmentObject var syncEngine: SyncEngine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {

                // Biometrics
                SensorRow(icon: "heart.fill",      color: .red,
                          label: "HF",
                          value: healthKitService.heartRate.map { "\(Int($0)) bpm" } ?? "–")
                SensorRow(icon: "waveform.path.ecg", color: .orange,
                          label: "HRV",
                          value: healthKitService.hrv.map { "\(Int($0)) ms" } ?? "–")
                SensorRow(icon: "drop.fill",        color: .blue,
                          label: "SpO₂",
                          value: healthKitService.spo2.map { "\(Int($0))%" } ?? "–")
                SensorRow(icon: "figure.walk",      color: .green,
                          label: "Schritte",
                          value: healthKitService.stepCount.map { "\($0)" } ?? "–")

                Divider()

                // Tremor
                SensorRow(icon: "waveform",         color: tremorColor,
                          label: "Tremor",
                          value: tremorText)

                Divider()

                // Sync
                SensorRow(icon: "arrow.triangle.2.circlepath",
                          color: syncEngine.isSyncing ? .blue : .secondary,
                          label: "Queue",
                          value: "\(eventQueue.pendingCount) pending")

                if let result = syncEngine.lastSyncResult {
                    Text("Sync: \(result.sent) gesendet · \(result.failed) Fehler")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
    }

    // MARK: - Helpers

    private var tremorColor: Color {
        switch sensorManager.tremorType {
        case .none:       return .secondary
        case .parkinson:  return .red
        case .essential:  return .orange
        }
    }

    private var tremorText: String {
        switch sensorManager.tremorType {
        case .none:
            return "Keiner"
        case .parkinson:
            return String(format: "Parkinson %.0f%%", sensorManager.tremorScore * 100)
        case .essential:
            return String(format: "Essentiell %.0f%%", sensorManager.tremorScore * 100)
        }
    }
}

// MARK: - SensorRow

private struct SensorRow: View {
    let icon: String
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 16)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
        }
    }
}
