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
        let streamingActive = vm.streamingMessageID != nil
        let activeStreamID = vm.streamingMessageID  // captured for log

        loadTask = Task { [weak self] in
            // Brief debounce so rapid selections only run the latest.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }

            // Only unload models if no agent is actively streaming AND the new
            // conversation uses a different backend profile.
            if !streamingActive {
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
                self.logger.info("Skipping model unload — agent is actively streaming (messageID: \(activeStreamID?.uuidString ?? "nil")).")
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
        guard vm.workflowRunHistory[conversationID] == nil else { return }
        let records = WorkflowRunHistoryStore.shared.load(forConversation: conversationID)
        if !records.isEmpty {
            vm.workflowRunHistory[conversationID] = records
        }
    }
}
