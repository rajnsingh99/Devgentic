// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatInputViewModel.swift
//  Devgentic
//
//  Created by Raj Singh.
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

protocol PromptServiceProtocol {
    func getAllPrompts() -> [DevPrompt]
    /// Records that a prompt was inserted into chat input. Drives the
    /// "Recently Used" sort in the sidebar.
    func recordUsage(of prompt: DevPrompt)
}

// MARK: - Service Conformance Extensions

extension WhisperRecognitionService: RecognitionServiceProtocol {}

extension PromptService: PromptServiceProtocol {}

// MARK: - State Structures

struct PromptSuggestionState {
    var isShowing: Bool = false
    var query: String = ""
    var filteredItems: [DevPrompt] = []
    var triggerRange: NSRange? = nil
    var selectedID: DevPrompt.ID? = nil
}

/// Holds `SkillSD` ids as plain strings rather than model objects, so the composer does not keep
/// SwiftData objects alive across a store change. A skill command addresses skills by name.
struct SkillSuggestionState {
    var isShowing: Bool = false
    var query: String = ""
    var filteredItems: [SkillCommandItem] = []
    /// One line per name more than one linked skill shares, among the names the query matches.
    var collisionNotes: [String] = []
    var triggerRange: NSRange? = nil
    var selectedID: String? = nil
}

/// One row in the `/` picker.
struct SkillCommandItem: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let displayName: String
    let description: String
}

/// Where the `@` picker's files come from right now; drives its empty state so an empty list says why
/// ("no folder", "indexing", "no files") instead of a generic "Type to search".
enum FileSuggestionSource: Equatable {
    case noFolder
    case indexing
    case ready

    @MainActor
    static func of(_ explorer: ExplorerViewModel) -> FileSuggestionSource {
        if explorer.selectedRootURL == nil { return .noFolder }
        if explorer.isIndexing && explorer.allSuggestableFiles.isEmpty { return .indexing }
        return .ready
    }
}

struct FileSuggestionState {
    var isShowing: Bool = false
    var query: String = ""
    var filteredItems: [FileSystemItem] = []
    var source: FileSuggestionSource = .ready
    /// A search has completed since the picker opened. Until then the list is not "empty", it
    /// is not-yet-known — the view must not claim "no files" for it.
    var hasResults: Bool = false
    var triggerRange: NSRange? = nil
    var selectedID: FileSystemItem.ID? = nil
    var multiSelectedIDs: Set<FileSystemItem.ID> = []
}

