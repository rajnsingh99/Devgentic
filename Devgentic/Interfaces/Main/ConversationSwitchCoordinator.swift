// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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

        releaseTracesForConversationsLeftBehind(vm: vm, keeping: conversationID)

        // Immediately, not after the debounce below: the composer, the Explorer and a send made
        // right after the click must all see this conversation's folder.
        // The model is read on both sides of the restore — reopening a project can change it.
        let codeModelBefore = Self.codeModelKey(vm)
        vm.conversationManagementCoordinator.restoreCodeProjectForSelectedConversation()
        let codeModelAfter = Self.codeModelKey(vm)

        loadTask = Task { [weak self] in
            // Brief debounce so rapid selections only run the latest.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }

            // [QA revival P1e] Unload models only if NO stream is active anywhere AND the new
            // conversation uses a different backend profile. `streamingActive` covers only the
            // main window's slot; also consult the shared ActiveStreamManager so a QuickAccess or
            // Orb run — which keep their own PRIVATE slots and never set the shared
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

                // ⚠️ Code: decide by MODEL, not profile. Every Code session shares ONE profile, so the
                // profile test never unloaded between two projects on different local models (both
                // stayed resident), yet always unloaded for a fresh empty session (no profile yet),
                // forcing a reload of the very model the next send uses. Both seen on device 2026-09-24.
                let shouldUnload = Self.shouldUnloadModels(codeModelBefore: codeModelBefore, codeModelAfter: codeModelAfter,
                                                           newProfileID: newProfileID, currentProfileID: currentProfileID)
                if let before = codeModelBefore, let after = codeModelAfter {
                    self.logger.info("[CODE_PROJECT] Code session switch — model \(before) → \(after): \(shouldUnload ? "different, unloading the previous one" : "same, keeping it loaded").")
                }

                if shouldUnload {
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

    /// Whether a conversation switch should unload the resident local models.
    ///
    /// Code compares the MODEL on either side of the switch (all Code sessions share one profile);
    /// everything else compares the profile, as before.
    nonisolated static func shouldUnloadModels(codeModelBefore: String?, codeModelAfter: String?,
                                   newProfileID: UUID?, currentProfileID: UUID?) -> Bool {
        if let before = codeModelBefore, let after = codeModelAfter { return before != after }
        return newProfileID != currentProfileID || newProfileID == nil
    }

    /// "provider/model" of the Code session, or nil outside Code mode or before a model is picked.
    private static func codeModelKey(_ vm: MainApplicationViewModel) -> String? {
        guard vm.interfaceMode == .code, let manager = vm.codeSessionManager, !manager.modelName.isEmpty else { return nil }
        return "\(manager.provider.rawValue)/\(manager.modelName)"
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
            // [workflow/vm-6] The loader strips node traces inside its own detached decode, so
            // the peak here is one record's traces rather than the whole page's.
            let loaded = await WorkflowRunHistoryStore.shared.loadFinalized(forConversation: conversationID)
            guard let self, let vm = self.viewModel else { return }
            self.applyLoadedRunHistory(loaded.records, droppedAtLoad: loaded.droppedEvents,
                                       for: conversationID, vm: vm)
        }
    }

    /// Merges disk records into the observable history — split out so the async load above stays
    /// readable. MERGE rather than replace: an in-flight run inserted while we were loading is
    /// newer than anything on disk and must survive. Keyed by id, in-memory wins.
    /// - Parameter droppedAtLoad: events the LOADER already stripped ([workflow/vm-6]). The
    ///   merge below strips again — idempotently — so its own count is 0 for these records, and
    ///   the log would otherwise report "0 events left on disk" for a page that dropped
    ///   thousands. Summed rather than replaced so a caller that hands in unstripped records
    ///   (a test) still reports honestly.
    private func applyLoadedRunHistory(_ records: [WorkflowRunRecord], droppedAtLoad: Int = 0,
                                       for conversationID: UUID, vm: MainApplicationViewModel) {
        guard !records.isEmpty else { return }

        let inMemory = vm.workflowRunHistory[conversationID] ?? []
        let merge = Self.mergeLoadedHistory(existing: inMemory, loaded: records)
        vm.workflowRunHistory[conversationID] = merge.merged
        let result = (merged: merge.merged, droppedEvents: merge.droppedEvents + droppedAtLoad)

        if inMemory.isEmpty {
            logger.info("[WORKFLOW] Loaded \(records.count) persisted run(s) for conversation \(conversationID.uuidString.prefix(8)); \(result.droppedEvents) node timeline event(s) left on disk. CONSEQUENCE: opening one of these runs re-reads its trace (one off-main decode); nothing is lost and the list itself needs none of it.")
        } else {
            logger.info("[WORKFLOW] Merged \(records.count) persisted run(s) with \(inMemory.count) already in memory for conversation \(conversationID.uuidString.prefix(8)) — \(result.merged.count) total, \(result.droppedEvents) node timeline event(s) left on disk; the in-memory rows are a run started during the load and win on id.")
        }
    }

    /// [XUI-15] Frees the per-node traces of SETTLED runs in every conversation except the one
    /// now on screen.
    ///
    /// ⚠️ `workflowExecutionStates` has the same never-evicted-per-conversation shape `XUI-11` was
    /// filed for, one level over — and after `XUI-11` it holds essentially ALL of the app's
    /// resident trace events, at `ChatMessage.maxTimelineEvents` (500), which is 25% ABOVE the
    /// persisted cap. It was freed only by a Back press in the run view or by deleting the
    /// conversation, so a user who navigates by SWITCHING conversations — the ordinary way — kept
    /// one full run's trace per workflow conversation for the whole session.
    ///
    /// ⚠️ A SWEEP, not a "previous conversation" drop. `handleSelectionChange` does not track what
    /// was left, and a state can be stranded by paths that never touch the selection at all
    /// (a scheduled or ChatOps run finishing off-screen). Walking the map is O(conversations that
    /// ran a workflow this session) once per switch, and it cannot miss one.
    ///
    /// ⚠️ Runs BEFORE the debounce, deliberately: it releases memory rather than reading state, so
    /// it must not be cancelled along with the load task if the user keeps clicking.
    /// The execution states whose conversation is no longer on screen.
    ///
    /// ⚠️ Extracted because the loop that used it lives on a method taking a
    /// `MainApplicationViewModel`, which claims global singletons and cannot be built in a test —
    /// so an inverted keep-test (sweeping the CURRENT conversation instead of the others, freeing
    /// the traces of the run the user is looking at) survived the first mutation battery with
    /// nothing able to reach it. Same shape, and same reason, as `mergeLoadedHistory`.
    ///
    /// A nil `current` means no conversation is selected, so every state is left behind.
    @MainActor
    static func statesLeftBehind(
        in states: [UUID: WorkflowExecutionState], keeping current: UUID?
    ) -> [WorkflowExecutionState] {
        states.compactMap { $0.key == current ? nil : $0.value }
    }

    private func releaseTracesForConversationsLeftBehind(
        vm: MainApplicationViewModel, keeping current: UUID?
    ) {
        var releasedEvents = 0
        var releasedConversations = 0
        for state in Self.statesLeftBehind(in: vm.workflowExecutionStates, keeping: current) {
            let released = state.releaseSettledTraces()
            if released > 0 {
                releasedEvents += released
                releasedConversations += 1
            }
        }
        guard releasedConversations > 0 else { return }
        // [CF-28] Only runs whose record has already been FROZEN are counted here — the state's
        // own guard refuses (and logs, with the run id) both a run still in flight and one that
        // has settled but whose `finalize()` has not yet run, because for the latter the store
        // holds only the `.running` stub and there is nothing to re-read.
        logger.info("[WORKFLOW] Released \(releasedEvents) live node timeline event(s) across \(releasedConversations) conversation(s) left behind by this switch. CONSEQUENCE: returning to one of those runs re-reads its trace from the store (one off-main decode); the run's identity, status and HITL wiring are untouched. Every released run was FROZEN first — its traces were copied into the record value — but `upsertFinalized` awaits an off-main encode, so a re-read inside that window can still find the older row and render the Timeline tabs empty until the write lands. A run still in flight, or settled but not yet frozen, is skipped entirely.")
    }

    /// What the in-memory mirror becomes after a disk load: existing rows first, then the loaded
    /// ones that are not already present, all of them without their node traces.
    ///
    /// ⚠️ [XUI-11] THIS IS THE LEAK, and it is the reason the strip lives here rather than only at
    /// finalize. This path brings in up to `WorkflowRunHistoryStore.maxRecordsPerConversation`
    /// fully decoded records — each node carrying up to 400 timeline events, tool rows holding
    /// whole outputs — on FIRST VISIT to a conversation, and nothing ever removes the key again.
    /// The history list reads only counts and failure flags; `WorkflowRunDisplayData.from(record:)`
    /// is the sole reader of a snapshot's trace and runs for the ONE selected run, which re-reads
    /// it (`WorkflowRunHistoryStore.loadRecord(id:)`).
    ///
    /// ⚠️ MERGE, never replace, and in-memory wins on id: a run started while the decode was in
    /// flight is newer than anything on disk. That rule predates this row and is not incidental —
    /// see the load-once guard's comment for what happens when this path gets its ordering wrong.
    ///
    /// `nonisolated static` and pure (WF-UI5): the coordinator's method mutates a view model that
    /// claims global singletons, so this is the only shape in which the rule can be tested — and
    /// a mutant that stopped stripping here survived the first battery precisely because it wasn't.
    nonisolated static func mergeLoadedHistory(
        existing: [WorkflowRunRecord], loaded: [WorkflowRunRecord]
    ) -> (merged: [WorkflowRunRecord], droppedEvents: Int) {
        let stripped = loaded.map { $0.strippingNodeTimelines() }
        let droppedEvents = stripped.reduce(0) { $0 + $1.droppedEvents }
        guard !existing.isEmpty else { return (stripped.map(\.record), droppedEvents) }
        let existingIDs = Set(existing.map(\.id))
        return (existing + stripped.map(\.record).filter { !existingIDs.contains($0.id) },
                droppedEvents)
    }
}
