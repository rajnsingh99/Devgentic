// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ConversationSwitchCoordinator.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

/// Owns the response to switching conversations: on each `selectedConversationID` change it cancels any in-flight
/// load, resets per-conversation UI state and runs a 250 ms-debounced load of the new conversation (messages, backend
/// profile, workflow run history). After 5 s it may analyse the conversation just left via `UserPersonalService`.
@MainActor
final class ConversationSwitchCoordinator {

    private let logger = DGLogger(category: "ConversationSwitch")

    // MARK: - Dependencies

    /// Weak back-reference for shared VM state not owned here: `selectedConversationID` (observed and read),
    /// `conversationManagementCoordinator` (backend rebind) and `workflowRunHistory` (mutated by the lazy-load helper).
    /// A switch unloads no model, so it reads no stream state.
    private weak var viewModel: MainApplicationViewModel?

    private let chatHistoryViewModel: ChatHistoryViewModel
    private let persistenceService: ChatPersistenceProtocol

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
        persistenceService: ChatPersistenceProtocol
    ) {
        self.viewModel = viewModel
        self.chatHistoryViewModel = chatHistoryViewModel
        self.persistenceService = persistenceService

        start()
    }

    deinit {
        // `observer` releases with us, so its own deinit flips its active flag. `loadTask` is captured strongly here but the
        // Task's closure captures `self` weakly, so cancelling here is sufficient.
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

        let conversationID = vm.selectedConversationID

        releaseTracesForConversationsLeftBehind(vm: vm, keeping: conversationID)

        // Immediately, not after the debounce below: the composer, the Explorer and a send made
        // right after the click must all see this conversation's folder.
        vm.conversationManagementCoordinator.restoreCodeProjectForSelectedConversation()

        loadTask = Task { [weak self] in
            // Brief debounce so rapid selections only run the latest.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }

            // A switch unloads nothing: viewing a conversation is not a request. Models swap only when a run that needs a different
            // one takes the local lock (`LocalInferenceCoordinator.didTakeLock`), and otherwise follow their engines' idle timers.

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

        // Load state is tracked explicitly: `workflowRunHistory` key presence proves nothing, since `sendMessage` creates
        // the key at run start and a send in the debounce window would skip the load forever.
        guard !loadedRunHistoryConversationIDs.contains(conversationID) else { return }
        loadedRunHistoryConversationIDs.insert(conversationID)

        // Decode off-main: the once-only guard above runs synchronously so the Task cannot double-load, and the merge below
        // is keyed by id with in-memory winning, so a run started during the decode survives.
        Task { [weak self] in
            // [workflow/vm-6] The loader strips node traces inside its own detached decode, so
            // the peak here is one record's traces rather than the whole page's.
            let loaded = await WorkflowRunHistoryStore.shared.loadFinalized(forConversation: conversationID)
            guard let self, let vm = self.viewModel else { return }
            self.applyLoadedRunHistory(loaded.records, droppedAtLoad: loaded.droppedEvents,
                                       for: conversationID, vm: vm)
        }
    }

    /// Merges disk records into the observable history. Merge, not replace: a run inserted while loading is newer than disk.
    /// - Parameter droppedAtLoad: events the loader already stripped; summed with this merge's own count so the log
    /// reports honestly.
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

    /// The execution states whose conversation is not the one on screen: the set swept to free settled run traces on a
    /// switch. A nil `current` means no conversation is selected, so every state is left behind. Static and pure so the
    /// keep rule is testable without a `MainApplicationViewModel`, which claims global singletons.
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
        // Only runs whose record is already frozen are counted: the state refuses (and logs) a run still in flight or settled
        // but not yet finalized.
        logger.info("[WORKFLOW] Released \(releasedEvents) live node timeline event(s) across \(releasedConversations) conversation(s) left behind by this switch. CONSEQUENCE: returning to one of those runs re-reads its trace from the store (one off-main decode); the run's identity, status and HITL wiring are untouched. Every released run was FROZEN first — its traces were copied into the record value — but `upsertFinalized` awaits an off-main encode, so a re-read inside that window can still find the older row and render the Timeline tabs empty until the write lands. A run still in flight, or settled but not yet frozen, is skipped entirely.")
    }

    // Why: strip node traces here, not only at finalize: a first visit loads up to `maxRecordsPerConversation` fully decoded
    // records that nothing evicts; only the selected run re-reads its trace.
    /// What the in-memory mirror becomes after a disk load: existing rows first, then loaded ones not already present,
    /// all without their node traces. Merge, never replace, and in-memory wins on id. `nonisolated static` and pure so
    /// the rule is testable.
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
