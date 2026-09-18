// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ConversationManagementCoordinator.swift
//  Devgentic
//
//  Owns conversation CRUD: creation (with reuse-of-empty heuristic), selection,
//  pin toggling, rename, delete (single + bulk), overlay transfer, export, and
//  the backend-profile <-> conversation mapping that travels with each
//  conversation. Extracted from `MainApplicationViewModel` as part of the
//  Gap C god-object split — before extraction these methods accounted for
//  ~175 of the VM's lines.
//
//  Dependency posture is identical to `MessagingCoordinator`:
//
//  - Services the coordinator uses directly (persistence, backendConfig,
//    chatHistoryViewModel) are injected explicitly.
//  - Shared state that still lives on `MainApplicationViewModel`
//    (`selectedConversationID`, `interfaceMode`, `workflowExecutionStates`,
//    `workflowRunHistory`, `codeSessionManager`, attached files) is reached
//    via a weak VM back-reference. Moving that state here would be a
//    different kind of refactor (observable-binding churn across views).
//

import Foundation
import SwiftUI
import SwiftData
import os

@MainActor
final class ConversationManagementCoordinator {

    private let logger = DGLogger(category: "ConversationManagement")

    /// Weak back-reference to the VM for the shared state it still owns.
    private weak var viewModel: MainApplicationViewModel?

    private let chatHistoryViewModel: ChatHistoryViewModel
    private let persistenceService: ChatPersistenceProtocol
    private let backendConfiguration: BackendConfiguration

    // MARK: - Init

    init(
        viewModel: MainApplicationViewModel,
        chatHistoryViewModel: ChatHistoryViewModel,
        persistenceService: ChatPersistenceProtocol,
        backendConfiguration: BackendConfiguration
    ) {
        self.viewModel = viewModel
        self.chatHistoryViewModel = chatHistoryViewModel
        self.persistenceService = persistenceService
        self.backendConfiguration = backendConfiguration
    }

    // MARK: - Create / Select

    func startNewConversation() {
        guard let vm = viewModel else { return }
        // NB no `clearAttachedFiles()` here any more. The composer's per-conversation
        // draft restore clears the box when the new (empty) conversation is selected —
        // and clearing HERE actively broke it: this ran BEFORE the id changed, so the
        // draft saved for the conversation being left captured zero attachments and the
        // user lost them. See ComposerDraftStore.
        let newConversationID = createAndSelectNewConversation()
        logger.info("Started new conversation with ID \(newConversationID.uuidString).")
    }

    /// Deselect the currently-open conversation and return to the welcome screen.
    func deselectConversationAndShowWelcome() {
        guard let vm = viewModel else { return }
        // As in `startNewConversation`: the draft restore owns clearing the composer, and
        // clearing before the id changes would discard the attachments of the very
        // conversation we're stepping away from.
        vm.selectedConversationID = nil
        backendConfiguration.selectedProfileID = nil
        chatHistoryViewModel.currentChatMessages = []

        if vm.interfaceMode == .code {
            vm.codeSessionManager?.resetSession()
        }

        logger.info("Deselected conversation, returning to welcome screen.")
    }

    /// Create (or reuse) an empty conversation and make it the selected one.
    /// Returns the conversation ID. Discardable so callers that only want the
    /// side-effect (UI navigation) can ignore the return value.
    @discardableResult
    func createAndSelectNewConversation() -> UUID {
        guard let vm = viewModel else { return UUID() }

        // Reuse an existing empty conversation if one exists — prevents duplicate empties.
        if let emptyConvID = findReusableEmptyConversation() {
            logger.info("[NewChat] Reusing existing empty conversation \(emptyConvID.uuidString).")
            tagConversationWithCurrentMode(emptyConvID)
            chatHistoryViewModel.currentChatMessages = []
            vm.selectedConversationID = emptyConvID
            return emptyConvID
        }

        let newConversation = Conversation(
            id: UUID(),
            messages: [],
            timestamp: Date(),
            backendType: .none,
            backendEntityId: nil
        )
        persistenceService.addConversation(from: newConversation)
        tagConversationWithCurrentMode(newConversation.id)
        chatHistoryViewModel.currentChatMessages = []
        vm.selectedConversationID = newConversation.id

        return newConversation.id
    }

    /// Tags a freshly-created or freshly-reused conversation with the current mode's
    /// profile type so it appears in the matching sidebar immediately. Chat mode is
    /// intentionally left untagged — chat hosts multiple profile types (bot/agent/imageGen)
    /// and the exact one isn't resolved until send time. This eliminates the "new code
    /// conversation invisible in sidebar until first message" edge case.
    private func tagConversationWithCurrentMode(_ conversationID: UUID) {
        guard let vm = viewModel else { return }
        switch vm.interfaceMode {
        case .code:
            persistenceService.updateProfileType(for: conversationID, profileTypeRaw: ProfileType.code.rawValue)
        case .workflow:
            persistenceService.updateProfileType(for: conversationID, profileTypeRaw: ProfileType.workflow.rawValue)
        case .chat:
            break
        }
    }

