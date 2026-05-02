// HealthKitService.swift
// WatchLogger — Universal Apple Watch Sensor Logger
//
// Reads health metrics from HealthKit via HKObserverQuery (passive, background)
// and HKSampleQuery (on-demand). Updates @Observable properties consumed by views.
//
// Requires HealthKit capability in the Xcode target.
// Privacy keys needed in Info.plist:
//   NSHealthShareUsageDescription — "WatchLogger reads heart rate and HRV..."
//   NSHealthUpdateUsageDescription — "WatchLogger writes tremor events..."

import Foundation
import HealthKit
import Observation

// MARK: - HealthKitService

@Observable
public final class HealthKitService {

    // MARK: - Published State

    /// Most recent heart rate reading (bpm).
    public private(set) var heartRate: Double?

    /// Most recent HRV reading (SDNN, ms).
    public private(set) var hrv: Double?

    /// Most recent blood oxygen reading (%). nil on Series 5 and older.
    public private(set) var spo2: Double?

    /// Step count for today.
    public private(set) var stepCount: Int?

    /// True after requestAuthorization() succeeds.
    public private(set) var isAuthorized = false

    /// Error from the last HealthKit operation.
    public private(set) var lastError: String?

    // MARK: - HealthKit

    private let store = HKHealthStore()

    private let readTypes: Set<HKObjectType> = [
        HKObjectType.quantityType(forIdentifier: .heartRate)!,
        HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
        HKObjectType.quantityType(forIdentifier: .oxygenSaturation)!,
        HKObjectType.quantityType(forIdentifier: .stepCount)!,
    ]

    private let writeTypes: Set<HKSampleType> = [
        // Reserved for future tremor event HealthKit integration
    ]

    // MARK: - Authorization

    /// Request HealthKit read permissions. Call once at app launch.
    public func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            lastError = "HealthKit not available on this device"
            return
        }
        do {
            try await store.requestAuthorization(toShare: writeTypes, read: readTypes)
            isAuthorized = true
            startObservers()
        } catch {
            lastError = "HealthKit authorization failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Observers

    /// Starts background HKObserverQuery for each metric.
    /// The OS delivers updates even when the app is not in foreground.
    private func startObservers() {
        observeQuantity(.heartRate, unit: .count().unitDivided(by: .minute())) { [weak self] value in
            self?.heartRate = value
        }
        observeQuantity(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli)) { [weak self] value in
            self?.hrv = value * 1000  // Convert s to ms
        }
        observeQuantity(.oxygenSaturation, unit: .percent()) { [weak self] value in
            self?.spo2 = value * 100  // Convert 0–1 to percentage
        }
        observeStepCount()
    }

    private func observeQuantity(_ identifier: HKQuantityTypeIdentifier,
                                  unit: HKUnit,
                                  handler: @escaping (Double) -> Void) {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return }

        let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, _, error in
            if let error {
                self?.lastError = "Observer error (\(identifier.rawValue)): \(error.localizedDescription)"
                return
            }
            self?.fetchLatest(type: type, unit: unit, handler: handler)
        }
        store.execute(query)

        // Enable background delivery
        store.enableBackgroundDelivery(for: type, frequency: .immediate) { _, error in
            if let error { print("Background delivery error: \(error)") }
        }
    }

    private func observeStepCount() {
        guard let type = HKObjectType.quantityType(forIdentifier: .stepCount) else { return }
        let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, _, _ in
            self?.fetchTodaySteps()
        }
        store.execute(query)
    }

    // MARK: - Sample Fetchers

    /// Fetches the most recent sample for a quantity type.
    private func fetchLatest(type: HKQuantityType, unit: HKUnit,
                              handler: @escaping (Double) -> Void) {
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let query = HKSampleQuery(sampleType: type, predicate: nil,
                                  limit: 1, sortDescriptors: [sort]) { _, samples, _ in
            guard let sample = samples?.first as? HKQuantitySample else { return }
            let value = sample.quantity.doubleValue(for: unit)
            DispatchQueue.main.async { handler(value) }
        }
        store.execute(query)
    }

    /// Fetches cumulative step count since midnight today.
    private func fetchTodaySteps() {
        guard let type = HKObjectType.quantityType(forIdentifier: .stepCount) else { return }
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: Date())
        let query = HKStatisticsQuery(quantityType: type,
                                      quantitySamplePredicate: predicate,
                                      options: .cumulativeSum) { [weak self] _, result, _ in
            let steps = result?.sumQuantity()?.doubleValue(for: .count()) ?? 0
            DispatchQueue.main.async { self?.stepCount = Int(steps) }
        }
        store.execute(query)
    }

    // MARK: - Snapshot

    /// Returns the current sensor values as a SensorReading snapshot.
    public func currentReading(tremorScore: Double = 0, tremorType: TremorType = .none) -> SensorReading {
        SensorReading(
            heartRate: heartRate,
            hrv: hrv,
            spo2: spo2,
            stepCount: stepCount,
            tremorScore: tremorScore,
            tremorType: tremorType
        )
    }
}
