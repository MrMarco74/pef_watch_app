// PairingView.swift
// WatchLogger — Universal Apple Watch Sensor Logger
//
// Shown on first launch (no config present) and after deauth.
// Two pairing methods:
//   1. Nonce-based PEF pairing (GET /api/auth/pairing/request-nonce → poll status)
//   2. Manual JSON config entry via QR code on iPhone companion (WatchConnectivity)
//
// The PEF pairing flow mirrors the existing PWA pairing in watch_app.js.

import SwiftUI

// MARK: - PairingView

struct PairingView: View {

    @EnvironmentObject var configStore: ConfigStore
    @State private var viewModel = PairingViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "applewatch")
                    .font(.system(size: 28))
                    .foregroundStyle(.blue)

                Text("WatchLogger")
                    .font(.headline)

                switch viewModel.phase {
                case .idle:
                    idleView
                case .fetchingNonce:
                    ProgressView("Generiere Code...")
                        .font(.system(size: 11))
                case .waitingForPairing(let nonce, let remaining):
                    waitingView(nonce: nonce, remaining: remaining)
                case .paired:
                    pairedView
                case .error(let message):
                    errorView(message: message)
                }
            }
            .padding(8)
        }
        .onAppear { viewModel.configStore = configStore }
    }

    // MARK: - Phase Views

    private var idleView: some View {
        VStack(spacing: 6) {
            Text("Koppeln via PEF oder QR-Code")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("PEF koppeln") {
                Task { await viewModel.startPairing() }
            }
            .buttonStyle(.bordered)
            .tint(.blue)

            Text("oder warte auf\nWatchConnectivity vom iPhone")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func waitingView(nonce: String, remaining: Int) -> some View {
        VStack(spacing: 4) {
            Text("Code im PEF eingeben:")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Text(nonce)
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundStyle(.cyan)
                .kerning(4)

            Text("\(remaining / 60):\(String(format: "%02d", remaining % 60))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)

            ProgressView()
                .scaleEffect(0.7)
        }
    }

    private var pairedView: some View {
        VStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.green)
            Text("Verbunden!")
                .font(.system(size: 12, weight: .semibold))
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Erneut versuchen") {
                Task { await viewModel.startPairing() }
            }
            .buttonStyle(.bordered)
            .font(.system(size: 11))
        }
    }
}

// MARK: - PairingViewModel

@Observable
final class PairingViewModel {

    enum Phase {
        case idle
        case fetchingNonce
        case waitingForPairing(nonce: String, remaining: Int)
        case paired
        case error(String)
    }

    var phase: Phase = .idle
    var configStore: ConfigStore?

    private var pollTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var nonce: String?

    /// Starts the PEF nonce-based pairing flow.
    func startPairing() async {
        guard let baseURL = detectBaseURL() else {
            phase = .error("Kein PEF-Server erreichbar. Konfiguriere via iPhone.")
            return
        }

        phase = .fetchingNonce
        pollTask?.cancel()
        countdownTask?.cancel()

        do {
            let url = URL(string: "\(baseURL)/api/auth/pairing/request-nonce")!
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(NonceResponse.self, from: data)
            nonce = response.nonce

            startCountdown(seconds: response.expiresIn)
            startPolling(baseURL: baseURL, nonce: response.nonce)

        } catch {
            phase = .error("Verbindungsfehler: \(error.localizedDescription)")
        }
    }

    private func startCountdown(seconds: Int) {
        countdownTask = Task { @MainActor in
            var remaining = seconds
            while remaining > 0 && !Task.isCancelled {
                if let n = nonce {
                    phase = .waitingForPairing(nonce: n, remaining: remaining)
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                remaining -= 1
            }
            if remaining <= 0 {
                phase = .error("Code abgelaufen. Bitte erneut versuchen.")
            }
        }
    }

    private func startPolling(baseURL: String, nonce: String) {
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)  // 3s
                guard let url = URL(string: "\(baseURL)/api/auth/pairing/status?nonce=\(nonce)") else { return }

                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      let status = try? JSONDecoder().decode(PairingStatus.self, from: data)
                else { continue }

                if status.status == "paired", let token = status.token {
                    countdownTask?.cancel()
                    // Build minimal config — user can refine via WatchConnectivity later
                    let config = WatchConfig.pefDefault(endpointURL: "\(baseURL)/api/logs", token: token)
                    configStore?.applyConfig(config)
                    phase = .paired
                    return
                } else if status.status == "expired" {
                    phase = .error("Code abgelaufen.")
                    return
                }
            }
        }
    }

    /// Tries to auto-detect the PEF server URL from known defaults.
    /// In production, this should be user-configurable.
    private func detectBaseURL() -> String? {
        // TODO: Replace with user-configurable server URL entry
        // or read from WatchConnectivity pre-config message.
        return nil
    }
}

// MARK: - API Response Types

private struct NonceResponse: Codable {
    let nonce: String
    let expiresIn: Int
    enum CodingKeys: String, CodingKey {
        case nonce
        case expiresIn = "expires_in"
    }
}

private struct PairingStatus: Codable {
    let status: String
    let token: String?
}
