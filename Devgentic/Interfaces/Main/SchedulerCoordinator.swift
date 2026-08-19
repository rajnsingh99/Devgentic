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
    /// - Mutating the shared streaming slot. ⚠️ CORRECTED 2026-08-17: this said the write makes
    ///   "HITL banners surface in the Mac UI". It does NOT and has not since the HITL
    ///   standardization — `InteractionBannerStack` keys purely on `selectedConversationID`
    ///   (InteractionBannerStack.swift:35, :129) and contains zero references to either slot
    ///   property. What the write actually load-bears is listed at the set site below.
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
        // [HITL/P5] Scheduled runs are UNATTENDED — bound them with a 10-minute container deadline.
        let scheduledRunDeadline: TimeInterval = 600
        // Workflow bookkeeping (no-op for other profile types). Without it a scheduled workflow
        // run left NO record at all — and history is the only surface an unattended run can be
        // reviewed from. It also flips HITL attribution to `.workflow`, which matters here more
        // than anywhere: a gate in a scheduled run parks under a banner nobody is watching, and
        // the 600 s deadline below kills the run if it goes unanswered.
        let workflowTicket = WorkflowRunBootstrap.begin(
            config: config,
            conversationID: conversationID,
            userInput: prompt,
            registry: vm,
            origin: .scheduled
        )

        return await withCheckedContinuation { continuation in
            var messageBox: ChatMessage? = nil
            var deadlineTask: Task<Void, Never>? = nil
            // ⚠️ UNATTENDED. Bound around `startMessageStream` so every task the stream spawns —
            // BOS, AgentConnect, the workflow executor, nested sub-workflows — inherits it. A
            // Router's ambiguity arbitration checks this and takes FIRST MATCH instead of parking:
            // a scheduled run renders no banner, so a park here only ever ended one way — the
            // 600s run deadline cancelling the whole run.
            let agentMessage = WorkflowRunAttendance.$isAttended.withValue(false) {
                activeStreamManager.startMessageStream(
                withConfig: config,
                conversationID: conversationID,
                userQuery: prompt,
                history: history,
                files: fileItems,
                workflowExecutionState: workflowTicket?.state,
                onComplete: { [weak self] in
                    deadlineTask?.cancel()
                    workflowTicket?.finalize()
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

                    // Release the shared streaming slot. ⚠️ CORRECTED 2026-08-17: this is NOT
                    // what hides a HITL banner (see the set site below). ⚠️ UNGUARDED — this nils
                    // the slot regardless of whether THIS run still owns it, so a run that
                    // superseded us is orphaned: the composer flips back to Send and that run
                    // becomes unstoppable from the UI. Logs nothing, so the eviction is invisible
                    // in the field. Tracked in LLM_Execution_Concurrency_Design.md (increment 1,
                    // which deletes both this line and the slot).
                    self?.viewModel?.streamingMessageID = nil
                    self?.viewModel?.streamingMessage = nil

                    continuation.resume(returning: summary)
                }
                )
            }
            messageBox = agentMessage // Fill the box so the closure can read it

            // ⚠️ CORRECTED 2026-08-17. This write does NOT drive HITL banners — the banner stack
            // keys on `selectedConversationID` only (InteractionBannerStack.swift:35, :129), and a
            // scheduled run deliberately never selects its conversation. That was true before the
            // HITL standardization replaced the banner's mount and deleted the consumer without
            // the producer.
            //
            // What this write ACTUALLY load-bears, undocumented until 2026-08-17:
            //   1. Stop's target            — MessagingCoordinator.cancelStreamingResponse:549
            //   2. The composer's Send/Stop state — ChatInputViewModel:279
            //   3. ChatOps `/status`
            //   4. The model-unload gate    — ConversationSwitchCoordinator:121, :139
            // On (4): because [C7] excludes `.parkedHITL` runs from the `activeStreams` scan, this
            // line is the ONLY thing keeping a multi-GB local model resident for a PARKED scheduled
            // run — so a parked run pins the model iff it happens to have last written this slot.
            // Deleting this line silently flips that policy. Owner decision 2026-08-17: a parked
            // run should NOT pin the model (2-minute idle unload, reload on resume), which is what
            // [C7] already intends. See LLM_Execution_Concurrency_Design.md §2.3 and §0.5.
            vm.streamingMessageID = agentMessage.id
            vm.streamingMessage = agentMessage

            // [HITL/P5] The deadline: if the unattended run is still going after 10 minutes
            // (e.g. parked on a HITL nobody is there to answer, now that the per-HITL watchdog is
            // gone), cancel the stream. Cancellation drains any parked suspension safely via the
            // withTaskCancellationHandler (deny / nil) → the stream finalizes → onComplete fires.
            let scheduledMessageID = agentMessage.id
            deadlineTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(scheduledRunDeadline))
                guard !Task.isCancelled, let self else { return }
                logger.notice("[sendScheduledMessage] ⏰ \(Int(scheduledRunDeadline))s deadline hit for \(scheduledMessageID) — cancelling unattended run.")
                self.activeStreamManager.cancelStream(for: scheduledMessageID)
                await ExecutionSuspensionService.shared.cancel(for: conversationID)
            }
        }
    }
}
