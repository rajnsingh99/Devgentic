//
//  ChatInputViewModel.swift
//  Devgentic
//
//  Created by Raj Singh on 21/07/25.
//

import SwiftUI
import AVFoundation
import os
import WhisperKit
import AppKit

// MARK: - Main ViewModel Delegate Protocol
// Decouples ChatInputViewModel from MainApplicationViewModel so the chat input
// subsystem can be tested in isolation and the view doesn't observe two VMs.

@MainActor
protocol ChatInputMainDelegate: AnyObject {
    var attachedFiles: [FileSystemItem] { get }
    var streamingMessageID: UUID? { get }

    func addAttachedFile(fileItem: FileSystemItem)
    func addAttachedFiles(fileItems: [FileSystemItem])
    func removeAttachedFile(fileItem: FileSystemItem)
    func cancelStreamingResponse()
    func getQueryFromHistory(direction: MainApplicationViewModel.QueryNavigationDirection) -> String?
    func resetQueryHistoryIndex()
}

// MARK: - Protocols for Dependency Injection

protocol RecognitionServiceProtocol {
    var loadingState: ModelLoadingState { get }

    // Batch transcription (retained)
    func transcribe(audioArray: [Float]) async throws -> String?

    // Streaming transcription
    func startStreaming(onStateChange: @escaping (StreamingTranscriptionState) -> Void) async throws
    func stopStreaming() async -> String?

    // Model management
    func switchModel(to modelName: String) async throws

    // Language configuration
    var currentLanguage: String? { get }
    func setLanguage(_ language: String?)

    // VAD configuration
    var isAutoStopEnabled: Bool { get }
    func setAutoStopEnabled(_ enabled: Bool)
}

protocol WebSearchServiceProtocol {
    func validate(apiKey: String) async -> (isValid: Bool, message: String)
}

protocol PromptServiceProtocol {
    func getAllPrompts() -> [DevPrompt]
}

// MARK: - Service Conformance Extensions

extension WhisperRecognitionService: RecognitionServiceProtocol {}

extension WebSearchService: WebSearchServiceProtocol {}
extension PromptService: PromptServiceProtocol {}

// MARK: - State Structures

struct PromptSuggestionState {
    var isShowing: Bool = false
    var query: String = ""
    var filteredItems: [DevPrompt] = []
    var triggerRange: NSRange? = nil
    var selectedID: DevPrompt.ID? = nil
}

struct FileSuggestionState {
    var isShowing: Bool = false
    var query: String = ""
    var filteredItems: [FileSystemItem] = []
    var triggerRange: NSRange? = nil
    var selectedID: FileSystemItem.ID? = nil
    var multiSelectedIDs: Set<FileSystemItem.ID> = []
}

enum ValidationState {
    case idle
    case validating
    case valid
    case invalid(String)
}

// MARK: - Isolated Recording Display Store
// Separated from ChatInputViewModel so high-frequency updates (power levels every ~100ms,
// recording time every 1s) don't fire ChatInputViewModel.objectWillChange and cause
// ChatInputAreaView to re-evaluate its entire body.
@Observable @MainActor
final class RecordingDisplayStore {
    var powerLevels: [Float] = []
    var recordingTime: TimeInterval = 0.0
    var liveTranscriptionText: String = ""
}

@Observable @MainActor
final class ChatInputViewModel {

    // MARK: - Properties
    var userInput: String = ""
    var voiceInputState: VoiceInputState = .idle
    var showModelSelectorPopover: Bool = false
    var pendingDownloadModelId: String?
    var pendingDeleteModelId: String?

    /// Unified alert type to prevent download and delete alerts from clashing (#15).
    enum WhisperAlertKind { case download, delete }
    var activeWhisperAlert: WhisperAlertKind?
    var showWhisperAlert: Bool = false
    var showAPIKeyInputPopup: Bool = false
    var apiKeyInput: String = ""
    var validationState: ValidationState = .idle

    // MARK: - Recording Display
    let recordingDisplay = RecordingDisplayStore()

    // MARK: - Suggestions
    var promptSuggestionState = PromptSuggestionState()
    var fileSuggestionState = FileSuggestionState()
    var attributedTextInsertionRequest: CustomTextEditor.AttributedTextInsertionAction? = nil

    // MARK: - Delegates
    @ObservationIgnored weak var mainDelegate: (any ChatInputMainDelegate)?
    @ObservationIgnored var onFileSearchRequest: ((String) -> (candidates: [FileSystemItem], attached: [FileSystemItem]))?