// MARK: - Isolated Recording Display Store
// Separated from `ChatInputViewModel` so high-frequency updates (power levels, recording time) do not fire
// its `objectWillChange` and re-evaluate `ChatInputAreaView`'s entire body.
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

    // MARK: - Recording Display
    let recordingDisplay = RecordingDisplayStore()

    // MARK: - Suggestions
    var promptSuggestionState = PromptSuggestionState()
    var fileSuggestionState = FileSuggestionState()
    var skillSuggestionState = SkillSuggestionState()
    var attributedTextInsertionRequest: CustomTextEditor.AttributedTextInsertionAction? = nil

    /// Set to true to ask the chat input's `TextEditor` to take keyboard focus on the next render.
    /// `ChatInputAreaView` observes it, flips its `@FocusState`, then the view model resets the flag.
    /// Used by external callers such as the prompt library's "Use in Chat".
    var pendingInputFocusRequest: Bool = false

    // MARK: - Delegates
    @ObservationIgnored weak var mainDelegate: (any ChatInputMainDelegate)?
    @ObservationIgnored var onFileSearchRequest: ((String) -> (candidates: [FileSystemItem], attached: [FileSystemItem], source: FileSuggestionSource))?

    // MARK: - Mediated Main ViewModel Access
    // These mirror mainDelegate state so SwiftUI re-renders when they change.
    // Updated via setupMainDelegateObservers().

    private(set) var attachedFiles: [FileSystemItem] = []
    private(set) var isStreaming: Bool = false

    /// Attaches the file unless `AttachmentIntake` refuses it; every composer attach route funnels through here.
    /// - Returns: the refusals (empty when attached), for callers to surface to the user.
    /// - Parameter deliveryMode: the active profile's mode, which decides whether a folder is accepted; nil if unresolved.
    @discardableResult
    func addAttachedFile(fileItem: FileSystemItem, deliveryMode: AttachmentDeliveryMode? = nil) -> [AttachmentIntake.Refusal] {
        addAttachedFiles(fileItems: [fileItem], deliveryMode: deliveryMode)
    }

    @discardableResult
    func addAttachedFiles(fileItems: [FileSystemItem], deliveryMode: AttachmentDeliveryMode? = nil) -> [AttachmentIntake.Refusal] {
        let (accepted, refused) = AttachmentIntake.partition(fileItems, deliveryMode: deliveryMode)
        if !refused.isEmpty {
            logger.warning("[ATTACH] Refused \(refused.count) attachment(s): \(refused.map { "\($0.item.name) — \($0.reason)" }.joined(separator: "; ")). CONSEQUENCE: not attached; the user is told why instead of the file failing at send with a read error the model never sees.")
        }
        guard !accepted.isEmpty else { return refused }
        if accepted.count == 1, fileItems.count == 1 {
            mainDelegate?.addAttachedFile(fileItem: accepted[0])
        } else {
            mainDelegate?.addAttachedFiles(fileItems: accepted)
        }
        return refused
    }
    func removeAttachedFile(fileItem: FileSystemItem) { mainDelegate?.removeAttachedFile(fileItem: fileItem) }

    /// Attachments the model will receive only part of (or none of) under the active profile —
    /// shown above the chips by `DeliveryWarningPanel`. Empty when nothing is lost.
    var deliveryWarnings: [DeliveryWarning] = []
    @ObservationIgnored private var deliveryWarningTask: Task<Void, Never>?

    /// Recomputes `deliveryWarnings` for the current attachments by running the backend's own
    /// read-then-plan (`DeliveryWarnings.outcomes`). Only an INJECTING profile can lose content;
    /// a path-manifest profile hands over paths, so it never warns.
    func refreshDeliveryWarnings(mode: AttachmentDeliveryMode?, profileType: ProfileType?,
                                 reader: FileProcessorService = FileProcessorService()) {
        deliveryWarningTask?.cancel()
        guard case .inject(let includeAbsolutePaths)? = mode else {
            deliveryWarnings = []
            return
        }
        // The backend injects every non-image attachment; files that fail to read (folders,
        // binaries) drop out of the plan there too, so only text and documents are candidates.
        let candidates = attachedFiles
            .filter { [.text, .document].contains(AttachmentClassifier.classify($0)) }
            .map { DeliveryWarnings.Candidate(name: $0.name, path: $0.url.path, url: $0.url) }
        guard !candidates.isEmpty else {
            deliveryWarnings = []
            return
        }
        let lane = DeliveryWarnings.Lane.attachment(includeAbsolutePaths: includeAbsolutePaths)
        let remedy = DeliveryWarnings.Remedy.forProfileType(profileType)
        deliveryWarningTask = Task { [weak self] in
            let outcomes = await DeliveryWarnings.outcomes(for: candidates, lane: lane, reader: reader)
            guard !Task.isCancelled, let self else { return }
            let warnings = DeliveryWarnings.warnings(for: outcomes, lane: lane, remedy: remedy)
            if warnings != self.deliveryWarnings {
                self.deliveryWarnings = warnings
                if !warnings.isEmpty {
                    self.logger.info("[ATTACH] Pre-send: \(warnings.count) attachment(s) won't reach the model in full: \(warnings.map(\.fileName).joined(separator: ", ")). CONSEQUENCE: shown above the chips with the reason and a suggestion; the send still cuts them to the budget.")
                }
            }
        }
    }

    /// Re-runs intake over files already attached and removes what the active profile cannot carry.
    /// Intake ran against the profile active at attach time; a profile switch or restored draft can leave a bad file.
    /// - Returns: the removed files, for the caller to report.
    @discardableResult
    func recheckAttachments(deliveryMode: AttachmentDeliveryMode?) -> [AttachmentIntake.Refusal] {
        let (_, refused) = AttachmentIntake.partition(attachedFiles, deliveryMode: deliveryMode)
        guard !refused.isEmpty else { return [] }
        for refusal in refused {
            mainDelegate?.removeAttachedFile(fileItem: refusal.item)
        }
        logger.notice("[ATTACH] Re-check removed \(refused.count) attachment(s) the active profile can't carry: \(refused.map { "\($0.item.name) — \($0.reason)" }.joined(separator: "; ")). CONSEQUENCE: they leave the composer now, with a notice, instead of failing at send.")
        return refused
    }
    func cancelStreamingResponse() { mainDelegate?.cancelStreamingResponse() }
    func getQueryFromHistory(direction: MainApplicationViewModel.QueryNavigationDirection) -> String? { mainDelegate?.getQueryFromHistory(direction: direction) }
    func resetQueryHistoryIndex() { mainDelegate?.resetQueryHistoryIndex() }

    // MARK: - Services
    @ObservationIgnored private var recognitionService: RecognitionServiceProtocol?
    @ObservationIgnored private let promptService: PromptServiceProtocol

    // MARK: - Private State
    @ObservationIgnored private let logger = DGLogger(category: "ChatInputViewModel")
    @ObservationIgnored private var recordingTimer: Timer?
    /// Pure detection core: a session that ran at least 1s with zero energy samples means the engine opened
    /// but delivered no audio.
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

    /// Guards `setupMainDelegateObservers()`: this view model is app-scoped and `ChatInputAreaView.onAppear` can re-fire,
    /// so this prevents stacking duplicate `ObservationStream` instances.
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
        promptService: PromptServiceProtocol = PromptService.shared
    ) {
        logger.info("ChatInputViewModel initialized.")

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
            observeRecognitionLoadingState()
            // AFTER the observer: its initial-state pass would otherwise overwrite a denial.
            syncMicPermissionStatus()
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

    /// The window hosting the composer, wired by `ChatInputAreaView`. Gates the app-wide ⌘⇧V shortcut so a recording
    /// does not start while another window is key, with no overlay to stop it.
    @ObservationIgnored weak var composerWindow: NSWindow?

    private func setupKeyboardShortcutObserver() {
        notificationObserver = NotificationCenter.default.addObserver(
            forName: GlobalConstants.toggleVoiceInputNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // The shortcut fires app-wide; honor the toggle only when the composer's window is key so the overlay is on screen.
                // Falls through when the window was never wired (nil), so the hotkey is not dead.
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
    @ObservationIgnored private var lastFileShowing: Bool = false

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
                // Redundant while `fileSuggestionState` is a struct, but kept: open/close is a real dependency of
                // `handleFilePickerOpenOrClose`, and an @Observable class tracking only `query` would stop seeing the picker open.
                _ = self?.fileSuggestionState.isShowing
            },
            onChange: { [weak self] in
                guard let self else { return }
                if self.handleFilePickerOpenOrClose() { return }
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

    // Why: a fresh `@` has the same empty query as last time, so a query-change trigger alone shows stale results.
    /// Searches at once when the picker opens and forgets its results when it closes.
    /// - Returns: true when this change was an open/close (handled here).
    func handleFilePickerOpenOrClose() -> Bool {
        let showing = fileSuggestionState.isShowing
        guard showing != lastFileShowing else { return false }
        lastFileShowing = showing
        fileDebounceTask?.cancel()
        if showing {
            lastFileQuery = fileSuggestionState.query
            fileSuggestionState.hasResults = false
            performFileSearch(query: fileSuggestionState.query)
        } else {
            lastFileQuery = ""
            fileSearchTask?.cancel()
            fileSuggestionState.filteredItems = []
            fileSuggestionState.hasResults = false
        }
        return true
    }

    private func performFileSearch(query: String) {
        guard let context = onFileSearchRequest?(query) else {
            logger.warning("File search skipped: onFileSearchRequest callback is nil (delegate not wired?).")
            return
        }
        processFileCandidates(context.candidates, attachedFiles: context.attached, source: context.source)
    }

    /// Called by the view when the Explorer's folder, index or indexing state changes while the
    /// picker is open — so a folder switched or indexed under an open `@` shows up live.
    func refreshFileSuggestions(using explorer: ExplorerViewModel) {
        let candidates = explorer.suggestableFiles(query: fileSuggestionState.query)
        processFileCandidates(candidates, attachedFiles: attachedFiles, source: .of(explorer))
    }

    func processFileCandidates(_ candidates: [FileSystemItem], attachedFiles: [FileSystemItem], source: FileSuggestionSource = .ready) {
        fileSearchTask?.cancel()

        fileSearchTask = Task.detached(priority: .userInitiated) {
            if Task.isCancelled { return }

            let attachedIDs = Set(attachedFiles.map { $0.id })
            let filtered = candidates.filter { !attachedIDs.contains($0.id) }

            if Task.isCancelled { return }

            await MainActor.run { [weak self] in
                self?.fileSuggestionState.filteredItems = filtered
                self?.fileSuggestionState.source = source
                self?.fileSuggestionState.hasResults = true
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

    /// Swaps the `/query` being typed for `/skill-name `, ready for the user's request.
    /// Inserts the command, not the skill body (unlike `selectPrompt`): a skill body belongs in a tool result.
    func selectSkillCommand(_ item: SkillCommandItem) {
        guard let range = skillSuggestionState.triggerRange else { return }
        logger.log("Skill command selected: '\(item.name)'")

        let insertionText = NSAttributedString(string: "/\(item.name) ", attributes: defaultTypingAttributes)
        self.attributedTextInsertionRequest = .init(range: range, attributedString: insertionText)

        resetSkillState()
    }

    func resetSkillState() {
        skillSuggestionState.isShowing = false
        skillSuggestionState.query = ""
        skillSuggestionState.filteredItems = []
        skillSuggestionState.collisionNotes = []
        skillSuggestionState.triggerRange = nil
        skillSuggestionState.selectedID = nil
    }

    /// Re-filters the `/` picker against what this profile's runs would actually load.
    /// Built from `SkillCommandOffer` (from `SkillResolution`, which runs use), so each row is the copy that will run;
    /// drafts, deleted skills and missing pins are excluded, and name collisions are reported in `collisionNotes`.
    @MainActor
    func refreshSkillSuggestions(offer: SkillCommandOffer) {
        guard skillSuggestionState.isShowing else { return }
        let all = offer.skills.map {
            SkillCommandItem(id: $0.skillID, name: $0.name, displayName: $0.displayName,
                             description: $0.description)
        }
        let query = skillSuggestionState.query.lowercased()
        let matched = query.isEmpty ? all : all.filter {
            $0.name.lowercased().contains(query) || $0.displayName.lowercased().contains(query)
        }
        // Only for names still on screen — a note about a row the query filtered away explains nothing.
        let matchedNames = Set(matched.map(\.name))
        skillSuggestionState.collisionNotes = offer.collisionNotes
            .filter { matchedNames.contains($0.name) }
            .map(\.note)
        // Prefix matches first — typing "co" should put `code-review` above `pandoc-convert`.
        skillSuggestionState.filteredItems = matched.sorted { lhs, rhs in
            let lhsPrefix = lhs.name.lowercased().hasPrefix(query)
            let rhsPrefix = rhs.name.lowercased().hasPrefix(query)
            if lhsPrefix != rhsPrefix { return lhsPrefix }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        if skillSuggestionState.selectedID == nil ||
            !skillSuggestionState.filteredItems.contains(where: { $0.id == skillSuggestionState.selectedID }) {
            skillSuggestionState.selectedID = skillSuggestionState.filteredItems.first?.id
        }
    }

    func selectPrompt(_ prompt: DevPrompt) {
        guard let range = promptSuggestionState.triggerRange else { return }
        logger.log("Prompt selected: '\(prompt.title)'")

        let insertionText = NSAttributedString(string: prompt.text + " ", attributes: defaultTypingAttributes)
        self.attributedTextInsertionRequest = .init(range: range, attributedString: insertionText)

        promptService.recordUsage(of: prompt)

        resetPromptState()
    }

    /// Stages a prompt for insertion from outside the chat input (e.g. the Prompt Library's "Use in chat").
    /// Inserts only the trimmed `prompt.text`, adding a leading space unless the draft ends in whitespace; records usage.
    /// - Returns: true when the prompt body was staged, false when it was empty.
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

        // Defer the focus request one runloop tick: setting it in the same frame as `attributedTextInsertionRequest`
        // triggers an extra `updateNSView` pass that beats `CustomTextEditor`'s sync-back and wipes the inserted text.
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
        case .skill:
            navigateGeneric(
                items: skillSuggestionState.filteredItems,
                selectedID: &skillSuggestionState.selectedID,
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
        fileSuggestionState.hasResults = false
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
            // .finalizingSilence must stop too: the button shows "stop" during the VAD hysteresis window.
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
            // Route through `DownloadCoordinator` so the download is persisted to history and skipped
            // if the model was already pulled.
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
                    // No models remain: tell the service the current model is gone so it goes idle,
                    // rather than pretending a default is selected.
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

    // Why: this runs from `init` at app scope; requesting permission here raises the macOS prompt on first launch.
    /// Mirrors the current microphone permission into the button state. Never prompts.
    private func syncMicPermissionStatus() {
        switch AVAudioApplication.shared.recordPermission {
        case .denied:
            logger.info("[VOICE] Microphone permission is denied. CONSEQUENCE: the mic button opens System Settings → Microphone instead of recording.")
            self.voiceInputState = .permissionsDeniedMic
        case .undetermined:
            logger.info("[VOICE] Microphone permission not yet requested — deferred to the first mic tap.")
        case .granted:
            break
        @unknown default:
            break
        }
    }

    // MARK: - Streaming Transcription Lifecycle

    private func startStreaming() async {
        // Synchronous re-entry guard: flipping the state before the first await makes a second rapid mic tap bail here,
        // otherwise it leaks the first recording timer and races a second Whisper session.
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
                    // `RecognitionError` carries user-appropriate descriptions; other errors keep the generic streaming-failed framing.
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

        // Hysteresis for `.finalizingSilence`: toggle `voiceInputState` only after sustained silence, to avoid rapid
        // state flips that fire `objectWillChange` and re-render parent views.
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

    /// Actionable message for a dead session (adapted from Orb's). Surfaced via
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
            // A session with zero audio concludes as a dead-mic error rather than an empty composer.
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
}
