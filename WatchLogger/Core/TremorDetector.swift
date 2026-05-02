// TremorDetector.swift
// WatchLogger — Universal Apple Watch Sensor Logger
//
// Detects Parkinson's resting tremor (4–6 Hz) from raw accelerometer data
// using a sliding-window FFT via Apple's vDSP framework.
//
// Algorithm overview:
//   1. Collect 256 accelerometer samples at ~100 Hz (~2.56 s window)
//   2. Apply Hann window to reduce spectral leakage
//   3. Compute FFT magnitude spectrum via vDSP
//   4. Integrate power in the 4–6 Hz band (Parkinson tremor)
//   5. Normalize against total power to get a 0–1 tremor score
//   6. Emit TremorEvent if score exceeds configurable threshold
//
// Frequency bands:
//   4–6 Hz  → Parkinson resting tremor
//   8–12 Hz → Essential tremor (detected but differentiated)
//   >15 Hz  → Likely motion artifact, ignored
//
// References:
//   - Bhidayasiri R. (2005). "Differential Diagnosis of Common Tremor Syndromes"
//   - Mera TO et al. (2012). "Feasibility of home-based automated Parkinson's assessment"

import Foundation
import Accelerate  // vDSP FFT

// MARK: - TremorDetector

/// Thread-safe tremor detector. Feed accelerometer samples via `addSample(_:)`.
/// Subscribe to `onTremorDetected` for automatic detection callbacks.
public final class TremorDetector {

    // MARK: - Configuration

    /// Number of samples per FFT window. Must be a power of 2.
    /// 256 samples at 100 Hz = 2.56 second window.
    public static let windowSize = 256

    /// Accelerometer sample rate in Hz. Match CMMotionManager.accelerometerUpdateInterval.
    public static let sampleRate: Double = 100.0

    /// Frequency resolution: sampleRate / windowSize = 0.39 Hz per bin.
    public static var frequencyResolution: Double {
        sampleRate / Double(windowSize)
    }

    /// Frequency range defining Parkinson's resting tremor band.
    public static let parkinsonBand = (low: 4.0, high: 6.0)

    /// Frequency range for essential tremor (for differentiation).
    public static let essentialTremorBand = (low: 8.0, high: 12.0)

    // MARK: - State

    /// Ring buffer holding the last `windowSize` accelerometer magnitudes.
    private var buffer: [Float] = Array(repeating: 0, count: windowSize)
    private var writeIndex = 0
    private var samplesCollected = 0

    /// How often to run FFT. 0.5 = every 50% of a full window (128 samples overlap).
    private let overlapFactor = 0.5

    /// Samples since last FFT run.
    private var samplesSinceLastFFT = 0

    /// FFT setup object — expensive to create, reused across calls.
    private let fftSetup: vDSP.FFT<DSPSplitComplex>

    private let lock = NSLock()

    // MARK: - Output

    /// Called on the main queue when a tremor event is detected.
    public var onTremorDetected: ((TremorEvent) -> Void)?

    /// Latest computed tremor score (0–1). 0 = no tremor, 1 = maximum.
    public private(set) var lastScore: Double = 0

    /// Latest detected tremor type.
    public private(set) var lastType: TremorType = .none

    // MARK: - Init

