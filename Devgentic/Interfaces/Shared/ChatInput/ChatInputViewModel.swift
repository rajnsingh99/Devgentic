// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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
    func startStreaming(owner: VoiceSurface, onStateChange: @escaping (StreamingTranscriptionState) -> Void) async throws
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
    /// Records that a prompt was inserted into chat input. Drives the
    /// "Recently Used" sort in the sidebar.
    func recordUsage(of prompt: DevPrompt)
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

    /// Set to `true` to request that the chat input's `TextEditor` grab
    /// keyboard focus on next render. `ChatInputAreaView` observes this via
    /// `.onChange` and flips its `@FocusState`, then the VM resets the flag.
    /// Used by external callers (prompt library's "Use in Chat") so the user
    /// doesn't have to manually click the input after navigation.
    var pendingInputFocusRequest: Bool = false

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
    @ObservationIgnored private let logger = DGLogger(category: "ChatInputViewModel")
    @ObservationIgnored private var recordingTimer: Timer?
    /// [Dead-mic] Pure detection core (ported from Jarvis): a session that ran ≥1s
    /// with zero energy samples = the engine opened but delivered no audio
    /// (`_StartIO error 35` class). Observed on-device 2026-07-19 as three silent
    /// sessions with a normal-looking recording UI and no error.
    @ObservationIgnored private var deadMicDetector = DeadMicDetector()
    /// Set when a session enters `.recording`; consumed (nilled) by the FIRST
    /// finalize path to run — manual stop and the stream-end continuation both
    /// finalize, and the assessment must count each session exactly once.
    @ObservationIgnored private var voiceSessionStartedAt: Date?
    @ObservationIgnored private let maxPowerLevelsToShow = 100

    // MARK: - Streaming Task Handle
    @ObservationIgnored private var streamingTask: Task<Void, Never>?
    @ObservationIgnored private var silenceUICounter: Int = 0
    @ObservationIgnored private let silenceUIThreshold: Int = 10

    // MARK: - Keyboard Shortcut Observer
    @ObservationIgnored private var notificationObserver: Any?

    /// Guard for `setupMainDelegateObservers()`. Since this VM is app-scoped,
    /// `ChatInputAreaView.onAppear` can re-fire on view recreation — this flag
    /// prevents us from stacking duplicate `ObservationStream` instances for
    /// the same two signals.
    @ObservationIgnored private var hasMainDelegateObservers = false

    /// Holds the two ObservationStreams bridging `mainDelegate`'s state.
    /// Released (→ each stream's `deinit` → chain cancellation) when the VM
    /// deallocates, though in practice this VM lives for the app's lifetime.
    @ObservationIgnored private var attachedFilesObserver: ObservationStream?
    @ObservationIgnored private var streamingStateObserver: ObservationStream?

    /// Suggestion-pipeline and recognition-loading observers — same lifetime
    /// semantics as above.
    @ObservationIgnored private var promptQueryObserver: ObservationStream?
    @ObservationIgnored private var fileQueryObserver: ObservationStream?
    @ObservationIgnored private var recognitionLoadingObserver: ObservationStream?

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
    /// refresh file suggestions on changes. Subsequent calls are no-ops — the
    /// observer chains registered on first call persist for the VM's lifetime.
    func setupMainDelegateObservers() {
        guard let delegate = mainDelegate else {
            logger.warning("setupMainDelegateObservers called but mainDelegate is nil — attached files and streaming state will not update.")
            return
        }
        guard !hasMainDelegateObservers else {
            // Already wired on a prior .onAppear. Just refresh the mirrored
            // snapshots in case the delegate's state changed between setups.
            self.attachedFiles = delegate.attachedFiles
            self.isStreaming = delegate.streamingMessageID != nil
            return
        }
        hasMainDelegateObservers = true

        // Mirror attached files.
        attachedFilesObserver = ObservationStream(
            track: { [weak self] in
                guard let self, let delegate = self.mainDelegate else { return }
                _ = delegate.attachedFiles
            },
            onChange: { [weak self] in
                guard let self, let delegate = self.mainDelegate else { return }
                self.attachedFiles = delegate.attachedFiles
                if self.fileSuggestionState.isShowing {
                    self.performFileSearch(query: self.fileSuggestionState.query)
                }
            }
        )
        self.attachedFiles = delegate.attachedFiles

        // Mirror streaming state.
        streamingStateObserver = ObservationStream(
            track: { [weak self] in
                guard let self, let delegate = self.mainDelegate else { return }
                _ = delegate.streamingMessageID
            },
            onChange: { [weak self] in
                guard let self, let delegate = self.mainDelegate else { return }
                self.isStreaming = delegate.streamingMessageID != nil
            }
        )
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

    /// [V3] The window hosting the composer, wired by `ChatInputAreaView` via a window
    /// reader. Used to gate the app-wide ⌘⇧V shortcut: a recording started while some
    /// OTHER window is key (QuickAccess panel, a file-viewer window) shows no overlay —
    /// a hot mic with no affordance to stop it.
    @ObservationIgnored weak var composerWindow: NSWindow?

    private func setupKeyboardShortcutObserver() {
        notificationObserver = NotificationCenter.default.addObserver(
            forName: GlobalConstants.toggleVoiceInputNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // [V3] CommandMenu shortcuts fire app-wide. Only honor the toggle when
                // the composer's window is key, so the recording overlay is actually
                // on screen. Fall through when the window was never wired (nil) —
                // a dead hotkey would be worse than the gate missing.
                if let window = self.composerWindow, !window.isKeyWindow {
                    self.logger.log("[VOICE] ⌘⇧V ignored — composer window is not key (key window: \(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "none")).")
                    return
                }
                self.toggleVoiceInput()
            }
        }
    }

    /// [V3] Called when the composer view leaves the hierarchy (main window closing).
    /// A dictation session must not outlive its UI: stop it and keep the transcript
    /// (it lands in `userInput`, which this app-scoped VM retains for reopen).
    func handleComposerDismantled() {
        guard voiceInputState == .recording || voiceInputState == .finalizingSilence else { return }
        logger.log("[VOICE] Composer view dismantled mid-recording — stopping dictation so the mic can't stay hot without UI (V3).")
        stopStreamingAndFinalize()
    }

    // MARK: - Suggestion Pipelines (Debounced)

    @ObservationIgnored private var promptDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var fileDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var lastPromptQuery: String = ""
    @ObservationIgnored private var lastFileQuery: String = ""

    private func setupSuggestionPipelines() {
        promptQueryObserver = ObservationStream(
            track: { [weak self] in
                _ = self?.promptSuggestionState.query
            },
            onChange: { [weak self] in
                guard let self else { return }
                let newQuery = self.promptSuggestionState.query
                guard newQuery != self.lastPromptQuery else { return }
                self.lastPromptQuery = newQuery
                self.promptDebounceTask?.cancel()
                self.promptDebounceTask = Task {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard !Task.isCancelled else { return }
                    self.performAsyncPromptFilter(query: newQuery)
                }
            }
        )

        fileQueryObserver = ObservationStream(
            track: { [weak self] in
                _ = self?.fileSuggestionState.query
            },
            onChange: { [weak self] in
                guard let self else { return }
                let newQuery = self.fileSuggestionState.query
                guard newQuery != self.lastFileQuery else { return }
                self.lastFileQuery = newQuery
                self.fileDebounceTask?.cancel()
                self.fileDebounceTask = Task {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard !Task.isCancelled else { return }
                    self.performFileSearch(query: newQuery)
                }
            }
        )
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

        promptService.recordUsage(of: prompt)

        resetPromptState()
    }

    /// Stages a prompt for insertion from *outside* the chat input (e.g. the
    /// Prompt Library detail view's "Use in chat" action or the sidebar row
    /// hover button). Unlike `selectPrompt`, no `/` trigger range is required.
    ///
    /// **Only `prompt.text` is inserted — the prompt's title, category, tags,
    /// and any other metadata stay in the library.** The text is trimmed of
    /// leading/trailing whitespace so no stray newlines bleed in. A leading
    /// space is prepended only when the existing `userInput` doesn't already
    /// end in whitespace — preserves the user's partially-typed draft without
    /// smashing it up against the prompt text.
    ///
    /// Also records usage so the prompt bubbles up in Recently-Used sort.
    /// Also flips `pendingInputFocusRequest` so the chat input grabs keyboard
    /// focus on the next render — spares the user a click after navigation.
    ///
    /// - Returns: `true` when the prompt body was staged, `false` when it was
    ///   empty (and therefore nothing would visibly change in the editor).
    ///   Callers typically surface a toast on `false`.
    @discardableResult
    func stagePromptFromLibrary(_ prompt: DevPrompt) -> Bool {
        let cleanText = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else {
            logger.warning("stagePromptFromLibrary: prompt '\(prompt.title)' has empty text — nothing to insert")
            return false
        }

        let needsLeadingSpace = !userInput.isEmpty
            && !userInput.hasSuffix(" ")
            && !userInput.hasSuffix("\n")
        let stringToInsert = (needsLeadingSpace ? " " : "") + cleanText

        logger.log("Staging prompt body from library: title='\(prompt.title)' chars=\(cleanText.count)")

        let insertionText = NSAttributedString(
            string: stringToInsert,
            attributes: defaultTypingAttributes
        )
        let endLocation = (userInput as NSString).length
        self.attributedTextInsertionRequest = .init(
            range: NSRange(location: endLocation, length: 0),
            attributedString: insertionText
        )

        promptService.recordUsage(of: prompt)

        // Defer the focus request to the next runloop tick. Setting it in
        // the same synchronous frame as `attributedTextInsertionRequest`
        // causes SwiftUI to fire our `.onChange(of: pendingInputFocusRequest)`
        // handler (which also mutates the VM), triggering an extra
        // `updateNSView` pass that beats `CustomTextEditor`'s async
        // `self.text = textView.string` sync-back — the stale empty
        // `userInput` then wins and wipes the just-inserted text via the
        // fallback sync-to-binding path. Separating the two mutations
        // across runloop ticks avoids that race.
        DispatchQueue.main.async { [weak self] in
            self?.pendingInputFocusRequest = true
        }
        return true
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
        if voiceInputState == .recording || voiceInputState == .finalizingSilence {
            // .finalizingSilence must stop too — the button shows "stop" during the
            // VAD hysteresis window, and a tap there was previously swallowed.
            stopStreamingAndFinalize()
        } else if voiceInputState == .available {
            Task { await startStreaming() }
        } else if voiceInputState == .idle || voiceInputState.isErrorState {
            // Model not loaded or failed — show selection popover
            showModelSelectorPopover = true
        } else if voiceInputState == .permissionsDeniedMic {
            // Denied mic permission is otherwise a silent dead end — route the user
            // to the Microphone privacy pane, the only place it can be fixed.
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
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
            // Route through DownloadCoordinator so the download is
            // persisted to history and short-circuits correctly if the
            // model was already pulled in a past session.
            Task { @MainActor in
                _ = await DownloadCoordinator.startWhisperDownloadIfNeeded(modelId: modelId)
            }
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
        // [Dead-mic] A user cancel is an abort, not evidence — clear without assessing.
        voiceSessionStartedAt = nil
        recordingDisplay.liveTranscriptionText = ""
        recordingDisplay.powerLevels = []
        recordingDisplay.recordingTime = 0.0
        userInput = ""
        voiceInputState = .available
    }

    // MARK: - State Management (Internal)

    /// Observes the recognition service's loadingState via `ObservationStream`,
    /// replacing the previous Combine publisher bridge.
    private func observeRecognitionLoadingState() {
        guard let service = recognitionService as? WhisperRecognitionService else { return }
        recognitionLoadingObserver = ObservationStream(
            track: { [weak service] in
                _ = service?.loadingState
            },
            onChange: { [weak self] in
                guard let self,
                      let service = self.recognitionService as? WhisperRecognitionService else { return }
                self.handleModelLoadingState(service.loadingState)
            }
        )
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
        // ⚠️⚠️ CALLED FROM `init`, SO MERELY CONSTRUCTING THE COMPOSER ASKS FOR THE MICROPHONE. In a
        // test host that is a real, modal, user-visible permission prompt raised by a process nobody
        // is watching and which exits when the suite finishes — and once answered it is remembered,
        // so a denial recorded here follows the developer's real app afterwards.
        guard TestHost.permits("request microphone permission", logger: logger) else { return }

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
        // [V4/C9] Synchronous re-entry guard. Two rapid mic taps each spawn a Task; both
        // bodies run serially on the MainActor, so flipping the state BEFORE the first
        // await makes the second body bail here. Without this, the second start leaked
        // the first recordingTimer (accumulating +1s/s forever) and raced a second
        // Whisper session against the shared service.
        guard voiceInputState == .available else {
            logger.log("[VOICE] startStreaming re-entry blocked (state: \(String(describing: self.voiceInputState))).")
            return
        }
        self.voiceInputState = .requestingPermissions

        logger.log("Starting streaming transcription...")
        guard recognitionService?.loadingState == .loaded else {
            logger.error("Cannot start streaming: model not ready (state: \(String(describing: self.recognitionService?.loadingState)))")
            self.voiceInputState = .error(String(localized: "Model not ready."))
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
        self.deadMicDetector.beginSession()
        self.voiceSessionStartedAt = Date()
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
                try await self.recognitionService?.startStreaming(owner: .mainComposer) { [weak self] streamState in
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
                self.logger.error("[VOICE] Streaming session failed: \(error)")
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.recordingTimer?.invalidate()
                    self.recordingTimer = nil
                    // [V1] Preserve whatever was transcribed before the failure — the
                    // overlay is about to collapse, and the text vanished with it.
                    let liveText = self.recordingDisplay.liveTranscriptionText
                    if !liveText.isEmpty {
                        self.userInput = liveText
                    }
                    self.recordingDisplay.liveTranscriptionText = ""
                    self.recordingDisplay.powerLevels = []
                    // RecognitionError carries user-appropriate descriptions ([V1]
                    // unexpected-end, [V2] busy-with-owner); other errors keep the
                    // generic streaming-failed framing.
                    if let recognitionError = error as? RecognitionError {
                        self.voiceInputState = .error(recognitionError.errorDescription ?? String(localized: "Voice input failed."))
                    } else {
                        self.voiceInputState = .error(String(localized: "Streaming failed: \(error.localizedDescription)"))
                    }
                }
            }
        }
    }

    private func handleStreamingUpdate(_ state: StreamingTranscriptionState) {
        // [Dead-mic] Energy samples are proof the engine is actually delivering audio.
        if !state.bufferEnergy.isEmpty {
            deadMicDetector.recordAudioArrived()
        }

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

    /// [Dead-mic] Consumes the session-start marker and assesses the session ONCE.
    /// Returns `true` when the session was dead (ran ≥ threshold, zero audio).
    /// User cancels clear the marker without assessing (an abort is not evidence).
    private func concludeVoiceSessionAssessingDeadMic() -> Bool {
        guard let startedAt = voiceSessionStartedAt else { return false }
        voiceSessionStartedAt = nil
        let duration = Date().timeIntervalSince(startedAt)
        let dead = deadMicDetector.assessSessionEnd(duration: duration)
        if dead {
            logger.warning("[VOICE] Dead mic session — \(String(format: "%.1f", duration))s with ZERO audio samples (\(self.deadMicDetector.consecutiveDeadSessions) consecutive). Engine likely failed to start (_StartIO error 35 class); surfacing error instead of silent empty transcript.")
        }
        return dead
    }

    /// Actionable message for a dead session (adapted from Jarvis's). Surfaced via
    /// the composer's existing error state.
    private var deadMicErrorMessage: String {
        String(localized: "The microphone opened but delivered no audio. Try again — if it keeps happening, another app may be holding the mic, or check your input device in System Settings → Sound.")
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
            // [Dead-mic] A ≥1s session with zero audio used to end here as a silently
            // empty composer — recording UI looked normal, nothing arrived, no error.
            self.voiceInputState = self.concludeVoiceSessionAssessingDeadMic()
                ? .error(self.deadMicErrorMessage)
                : .available
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
        // [Dead-mic] Same assessment as the manual-stop path; whichever finalize
        // runs first consumes the marker, so a session is counted exactly once.
        self.voiceInputState = concludeVoiceSessionAssessingDeadMic()
            ? .error(deadMicErrorMessage)
            : .available
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
