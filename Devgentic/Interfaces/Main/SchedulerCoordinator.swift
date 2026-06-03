//
//  SchedulerCoordinator.swift
//  Devgentic
//
//  Owns the message flow for automation paths that run *outside* the Mac chat
//  UI selection — scheduled tasks (via `SchedulerService`) and remote inbound
//  messages from the three ChatOps bridges (Telegram/Discord/Slack) that need
//  to materialize a conversation before their first message arrives.
//
//  Two methods:
//
//  - `createConversationForScheduledTask(profileID:title:)`
//        Materializes a conversation record with a pre-set title and bound
//        profile, without touching `selectedConversationID`. Used as the
//        first-message bootstrap by schedulers and ChatOps bridges.
//
//  - `sendScheduledMessage(prompt:config:conversationID:attachedFileURLs:)`
//        Async run-to-completion send that bypasses the regular UI send path
//        (no attached-files clearing, no query history mutation). Returns a
//        short summary string once the stream completes.
//
//  These paths are adjacent to the main messaging pipeline but have distinct
//  semantics (no UI selection side-effects, awaited completion), so they
//  live in their own coordinator rather than as a branch inside
//  `MessagingCoordinator`.
//

import Foundation
import os

@MainActor
final class SchedulerCoordinator {

    private let logger = DGLogger(category: "SchedulerCoordinator")

    /// Weak back-reference to the VM. Used for:
    /// - Mutating streaming state (so HITL banners surface in the Mac UI
    ///   when a scheduled agent pauses for confirmation).
    /// - Reaching `messagingCoordinator.createUserMessage(...)` and
    ///   `updateBackendForCurrentConversation(...)` through the VM so this
    ///   coordinator stays oblivious to its sibling coordinators.
    private weak var viewModel: MainApplicationViewModel?

    private let persistenceService: ChatPersistenceProtocol
    private let activeStreamManager: ActiveStreamManager

    init(
        viewModel: MainApplicationViewModel,
        persistenceService: ChatPersistenceProtocol,
        activeStreamManager: ActiveStreamManager
    ) {
        self.viewModel = viewModel
        self.persistenceService = persistenceService
        self.activeStreamManager = activeStreamManager
    }

    // MARK: - Conversation Bootstrap

    /// Create a conversation for a scheduled task (or for a new ChatOps
    /// remote sender) without selecting it in the Mac UI. The returned ID
    /// is the caller's handle for subsequent `sendScheduledMessage` calls.
    @discardableResult
    func createConversationForScheduledTask(profileID: BackendProfileModel, title: String) -> UUID {
        let newConversation = Conversation(
            id: UUID(),
            messages: [],
            timestamp: Date(),
            userDefinedTitle: title,
            backendType: .none,
            backendEntityId: profileID.id
        )
        persistenceService.addConversation(from: newConversation)

        // Persist the profile→conversation mapping via the VM's forward
        // (which lands in ConversationManagementCoordinator).
        viewModel?.updateBackendForCurrentConversation(
            conversationID: newConversation.id,
            profileID: profileID.id
        )
        logger.info("Created conversation for scheduled task: \(title) (\(newConversation.id.uuidString))")
        return newConversation.id
    }

    // MARK: - Run-to-Completion Send

    /// Send a message for a scheduled task / remote bridge without modifying
    /// the UI's selected conversation. Awaits stream completion and returns
    /// a short summary string for the caller to surface (e.g. Telegram reply
    /// body).
    func sendScheduledMessage(
        prompt: String,
        config: BackendRequestConfig,
        conversationID: UUID,
        attachedFileURLs: [URL]
    ) async -> String {
        guard persistenceService.getConversation(withId: conversationID) != nil else {
            logger.error("[sendScheduledMessage] Conversation \(conversationID.uuidString) not found.")
            return "Error: conversation not found."
        }
        guard let vm = viewModel else {
            logger.warning("[sendScheduledMessage] View model deallocated before send.")
            return "Error: view model unavailable."
        }

        // Build file items from URLs
        let fileItems: [FileSystemItem] = attachedFileURLs.compactMap { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            return FileSystemItem(id: url, name: url.lastPathComponent, url: url, isDirectory: isDir.boolValue)
        }

        // Create user message via the messaging coordinator's factory (same
        // text/image file classification logic as the UI send path).
        let userMessage = await vm.messagingCoordinator.createUserMessage(
            conversationID: conversationID,
            query: prompt,
            files: fileItems
        )
        await persistenceService.addMessage(userMessage, toConversation: conversationID)

        // Fetch history for context.
        let history = await persistenceService.fetchMessages(for: conversationID, offset: 0, limit: 50)

        // Start stream and await completion.
        // Use a box to break the forward-capture cycle: the closure captures
        // `messageBox` (already declared), and we fill it after the call returns.
        return await withCheckedContinuation { continuation in
            var messageBox: ChatMessage? = nil
            let agentMessage = activeStreamManager.startMessageStream(
                withConfig: config,
                conversationID: conversationID,
                userQuery: prompt,
                history: history,
                files: fileItems,
                onComplete: { [weak self] in
                    // Extract summary from the completed message.
                    let summary: String
                    switch messageBox?.content {
                    case .plainText(let text), .markdownText(let text):
                        summary = String(text.prefix(100))
                    case .error(_, let details, _, _):
                        summary = "Error: \(details)"
                    default:
                        summary = "Response complete."
                    }

                    // Clear streaming state so the Mac UI hides any HITL banner
                    // it raised for this scheduled run.
                    self?.viewModel?.streamingMessageID = nil
                    self?.viewModel?.streamingMessage = nil

                    continuation.resume(returning: summary)
                }
            )
            messageBox = agentMessage // Fill the box so the closure can read it

            // Set streaming state so the Mac UI can display HITL banners
            // (ask_user / tool confirmation) for remotely-triggered work.
            vm.streamingMessageID = agentMessage.id
            vm.streamingMessage = agentMessage
        }
    }
}