    /// Finds the most recent empty conversation (zero messages) that can be reused.
    private func findReusableEmptyConversation() -> UUID? {
        guard let context = ChatPersistenceStore.shared.modelContainer?.mainContext else { return nil }
        // [QA revival P1e] Never repurpose the QuickAccess conversation — it's owned by the
        // panel. (create-on-first-send already means it's rarely empty, but guard the gap.)
        let qaID = UserDefaults.standard.string(forKey: GlobalConstants.quickAccessOverlayConversationId).flatMap(UUID.init)
        var descriptor = FetchDescriptor<ConversationSD>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 5
        guard let results = try? context.fetch(descriptor) else { return nil }
        return results.first(where: { $0.messages.isEmpty && $0.id != qaID })?.id
    }

    // MARK: - Backend Profile Binding

    /// Called when a conversation is newly selected — pulls its persisted
    /// backend profile into `backendConfiguration` so the next send uses it.
    func loadBackendStateForSelectedConversation(conversationID: UUID) {
        guard let conversationSD = persistenceService.getConversation(withId: conversationID) else {
            logger.warning("Could not find conversation \(conversationID.uuidString) to load backend state. Resetting.")
            backendConfiguration.selectedProfileID = nil
            return
        }

        let profileID = conversationSD.backendEntityId
        backendConfiguration.selectedProfileID = profileID

        logger.info("Loaded backend profile ID \(profileID?.uuidString ?? "nil") (type: \(self.viewModel?.selectedProfileType?.rawValue ?? "nil")) for conversation \(conversationID)")
    }

    /// Persists the backend profile selection on the given conversation.
    /// Called at send time by `MessagingCoordinator` (through a VM forward)
    /// and from the scheduler path.
    func updateBackendForCurrentConversation(conversationID: UUID, profileID: UUID?) {
        var legacyBackendType: BackendType = .none
        if let id = profileID, let profile = (try? BackendProfileStore.shared.fetchProfiles())?.first(where: { $0.id == id }) {
            switch profile.profileType {
            case .agent:
                legacyBackendType = .agent
            case .bot:
                if case .bot(let config) = profile.details, config.llmConfig.apiProvider == .ollama {
                    legacyBackendType = .ollama
                } else {
                    legacyBackendType = .remote
                }
            case .workflow:
                legacyBackendType = .none
            case .imageGen:
                legacyBackendType = .none
            case .code:
                legacyBackendType = .none
            }
        }

        persistenceService.updateBackendForConversation(
            id: conversationID,
            backendType: legacyBackendType,
            backendEntityId: profileID
        )
        logger.debug("Persisted profile ID \(profileID?.uuidString ?? "nil") for conversation \(conversationID.uuidString).")
    }

    // MARK: - Overlay Handoff

    /// Transfers the currently-selected conversation to the QuickAccess overlay
    /// window. Clears the Mac UI selection so the two surfaces don't double-own
    /// the same conversation.
    func transferSelectedConversationToOverlay() {
        guard let vm = viewModel else { return }
        guard let conversationID = vm.selectedConversationID else { return }
        // [QA revival P0] Use the shared constants, not literals. The panel is created
        // by AppDelegate reading GlobalConstants.quickAccessOverlayConversationId, and
        // AppDelegate observes GlobalConstants.showQuickAccessPanelNotification
        // ("devgentic.showQuickAccessPanel") — the old literal "showQuickAccessPanel"
        // was never received, so the transfer flow silently did nothing.
        UserDefaults.standard.set(conversationID.uuidString, forKey: GlobalConstants.quickAccessOverlayConversationId)
        NotificationCenter.default.post(
            name: GlobalConstants.showQuickAccessPanelNotification,
            object: nil,
            userInfo: ["forceExpand": true]
        )
        vm.selectedConversationID = nil
    }

    // MARK: - Pin / Delete / Rename

    func togglePinStatus(for conversationId: UUID) {
        logger.debug("Toggling pin status for conversation: \(conversationId.uuidString)")
        persistenceService.togglePinStatus(for: conversationId)
    }

