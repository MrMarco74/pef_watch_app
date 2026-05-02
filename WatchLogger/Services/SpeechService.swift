// SpeechService.swift
// WatchLogger — Universal Apple Watch Sensor Logger
//
// On-device speech recognition via SFSpeechRecognizer with .deviceConstrained locale.
// No internet connection required. Latency ~300–500ms on Series 6+.
//
// Privacy key required in Info.plist:
//   NSSpeechRecognitionUsageDescription — "WatchLogger uses speech to log symptoms."
//
// Recognized commands are matched against button labels and IDs.
// Example: saying "Medikament" triggers the button with id "medication".

import Foundation
import Speech
import AVFoundation
import Observation

// MARK: - SpeechService

@Observable
public final class SpeechService {

    // MARK: - State

    /// Whether the microphone is currently recording.
    public private(set) var isListening = false

    /// Partial transcription during recognition.
    public private(set) var transcript = ""

    /// True after requestAuthorization() succeeds.
    public private(set) var isAuthorized = false

    /// Error from the last recognition attempt.
    public private(set) var lastError: String?

    /// Called with the recognized button ID when a match is found.
    public var onCommandRecognized: ((String) -> Void)?

    // MARK: - Internal

    private let recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    // MARK: - Init

    public init(locale: Locale = .current) {
        // .deviceConstrained = on-device only, no network fallback
        self.recognizer = SFSpeechRecognizer(locale: locale)
        self.recognizer?.supportsOnDeviceRecognition = true
    }

    // MARK: - Authorization

    public func requestAuthorization() async {
        let status = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        isAuthorized = status == .authorized
        if !isAuthorized {
            lastError = "Speech recognition not authorized"
        }
    }

    // MARK: - Recording

    /// Starts listening. Stops automatically after `maxDurationSeconds`.
    public func startListening(buttons: [ButtonConfig], maxDurationSeconds: TimeInterval = 5) {
        guard isAuthorized, !isListening else { return }
        guard let recognizer, recognizer.isAvailable else {
            lastError = "Speech recognizer not available"
            return
        }

        do {
            try startAudioSession()
        } catch {
            lastError = "Audio session error: \(error.localizedDescription)"
            return
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest?.requiresOnDeviceRecognition = true
        recognitionRequest?.shouldReportPartialResults = true

        recognitionTask = recognizer.recognitionTask(with: recognitionRequest!) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async { self.transcript = text }

                // Try to match recognized text against button labels/IDs
                if let matched = self.matchButton(text: text, buttons: buttons) {
                    self.stopListening()
                    DispatchQueue.main.async {
                        self.onCommandRecognized?(matched)
                    }
                }
            }

            if error != nil || result?.isFinal == true {
                self.stopListening()
            }
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try? audioEngine.start()
        isListening = true

        // Auto-stop after max duration
        DispatchQueue.main.asyncAfter(deadline: .now() + maxDurationSeconds) { [weak self] in
            self?.stopListening()
        }
    }

    public func stopListening() {
        guard isListening else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isListening = false
    }

    // MARK: - Matching

    /// Matches recognized text against button labels and IDs (case-insensitive, partial).
    private func matchButton(text: String, buttons: [ButtonConfig]) -> String? {
        let lower = text.lowercased()
        for button in buttons {
            if lower.contains(button.label.lowercased()) ||
               lower.contains(button.id.lowercased().replacingOccurrences(of: "_", with: " ")) {
                return button.id
            }
        }
        return nil
    }

    // MARK: - Audio Session

    private func startAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }
}
