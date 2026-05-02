// ConfigStore.swift
// WatchLogger — Universal Apple Watch Sensor Logger
//
// Persists WatchConfig in SwiftData and the auth token in Keychain.
// Loads config from three sources (in priority order):
//   1. WatchConnectivity message from iPhone companion
//   2. QR code scan (base64-encoded JSON)
//   3. Existing PersistedConfig row in SwiftData (survives restarts)
//
// The auth token is stored separately in Keychain (not in SwiftData)
// so it survives app deletion + reinstall on the same device only when
// iCloud Keychain sync is enabled.

import Foundation
import Security
import SwiftData
import WatchConnectivity
import Observation

// MARK: - ConfigStore

@Observable
public final class ConfigStore: NSObject {

    // MARK: - State

    /// The currently active configuration. nil = not yet configured (show pairing screen).
    public private(set) var currentConfig: WatchConfig?

    /// True when a valid config + auth token are present.
    public var isConfigured: Bool { currentConfig != nil }

    /// Error from the last config load/save attempt.
    public private(set) var lastError: String?

    private var modelContext: ModelContext?

    // MARK: - Keys

    private static let keychainTokenKey = "de.watchlogger.auth_token"
    private static let keychainServiceKey = "WatchLogger"

    // MARK: - Setup

    public override init() {
        super.init()
        activateWatchConnectivity()
    }

    /// Call after SwiftData container is ready.
    public func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        loadPersistedConfig()
    }

    // MARK: - Config Management

    /// Apply a new config from any source (QR code, WatchConnectivity, manual).
    public func applyConfig(_ config: WatchConfig) {
        currentConfig = config
        persistConfig(config)
        saveTokenToKeychain(config.authToken)
    }

    /// Load config from a base64-encoded JSON string (QR code format).
    /// Returns false and sets lastError if parsing fails.
    @discardableResult
    public func applyFromBase64(_ base64: String) -> Bool {
        guard let data = Data(base64Encoded: base64),
              let config = try? JSONDecoder().decode(WatchConfig.self, from: data)
        else {
            lastError = "Invalid QR code format"
            return false
        }
        applyConfig(config)
        return true
    }

    /// Remove all config and token — returns to pairing screen.
    public func clearConfig() {
        currentConfig = nil
        deletePersistedConfig()
        deleteTokenFromKeychain()
    }

    // MARK: - SwiftData Persistence

    private func loadPersistedConfig() {
        guard let ctx = modelContext else { return }
        let descriptor = FetchDescriptor<PersistedConfig>(
            predicate: #Predicate { $0.configKey == "active" }
        )
        guard let persisted = try? ctx.fetch(descriptor).first,
              let data = persisted.configJSON.data(using: .utf8),
              let config = try? JSONDecoder().decode(WatchConfig.self, from: data)
        else { return }
        currentConfig = config
    }

    private func persistConfig(_ config: WatchConfig) {
        guard let ctx = modelContext,
              let data = try? JSONEncoder().encode(config),
              let json = String(data: data, encoding: .utf8)
        else { return }

        let descriptor = FetchDescriptor<PersistedConfig>(
            predicate: #Predicate { $0.configKey == "active" }
        )
        if let existing = try? ctx.fetch(descriptor).first {
            existing.configJSON = json
            existing.updatedAt = Date()
        } else {
            ctx.insert(PersistedConfig(configJSON: json))
        }
        try? ctx.save()
    }

    private func deletePersistedConfig() {
        guard let ctx = modelContext else { return }
        let descriptor = FetchDescriptor<PersistedConfig>(
            predicate: #Predicate { $0.configKey == "active" }
        )
        (try? ctx.fetch(descriptor))?.forEach { ctx.delete($0) }
        try? ctx.save()
    }

    // MARK: - Keychain (auth token)

    /// Stores the auth token in the device Keychain.
    private func saveTokenToKeychain(_ token: String) {
        guard let data = token.data(using: .utf8) else { return }
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: Self.keychainServiceKey,
            kSecAttrAccount: Self.keychainTokenKey,
        ]
        let attributes: [CFString: Any] = [kSecValueData: data]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    private func deleteTokenFromKeychain() {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: Self.keychainServiceKey,
            kSecAttrAccount: Self.keychainTokenKey,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - WatchConnectivity

    private func activateWatchConnectivity() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }
}

// MARK: - WCSessionDelegate

extension ConfigStore: WCSessionDelegate {

    /// Receives config push from iPhone companion app.
    public func session(_ session: WCSession,
                        didReceiveUserInfo userInfo: [String: Any]) {
        guard let configBase64 = userInfo["config_base64"] as? String else { return }
        DispatchQueue.main.async { self.applyFromBase64(configBase64) }
    }

    public func session(_ session: WCSession,
                        activationDidCompleteWith activationState: WCSessionActivationState,
                        error: Error?) {
        if let error { print("WCSession activation error: \(error)") }
    }
}