    /// [HITL/P5] Tear down any live run for a conversation before it is deleted. With the per-HITL
    /// watchdog gone, a run parked on a HITL would otherwise strand forever (deletion is terminal —
    /// there is no "switch back and answer"). Cancelling the stream cascades to the suspension's
    /// cancellation handler (deny / nil); `cancel(for:)` (which also posts `.hitl*Resolved`) and
    /// `resolveAll` are belt-and-suspenders so the unified queue is cleared even on the remote path.
    private func drainLiveExecution(conversationID: UUID, vm: MainApplicationViewModel) {
        let short = conversationID.uuidString.prefix(8)
        // Four separate teardowns, each previously silent. Deleting a conversation with a
        // run in flight is exactly when you need to see them.
        vm.activeStreamManager.cancelStreams(forConversation: conversationID)
        vm.interactionCenter.resolveAll(conversationID: conversationID)
        logger.info("[DELETE] \(short) — cancelled in-flight streams and resolved pending interactions.")
        Task {
            await ExecutionSuspensionService.shared.cancel(for: conversationID)
            logger.info("[DELETE] \(short) — released any parked (HITL-suspended) operations.")
        }
        // Drop this conversation's "Allow for this chat" tool grants — the conversation is being
        // deleted, so its durable per-conversation allowlist should go with it.
        Task {
            await SessionToolApprovals.shared.clear(conversationID: conversationID)
            logger.info("[DELETE] \(short) — cleared 'Allow for this chat' tool grants.")
        }
    }


    /// Clears the ChatOps cursor for a conversation that no longer exists.
    ///
    /// ⚠️⚠️ THE CURSOR OUTLIVING ITS CONVERSATION IS NOT INERT — IT MISDIAGNOSES EVERY LATER
    /// MESSAGE. The three bridges' free-text path guards `activeConversationID != nil`, then asks
    /// `profile(boundTo:)`, which collapses "the conversation row is gone" into "no profile bound"
    /// — so the bot answers "⚠️ No agent profile found for this conversation" forever, while
    /// `/status` in the same chat correctly reports "Active Conversation: None". Two surfaces, two
    /// answers, neither actionable.
    ///
    /// ⚠️ Cleared for EVERY provider whose cursor points here, not just the current one: three
    /// bridges can be bound to the same conversation at once.
    private func forgetRemoteBindings(conversationID: UUID) {
        for provider in RemoteChannel.Provider.allCases
        where RemoteSessionStore.shared.activeConversation(for: provider) == conversationID {
            RemoteSessionStore.shared.setActiveConversation(nil, for: provider)
            logger.info("[DELETE] \(conversationID.uuidString.prefix(8)) — cleared the \(provider.rawValue) ChatOps cursor, which pointed at it. CONSEQUENCE: the next remote message is answered with 'no active conversation' and a prompt to pick one, instead of a misleading 'no agent profile found' repeated indefinitely.")
        }
        // ⚠️ The mirror's session is an address book keyed by conversation; a deleted conversation
        // can never legitimately be mirrored again, and `unregisterSession` had no callers at all
        // until this one.
        guard let vm = viewModel else { return }
        for mirror in [vm.chatOpsBridge?.remoteMirrorService,
                       vm.discordChatOpsBridge?.remoteMirrorService,
                       vm.slackChatOpsBridge?.remoteMirrorService] {
            mirror?.unregisterSession(conversationID: conversationID)
        }
    }

    func deleteConversation(conversationID: UUID) {
        guard let vm = viewModel else { return }
        let short = conversationID.uuidString.prefix(8)
        logger.info("[DELETE] Deleting conversation \(short) — draining live execution first.")
        drainLiveExecution(conversationID: conversationID, vm: vm)
        // Unsent draft text shouldn't outlive the conversation it belonged to.
        ComposerDraftStore.shared.discard(for: conversationID)
        logger.info("[DELETE] \(short) — discarded any unsent composer draft.")
        // [CF-39] Same reasoning as the draft above: a side store keyed by conversation id must
        // not outlive the conversation.
        RemoteConversationOriginStore.forget(conversationID: conversationID)
        forgetRemoteBindings(conversationID: conversationID)
        persistenceService.deleteConversation(with: conversationID)
        // Privacy: delete the conversation's traces too (FK cascades spans/events/configs),
        // so its raw content doesn't linger in traces.sqlite after deletion (§12.5).
        //
        // The failure was swallowed by `try?`: a throw here left the conversation's raw
        // prompts and responses in traces.sqlite with nothing said, which defeats the
        // privacy guarantee this line exists to provide.
        do {
            try TraceStore.shared?.deleteTraces(forConversationID: conversationID.uuidString)
            logger.info("[DELETE] \(short) — traces removed from traces.sqlite (spans/events/configs cascade).")
        } catch {
            logger.error("[DELETE] \(short) — FAILED to delete traces: \(error.localizedDescription). The conversation's raw prompts and responses REMAIN in traces.sqlite.")
        }
        // Same for its vector memory (chunks + parents): without this the RAG store
        // is append-only — the deleted conversation's content would linger in the
        // HNSW index, and on disk, forever.
        Task.detached(priority: .utility) {
            VectorStoreService.shared.deleteDocuments(forConversation: conversationID)
        }
        let hadExecState = vm.workflowExecutionStates.removeValue(forKey: conversationID) != nil
        let hadRunHistory = vm.workflowRunHistory.removeValue(forKey: conversationID) != nil
        WorkflowRunHistoryStore.shared.clearHistory(forConversation: conversationID)
        logger.info("[DELETE] \(short) — in-memory workflow state cleared (exec state: \(hadExecState), run history: \(hadRunHistory)). Vector cleanup runs off the main actor and logs separately.")
        if vm.selectedConversationID == conversationID {
            vm.selectedConversationID = nil
        }
        logger.info("[DELETE] \(short) — teardown complete.")
    }

