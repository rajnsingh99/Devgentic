//
//  WhisperRecognitionService.swift
//  Devgentic
//
//  Created by Raj Singh on 23/07/25.
//

import Foundation
import AVFoundation
import WhisperKit
import os

// MARK: - Error Types

/// An error enum for the WhisperRecognitionService.
enum RecognitionError: Error {
    case modelNotLoaded
    case transcriptionFailed(Error)
    case modelSwitchFailed(String)
}

// MARK: - State Types

/// The different states of the model loading process.
enum ModelLoadingState: Equatable {
    case idle
    case downloading
    case preparing
    case loaded
    case error(String)
}

/// Streaming transcription state bridged from AudioStreamTranscriber to the UI layer.
struct StreamingTranscriptionState {
    let confirmedText: String
    let partialText: String
    let bufferEnergy: [Float]
    let isRecording: Bool
    let isSilenceDetected: Bool

    var fullText: String {
        // Join with a space separator if both parts have content to avoid
        // inconsistent spacing when switching between currentText and unconfirmedSegments
        let parts = [confirmedText, partialText].filter { !$0.isEmpty }
        let combined = parts.joined(separator: " ")
        // Collapse multiple whitespace runs into single spaces for stable display
        return combined
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Service

/// A service to manage audio transcription using WhisperKit with on-demand model downloading,
/// real-time streaming via AudioStreamTranscriber, multi-language support, and VAD auto-stop.
@MainActor
@Observable
class WhisperRecognitionService {

    // MARK: - Shared Singleton
    /// Single app-wide instance. Prevents WhisperKit model from being loaded
    /// multiple times when SwiftUI recreates ChatInputViewModel instances.
    static let shared: WhisperRecognitionService = {
        let savedModel = UserDefaults.standard.string(forKey: AppSettings.speechModelKey) ?? "base.en"
        let savedLanguage = UserDefaults.standard.string(forKey: AppSettings.speechLanguageKey)
        let savedAutoStop = (UserDefaults.standard.object(forKey: AppSettings.speechAutoStopOnSilenceKey) as? Bool) ?? true
        return WhisperRecognitionService(
            modelName: savedModel,
            language: savedLanguage,
            autoStop: savedAutoStop
        )
    }()

    // MARK: - Published State
    private(set) var loadingState: ModelLoadingState = .idle

    // MARK: - Private State
    private var whisperKit: WhisperKit?
    private var streamTranscriber: AudioStreamTranscriber?
    private var currentModelName: String
    private var _currentLanguage: String?
    private var _isAutoStopEnabled: Bool
    private var onStateChangeCallback: ((StreamingTranscriptionState) -> Void)?
    nonisolated(unsafe) private var notificationObservers: [Any] = []

    // Silence tracking for auto-stop
    private var consecutiveSilenceCount: Int = 0
    private let silenceThresholdForAutoStop: Int = 15 // ~1.5s at ~100ms callback intervals

    // Cache for final transcript assembly
    private var lastConfirmedText: String = ""
    private var lastPartialText: String = ""

    private let logger = DGLogger(category: "WhisperRecognitionService")

    // MARK: - Initialization

    /// Use `WhisperRecognitionService.shared` instead of creating new instances.
    /// Kept internal for test injection via `RecognitionServiceProtocol`.
    init(modelName: String = "base.en", language: String? = nil, autoStop: Bool = true) {
        self.currentModelName = modelName
        self._currentLanguage = language
        self._isAutoStopEnabled = autoStop

        setupSettingsObservers()

        // Only auto-load if the model is already downloaded (no surprise downloads)
        let downloadService = WhisperModelDownloadService.shared
        if downloadService.isModelDownloaded(modelName) {
            Task {
                await loadModel(named: modelName)
            }
        } else {
            logger.log("Model '\(modelName)' not downloaded — staying idle.")
            loadingState = .idle
        }
    }

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Settings Observers

    private func setupSettingsObservers() {
        let modelObs = NotificationCenter.default.addObserver(
            forName: GlobalConstants.speechModelChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let modelName = notification.object as? String else { return }
            Task { @MainActor [weak self] in
                do {
                    try await self?.switchModel(to: modelName)
                } catch {
                    self?.logger.error("Failed to switch speech model to '\(modelName)': \(error.localizedDescription)")
                }
            }
        }
        notificationObservers.append(modelObs)

        let langObs = NotificationCenter.default.addObserver(
            forName: GlobalConstants.speechLanguageChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let language = notification.object as? String else { return }
            Task { @MainActor [weak self] in
                self?.setLanguage(language.isEmpty ? nil : language)
            }
        }
        notificationObservers.append(langObs)

        let autoStopObs = NotificationCenter.default.addObserver(
            forName: GlobalConstants.speechAutoStopChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let enabled = notification.object as? Bool else { return }
            Task { @MainActor [weak self] in
                self?.setAutoStopEnabled(enabled)
            }
        }
        notificationObservers.append(autoStopObs)
    }

    // MARK: - Model Loading

    /// Asynchronously loads a WhisperKit model. Downloads on first run, cached thereafter.
    /// Uses a two-phase approach: download → prepare/prewarm, giving the UI finer-grained progress.
    private func loadModel(named modelName: String) async {
        // Tear down existing transcriber and model
        if streamTranscriber != nil {
            await streamTranscriber?.stopStreamTranscription()
            streamTranscriber = nil
        }
        whisperKit = nil

        do {
            logger.log("Starting model load for '\(modelName)'.")
            loadingState = .downloading

            // Phase 1: Download model files (or resolve from cache)
            logger.log("Initializing WhisperKit (download phase)...")
            whisperKit = try await WhisperKit(model: modelName, prewarm: false, load: false)

            // Phase 2: Prewarm and load into memory
            logger.log("Prewarming and loading model into memory...")
            loadingState = .preparing
            try await whisperKit?.prewarmModels()
            try await whisperKit?.loadModels()

            logger.log("WhisperKit initialized. Tokenizer present: \(self.whisperKit?.tokenizer != nil)")

            self.currentModelName = modelName
            loadingState = .loaded
            logger.log("Model '\(modelName)' loaded and prewarmed.")
        } catch {
            let msg = "Error loading model '\(modelName)': \(error.localizedDescription)"
            loadingState = .error(msg)
            logger.error("\(msg)")
        }
    }

    // MARK: - Streaming Transcription

    /// Starts real-time streaming transcription using AudioStreamTranscriber.
    /// This method blocks the calling task until `stopStreaming()` is called or VAD auto-stops.
    /// - Parameter onStateChange: Callback fired on each transcription state update (bridged to MainActor).
    func startStreaming(
        onStateChange: @escaping (StreamingTranscriptionState) -> Void
    ) async throws {
        guard let whisperKit = whisperKit, loadingState == .loaded else {
            logger.error("startStreaming: model not loaded (state: \(String(describing: self.loadingState)))")
            throw RecognitionError.modelNotLoaded
        }

        guard let tokenizer = whisperKit.tokenizer else {
            logger.error("startStreaming: tokenizer is nil after model loaded")
            throw RecognitionError.modelNotLoaded
        }

        logger.log("Configuring streaming transcription (model: \(self.currentModelName), lang: \(self._currentLanguage ?? "auto"))")

        self.onStateChangeCallback = onStateChange
        self.consecutiveSilenceCount = 0
        self.lastConfirmedText = ""
        self.lastPartialText = ""

        // Build DecodingOptions with language config
        var options = DecodingOptions()
        options.withoutTimestamps = true  // Prevent timestamp tokens in output
        let isEnglishOnly = currentModelName.hasSuffix(".en")
        if isEnglishOnly {
            options.language = "en"
            options.detectLanguage = false
            options.usePrefillPrompt = true
        } else if let lang = _currentLanguage, !lang.isEmpty {
            options.language = lang
            options.detectLanguage = false
            options.usePrefillPrompt = true
        } else {
            // Auto-detect: multilingual mode
            options.language = nil
            options.detectLanguage = true
            options.usePrefillPrompt = false
        }

        logger.log("Creating AudioStreamTranscriber...")
        let transcriber = AudioStreamTranscriber(
            audioEncoder: whisperKit.audioEncoder,
            featureExtractor: whisperKit.featureExtractor,
            segmentSeeker: whisperKit.segmentSeeker,
            textDecoder: whisperKit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: whisperKit.audioProcessor,
            decodingOptions: options,
            useVAD: true,
            stateChangeCallback: { [weak self] oldState, newState in
                Task { @MainActor [weak self] in
                    self?.handleStreamStateChange(oldState: oldState, newState: newState)
                }
            }
        )

        self.streamTranscriber = transcriber

        logger.log("Starting stream transcription (calling startStreamTranscription)...")
        // Blocks until stopStreamTranscription() is called
        try await transcriber.startStreamTranscription()
        logger.log("Stream transcription ended normally.")
    }

    /// Stops the active streaming transcription and returns the final combined text.
    func stopStreaming() async -> String? {
        guard let transcriber = streamTranscriber else {
            logger.warning("stopStreaming called but no active stream transcriber exists.")
            return nil
        }

        await transcriber.stopStreamTranscription()

        let finalText = buildFinalTranscript()

        self.streamTranscriber = nil
        self.onStateChangeCallback = nil
        self.consecutiveSilenceCount = 0

        return finalText
    }

    // MARK: - Stream State Bridging (MainActor)

    private func handleStreamStateChange(
        oldState: AudioStreamTranscriber.State,
        newState: AudioStreamTranscriber.State
    ) {
        // Build confirmed text from segments, stripping special tokens
        let confirmedText = stripSpecialTokens(
            newState.confirmedSegments.map { $0.text }.joined()
        )

        // Build partial text: currentText is the live decode of the same audio window
        // that unconfirmedSegments covers, so use whichever is more current (not both).
        // - During active decoding: currentText has the latest real-time progress
        // - After a decode cycle completes: currentText is cleared, use unconfirmedSegments
        let rawCurrentText = newState.currentText
        let isStatusMessage = rawCurrentText.hasPrefix("Waiting for")
        let partialText: String
        if !rawCurrentText.isEmpty && !isStatusMessage {
            partialText = stripSpecialTokens(rawCurrentText)
        } else {
            partialText = stripSpecialTokens(
                newState.unconfirmedSegments.map { $0.text }.joined()
            )
        }

        // Detect silence via low buffer energy
        let isSilent = detectSilence(energy: newState.bufferEnergy)

        // Track consecutive silence for auto-stop (only if there's confirmed text)
        if isSilent && _isAutoStopEnabled && !confirmedText.isEmpty {
            consecutiveSilenceCount += 1
            if consecutiveSilenceCount >= silenceThresholdForAutoStop {
                Task { await performAutoStop() }
                return
            }
        } else if !isSilent {
            consecutiveSilenceCount = 0
        }

        // Cache for final transcript
        self.lastConfirmedText = confirmedText
        self.lastPartialText = partialText

        let streamState = StreamingTranscriptionState(
            confirmedText: confirmedText,
            partialText: partialText,
            bufferEnergy: newState.bufferEnergy,
            isRecording: newState.isRecording,
            isSilenceDetected: isSilent
        )
        onStateChangeCallback?(streamState)
    }

    private func detectSilence(energy: [Float]) -> Bool {
        guard !energy.isEmpty else { return false }
        let recentEnergy = energy.suffix(10)
        let avgEnergy = recentEnergy.reduce(0, +) / Float(recentEnergy.count)
        return avgEnergy < 0.05
    }

    private func performAutoStop() async {
        let _ = await stopStreaming()
        // The ViewModel handles finalization when the streaming task completes
    }

    private func buildFinalTranscript() -> String {
        let combined = lastConfirmedText + lastPartialText
        return stripSpecialTokens(combined)
    }

    /// Strips WhisperKit special tokens (e.g. <|startoftranscript|>, <|en|>, <|0.00|>) from text.
    private func stripSpecialTokens(_ text: String) -> String {
        text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Model Teardown

    /// Tears down the currently-loaded model and returns to idle.
    /// Called by `WhisperModelDownloadService` before deleting model files on disk,
    /// so we don't hold stale references to deleted CoreML bundles.
    func unloadCurrentModel() async {
        if streamTranscriber != nil {
            let _ = await stopStreaming()
        }
        whisperKit = nil
        loadingState = .idle
        logger.log("Model '\(self.currentModelName)' unloaded.")
    }

    // MARK: - Model Switching

    /// Switches to a different Whisper model. Stops any active streaming first.
    /// Only loads if the model is already downloaded; otherwise stays idle.
    func switchModel(to modelName: String) async throws {
        guard modelName != currentModelName || loadingState == .idle else { return }
        logger.log("Switching model from '\(self.currentModelName)' to '\(modelName)'.")

        if streamTranscriber != nil {
            let _ = await stopStreaming()
        }

        // Only load if already downloaded — download lifecycle is managed by WhisperModelDownloadService
        guard WhisperModelDownloadService.shared.isModelDownloaded(modelName) else {
            logger.log("Model '\(modelName)' not downloaded — staying idle.")
            whisperKit = nil  // Release old model memory
            self.currentModelName = modelName
            loadingState = .idle
            return
        }

        await loadModel(named: modelName)
        if case .error(let msg) = loadingState {
            throw RecognitionError.modelSwitchFailed(msg)
        }
    }

    // MARK: - Language Config

    var currentLanguage: String? { _currentLanguage }

    func setLanguage(_ language: String?) {
        self._currentLanguage = language
        logger.log("Speech language set to: \(language ?? "auto-detect")")
    }

    // MARK: - VAD Auto-Stop Config

    var isAutoStopEnabled: Bool { _isAutoStopEnabled }

    func setAutoStopEnabled(_ enabled: Bool) {
        self._isAutoStopEnabled = enabled
        logger.log("Auto-stop on silence: \(enabled)")
    }

    // MARK: - Batch Transcription (Retained for backward compat)

    /// Transcribes a complete array of audio samples.
    /// - Parameter audioArray: An array of audio samples in 16kHz, 32-bit float format.
    /// - Returns: The full transcribed text as a single string.
    func transcribe(audioArray: [Float]) async throws -> String? {
        guard let whisperKit = whisperKit, loadingState == .loaded else {
            logger.error("transcribe called but model is not in a loaded state.")
            throw RecognitionError.modelNotLoaded
        }

        do {
            logger.log("Beginning batch transcription of \(audioArray.count) samples.")
            var options = DecodingOptions()
            if let lang = _currentLanguage, !lang.isEmpty {
                options.language = lang
            }
            let results: [TranscriptionResult] = try await whisperKit.transcribe(
                audioArray: audioArray, decodeOptions: options
            )
            let transcript = results.map { $0.text }.joined()
            logger.log("Batch transcription finished.")
            return transcript
        } catch {
            logger.error("Batch transcription failed: \(error.localizedDescription)")
            throw RecognitionError.transcriptionFailed(error)
        }
    }
}
