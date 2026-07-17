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

    // MARK: - Small Delegations

    func toggleUserMessagesFilter() {
        chatHistoryViewModel.toggleUserMessagesFilter()
    }

    // MARK: - Create / Select

    func startNewConversation() {
        guard let vm = viewModel else { return }
        vm.clearAttachedFiles()
        let newConversationID = createAndSelectNewConversation()
        chatHistoryViewModel.isUserMessagesOnlyFilterActive = false
        logger.info("Started new conversation with ID \(newConversationID.uuidString).")
    }

    /// Deselect the currently-open conversation and return to the welcome screen.
    func deselectConversationAndShowWelcome() {
        guard let vm = viewModel else { return }
        vm.clearAttachedFiles()
        vm.selectedConversationID = nil
        backendConfiguration.selectedProfileID = nil
        chatHistoryViewModel.currentChatMessages = []
        chatHistoryViewModel.isUserMessagesOnlyFilterActive = false

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
            chatHistoryViewModel.isUserMessagesOnlyFilterActive = false
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
        chatHistoryViewModel.isUserMessagesOnlyFilterActive = false

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
        vm.activeStreamManager.cancelStreams(forConversation: conversationID)
        vm.interactionCenter.resolveAll(conversationID: conversationID)
        Task { await ExecutionSuspensionService.shared.cancel(for: conversationID) }
        // Drop this conversation's "Allow for this chat" tool grants — the conversation is being
        // deleted, so its durable per-conversation allowlist should go with it.
        Task { await SessionToolApprovals.shared.clear(conversationID: conversationID) }
    }

    func deleteConversation(conversationID: UUID) {
        guard let vm = viewModel else { return }
        drainLiveExecution(conversationID: conversationID, vm: vm)
        persistenceService.deleteConversation(with: conversationID)
        // Privacy: delete the conversation's traces too (FK cascades spans/events/configs),
        // so its raw content doesn't linger in traces.sqlite after deletion (§12.5).
        try? TraceStore.shared?.deleteTraces(forConversationID: conversationID.uuidString)
        // Same for its vector memory (chunks + parents): without this the RAG store
        // is append-only — the deleted conversation's content would linger in the
        // HNSW index, and on disk, forever.
        Task.detached(priority: .utility) {
            VectorStoreService.shared.deleteDocuments(forConversation: conversationID)
        }
        vm.workflowExecutionStates.removeValue(forKey: conversationID)
        vm.workflowRunHistory.removeValue(forKey: conversationID)
        WorkflowRunHistoryStore.shared.clearHistory(forConversation: conversationID)
        if vm.selectedConversationID == conversationID {
            vm.selectedConversationID = nil
        }
    }

    func deleteMultipleConversations(ids: Set<UUID>) {
        guard !ids.isEmpty, let vm = viewModel else { return }
        for id in ids {
            drainLiveExecution(conversationID: id, vm: vm)
            persistenceService.deleteConversation(with: id)
            try? TraceStore.shared?.deleteTraces(forConversationID: id.uuidString)
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
        let title = conversationSD.toStruct().displayTitle

        Task { [persistenceService] in
            let messages = await persistenceService.fetchMessages(for: conversationID, offset: 0, limit: 10000)
            await ConversationExporter.exportToFile(title: title, messages: messages)
        }
    }
}