    func deleteMultipleConversations(ids: Set<UUID>) {
        guard !ids.isEmpty, let vm = viewModel else { return }
        logger.info("[DELETE] Bulk delete of \(ids.count) conversation(s) starting.")
        var traceFailures = 0
        for id in ids {
            drainLiveExecution(conversationID: id, vm: vm)
            ComposerDraftStore.shared.discard(for: id)
            RemoteConversationOriginStore.forget(conversationID: id)   // [CF-39]
            forgetRemoteBindings(conversationID: id)
            persistenceService.deleteConversation(with: id)
            do {
                try TraceStore.shared?.deleteTraces(forConversationID: id.uuidString)
            } catch {
                traceFailures += 1
                logger.error("[DELETE] \(id.uuidString.prefix(8)) — FAILED to delete traces: \(error.localizedDescription). Raw prompts/responses REMAIN in traces.sqlite.")
            }
            Task.detached(priority: .utility) {
                VectorStoreService.shared.deleteDocuments(forConversation: id)
            }
            vm.workflowExecutionStates.removeValue(forKey: id)
            vm.workflowRunHistory.removeValue(forKey: id)
            WorkflowRunHistoryStore.shared.clearHistory(forConversation: id)
        }
        if let currentSelected = vm.selectedConversationID, ids.contains(currentSelected) {
            vm.selectedConversationID = nil
        }
        if traceFailures > 0 {
            logger.error("[DELETE] Bulk delete finished — \(traceFailures) of \(ids.count) conversation(s) left traces behind in traces.sqlite.")
        } else {
            logger.info("[DELETE] Bulk delete finished — \(ids.count) conversation(s) torn down cleanly.")
        }
    }

    func renameConversation(conversationID: UUID, newTitle: String) {
        guard let conversationSD = persistenceService.getConversation(withId: conversationID) else { return }
        let trimmedTitle = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        conversationSD.userDefinedTitle = trimmedTitle.isEmpty ? nil : trimmedTitle
    }

    // MARK: - Export

    func exportConversation(conversationID: UUID) {
        guard let conversationSD = persistenceService.getConversation(withId: conversationID) else {
            logger.warning("Cannot export: conversation \(conversationID.uuidString) not found.")
            return
        }
        let title = conversationSD.toRowStruct().displayTitle

        // [mm-4] The save panel goes up FIRST; the fetch runs only after the user picks a file,
        // through the export projection (no image bytes). It used to fetch everything — every
        // attached image's external-storage blob included, on the main actor — before the panel
        // existed, so a long image-heavy conversation froze the window with nothing on screen.
        let persistenceService = persistenceService
        let logger = logger
        ConversationExporter.exportToFile(title: title) {
            // The panel is modeless: the conversation can be deleted while it is up. Nil tells
            // the exporter to report that instead of writing a header-only file.
            guard persistenceService.getConversation(withId: conversationID) != nil else {
                logger.warning("[EXPORT] Conversation \(conversationID.uuidString.prefix(8)) no longer exists at save time — export abandoned.")
                return nil
            }
            let limit = 10_000
            let source = await persistenceService.fetchMessagesForExport(for: conversationID, limit: limit)
            // Newest-first, so hitting the cap drops the conversation's EARLIEST turns. That used
            // to happen with no log and no notice in the file: the export simply began partway
            // through.
            if source.isTruncated {
                logger.warning("[EXPORT] Conversation \(conversationID.uuidString.prefix(8)) exceeds the \(limit)-message export cap — the export carries the most recent \(source.messages.count) and its EARLIEST turns are omitted. CONSEQUENCE: stated in the exported document's header so the file is not silently partial.")
            }
            return source
        }
    }
}
