// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SchedulerCoordinator.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

/// Runs the message flow for automation paths outside the chat UI selection: scheduled tasks and ChatOps inbound
/// messages. Creates conversations without selecting them and sends async, awaited-to-completion messages.
@MainActor
final class SchedulerCoordinator {

    private let logger = DGLogger(category: "SchedulerCoordinator")

    /// Weak, optional back-reference to the view model, used only by `ensureConversation` to update the backend.
    /// A nil view model degrades that one step and is logged where it happens.
    private weak var viewModel: MainApplicationViewModel?

    private let persistenceService: ChatPersistenceProtocol

    /// The `MessageStreamStarting` seam rather than the concrete manager: this surface only starts a run and cancels
    /// the one it started, and the seam lets a test observe the hand-off.
    private let activeStreamManager: any MessageStreamStarting

    /// Needed only to build the user message. Previously reached through
    /// `viewModel!.messagingCoordinator`, which made the whole send path untestable.
    private let fileProcessorService: FileProcessorService

    /// Workflow-run bookkeeping via the narrow protocol, not the view model: constructing a `MainApplicationViewModel`
    /// claims `HITLPresenter` globally and opens real ChatOps connections.
    private weak var runRegistry: (any WorkflowRunRegistry)?

    init(
        viewModel: MainApplicationViewModel?,
        persistenceService: ChatPersistenceProtocol,
        activeStreamManager: any MessageStreamStarting,
        fileProcessorService: FileProcessorService,
        runRegistry: (any WorkflowRunRegistry)?
    ) {
        self.viewModel = viewModel
        self.persistenceService = persistenceService
        self.activeStreamManager = activeStreamManager
        self.fileProcessorService = fileProcessorService
        self.runRegistry = runRegistry
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
            backendEntityId: profileID.id
        )
        persistenceService.addConversation(from: newConversation)

