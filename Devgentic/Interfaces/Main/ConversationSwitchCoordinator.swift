//
//  ConversationSwitchCoordinator.swift
//  Devgentic
//
//  Owns the "what happens when the user switches conversations" pipeline.
//  Extracted from `MainApplicationViewModel.setupConversationLoader()` — the
//  behaviour wasn't really about *loading* a conversation, it was a
//  multi-step selection-change response: debounce, web-search-active reset,
//  conditional model unload, message load, backend profile rebind, workflow
//  history fetch, and a delayed user-personal analysis trigger.
//
//  Putting this in its own file lets the coordinator own its own lifecycle
//  state (the observation stream and the debounce task) instead of those
//  living as loose properties on the VM.
//
//  On each `selectedConversationID` change:
//
//    1.  Cancel any in-flight load task and reset `isWebSearchActive`.
//    2.  Start a fresh 250 ms-debounced task that:
//          a. Unloads MLX + Ollama models *only if* no stream is active
//             AND the new conversation uses a different backend profile.
//          b. Loads the new conversation's messages via `ChatHistoryViewModel`.
//          c. Rebinds the backend profile selection to whatever the conversation
//             had persisted (via `ConversationManagementCoordinator`).
//          d. Lazy-loads workflow run history for the new conversation.
//    3.  After 5 s, opportunistically invoke `UserPersonalService` to analyse
//        the conversation the user just left — skipped if the cooldown gate
//        inside that service says we're not due.
//

import Foundation
import os

@MainActor
final class ConversationSwitchCoordinator {

    private let logger = DGLogger(category: "ConversationSwitch")

    // MARK: - Dependencies

    /// Weak back-reference for shared VM state we don't own here:
    /// `selectedConversationID` (observed + read), `isWebSearchActive` (write),
    /// `streamingMessageID` (read for the "don't unload during active stream"
    /// guard), `conversationManagementCoordinator` (for the backend rebind),
    /// and `workflowRunHistory` (mutated by the lazy-load helper).
    private weak var viewModel: MainApplicationViewModel?

    private let chatHistoryViewModel: ChatHistoryViewModel
    private let persistenceService: ChatPersistenceProtocol
    private let backendConfiguration: BackendConfiguration
    private let ollamaService: OllamaService

    // MARK: - Owned Lifecycle State

    /// Fires on every `selectedConversationID` change and re-registers itself.
    /// Held here so we don't expose the stream handle to the VM.
    private var observer: ObservationStream?

    /// Current in-flight debounced load task. Cancelled on each selection
    /// change so only the newest selection's work reaches completion.
    private var loadTask: Task<Void, Never>?

    /// Conversations whose persisted workflow run history has been read from disk this session.
    /// Tracked explicitly because `workflowRunHistory` key presence does NOT mean "loaded" —
    /// starting a run creates the key too. See `loadWorkflowRunHistoryIfNeeded`.
    private var loadedRunHistoryConversationIDs: Set<UUID> = []

    // MARK: - Init

    init(
        viewModel: MainApplicationViewModel,
        chatHistoryViewModel: ChatHistoryViewModel,
        persistenceService: ChatPersistenceProtocol,
        backendConfiguration: BackendConfiguration,
        ollamaService: OllamaService
    ) {
        self.viewModel = viewModel
        self.chatHistoryViewModel = chatHistoryViewModel
        self.persistenceService = persistenceService
        self.backendConfiguration = backendConfiguration
        self.ollamaService = ollamaService

        start()
    }

    deinit {
        // `observer` releases with us → its own deinit flips its active flag.
        // `loadTask` is captured strongly here but the Task's closure captures
        // `self` weakly, so cancelling here is sufficient.
    }

    // MARK: - Public (called from VM init's wiring)

    /// Begin observing conversation-selection changes. Called from init;
    /// separated into its own method purely for readability.
    private func start() {
        observer = ObservationStream(
            track: { [weak self] in
                _ = self?.viewModel?.selectedConversationID
            },
            onChange: { [weak self] in
                self?.handleSelectionChange()
            }
        )
    }

    // MARK: - Selection-Change Handler

