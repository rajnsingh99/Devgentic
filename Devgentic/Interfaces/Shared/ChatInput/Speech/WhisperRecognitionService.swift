// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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
enum RecognitionError: Error, LocalizedError {
    case modelNotLoaded
    case transcriptionFailed(Error)
    case modelSwitchFailed(String)
    /// [V2] Another surface holds the single app-wide stream slot.
    case sessionBusy(activeOwner: VoiceSurface)
    /// [V1] The realtime stream ended with no stop on record — WhisperKit swallowed a
    /// mid-stream decode error. The service has already forced the engine closed.
    case streamEndedUnexpectedly

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return String(localized: "The speech model isn't loaded.")
        case .transcriptionFailed(let error):
            return String(localized: "Transcription failed: \(error.localizedDescription)")
        case .modelSwitchFailed(let message):
            return String(localized: "Couldn't switch speech models: \(message)")
        case .sessionBusy(let owner):
            return String(localized: "Voice input is already active in \(owner.displayName).")
        case .streamEndedUnexpectedly:
            return String(localized: "Voice input stopped unexpectedly. The microphone has been released — tap the mic to try again.")
        }
    }
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
        Self.joined(confirmed: confirmedText, partial: partialText)
    }

    /// Single source of truth for joining confirmed + partial text. The live display
    /// and the FINAL transcript must agree — [V7] the final path used raw concatenation
    /// ("there.How") while the user watched this space-joined version, so the text
    /// changed underneath them at stop.
    static func joined(confirmed: String, partial: String) -> String {
        // Join with a space separator if both parts have content to avoid
        // inconsistent spacing when switching between currentText and unconfirmedSegments
        let parts = [confirmed, partial].filter { !$0.isEmpty }
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

    /// Which surface currently holds the single app-wide stream slot, if any.
    ///
    /// The ledger is private so nothing outside can corrupt the slot bookkeeping, but "who has
    /// the microphone" is the single most useful diagnostic this subsystem has: when a surface is
    /// refused with `.sessionBusy` the user sees an error naming a panel they may have forgotten
    /// is open. Exposing the owner (never the session) lets a settings pane answer it directly.
    var activeVoiceOwner: VoiceSurface? { ledger.active?.owner }

    /// The Whisper model currently selected, for diagnostics.
    var activeModelName: String { currentModelName }

    // MARK: - Private State
    private var whisperKit: WhisperKit?
    private var streamTranscriber: AudioStreamTranscriber?
    /// [V1/V2/V6] Bookkeeping for the single app-wide stream slot — who holds it,
    /// whether a stop is on record, and which teardown is authoritative.
    private var ledger = VoiceSessionLedger()
    /// [Phase 4b] A BORROWED reference to the panel-scoped duplex engine — never owned here.
    ///
    /// ⚠️ Its lifetime is the PANEL session (`OrbDuplexAudio`), not the stream session. Tying
    /// it to the stream session meant rebuilding voice processing after every answer, seconds
    /// after AVSpeechSynthesizer released its audio unit, and it captured nothing. Do not add a
    /// `stopEngine` call anywhere in this file.
    private var orbDuplexProcessor: OrbAudioProcessor?
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

    /// Whether ANY energy sample arrived this session — "proof the engine is
    /// actually delivering audio" (Orb's phrase). Logged at finalize so a
    /// dead-mic session (`_StartIO error 35` class) is identifiable from the
    /// [VOICE] narrative alone, for every surface.
    private var sessionSawAudio = false

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
        // Tear down existing transcriber and model — through stopStreaming so the
        // session ledger stays truthful (a direct transcriber stop would leave a
        // phantom active session that rejects every future start as busy).
        if ledger.isBusy {
            logger.log("[VOICE] Model load requested while a session is active — stopping it first.")
            _ = await stopStreaming()
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
    /// - Parameters:
    ///   - owner: Which surface is claiming the single app-wide stream slot — named in
    ///     logs and in the `.sessionBusy` error another surface receives ([V2]).
    ///   - onStateChange: Callback fired on each transcription state update (bridged to MainActor).
    /// - Throws: `.sessionBusy` when another surface is recording; `.streamEndedUnexpectedly`
    ///   when the stream died mid-run on a swallowed WhisperKit error ([V1] — the engine
    ///   has been forced closed by then).
    func startStreaming(
        owner: VoiceSurface,
        onStateChange: @escaping (StreamingTranscriptionState) -> Void
    ) async throws {
        guard let whisperKit = whisperKit, loadingState == .loaded else {
            logger.error("[VOICE] startStreaming(\(owner.rawValue)): model not loaded (state: \(String(describing: self.loadingState)))")
            throw RecognitionError.modelNotLoaded
        }

        guard let tokenizer = whisperKit.tokenizer else {
            logger.error("[VOICE] startStreaming(\(owner.rawValue)): tokenizer is nil after model loaded")
            throw RecognitionError.modelNotLoaded
        }

        // [V2] Single-slot guard. Every surface-level guard is per-instance, so this is
        // the only place that can see a cross-surface collision (main composer recording
        // while QuickAccess or Orb starts). Overwriting the live session here is what
        // used to orphan a transcriber into a permanent decode loop.
        guard let session = ledger.begin(owner: owner) else {
            let holder = ledger.active?.owner ?? owner
            logger.error("[VOICE] START REJECTED for '\(owner.rawValue)' — slot held by '\(holder.rawValue)' (session \(self.ledger.active?.shortID ?? "?")). Surfaces must stop the active session first.")
            throw RecognitionError.sessionBusy(activeOwner: holder)
        }

        logger.log("[VOICE] Session \(session.shortID) START (owner: \(owner.rawValue), model: \(self.currentModelName), lang: \(self._currentLanguage ?? "auto"), autoStop: \(self._isAutoStopEnabled))")

        self.onStateChangeCallback = onStateChange
        self.consecutiveSilenceCount = 0
        self.lastConfirmedText = ""
        self.lastPartialText = ""
        self.sessionSawAudio = false

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

        // ⚠️ BORROWED, never built here. The engine is owned by `OrbDuplexAudio` for the whole
        // panel session: building one per stream session meant constructing voice processing
        // seconds after AVSpeechSynthesizer released its audio unit, and it captured nothing.
        // A cold engine yields nil, which falls through to WhisperKit's own below — that fallback
        // is why a duplex failure never fails a session, and it must stay.
        let duplexProcessor = OrbDuplexAudio.shared.borrow(for: owner)
        if duplexProcessor != nil {
            logger.log("[VOICE] Session \(session.shortID) using the panel-scoped Orb DUPLEX engine (echo cancellation active).")
        }
        orbDuplexProcessor = duplexProcessor

        logger.log("Creating AudioStreamTranscriber...")
        let transcriber = AudioStreamTranscriber(
            audioEncoder: whisperKit.audioEncoder,
            featureExtractor: whisperKit.featureExtractor,
            segmentSeeker: whisperKit.segmentSeeker,
            textDecoder: whisperKit.textDecoder,
            tokenizer: tokenizer,
            // [Phase 4a] Orb may supply its OWN engine with echo cancellation enabled, through
            // WhisperKit's public `AudioProcessing` seam — no fork. Everything else (composer,
            // QuickAccess) keeps WhisperKit's engine untouched, and Orb falls back to it the
            // moment the flag is off or the duplex engine refuses to start.
            audioProcessor: duplexProcessor ?? whisperKit.audioProcessor,
            decodingOptions: options,
            useVAD: true,
            stateChangeCallback: { [weak self] oldState, newState in
                Task { @MainActor [weak self] in
                    self?.handleStreamStateChange(oldState: oldState, newState: newState)
                }
            }
        )

        self.streamTranscriber = transcriber

        logger.log("[VOICE] Session \(session.shortID) opening audio engine (calling startStreamTranscription)...")
        do {
            // Blocks until stopStreamTranscription() is called
            try await transcriber.startStreamTranscription()
        } catch {
            // WhisperKit's realtimeLoop currently swallows errors instead of rethrowing,
            // but if a future version DOES throw, the engine must not stay open.
            logger.error("[VOICE] Session \(session.shortID) stream THREW: \(error.localizedDescription) — forcing engine teardown.")
            await transcriber.stopStreamTranscription()
            _ = finalizeSession(session, reason: "stream-threw")
            throw RecognitionError.transcriptionFailed(error)
        }

        // Post-return triage. Three ways the blocking call comes back:
        if Task.isCancelled {
            // Caller cancelled the owning task (QuickAccess stop(), main-composer
            // cancelRecording(), Orb stopListening()) — realtimeLoop breaks on the
            // swallowed CancellationError WITHOUT stopping the recorder. Every canceller
            // pairs the cancel with an explicit stopStreaming(), which performs the real
            // teardown; doing it here too would race that call's finalize.
            logger.log("[VOICE] Session \(session.shortID) returned via task cancellation — teardown deferred to the paired stopStreaming().")
            return
        }
        if ledger.isUnrequestedEnd(session.id) {
            // [V1] Nothing requested this end: WhisperKit's realtimeLoop caught a decode
            // error and broke with `state.isRecording` still true and the AVAudioEngine
            // tap still open — then returned as if the session ended cleanly. The UI
            // would show idle over a live microphone. Force the engine closed and
            // surface the failure instead of pretending success.
            logger.error("[VOICE] Session \(session.shortID) (owner: \(owner.rawValue)) ended WITHOUT a stop request — swallowed mid-stream decode failure (V1). Forcing engine teardown; surfacing error to the UI.")
            await transcriber.stopStreamTranscription()
            _ = finalizeSession(session, reason: "abnormal-end")
            throw RecognitionError.streamEndedUnexpectedly
        }
        logger.log("[VOICE] Session \(session.shortID) ended via requested stop.")
    }

    /// Stops the active streaming transcription and returns the final combined text.
    /// Safe to call from any surface and safe to double-call: teardown is keyed to the
    /// session that started it ([V6]), so a stop resuming after its await can't clobber
    /// state that no longer belongs to it.
    func stopStreaming() async -> String? {
        // Mark intent BEFORE any await ([V1]): the blocking startStreamTranscription()
        // return races this continuation on the MainActor, and only the pending-stop
        // record tells it this end was requested.
        guard let session = ledger.markStopRequested(), let transcriber = streamTranscriber else {
            logger.warning("[VOICE] stopStreaming: no active session — no-op.")
            return nil
        }
        logger.log("[VOICE] Session \(session.shortID) STOP requested (owner: \(session.owner.rawValue)).")

        await transcriber.stopStreamTranscription()

        return finalizeSession(session, reason: "stop-requested")
    }

    /// Single teardown point: ends ledger bookkeeping, builds the final transcript, and
    /// clears the stream references. Returns `nil` when this session was already
    /// finalized by a racing teardown ([V6] — the caller must not touch state then).
    private func finalizeSession(_ session: VoiceSessionLedger.Session, reason: String) -> String? {
        guard case .finalized = ledger.end(session.id) else {
            logger.log("[VOICE] Session \(session.shortID) teardown skipped — already finalized elsewhere (attempted reason: \(reason)) (V6 guard).")
            return nil
        }
        let finalText = buildFinalTranscript()
        self.streamTranscriber = nil
        self.onStateChangeCallback = nil
        // ⚠️⚠️ THE ENGINE IS BORROWED — DO NOT STOP IT HERE. Its lifetime is the PANEL session,
        // owned by `OrbDuplexAudio`; stopping it per stream session is exactly the bug this
        // phase fixed, because rebuilding voice processing after every answer never captures.
        // Only the reference is dropped. Release is the panel's job and is wired at each of its
        // teardown paths: panel close, system sleep/lock, Repair Audio, profile switch, duplex
        // toggled off, recognizer switched to Apple Speech, and app termination.
        // ⚠️ A live AVAudioEngine at process death still wedges coreaudiod into `_StartIO error
        // 35` — that hazard is now wider, not gone.
        orbDuplexProcessor = nil
        self.consecutiveSilenceCount = 0
        logger.log("[VOICE] Session \(session.shortID) FINALIZED (owner: \(session.owner.rawValue), reason: \(reason), transcript: \(finalText.count) chars, audio: \(sessionSawAudio ? "yes" : "NONE — engine likely failed to start")).")
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

        if !newState.bufferEnergy.isEmpty { sessionSawAudio = true }

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
        // [V7] Share the live display's join — raw concatenation produced "there.How"
        // while the overlay showed "there. How", so the text changed at stop.
        stripSpecialTokens(StreamingTranscriptionState.joined(
            confirmed: lastConfirmedText, partial: lastPartialText
        ))
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
        if ledger.isBusy {
            logger.log("[VOICE] Model unload requested while a session is active — stopping it first.")
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

        if ledger.isBusy {
            logger.log("[VOICE] Model switch requested while a session is active — stopping it first.")
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
