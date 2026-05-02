// SensorManager.swift
// WatchLogger — Universal Apple Watch Sensor Logger
//
// Orchestrates CoreMotion at 100 Hz and feeds samples into TremorDetector.
// Also manages the HKWorkoutSession needed for background sensor access on watchOS.
//
// CoreMotion on watchOS:
//   - CMMotionManager.accelerometerUpdateInterval = 0.01 (100 Hz)
//   - Data available only while app is in foreground OR during an active HKWorkoutSession
//   - For continuous background monitoring, start a workout session (requires HealthKit)

import Foundation
import CoreMotion
import HealthKit
import Observation

// MARK: - SensorManager

@Observable
public final class SensorManager {

    // MARK: - State

    /// Whether CoreMotion is currently active.
    public private(set) var isRunning = false

    /// Raw accelerometer magnitude from the last sample.
    public private(set) var lastMagnitude: Double = 0

    /// Current tremor score from TremorDetector (0–1).
    public var tremorScore: Double { detector.lastScore }

    /// Current tremor type classification.
    public var tremorType: TremorType { detector.lastType }

    /// Called when TremorDetector fires a detection event.
    /// Set by EventQueue to auto-enqueue detected tremors.
    public var onTremorDetected: ((TremorEvent) -> Void)? {
        didSet { detector.onTremorDetected = onTremorDetected }
    }

    // MARK: - Internal

    private let motion = CMMotionManager()
    private let detector = TremorDetector()
    private let operationQueue = OperationQueue()

    // Optional workout session for background CoreMotion access
    private var workoutSession: HKWorkoutSession?
    private let healthStore = HKHealthStore()

    // MARK: - Public API

    /// Starts accelerometer updates at 100 Hz.
    /// `useWorkoutSession`: set true to keep running in the background.
    public func start(useWorkoutSession: Bool = true) {
        guard !isRunning else { return }
        guard motion.isAccelerometerAvailable else {
            print("SensorManager: accelerometer not available on this device")
            return
        }

        motion.accelerometerUpdateInterval = 1.0 / 100.0  // 100 Hz

        if useWorkoutSession {
            startWorkoutSession()
        }

        motion.startAccelerometerUpdates(to: operationQueue) { [weak self] data, error in
            guard let data, error == nil else { return }
            let acc = data.acceleration
            let magnitude = (acc.x * acc.x + acc.y * acc.y + acc.z * acc.z).squareRoot()
            DispatchQueue.main.async { self?.lastMagnitude = magnitude }
            self?.detector.addSample(magnitude)
        }

        isRunning = true
    }

    /// Stops CoreMotion and the workout session.
    public func stop() {
        guard isRunning else { return }
        motion.stopAccelerometerUpdates()
        stopWorkoutSession()
        detector.reset()
        isRunning = false
        lastMagnitude = 0
    }

    // MARK: - HKWorkoutSession (background CoreMotion)

    /// Starts a workout session so CoreMotion continues in the background.
    /// The workout type is .other to avoid polluting the user's workout history.
    private func startWorkoutSession() {
        let config = HKWorkoutConfiguration()
        config.activityType = .other
        config.locationType = .unknown

        do {
            workoutSession = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            workoutSession?.startActivity(with: Date())
        } catch {
            // Non-fatal: CoreMotion will still work in the foreground
            print("SensorManager: Could not start workout session: \(error)")
        }
    }

    private func stopWorkoutSession() {
        workoutSession?.stopActivity(with: Date())
        workoutSession?.end()
        workoutSession = nil
    }
}
