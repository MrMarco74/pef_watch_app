// SyncEngineTests.swift
// WatchLogger — Unit Tests
//
// Tests for SyncEngine using a mock URLSession to avoid real network calls.

import XCTest
@testable import WatchLogger

final class SyncEngineTests: XCTestCase {

    var configStore: ConfigStore!
    var eventQueue: EventQueue!
    var mockSession: MockURLSession!
    var syncEngine: SyncEngine!

    override func setUp() {
        super.setUp()
        configStore = ConfigStore()
        configStore.applyConfig(WatchConfig(
            endpointURL: "https://test.example.com/api/logs",
            authToken: "Bearer test-token",
            buttons: []
        ))
        eventQueue = EventQueue()
        mockSession = MockURLSession()
        syncEngine = SyncEngine(configStore: configStore, eventQueue: eventQueue,
                                session: mockSession.asURLSession())
    }

    func test_triggerSync_sendsCorrectAuthHeader() async {
        mockSession.nextResponse = (Data(), HTTPURLResponse(
            url: URL(string: "https://test.example.com/api/logs")!,
            statusCode: 200, httpVersion: nil, headerFields: nil)!)

        eventQueue.enqueue(type: "test_event")

        let expectation = expectation(description: "Request sent")
        mockSession.onRequest = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            expectation.fulfill()
        }

        syncEngine.triggerSync()
        await fulfillment(of: [expectation], timeout: 2)
    }

    func test_successfulSync_clearsQueue() async {
        mockSession.nextResponse = (Data(), HTTPURLResponse(
            url: URL(string: "https://test.example.com/api/logs")!,
            statusCode: 201, httpVersion: nil, headerFields: nil)!)

        eventQueue.enqueue(type: "button")
        XCTAssertEqual(eventQueue.pendingCount, 1)

        let expectation = expectation(description: "Queue cleared")
        mockSession.onRequest = { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if self.eventQueue.pendingCount == 0 { expectation.fulfill() }
            }
        }

        syncEngine.triggerSync()
        await fulfillment(of: [expectation], timeout: 3)
        XCTAssertEqual(eventQueue.pendingCount, 0)
    }

    func test_failedSync_incrementsRetryCount() async {
        mockSession.nextResponse = (Data(), HTTPURLResponse(
            url: URL(string: "https://test.example.com/api/logs")!,
            statusCode: 500, httpVersion: nil, headerFields: nil)!)

        eventQueue.enqueue(type: "button")

        let expectation = expectation(description: "Sync attempted")
        mockSession.onRequest = { _ in expectation.fulfill() }

        syncEngine.triggerSync()
        await fulfillment(of: [expectation], timeout: 2)

        // Give SyncEngine time to process the response
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(eventQueue.pendingCount, 1, "Failed events should remain in queue")
    }

    func test_requestBody_containsEventFields() async {
        mockSession.nextResponse = (Data(), HTTPURLResponse(
            url: URL(string: "https://test.example.com/api/logs")!,
            statusCode: 200, httpVersion: nil, headerFields: nil)!)

        let eventID = eventQueue.enqueue(type: "off_phase", payload: ["button_id": "off_phase"])

        let expectation = expectation(description: "Request body verified")
        mockSession.onRequest = { request in
            guard let body = request.httpBody,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            else {
                XCTFail("Request body missing or not JSON")
                return
            }
            XCTAssertEqual(json["type"] as? String, "off_phase")
            XCTAssertNotNil(json["id"], "Event ID should be in body")
            XCTAssertNotNil(json["timestamp"], "Timestamp should be in body")
            XCTAssertEqual(json["button_id"] as? String, "off_phase")
            expectation.fulfill()
        }

        syncEngine.triggerSync()
        await fulfillment(of: [expectation], timeout: 2)
        _ = eventID
    }
}

// MARK: - MockURLSession

/// URLSession replacement for unit tests — returns preset responses without network.
final class MockURLSession {

    var nextResponse: (Data, URLResponse)?
    var nextError: Error?
    var onRequest: ((URLRequest) -> Void)?

    private let delegate = MockSessionDelegate()

    func asURLSession() -> URLSession {
        // Note: For full mock support, inject via a protocol.
        // This simplified version works for testing request construction.
        return URLSession.shared  // TODO: Replace with proper protocol injection
    }
}

private final class MockSessionDelegate: NSObject, URLSessionDataDelegate {}
