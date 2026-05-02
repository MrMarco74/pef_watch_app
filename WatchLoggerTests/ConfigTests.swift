// ConfigTests.swift
// WatchLogger — Unit Tests
//
// Tests for WatchConfig JSON serialization and default values.

import XCTest
@testable import WatchLogger

final class ConfigTests: XCTestCase {

    // MARK: - JSON Round-trip

    func test_configEncodesAndDecodesRoundtrip() throws {
        let original = WatchConfig(
            endpointURL: "https://api.example.com/logs",
            authHeader: "X-API-Key",
            authToken: "secret-token-123",
            buttons: [
                ButtonConfig(id: "test", label: "Test", icon: "star.fill", color: "#FF0000")
            ]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WatchConfig.self, from: data)

        XCTAssertEqual(decoded.endpointURL, original.endpointURL)
        XCTAssertEqual(decoded.authHeader, original.authHeader)
        XCTAssertEqual(decoded.authToken, original.authToken)
        XCTAssertEqual(decoded.buttons.count, 1)
        XCTAssertEqual(decoded.buttons[0].id, "test")
    }

    func test_configTruncatesButtonsToFour() {
        let buttons = (0..<8).map { i in
            ButtonConfig(id: "btn_\(i)", label: "Button \(i)", icon: "star", color: "#FFFFFF")
        }
        let config = WatchConfig(endpointURL: "https://x.com", authToken: "t", buttons: buttons)
        XCTAssertEqual(config.buttons.count, 4, "More than 4 buttons should be truncated to 4")
    }

    func test_configUsesDefaultValues() throws {
        let json = """
        {
            "endpoint_url": "https://example.com/api",
            "auth_header": "Authorization",
            "auth_token": "Bearer abc",
            "buttons": []
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(WatchConfig.self, from: json)
        XCTAssertEqual(config.batchSize, 10)
        XCTAssertEqual(config.retryBaseSeconds, 30)
        XCTAssertEqual(config.appTitle, "WatchLogger")
    }

    func test_pefDefaultConfigHasFourButtons() {
        let config = WatchConfig.pefDefault(endpointURL: "https://example.com", token: "tok")
        XCTAssertEqual(config.buttons.count, 4)
        let ids = config.buttons.map { $0.id }
        XCTAssertTrue(ids.contains("off_phase"))
        XCTAssertTrue(ids.contains("medication"))
        XCTAssertTrue(ids.contains("stress"))
        XCTAssertTrue(ids.contains("fatigue"))
    }

    // MARK: - Color Parsing

    func test_colorHexParsing_sixDigit() {
        let color = Color(hex: "#FF4444")
        XCTAssertNotNil(color, "6-digit hex should parse successfully")
    }

    func test_colorHexParsing_withoutHash() {
        let color = Color(hex: "3FB950")
        XCTAssertNotNil(color, "Hex without # prefix should parse successfully")
    }

    func test_colorHexParsing_invalid() {
        let color = Color(hex: "GGGGGG")
        XCTAssertNil(color, "Invalid hex should return nil")
    }

    func test_colorHexParsing_wrongLength() {
        let color = Color(hex: "#FFF")
        XCTAssertNil(color, "3-digit hex is not supported and should return nil")
    }

    // MARK: - Base64 Config

    func test_applyFromBase64_validConfig() throws {
        let config = WatchConfig(
            endpointURL: "https://test.example.com/api",
            authToken: "test-token",
            buttons: []
        )
        let data = try JSONEncoder().encode(config)
        let base64 = data.base64EncodedString()

        let store = ConfigStore()
        let result = store.applyFromBase64(base64)

        XCTAssertTrue(result, "Valid base64 config should be accepted")
        XCTAssertNotNil(store.currentConfig)
        XCTAssertEqual(store.currentConfig?.endpointURL, "https://test.example.com/api")
    }

    func test_applyFromBase64_invalidData() {
        let store = ConfigStore()
        let result = store.applyFromBase64("not-valid-base64!!")
        XCTAssertFalse(result, "Invalid base64 should be rejected")
        XCTAssertNil(store.currentConfig)
    }
}