        // Why: not a bare optional chain: with a nil view model the call would vanish silently while the success log still printed
        // Persists the profile-to-conversation mapping via the view model's forward.
        if let viewModel {
            viewModel.updateBackendForCurrentConversation(
                conversationID: newConversation.id,
                profileID: profileID.id
            )
        } else {
            logger.error("[SCHEDULER] Conversation \(newConversation.id.uuidString.prefix(8)) for scheduled task '\(title)' was created with NO view model, so the profile→conversation backend mapping was NOT written. CONSEQUENCE: the row keeps backendType .none and backendEntityId \(profileID.id.uuidString.prefix(8)); anything resolving the conversation's backend from the legacy column (rather than from the profile id) will not find it. The scheduled run itself proceeds normally.")
        }
        logger.info("Created conversation for scheduled task: \(title) (\(newConversation.id.uuidString))")
        return newConversation.id
    }

    // MARK: - Scheduled Request Pre-flight

    /// Persists a scheduled run's question before the send, so the durable row exists even if the run dies before streaming.
    /// `static` and internal so the contract is testable without a `MainApplicationViewModel` or a live backend stream.
    static func persistScheduledQuestion(
        userMessage: ChatMessage,
        conversationID: UUID,
        persistence: ChatPersistenceProtocol,
        logger: DGLogger
    ) async {
        await persistence.addMessage(userMessage, toConversation: conversationID)
        logger.info("[HISTORY] Scheduled question persisted \u{2014} messageID: \(userMessage.id.uuidString.prefix(8)), conversationID: \(conversationID.uuidString.prefix(8)). The history this run carries is DERIVED downstream and reported by ActiveStreamManager's own [HISTORY] line.")
    }

    // MARK: - Run-to-Completion Send

    /// How a scheduled run ended; the task record and its notification report timeouts, error cards and a missing
    /// conversation distinctly from completion.
    enum ScheduledRunOutcome: Equatable, Sendable {
        case completed
        case completedWithWarnings
        case failed
        case timedOut
        case cancelled

        var succeeded: Bool { self == .completed || self == .completedWithWarnings }

        var notificationTitle: String {
            switch self {
            case .completed, .completedWithWarnings: return "Scheduled Task Completed"
            case .failed:    return "Scheduled Task Failed"
            case .timedOut:  return "Scheduled Task Timed Out"
            case .cancelled: return "Scheduled Task Cancelled"
            }
        }
    }

    struct ScheduledRunResult: Sendable {
        let summary: String
        let outcome: ScheduledRunOutcome
    }

    /// A scheduled run's execution limit when its profile sets none.
    static let defaultScheduledRunLimit: TimeInterval = 30 * 60

    /// Reads how the run ended off its message. `timedOut` wins: the limit stamps `.failed`
    /// before cancelling, and that is a timeout, not a failure of the work.
    static func outcome(of message: ChatMessage?, timedOut: Bool) -> ScheduledRunOutcome {
        if timedOut { return .timedOut }
        switch message?.terminalOutcome {
        case .completed?:             return .completed
        case .completedWithWarnings?: return .completedWithWarnings
        case .failed?:                return .failed
        case .cancelled?:             return .cancelled
        case .timedOut?:              return .timedOut
        case nil:
            if case .error? = message?.content { return .failed }
            return .completed
        }
    }

    /// The task's own limit, else the profile's `executionTimeout`, else the default. An unusable
    /// value (0, negative, non-finite) is skipped rather than stopping the run the moment it starts.
    static func scheduledRunLimit(for profile: BackendProfileModel, taskLimit: TimeInterval? = nil) -> TimeInterval {
        if let own = taskLimit, own.isFinite, own > 0 { return own }
        if let own = profile.details.executionTimeout, own.isFinite, own > 0 { return own }
        return defaultScheduledRunLimit
    }

    /// Sends a message for a scheduled task or remote bridge without changing the UI's selected conversation.
    /// Awaits stream completion and returns a short summary string for the caller to surface.
    func sendScheduledMessage(
        prompt: String,
        config: BackendRequestConfig,
        conversationID: UUID,
        attachedFileURLs: [URL]
    ) async -> String {
        await runScheduledMessage(prompt: prompt, config: config, conversationID: conversationID,
                                  attachedFileURLs: attachedFileURLs).summary
    }

    /// `sendScheduledMessage`, reporting HOW the run ended as well as its summary.
    func runScheduledMessage(
        prompt: String,
        config: BackendRequestConfig,
        conversationID: UUID,
        attachedFileURLs: [URL],
        runLimit taskLimit: TimeInterval? = nil
    ) async -> ScheduledRunResult {
        guard persistenceService.getConversation(withId: conversationID) != nil else {
            logger.error("[sendScheduledMessage] Conversation \(conversationID.uuidString) not found.")
            return ScheduledRunResult(summary: "Error: conversation not found.", outcome: .failed)
        }

        // Build file items from URLs
        let fileItems: [FileSystemItem] = attachedFileURLs.compactMap { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            return FileSystemItem(id: url, name: url.lastPathComponent, url: url, isDirectory: isDir.boolValue)
        }

        // Registry check before the durable write, and only for workflow profiles (`WorkflowRunBootstrap.begin` returns nil
        // for other types): a missing registry then leaves the conversation untouched.
        if config.profile.profileType == .workflow, runRegistry == nil {
            logger.error("[WF_RUN] Scheduled WORKFLOW run for conversation \(conversationID.uuidString.prefix(8)) has NO run registry — the coordinator outlived it. CONSEQUENCE: the run is refused BEFORE its question is persisted, so nothing is left unanswered in the conversation; the schedule reports an error and will fire again on its next occurrence. Bot/agent/imageGen schedules are unaffected and are not refused here.")
            return ScheduledRunResult(summary: "Error: run registry unavailable.", outcome: .failed)
        }

        // Builds the user message with the same factory the UI send path uses, without needing the view model.
        let userMessage = await MessagingCoordinator.makeUserMessage(
            conversationID: conversationID,
            query: prompt,
            files: fileItems,
            fileProcessorService: fileProcessorService,
            deliveryMode: AttachmentDeliveryMode.resolve(for: config.profile)
        )
        // Set before the send, as QuickAccess and Orb do, so `[STREAM_START]` reads `.scheduled` from the user message.
        // `messageSource` is transient (not persisted), so reloaded rows read `.localUI`.
        userMessage.messageSource = .scheduled
        await Self.persistScheduledQuestion(
            userMessage: userMessage,
            conversationID: conversationID,
            persistence: persistenceService,
            logger: logger
        )

        // Starts the stream and awaits completion; `messageBox` breaks the forward-capture cycle and is filled after the call.
        // The run limit is the profile's `executionTimeout`, else 30 min, credited to this run's own park scope.
        let runLimit = Self.scheduledRunLimit(for: config.profile, taskLimit: taskLimit)
        let runScope = UUID()
        await ExecutionSuspensionService.shared.registerScope(runScope, conversationID: conversationID, attended: false)
        // Nesting: the run is the outermost budget — a turn, node or tool inside it is shortened to
        // fit, so its own timeout (and a workflow's error branch) fires before the run is cut off.
        let runFrame = await ExecutionBudget.frame(
            owner: "the scheduled run's \(ToolExecutionMediator.describe(runLimit)) limit",
            limit: runLimit, scope: runScope)
        // Workflow bookkeeping (a no-op for other profile types): records the run in history, the only surface an unattended
        // run can be reviewed from, and attributes HITL to `.workflow`. A nil registry here means a non-workflow run.
        let workflowTicket = runRegistry.map { registry in
            WorkflowRunBootstrap.begin(
                config: config,
                conversationID: conversationID,
                userInput: prompt,
                registry: registry,
                origin: .scheduled
            )
        } ?? nil

        return await withCheckedContinuation { continuation in
            var messageBox: ChatMessage? = nil
            var deadlineTask: Task<Void, Never>? = nil
            let timedOut = ScheduledRunFlag()
            // Unattended: bound around `startMessageStream` so every spawned task inherits it. A Router takes first match
            // instead of parking, since a scheduled run renders no banner.
            let agentMessage = WorkflowRunAttendance.$isAttended.withValue(false) {
                // CREATED inside the run's scope: every task the stream spawns inherits the chain.
                ParkScope.bind(runScope) { ExecutionBudget.bind(runFrame) {
                activeStreamManager.startMessageStream(
                withConfig: config,
                userMessage: userMessage,
                // Spelled out because a protocol witness carries no default arguments.
                promptOverride: nil,
                files: fileItems,
                updating: nil,
                workflowExecutionState: workflowTicket?.state,
                resumeState: nil,
                onComplete: { [weak self] in
                    deadlineTask?.cancel()
                    Task { await ExecutionSuspensionService.shared.unregisterScope(runScope) }
                    workflowTicket?.finalize()
                    // Extract summary from the completed message.
                    var summary: String
                    switch messageBox?.content {
                    case .plainText(let text), .markdownText(let text):
                        summary = String(text.prefix(100))
                    case .error(_, let details, _, _):
                        summary = "Error: \(details)"
                    default:
                        summary = "Response complete."
                    }
                    let outcome = Self.outcome(of: messageBox, timedOut: timedOut.isSet)
                    if outcome == .timedOut {
                        summary = "Timed out: exceeded its \(ToolExecutionMediator.describe(runLimit)) execution limit."
                    }

                    self?.logger.info("[RUN_LIFECYCLE] scheduled run ended (\(String(describing: outcome))) for conversation \(conversationID.uuidString.prefix(8)).")

                    continuation.resume(returning: ScheduledRunResult(summary: summary, outcome: outcome))
                }
                )
                } }
            }
            // Attributes the unattended run, as ChatOps and QuickAccess do. Set after `startMessageStream` returns, since the
            // mirror's didStartStream always sees `.localUI` and cannot classify.
            agentMessage.messageSource = .scheduled
            messageBox = agentMessage // Fill the box so the closure can read it

            // The execution limit: on expiry the run is recorded as timed out, stamped before the cancel (finalize writes
            // "Cancelled by user" only when no outcome is set), and only this run's parks are drained.
            let scheduledMessageID = agentMessage.id
            deadlineTask = Task { @MainActor [weak self] in
                do {
                    try await ComputeTimeoutSentinel.sleepUntilComputeExceeded(
                        limit: runLimit,
                        scope: runScope,
                        logTag: "SCHEDULER",
                        subject: "Scheduled run \(scheduledMessageID.uuidString.prefix(8))",
                        consequence: "the run is stopped and recorded as timed out; time spent awaiting a human was excluded.")
                } catch is AgentExecutionError {
                    guard let self else { return }
                    timedOut.isSet = true
                    agentMessage.terminalOutcome = .timedOut
                    agentMessage.terminalReason = ActiveStreamManager.executionTimeoutMessage(limit: runLimit)
                    self.activeStreamManager.cancelStream(for: scheduledMessageID)
                    await ExecutionSuspensionService.shared.cancel(scope: runScope)
                } catch {
                    return   // the run finished first and cancelled the deadline
                }
            }
        }
    }
}

/// Set by a scheduled run's deadline, read by its completion — both on the main actor.
@MainActor
final class ScheduledRunFlag {
    var isSet = false
}