    private func handleSelectionChange() {
        guard let vm = viewModel else { return }

        // Cancel any in-flight load task from a prior selection.
        loadTask?.cancel()

        // Reset the per-conversation ephemeral UI state.
        vm.isWebSearchActive = false
        logger.debug("Conversation changed. Resetting web search active state to OFF.")

        let conversationID = vm.selectedConversationID
        let currentProfileID = backendConfiguration.selectedProfileID

        loadTask = Task { [weak self] in
            // Brief debounce so rapid selections only run the latest.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }

            // [QA revival P1e] Unload models only if NO stream is active anywhere AND the new
            // conversation uses a different backend profile. `streamingActive` covers only the
            // main window's slot; also consult the shared ActiveStreamManager so a QuickAccess or
            // Jarvis run — which keep their own PRIVATE slots and never set the shared
            // streamingMessageID — isn't rug-pulled mid-generation. Re-read after the debounce so
            // a run that began during it counts.
            // ⚠️ CORRECTED 2026-08-17: this comment previously claimed ChatOps and scheduler runs
            // "never set streamingMessageID". They demonstrably DO — MessagingCoordinator:690 and
            // SchedulerCoordinator:186 — so they are covered by the `streamingActive` term, not by
            // the activeStreams scan. That is not the same as being covered CORRECTLY; see [C7].
            // [C7] Count only ACTIVELY-STREAMING runs. A run parked on a HITL sits in
            // activeStreams until answered (possibly hours) but is idle — excluding it lets the
            // model unload while parked (reloading cheaply on resume) instead of pinning multiple
            // large local models resident indefinitely.
            // ✅ SIMPLIFIED 2026-08-17 (design doc increment 1). This used to be
            // `streamingActive || <scan>`, where `streamingActive` was the shared
            // `streamingMessageID` slot. That first term DEFEATED [C7] below by accident: the scan
            // deliberately excludes `.parkedHITL` runs, but the slot did not, so a parked run
            // pinned a multi-GB model iff it happened to have last written the slot — i.e. the
            // residency of a local model was decided by a race. With the slot gone, [C7] applies
            // consistently, which is what it always said it did.
            let anyStreamActive = self.viewModel?.activeStreamManager.activeStreams.values.contains { message in
                if case .streaming = message.lifecycleState { return true }
                return false
            } ?? false

            if !anyStreamActive {
                let newProfileID: UUID? = conversationID.flatMap {
                    self.persistenceService.getConversation(withId: $0)?.backendEntityId
                }

                if newProfileID != currentProfileID || newProfileID == nil {
                    let stats = await MLXService.shared.unloadModel()
                    self.logger.debug("Conversation switch MLX unload stats: \(stats)")
                    await self.ollamaService.unloadModel()
                } else {
                    self.logger.info("Skipping model unload — new conversation uses same backend profile (\(currentProfileID?.uuidString ?? "nil")).")
                }
            } else {
                self.logger.info("[C7] Skipping model unload — at least one ACTIVELY-STREAMING run is live in ActiveStreamManager. CONSEQUENCE: the local model stays resident until it finishes; HITL-parked runs deliberately do not count and let the model unload (2-minute idle path), reloading on resume.")
            }

            await self.chatHistoryViewModel.loadConversation(id: conversationID)

            if let id = conversationID, let vm = self.viewModel {
                vm.conversationManagementCoordinator.loadBackendStateForSelectedConversation(conversationID: id)
                self.loadWorkflowRunHistoryIfNeeded(for: id)
            }
        }

        // User Personal: trigger background analysis when leaving a conversation.
        // Uses a longer delay so it doesn't compete with the cleanup task above.
        if conversationID == nil || conversationID != vm.selectedConversationID {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                guard UserPersonalService.shared.shouldAnalyze() else { return }
                await UserPersonalService.shared.analyzeRecentConversations()
            }
        }
    }

    // MARK: - Workflow History Helper

    /// Lazily loads workflow run history for a conversation from disk on first
    /// visit. Records land back on the VM's observable `workflowRunHistory`
    /// dictionary so SwiftUI views see them.
    private func loadWorkflowRunHistoryIfNeeded(for conversationID: UUID) {
        guard let vm = viewModel else { return }

        // Load state is tracked EXPLICITLY. This used to guard on
        // `vm.workflowRunHistory[conversationID] == nil`, inferring "already loaded from disk"
        // from key presence — but `MessagingCoordinator.sendMessage` creates that key itself at
        // run start (`workflowRunHistory[cid, default: []].insert(initialRecord, at: 0)`). This
        // loader runs at the END of a debounced task (250 ms sleep, then the MLX/Ollama unloads,
        // then `loadConversation`), so a send landing inside that window won the race and the
        // disk load was then skipped FOREVER — the function has no other caller and no
        // invalidation. The run picker, the "1/N" badge and the whole history list showed only
        // the new run until relaunch.
        guard !loadedRunHistoryConversationIDs.contains(conversationID) else { return }
        loadedRunHistoryConversationIDs.insert(conversationID)

        // Decode OFF-MAIN (WF-UI6): this used to block the main thread for the full JSON decode
        // of up to 20 run blobs on first visit. The once-only guard above ran synchronously, so
        // the Task cannot double-load; the merge below is keyed by id and in-memory wins, so a
        // run started while the decode was in flight survives regardless of ordering.
        Task { [weak self] in
            let records = await WorkflowRunHistoryStore.shared.loadFinalized(forConversation: conversationID)
            guard let self, let vm = self.viewModel else { return }
            self.applyLoadedRunHistory(records, for: conversationID, vm: vm)
        }
    }

    /// Merges disk records into the observable history — split out so the async load above stays
    /// readable. MERGE rather than replace: an in-flight run inserted while we were loading is
    /// newer than anything on disk and must survive. Keyed by id, in-memory wins.
    private func applyLoadedRunHistory(_ records: [WorkflowRunRecord], for conversationID: UUID, vm: MainApplicationViewModel) {
        guard !records.isEmpty else { return }
        let inMemory = vm.workflowRunHistory[conversationID] ?? []
        if inMemory.isEmpty {
            vm.workflowRunHistory[conversationID] = records
            logger.info("[WORKFLOW] Loaded \(records.count) persisted run(s) for conversation \(conversationID.uuidString.prefix(8)).")
            return
        }
        let inMemoryIDs = Set(inMemory.map(\.id))
        let merged = inMemory + records.filter { !inMemoryIDs.contains($0.id) }
        vm.workflowRunHistory[conversationID] = merged
        logger.info("[WORKFLOW] Merged \(records.count) persisted run(s) with \(inMemory.count) already in memory for conversation \(conversationID.uuidString.prefix(8)) — \(merged.count) total; the in-memory rows are a run started during the load and win on id.")
    }
}