    public init() {
        let log2n = vDSP_Length(log2(Float(Self.windowSize)))
        guard let setup = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
            fatalError("Failed to create vDSP FFT setup for n=\(Self.windowSize)")
        }
        fftSetup = setup
    }

    // MARK: - Public API

    /// Feed one accelerometer sample (vector magnitude of x/y/z).
    /// Call this from CMMotionManager's update handler at ~100 Hz.
    ///
    /// - Parameter magnitude: sqrt(x² + y² + z²) from CMAcceleration
    public func addSample(_ magnitude: Double) {
        lock.lock()
        defer { lock.unlock() }

        buffer[writeIndex % Self.windowSize] = Float(magnitude)
        writeIndex += 1
        samplesCollected += 1
        samplesSinceLastFFT += 1

        let stepSize = Int(Double(Self.windowSize) * overlapFactor)
        guard samplesCollected >= Self.windowSize,
              samplesSinceLastFFT >= stepSize else { return }

        samplesSinceLastFFT = 0

        // Extract samples in chronological order from ring buffer
        var window = [Float](repeating: 0, count: Self.windowSize)
        let start = writeIndex % Self.windowSize
        for i in 0..<Self.windowSize {
            window[i] = buffer[(start + i) % Self.windowSize]
        }

        let event = computeFFT(samples: window)
        if let event {
            DispatchQueue.main.async { [weak self] in
                self?.onTremorDetected?(event)
            }
        }
    }

    /// Reset the internal buffer (e.g. when the user starts a new session).
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        buffer = Array(repeating: 0, count: Self.windowSize)
        writeIndex = 0
        samplesCollected = 0
        samplesSinceLastFFT = 0
        lastScore = 0
        lastType = .none
    }

    // MARK: - FFT Computation

    /// Applies Hann window + vDSP FFT, returns a TremorEvent if score > 0.1.
    private func computeFFT(samples: [Float]) -> TremorEvent? {
        var windowed = applyHannWindow(samples)

        // vDSP FFT requires split complex input
        let halfN = Self.windowSize / 2
        var realParts = [Float](repeating: 0, count: halfN)
        var imagParts = [Float](repeating: 0, count: halfN)

        windowed.withUnsafeMutableBufferPointer { ptr in
            ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                realParts.withUnsafeMutableBufferPointer { rPtr in
                    imagParts.withUnsafeMutableBufferPointer { iPtr in
                        var splitComplex = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfN))
                    }
                }
            }
        }

        var magnitudes = [Float](repeating: 0, count: halfN)
        realParts.withUnsafeMutableBufferPointer { rPtr in
            imagParts.withUnsafeMutableBufferPointer { iPtr in
                var splitComplex = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                fftSetup.forward(input: splitComplex, output: &splitComplex)
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfN))
            }
        }

        // Scale magnitudes
        var scale = Float(1.0 / Float(Self.windowSize))
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(halfN))

        let parkinsonPower  = bandPower(magnitudes: magnitudes, low: Self.parkinsonBand.low,  high: Self.parkinsonBand.high)
        let essentialPower  = bandPower(magnitudes: magnitudes, low: Self.essentialTremorBand.low, high: Self.essentialTremorBand.high)
        let totalPower      = magnitudes.reduce(0, +)

        guard totalPower > 0 else { return nil }

        let parkinsonScore = Double(parkinsonPower / totalPower)
        let essentialScore = Double(essentialPower / totalPower)
        let dominantScore  = max(parkinsonScore, essentialScore)

        lastScore = dominantScore

        guard dominantScore > 0.1 else {
            lastType = .none
            return nil
        }

        let type: TremorType = parkinsonScore >= essentialScore ? .parkinson : .essential
        lastType = type

        return TremorEvent(
            score: dominantScore,
            type: type,
            parkinsonBandPower: parkinsonScore,
            essentialBandPower: essentialScore,
            dominantFrequency: dominantFrequency(magnitudes: magnitudes),
            timestamp: Date()
        )
    }

    // MARK: - DSP Helpers

    /// Multiplies samples by a Hann window to reduce spectral leakage.
    private func applyHannWindow(_ samples: [Float]) -> [Float] {
        var result = samples
        var window = [Float](repeating: 0, count: Self.windowSize)
        vDSP_hann_window(&window, vDSP_Length(Self.windowSize), Int32(vDSP_HANN_NORM))
        vDSP_vmul(samples, 1, window, 1, &result, 1, vDSP_Length(Self.windowSize))
        return result
    }

    /// Sums FFT magnitudes within a frequency band.
    private func bandPower(magnitudes: [Float], low: Double, high: Double) -> Float {
        let lowBin  = Int(low  / Self.frequencyResolution)
        let highBin = Int(high / Self.frequencyResolution)
        let clampedLow  = max(0, min(lowBin,  magnitudes.count - 1))
        let clampedHigh = max(0, min(highBin, magnitudes.count - 1))
        return magnitudes[clampedLow...clampedHigh].reduce(0, +)
    }

    /// Returns the frequency (Hz) of the bin with maximum magnitude.
    private func dominantFrequency(magnitudes: [Float]) -> Double {
        guard let maxIdx = magnitudes.indices.max(by: { magnitudes[$0] < magnitudes[$1] }) else { return 0 }
        return Double(maxIdx) * Self.frequencyResolution
    }
}

// MARK: - TremorEvent

/// Result of one FFT analysis window.
public struct TremorEvent {
    /// Normalized tremor score 0–1. Higher = stronger tremor signal.
    public let score: Double

    /// Whether this looks like Parkinson (4–6 Hz) or Essential (8–12 Hz) tremor.
    public let type: TremorType

    /// Fraction of total power in the 4–6 Hz Parkinson band.
    public let parkinsonBandPower: Double

    /// Fraction of total power in the 8–12 Hz essential tremor band.
    public let essentialBandPower: Double

    /// Frequency of the single strongest peak in the spectrum.
    public let dominantFrequency: Double

    /// When this window was analyzed.
    public let timestamp: Date
}

// MARK: - TremorType

public enum TremorType: String, Codable {
    case none
    /// 4–6 Hz resting tremor — characteristic of Parkinson's disease.
    case parkinson
    /// 8–12 Hz action/postural tremor — essential tremor or physiological.
    case essential
}