    // MARK: - Mediated Main ViewModel Access
    // These mirror mainDelegate state so SwiftUI re-renders when they change.
    // Updated via setupMainDelegateObservers().

    private(set) var attachedFiles: [FileSystemItem] = []
    private(set) var isStreaming: Bool = false

    func addAttachedFile(fileItem: FileSystemItem) { mainDelegate?.addAttachedFile(fileItem: fileItem) }
    func addAttachedFiles(fileItems: [FileSystemItem]) { mainDelegate?.addAttachedFiles(fileItems: fileItems) }
    func removeAttachedFile(fileItem: FileSystemItem) { mainDelegate?.removeAttachedFile(fileItem: fileItem) }
    func cancelStreamingResponse() { mainDelegate?.cancelStreamingResponse() }
    func getQueryFromHistory(direction: MainApplicationViewModel.QueryNavigationDirection) -> String? { mainDelegate?.getQueryFromHistory(direction: direction) }
    func resetQueryHistoryIndex() { mainDelegate?.resetQueryHistoryIndex() }

    // MARK: - Services
    @ObservationIgnored private var recognitionService: RecognitionServiceProtocol?
    @ObservationIgnored private let webSearchService: WebSearchServiceProtocol
    @ObservationIgnored private let promptService: PromptServiceProtocol

    // MARK: - Private State
    @ObservationIgnored private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ChatInputViewModel")
    @ObservationIgnored private var recordingTimer: Timer?
    @ObservationIgnored private let maxPowerLevelsToShow = 100

    // MARK: - Streaming Task Handle
    @ObservationIgnored private var streamingTask: Task<Void, Never>?
    @ObservationIgnored private var silenceUICounter: Int = 0
    @ObservationIgnored private let silenceUIThreshold: Int = 10

    // MARK: - Keyboard Shortcut Observer
    @ObservationIgnored private var notificationObserver: Any?

    // MARK: - Async Task Handles
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var fileSearchTask: Task<Void, Never>?

    // MARK: - Initialization
    init(
        recognitionService: RecognitionServiceProtocol? = nil,
        webSearchService: WebSearchServiceProtocol = WebSearchService(),
        promptService: PromptServiceProtocol = PromptService.shared
    ) {
        logger.info("ChatInputViewModel initialized.")

        self.webSearchService = webSearchService
        self.promptService = promptService

        if let injectedService = recognitionService {
            self.recognitionService = injectedService
        } else {
            // Use the shared singleton — avoids loading WhisperKit model on every
            // ChatInputViewModel recreation caused by SwiftUI view lifecycle.
            self.recognitionService = WhisperRecognitionService.shared
        }

        setupSuggestionPipelines()
        setupKeyboardShortcutObserver()

        Task {
            await checkMicPermissions()
            observeRecognitionLoadingState()
        }
    }

    /// Call once after setting `mainDelegate` to mirror its observed state and
    /// refresh file suggestions on changes.
    func setupMainDelegateObservers() {
        guard let delegate = mainDelegate else {
            logger.warning("setupMainDelegateObservers called but mainDelegate is nil — attached files and streaming state will not update.")
            return
        }

        // Mirror attached files via withObservationTracking
        func observeFiles() {
            withObservationTracking {
                _ = delegate.attachedFiles
            } onChange: {
                Task { @MainActor [weak self] in
                    guard let self, let delegate = self.mainDelegate else { return }
                    self.attachedFiles = delegate.attachedFiles
                    if self.fileSuggestionState.isShowing {
                        self.performFileSearch(query: self.fileSuggestionState.query)
                    }
                    observeFiles()
                }
            }
        }
        observeFiles()
        self.attachedFiles = delegate.attachedFiles

        // Mirror streaming state
        func observeStreaming() {
            withObservationTracking {
                _ = delegate.streamingMessageID
            } onChange: {
                Task { @MainActor [weak self] in
                    guard let self, let delegate = self.mainDelegate else { return }
                    self.isStreaming = delegate.streamingMessageID != nil
                    observeStreaming()
                }
            }
        }
        observeStreaming()
        self.isStreaming = delegate.streamingMessageID != nil
    }

