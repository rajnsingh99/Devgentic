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

                    // ✅ The unguarded shared-slot clear that used to live here was DELETED
                    // 2026-08-17 (design doc increment 1) along with the slot itself. It nil'd the
                    // slot regardless of ownership, orphaning whichever run had superseded this
                    // one. There is nothing to release: the composer derives its state from
                    // ActiveStreamManager, which this run's finalize already updates.
                    self?.logger.info("[RUN_LIFECYCLE] scheduled run completed for conversation \(conversationID.uuidString.prefix(8)).")

                    continuation.resume(returning: summary)
                }
                )
            }
            messageBox = agentMessage // Fill the box so the closure can read it

            // ✅ The shared-slot claim that used to live here was DELETED 2026-08-17 (design doc
            // increment 1). It never drove HITL banners — the banner stack keys on
            // `selectedConversationID` only (InteractionBannerStack.swift:35, :129), and a
            // scheduled run deliberately never selects its conversation.
            //
            // What it DID silently load-bear, and where each moved:
            //   1. Stop's target  → derived per-conversation; an unattended run in an UNSELECTED
            //      conversation is now correctly out of the composer's reach, and stoppable by
            //      opening its conversation.
            //   2. Composer state → same derivation, so a background scheduled run no longer locks
            //      the main composer for its whole duration.
            //   3. ChatOps /status → now asks ActiveStreamManager about its OWN conversation.
            //   4. The model-unload gate → the `[C7]` policy now applies consistently. Previously a
            //      PARKED run pinned a multi-GB model iff it happened to have last written this
            //      slot, i.e. by race. Owner decision 2026-08-17: a parked run does NOT pin the
            //      model (2-minute idle unload, reload on resume) — which is what [C7] already
            //      intended. See LLM_Execution_Concurrency_Design.md §2.3 and §0.5.

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
