// ButtonGridView.swift
// WatchLogger — Universal Apple Watch Sensor Logger
//
// 2×2 grid of configurable symptom buttons + Send button.
// Buttons are driven entirely by WatchConfig.buttons — no hardcoded labels.
//
// Interactions:
//   Single tap    → toggle button state
//   Send          → enqueue active buttons as one event each, reset grid
//   Microphone    → activate SpeechService for voice input
//   Double-tap    → (Series 9 / Ultra 2) quicklog last active button

import SwiftUI
import WatchKit

// MARK: - ButtonGridView

struct ButtonGridView: View {

    @EnvironmentObject var configStore: ConfigStore
    @EnvironmentObject var eventQueue: EventQueue
    @EnvironmentObject var sensorManager: SensorManager
    @EnvironmentObject var healthKitService: HealthKitService

    @StateObject private var speechService = SpeechService()

    /// Which button IDs are currently active (toggled on).
    @State private var activeButtons: Set<String> = []

    /// Whether to show the send confirmation checkmark.
    @State private var showSentFeedback = false

    var body: some View {
        VStack(spacing: 4) {
            // Title
            if let title = configStore.currentConfig?.appTitle {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }

            // 2×2 button grid
            let buttons = configStore.currentConfig?.buttons ?? []
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                ForEach(buttons) { button in
                    SymptomButton(
                        config: button,
                        isActive: activeButtons.contains(button.id)
                    ) {
                        toggleButton(button)
                    }
                }
            }

            // Send + Voice row
            HStack(spacing: 4) {
                // Voice input
                Button {
                    startVoiceInput()
                } label: {
                    Image(systemName: speechService.isListening ? "mic.fill" : "mic")
                        .foregroundStyle(speechService.isListening ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 36)

                // Send
                Button {
                    sendActiveEvents()
                } label: {
                    if showSentFeedback {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.green)
                    } else {
                        Text("Senden")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                .disabled(activeButtons.isEmpty && !showSentFeedback)
            }
            .padding(.top, 2)

            // Sync queue indicator
            if eventQueue.pendingCount > 0 {
                Text("\(eventQueue.pendingCount) ausstehend")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
        }
        .padding(6)
        .onAppear {
            wireVoiceService()
        }
    }

    // MARK: - Actions

    private func toggleButton(_ button: ButtonConfig) {
        WKInterfaceDevice.current().play(hapticForStyle(button.haptic))
        if activeButtons.contains(button.id) {
            activeButtons.remove(button.id)
        } else {
            activeButtons.insert(button.id)
        }
    }

    private func sendActiveEvents() {
        guard !activeButtons.isEmpty else { return }
        WKInterfaceDevice.current().play(.success)

        let snapshot = healthKitService.currentReading(
            tremorScore: sensorManager.tremorScore,
            tremorType: sensorManager.tremorType
        )
        for buttonID in activeButtons {
            eventQueue.enqueueButtonTap(buttonID: buttonID, sensorSnapshot: snapshot)
        }

        activeButtons.removeAll()
        showSentFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showSentFeedback = false
        }
    }

    private func startVoiceInput() {
        guard let buttons = configStore.currentConfig?.buttons else { return }
        speechService.startListening(buttons: buttons)
    }

    private func wireVoiceService() {
        speechService.onCommandRecognized = { [weak eventQueue, weak healthKitService, weak sensorManager] buttonID in
            WKInterfaceDevice.current().play(.click)
            let snapshot = healthKitService?.currentReading(
                tremorScore: sensorManager?.tremorScore ?? 0,
                tremorType: sensorManager?.tremorType ?? .none
            )
            eventQueue?.enqueueButtonTap(buttonID: buttonID, inputMethod: .voice, sensorSnapshot: snapshot)
        }
        Task { await speechService.requestAuthorization() }
    }

    // MARK: - Haptic Mapping

    private func hapticForStyle(_ style: HapticStyle) -> WKHapticType {
        switch style {
        case .click:        return .click
        case .success:      return .success
        case .failure:      return .failure
        case .retry:        return .retry
        case .start:        return .start
        case .stop:         return .stop
        case .notification: return .notification
        }
    }
}

// MARK: - SymptomButton

private struct SymptomButton: View {
    let config: ButtonConfig
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: config.icon)
                    .font(.system(size: 18))
                    .foregroundStyle(isActive ? config.swiftUIColor : .secondary)
                Text(config.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isActive ? .white : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isActive
                          ? config.swiftUIColor.opacity(0.2)
                          : Color(.darkGray).opacity(0.3))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(isActive ? config.swiftUIColor : Color.clear, lineWidth: 1.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(config.label)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}