    deinit {
        if streamingTask != nil { logger.info("Cancelling active streaming task during deinit.") }
        if searchTask != nil { logger.debug("Cancelling active search task during deinit.") }
        if fileSearchTask != nil { logger.debug("Cancelling active file search task during deinit.") }
        logger.info("ChatInputViewModel deinitialized.")
        recordingTimer?.invalidate()
        streamingTask?.cancel()
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        searchTask?.cancel()
        fileSearchTask?.cancel()
    }

    // MARK: - Keyboard Shortcut Observer

    private func setupKeyboardShortcutObserver() {
        notificationObserver = NotificationCenter.default.addObserver(
            forName: GlobalConstants.toggleVoiceInputNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.toggleVoiceInput()
            }
        }
    }

    // MARK: - Suggestion Pipelines (Debounced)

    @ObservationIgnored private var promptDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var fileDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var lastPromptQuery: String = ""
    @ObservationIgnored private var lastFileQuery: String = ""

    private func setupSuggestionPipelines() {
        func observePromptQuery() {
            withObservationTracking {
                _ = self.promptSuggestionState.query
            } onChange: {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let newQuery = self.promptSuggestionState.query
                    if newQuery != self.lastPromptQuery {
                        self.lastPromptQuery = newQuery
                        self.promptDebounceTask?.cancel()
                        self.promptDebounceTask = Task {
                            try? await Task.sleep(nanoseconds: 150_000_000)
                            guard !Task.isCancelled else { return }
                            self.performAsyncPromptFilter(query: newQuery)
                        }
                    }
                    observePromptQuery()
                }
            }
        }
        observePromptQuery()

        func observeFileQuery() {
            withObservationTracking {
                _ = self.fileSuggestionState.query
            } onChange: {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let newQuery = self.fileSuggestionState.query
                    if newQuery != self.lastFileQuery {
                        self.lastFileQuery = newQuery
                        self.fileDebounceTask?.cancel()
                        self.fileDebounceTask = Task {
                            try? await Task.sleep(nanoseconds: 150_000_000)
                            guard !Task.isCancelled else { return }
                            self.performFileSearch(query: newQuery)
                        }
                    }
                    observeFileQuery()
                }
            }
        }
        observeFileQuery()
    }

    private func performAsyncPromptFilter(query: String) {
        searchTask?.cancel()
        let service = self.promptService

        searchTask = Task.detached(priority: .userInitiated) {
            if Task.isCancelled { return }

            let allPrompts = service.getAllPrompts()
            let filtered = allPrompts.filter {
                query.isEmpty || $0.title.lowercased().contains(query.lowercased())
            }

            if Task.isCancelled { return }

            await MainActor.run { [weak self] in
                self?.promptSuggestionState.filteredItems = filtered
                self?.ensurePromptSelection()
            }
        }
    }

    private func performFileSearch(query: String) {
        guard let context = onFileSearchRequest?(query) else {
            logger.warning("File search skipped: onFileSearchRequest callback is nil (delegate not wired?).")
            return
        }
        processFileCandidates(context.candidates, attachedFiles: context.attached)
    }

    /// Called by the view when ExplorerViewModel changes while file suggestions are showing.
    func refreshFileSuggestions(using explorer: ExplorerViewModel) {
        let candidates = explorer.suggestableFiles(query: fileSuggestionState.query)
        processFileCandidates(candidates, attachedFiles: attachedFiles)
    }

    func processFileCandidates(_ candidates: [FileSystemItem], attachedFiles: [FileSystemItem]) {
        fileSearchTask?.cancel()

        fileSearchTask = Task.detached(priority: .userInitiated) {
            if Task.isCancelled { return }

            let attachedIDs = Set(attachedFiles.map { $0.id })
            let filtered = candidates.filter { !attachedIDs.contains($0.id) }

            if Task.isCancelled { return }

            await MainActor.run { [weak self] in
                self?.fileSuggestionState.filteredItems = filtered
                self?.ensureFileSelection()
            }
        }
    }

    // MARK: - Selection Helpers

    private func ensurePromptSelection() {
        if promptSuggestionState.selectedID == nil ||
            !promptSuggestionState.filteredItems.contains(where: { $0.id == promptSuggestionState.selectedID }) {
            promptSuggestionState.selectedID = promptSuggestionState.filteredItems.first?.id
        }
    }

    private func ensureFileSelection() {
        if fileSuggestionState.selectedID == nil ||
            !fileSuggestionState.filteredItems.contains(where: { $0.id == fileSuggestionState.selectedID }) {
            fileSuggestionState.selectedID = fileSuggestionState.filteredItems.first?.id
        }
    }

    // MARK: - Actions (View Triggers)

    func selectPrompt(_ prompt: DevPrompt) {
        guard let range = promptSuggestionState.triggerRange else { return }
        logger.log("Prompt selected: '\(prompt.title)'")

        let insertionText = NSAttributedString(string: prompt.text + " ", attributes: defaultTypingAttributes)
        self.attributedTextInsertionRequest = .init(range: range, attributedString: insertionText)

        resetPromptState()
    }

    func selectFile(_ file: FileSystemItem) -> FileSystemItem {
        if let range = fileSuggestionState.triggerRange {
            let insertionText = NSAttributedString(string: "", attributes: defaultTypingAttributes)
            self.attributedTextInsertionRequest = .init(range: range, attributedString: insertionText)
        }
        resetFileState()
        return file
    }

    func selectMultipleFiles(_ files: [FileSystemItem]) {
        if let range = fileSuggestionState.triggerRange {
            let insertionText = NSAttributedString(string: "", attributes: defaultTypingAttributes)
            self.attributedTextInsertionRequest = .init(range: range, attributedString: insertionText)
        }
        resetFileState()
    }

    func navigateSuggestions(direction: SuggestionNavigationDirection, type: TextTriggerAnalyzer.TriggerType) {
        switch type {
        case .prompt:
            navigateGeneric(
                items: promptSuggestionState.filteredItems,
                selectedID: &promptSuggestionState.selectedID,
                direction: direction
            )
        case .file:
            navigateGeneric(
                items: fileSuggestionState.filteredItems,
                selectedID: &fileSuggestionState.selectedID,
                direction: direction
            )
        }
    }

    private func navigateGeneric<T: Identifiable>(items: [T], selectedID: inout T.ID?, direction: SuggestionNavigationDirection) {
        guard !items.isEmpty else { return }

        guard let currentId = selectedID,
              let currentIndex = items.firstIndex(where: { $0.id == currentId }) else {
            selectedID = items.first?.id
            return
        }

        var nextIndex: Int
        switch direction {
        case .up: nextIndex = currentIndex - 1 < 0 ? items.count - 1 : currentIndex - 1
        case .down: nextIndex = currentIndex + 1 >= items.count ? 0 : currentIndex + 1
        }
        selectedID = items[nextIndex].id
    }

    private func resetPromptState() {
        promptSuggestionState.isShowing = false
        promptSuggestionState.query = ""
        promptSuggestionState.triggerRange = nil
        promptSuggestionState.filteredItems = []
        searchTask?.cancel()
    }

    private func resetFileState() {
        fileSuggestionState.isShowing = false
        fileSuggestionState.query = ""
        fileSuggestionState.triggerRange = nil
        fileSuggestionState.filteredItems = []
        fileSuggestionState.multiSelectedIDs = []
        fileSearchTask?.cancel()
    }

    // MARK: - Typography Helpers
    private var defaultTypingAttributes: [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        return [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]
    }

    // MARK: - Voice Input Control

    /// The currently-saved speech model name for display in the selector popover.
    var currentSpeechModelName: String {
        UserDefaults.standard.string(forKey: AppSettings.speechModelKey) ?? "base.en"
    }

    func toggleVoiceInput() {
        if voiceInputState == .recording {
            stopStreamingAndFinalize()
        } else if voiceInputState == .available {
            Task { await startStreaming() }
        } else if voiceInputState == .idle || voiceInputState.isErrorState {
            // Model not loaded or failed — show selection popover
            showModelSelectorPopover = true
        }
    }

    /// Called from the model selector popover when the user picks an already-downloaded model.
    func selectDownloadedModel(_ modelName: String) {
        showModelSelectorPopover = false

        // Persist the selection
        UserDefaults.standard.set(modelName, forKey: AppSettings.speechModelKey)

        // Notify WhisperRecognitionService to switch/load the model.
        NotificationCenter.default.post(
            name: GlobalConstants.speechModelChangedNotification,
            object: modelName
        )
    }

    /// Called from the model selector popover when the user picks an undownloaded model.
    /// Dismisses the popover first, then shows the alert on the next run-loop tick (#8).
    func requestDownloadConfirmation(for modelName: String) {
        pendingDownloadModelId = modelName
        showModelSelectorPopover = false
        // Defer alert presentation so the popover dismissal animation completes first
        Task { @MainActor in
            activeWhisperAlert = .download
            showWhisperAlert = true
        }
    }

    /// Called when the user confirms the download in the alert dialog.
    func confirmWhisperAlert() {
        switch activeWhisperAlert {
        case .download:
            guard let modelId = pendingDownloadModelId else { return }
            pendingDownloadModelId = nil
            WhisperModelDownloadService.shared.downloadModel(modelId)
        case .delete:
            guard let modelId = pendingDeleteModelId else { return }
            pendingDeleteModelId = nil
            Task {
                let fallback = await WhisperModelDownloadService.shared.deleteModel(modelId)
                if let fallback {
                    selectDownloadedModel(fallback)
                } else {
                    // Fix #6: No models remain — notify service so it goes idle.
                    // Don't pretend base.en is selected; just tell the service
                    // the current model is gone.
                    voiceInputState = .idle
                    NotificationCenter.default.post(
                        name: GlobalConstants.speechModelChangedNotification,
                        object: UserDefaults.standard.string(forKey: AppSettings.speechModelKey) ?? "base.en"
                    )
                }
            }
        case .none:
            break
        }
        activeWhisperAlert = nil
    }

    /// Called when the user cancels the alert dialog.
    func cancelWhisperAlert() {
        pendingDownloadModelId = nil
        pendingDeleteModelId = nil
        activeWhisperAlert = nil
    }

    /// Called from the popover when the user taps the trash icon on a downloaded model.
    /// Dismisses the popover first, then shows the alert on the next run-loop tick (#8).
    func requestDeleteConfirmation(for modelName: String) {
        pendingDeleteModelId = modelName
        showModelSelectorPopover = false
        Task { @MainActor in
            activeWhisperAlert = .delete
            showWhisperAlert = true
        }
    }

    func cancelRecording() {
        logger.log("Cancelling streaming recording.")
        streamingTask?.cancel()
        streamingTask = nil

        Task {
            let _ = await recognitionService?.stopStreaming()
        }

        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingDisplay.liveTranscriptionText = ""
        recordingDisplay.powerLevels = []
        recordingDisplay.recordingTime = 0.0
        userInput = ""
        voiceInputState = .available
    }

    // MARK: - State Management (Internal)

    /// Observes the recognition service's loadingState using @Observable tracking,
    /// replacing the previous Combine publisher bridge.
    private func observeRecognitionLoadingState() {
        guard let service = recognitionService as? WhisperRecognitionService else { return }
        withObservationTracking {
            _ = service.loadingState
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let service = self.recognitionService as? WhisperRecognitionService else { return }
                self.handleModelLoadingState(service.loadingState)
                self.observeRecognitionLoadingState()
            }
        }
        // Handle initial state
        handleModelLoadingState(service.loadingState)
    }

    private func handleModelLoadingState(_ state: ModelLoadingState) {
        switch state {
        case .idle: self.voiceInputState = .idle
        case .downloading: self.voiceInputState = .modelLoading
        case .preparing: self.voiceInputState = .modelPreparing
        case .loaded:
            if voiceInputState != .recording && voiceInputState != .processing {
                self.voiceInputState = .available
            }
        case .error(let message): self.voiceInputState = .error(message)
        }
    }

    private func checkMicPermissions() async {
        self.voiceInputState = .requestingPermissions
        logger.info("Requesting microphone permission...")
        let granted = await AVAudioApplication.requestRecordPermission()
        if !granted {
            logger.warning("Microphone permission denied by user.")
            self.voiceInputState = .permissionsDeniedMic
        } else {
            logger.info("Microphone permission granted.")
            // Restore state based on model loading — don't leave it stuck
            // on .requestingPermissions, which disables the mic button.
            if let service = recognitionService as? WhisperRecognitionService {
                handleModelLoadingState(service.loadingState)
            } else {
                self.voiceInputState = .idle
            }
        }
    }

    // MARK: - Streaming Transcription Lifecycle

    private func startStreaming() async {
        logger.log("Starting streaming transcription...")
        guard recognitionService?.loadingState == .loaded else {
            logger.error("Cannot start streaming: model not ready (state: \(String(describing: self.recognitionService?.loadingState)))")
            self.voiceInputState = .error("Model not ready.")
            return
        }

        // Pre-flight mic permission check using AVAudioApplication (consistent API)
        let micGranted = await AVAudioApplication.requestRecordPermission()
        guard micGranted else {
            logger.error("Cannot start streaming: microphone permission not granted")
            self.voiceInputState = .permissionsDeniedMic
            return
        }
        logger.log("Microphone permission confirmed, proceeding with streaming.")

        self.voiceInputState = .recording
        self.silenceUICounter = 0
        self.userInput = ""
        self.recordingDisplay.liveTranscriptionText = ""
        self.recordingDisplay.powerLevels = Array(repeating: 0.0, count: maxPowerLevelsToShow)
        self.recordingDisplay.recordingTime = 0.0

        // Start timer (1s interval — display only shows whole seconds)
        self.recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.recordingDisplay.recordingTime += 1.0
        }

        // Launch streaming in a separate task (startStreaming blocks until stopped)
        streamingTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.recognitionService?.startStreaming { [weak self] streamState in
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        self.handleStreamingUpdate(streamState)
                    }
                }
                // Streaming ended (either via manual stop or auto-stop from VAD)
                await MainActor.run { [weak self] in
                    self?.finalizeAfterStreamEnd()
                }
            } catch {
                self.logger.error("Streaming transcription error: \(error)")
                await MainActor.run { [weak self] in
                    self?.voiceInputState = .error("Streaming failed: \(error.localizedDescription)")
                    self?.recordingTimer?.invalidate()
                    self?.recordingTimer = nil
                }
            }
        }
    }

    private func handleStreamingUpdate(_ state: StreamingTranscriptionState) {
        // Only update live text when it actually changes to avoid unnecessary re-renders
        let newText = state.fullText
        if newText != recordingDisplay.liveTranscriptionText {
            recordingDisplay.liveTranscriptionText = newText
        }

        // Map buffer energy to power levels (writes to isolated store, not ViewModel).
        // Pad to fixed count so ForEach bar count stays constant, preventing layout shifts.
        let energySlice = Array(state.bufferEnergy.suffix(maxPowerLevelsToShow))
        if !energySlice.isEmpty {
            if energySlice.count < maxPowerLevelsToShow {
                let padding = Array(repeating: Float(0), count: maxPowerLevelsToShow - energySlice.count)
                recordingDisplay.powerLevels = padding + energySlice
            } else {
                recordingDisplay.powerLevels = energySlice
            }
        }

        // Hysteresis for .finalizingSilence state — only toggle voiceInputState after
        // sustained silence to prevent rapid .recording↔.finalizingSilence flipping
        // that fires objectWillChange and causes parent view re-renders.
        if state.isSilenceDetected && (recognitionService?.isAutoStopEnabled ?? false) {
            silenceUICounter += 1
            if silenceUICounter >= silenceUIThreshold && voiceInputState == .recording {
                self.voiceInputState = .finalizingSilence
            }
        } else {
            if silenceUICounter > 0 {
                silenceUICounter = 0
                if voiceInputState == .finalizingSilence {
                    self.voiceInputState = .recording
                }
            }
        }
    }

    private func stopStreamingAndFinalize() {
        logger.log("Stopping streaming, finalizing transcription...")
        self.voiceInputState = .processing
        recordingTimer?.invalidate()
        recordingTimer = nil

        Task {
            if let transcript = await recognitionService?.stopStreaming() {
                self.userInput = transcript
            }
            self.recordingDisplay.liveTranscriptionText = ""
            self.recordingDisplay.powerLevels = []
            self.voiceInputState = .available
        }
    }

    private func finalizeAfterStreamEnd() {
        // Called when streaming ends naturally (e.g., auto-stop from VAD)
        recordingTimer?.invalidate()
        recordingTimer = nil

        let liveText = recordingDisplay.liveTranscriptionText
        if !liveText.isEmpty {
            self.userInput = liveText
        }
        self.recordingDisplay.liveTranscriptionText = ""
        self.recordingDisplay.powerLevels = []
        self.voiceInputState = .available
    }

    // MARK: - API Key Validation
    func validateEnteredAPIKey() async {
        guard !apiKeyInput.isEmpty else { return }
        self.validationState = .validating
        let (isValid, message) = await webSearchService.validate(apiKey: self.apiKeyInput)
        if isValid { self.validationState = .valid }
        else { self.validationState = .invalid(message) }
    }

    func resetAPIKeyPopupState() {
        apiKeyInput = ""
        validationState = .idle
        showAPIKeyInputPopup = false
    }
}
