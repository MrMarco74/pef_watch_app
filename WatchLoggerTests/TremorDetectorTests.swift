// TremorDetectorTests.swift
// WatchLogger — Unit Tests
//
// Tests for the FFT-based tremor detection algorithm.
// All tests use synthetic signals so no device is required.

import XCTest
@testable import WatchLogger

final class TremorDetectorTests: XCTestCase {

    var detector: TremorDetector!
    var detectedEvents: [TremorEvent] = []

    override func setUp() {
        super.setUp()
        detector = TremorDetector()
        detectedEvents = []
        detector.onTremorDetected = { [weak self] event in
            self?.detectedEvents.append(event)
        }
    }

    // MARK: - Signal Generators

    /// Generates a pure sine wave at the given frequency.
    func sineWave(frequency: Double, amplitude: Double = 1.0,
                  sampleRate: Double = TremorDetector.sampleRate,
                  count: Int = TremorDetector.windowSize * 2) -> [Double] {
        (0..<count).map { i in
            amplitude * sin(2 * .pi * frequency * Double(i) / sampleRate)
        }
    }

    /// Feeds samples into the detector and waits for FFT to run.
    func feedSamples(_ samples: [Double]) {
        samples.forEach { detector.addSample($0) }
        // Give the main queue a chance to deliver callbacks
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    }

    // MARK: - Tests

    func test_noTremorOnSilence() {
        let silence = [Double](repeating: 0, count: TremorDetector.windowSize * 2)
        feedSamples(silence)
        XCTAssertTrue(detectedEvents.isEmpty, "Silent signal should not trigger tremor detection")
        XCTAssertEqual(detector.lastScore, 0, accuracy: 0.01)
        XCTAssertEqual(detector.lastType, .none)
    }

    func test_noTremorOnDCOffset() {
        // Constant signal = 1g gravity component, no oscillation
        let dc = [Double](repeating: 1.0, count: TremorDetector.windowSize * 2)
        feedSamples(dc)
        XCTAssertTrue(detectedEvents.isEmpty, "DC offset should not trigger tremor detection")
    }

    func test_parkinsonTremorDetected_at5Hz() {
        // 5 Hz sine = center of Parkinson band (4–6 Hz)
        let signal = sineWave(frequency: 5.0, amplitude: 2.0)
        feedSamples(signal)

        XCTAssertFalse(detectedEvents.isEmpty, "5 Hz signal should trigger Parkinson tremor detection")
        guard let event = detectedEvents.first else { return }

        XCTAssertEqual(event.type, .parkinson)
        XCTAssertGreaterThan(event.score, 0.5, "Tremor score should be high for pure 5 Hz signal")
        XCTAssertEqual(event.dominantFrequency, 5.0, accuracy: 0.5,
                       "Dominant frequency should be near 5 Hz")
    }

    func test_essentialTremorDetected_at10Hz() {
        let signal = sineWave(frequency: 10.0, amplitude: 2.0)
        feedSamples(signal)

        XCTAssertFalse(detectedEvents.isEmpty, "10 Hz signal should trigger essential tremor detection")
        guard let event = detectedEvents.first else { return }

        XCTAssertEqual(event.type, .essential)
        XCTAssertGreaterThan(event.score, 0.5)
        XCTAssertEqual(event.dominantFrequency, 10.0, accuracy: 1.0)
    }

    func test_parkinsonVsEssentialDifferentiation() {
        // Pure 5 Hz → should classify as Parkinson, not essential
        let parkinsonSignal = sineWave(frequency: 5.0, amplitude: 3.0)
        feedSamples(parkinsonSignal)

        let parkinsonEvents = detectedEvents.filter { $0.type == .parkinson }
        let essentialEvents = detectedEvents.filter { $0.type == .essential }

        XCTAssertFalse(parkinsonEvents.isEmpty, "5 Hz should produce Parkinson events")
        XCTAssertTrue(essentialEvents.isEmpty, "5 Hz should not produce essential tremor events")
    }

    func test_noTremorFor15HzArtifact() {
        // 15 Hz = motion artifact zone, should not classify as either tremor type
        let signal = sineWave(frequency: 15.0, amplitude: 0.5)
        feedSamples(signal)

        let classified = detectedEvents.filter { $0.type != .none }
        XCTAssertTrue(classified.isEmpty,
                      "15 Hz motion artifact should not be classified as tremor")
    }

    func test_resetClearsState() {
        let signal = sineWave(frequency: 5.0, amplitude: 2.0)
        feedSamples(signal)
        XCTAssertFalse(detectedEvents.isEmpty)

        detector.reset()
        detectedEvents.removeAll()

        // Feed silence — should not fire after reset
        let silence = [Double](repeating: 0, count: TremorDetector.windowSize)
        feedSamples(silence)
        XCTAssertTrue(detectedEvents.isEmpty, "No events should fire after reset + silence")
        XCTAssertEqual(detector.lastScore, 0)
        XCTAssertEqual(detector.lastType, .none)
    }

    func test_tremorScoreRange() {
        // Score must always be in [0, 1]
        let signal = sineWave(frequency: 5.0, amplitude: 10.0)
        feedSamples(signal)

        for event in detectedEvents {
            XCTAssertGreaterThanOrEqual(event.score, 0.0, "Score must be >= 0")
            XCTAssertLessThanOrEqual(event.score, 1.0, "Score must be <= 1")
        }
    }

    func test_frequencyResolution() {
        // Verify the frequency resolution constant is correct
        let expected = TremorDetector.sampleRate / Double(TremorDetector.windowSize)
        XCTAssertEqual(TremorDetector.frequencyResolution, expected, accuracy: 0.001)
        // At 100 Hz / 256 samples ≈ 0.39 Hz/bin
        XCTAssertEqual(TremorDetector.frequencyResolution, 0.390625, accuracy: 0.001)
    }

    func test_bandPowerSumsCorrectBins() {
        // Indirectly test via a 4.5 Hz signal — should fall in Parkinson band
        let signal = sineWave(frequency: 4.5, amplitude: 2.0)
        feedSamples(signal)
        guard let event = detectedEvents.first else {
            XCTFail("Expected tremor event for 4.5 Hz signal")
            return
        }
        XCTAssertGreaterThan(event.parkinsonBandPower, event.essentialBandPower,
                             "4.5 Hz should have more power in Parkinson band than essential band")
    }

    func test_overlappingWindowsFireMultipleEvents() {
        // At 50% overlap and 4× window size, we expect at least 3 FFT windows
        let signal = sineWave(frequency: 5.0, amplitude: 2.0,
                              count: TremorDetector.windowSize * 4)
        feedSamples(signal)
        XCTAssertGreaterThanOrEqual(detectedEvents.count, 3,
                                    "Should fire multiple events with overlapping windows")
    }
}
