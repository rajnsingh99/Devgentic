// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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

    /// Weak back-reference to the VM, and OPTIONAL: the send path no longer needs it at all.
    ///
    /// ⚠️ ONE use remains, in `ensureConversation` — `updateBackendForCurrentConversation(...)`,
    /// so this coordinator stays oblivious to its sibling coordinators. Everything else this
    /// comment used to list is gone: the shared streaming slot was deleted 2026-08-17 (see the
    /// body notes at the old set site), and `messagingCoordinator.createUserMessage(...)` was
    /// replaced on 2026-09-06 by the static `MessagingCoordinator.makeUserMessage` with an
    /// injected `FileProcessorService`. A nil VM therefore degrades exactly one thing, and that
    /// degradation is logged where it happens rather than swallowed by the optional chain.
    private weak var viewModel: MainApplicationViewModel?

    private let persistenceService: ChatPersistenceProtocol

    /// ⚠️ The SEAM, not the concrete manager. This surface only starts a run and cancels the one
    /// it started, and depending on `MessageStreamStarting` is what lets a test observe the
    /// hand-off — which is how the invariant #8 violation this path shipped went uncaught.
    private let activeStreamManager: any MessageStreamStarting

    /// Needed only to build the user message. Previously reached through
    /// `viewModel!.messagingCoordinator`, which made the whole send path untestable.
    private let fileProcessorService: FileProcessorService

    /// Workflow-run bookkeeping, as the narrow protocol rather than the view model. Its own
    /// header says why (`WorkflowRunBootstrap.swift:40-43`): constructing a
    /// `MainApplicationViewModel` claims `HITLPresenter` globally, loads settings, and — via
    /// `ChatOpsCoordinator.bootstrap()` — opens real Telegram/Discord/Slack connections.
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

        // Persist the profile→conversation mapping via the VM's forward
        // (which lands in ConversationManagementCoordinator).
        //
        // ⚠️ NOT a bare optional chain. `viewModel` became optional on 2026-09-06 so the send path
        // could be constructed without one; with a nil VM this call evaporates, and an optional
        // chain would do that in silence while the success log below still printed.
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

    /// Persists a scheduled run's question, before the send.
    ///
    /// ⚠️ ORDER. This is awaited before `startMessageStream`, but NOT because the request would
    /// otherwise lose the question: `deriveHistory` passes `inMemory: [userMessage]` and
    /// `BackendHistoryResolver.merge` keeps in-memory-only rows unconditionally, so the question
    /// is in the derived history whether or not the write has landed. (An earlier version of this
    /// comment claimed the opposite and was contradicted by the `inMemory` note further down its
    /// own block.) What the order does buy is that the DURABLE row exists before anything can
    /// fail: a run that dies between here and the send leaves a question the user can see, and
    /// nothing downstream has to reconstruct it.
    ///
    /// ⚠️ It used to also resolve that history and return it. `ActiveStreamManager` derives it now,
    /// so the result was read by NOBODY — the caller was `_ = await …` — while still costing a
    /// full `fetchMessages(limit: 300)` on every firing, and `fetchMessages` runs `toChatMessage()`
    /// per row, decoding timeline and token blobs and materialising every attached image's full
    /// `binaryData`, on the main actor (see `ChatPersistenceProtocol.fetchSearchDocuments`, which
    /// exists precisely because that cost was judged too high for ⌘F). A recurring task in a long
    /// conversation paid it twice per run and used the second copy. Removed 2026-09-07.
    ///
    /// ⚠️ The `will carry: N` log line went with it: `deriveHistory` omits turns still being
    /// written, so a pre-flight count could ASSERT a number the request did not deliver — a
    /// discrepancy that reads as a derivation bug rather than a stale pre-flight.
    ///
    /// ⚠️ THE REST OF THIS BLOCK IS HISTORY, not a description of this function. It records why
    /// the resolve that used to live here existed, because the reasoning still governs
    /// `ActiveStreamManager.deriveHistory`, which now does it. This function's whole body is one
    /// `addMessage` and one log line — no resolve, no window, no `inMemory:`.
    ///
    /// ⚠️ WHY THE RESOLVER, not `fetchMessages`. The scheduled send used to be a raw
    /// `fetchMessages(offset: 0, limit: 50)` handed VERBATIM to `startMessageStream`.
    /// `ChatPersistenceStore.fetchMessages` sorts `SortDescriptor(\.timestamp, order: .reverse)`,
    /// so scheduled runs shipped DESCENDING history into `EpisodicHistoryFormatter.pairTurns`,
    /// which walks forward. That violated `architecture_readme.md` §7 invariant #8 and produced
    /// three silent defects from the one bug:
    ///   1. Every reply was paired with the WRONG question, and the newest agent turn was dropped
    ///      entirely — n turns in, n-1 mispaired turns out.
    ///   2. The conversation's oldest user message came out as an orphan marked
    ///      wasCancelled / "Agent never responded to this query".
    ///   3. `BackendOrchestrationService`'s duplicate-query strip inspects `.last`, which on a
    ///      descending array is the OLDEST row. So the current query was double-prompted — and on
    ///      a RECURRING task, where every firing sends the same prompt, the text comparison
    ///      matched that oldest row instead and silently DELETED the conversation's first turn.
    ///
    /// The resolver also raised the window from 50 to `BackendHistoryResolver.messageLimit` (300),
    /// deliberately: a scheduled turn must not get a smaller view of the conversation than the
    /// desktop UI would give it — the rule ChatOps already follows
    /// (`MessagingCoordinator.submitRemoteMessage`). `deriveHistory` preserves that.
    ///
    /// `static` + internal so the contract is testable without a `MainApplicationViewModel` (whose
    /// init calls `ChatOpsCoordinator.bootstrap()`, which starts REAL network listeners when the
    /// developer has ChatOps enabled) and without launching a live backend stream. Same reason
    /// `MessagingCoordinator.deliverCheckpoint` is extracted. Pinned by `SchedulerCoordinatorTests`.
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

    /// How a scheduled run ended (HITL Waiting Contract §3). The task record and its notification
    /// used to say "completed" for every outcome — timeouts, error cards, a missing conversation
    /// (Timeout inventory D-13).
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

    /// A scheduled run's execution limit when its profile sets none (Contract §5, owner decision
    /// 2026-09-27). Replaces the fixed 600 s WALL-clock deadline, which counted parks and queue
    /// time, ignored the profile's own `executionTimeout`, and killed any run longer than ten minutes.
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

        // ⚠️ REGISTRY CHECK BEFORE THE DURABLE WRITE. This guard used to sit below the persist,
        // so a missing registry left the user's scheduled question in the store with nothing
        // answering it — `pairTurns` then reports that row to the model as a turn the agent
        // abandoned. Refusing before anything is written leaves the conversation untouched.
        //
        // ⚠️ AND ONLY FOR WORKFLOW PROFILES. `WorkflowRunBootstrap.begin` returns nil for every
        // other profile type without touching the registry, so aborting a bot or agent run for a
        // missing registry refused work that never needed it — while the log line said in so many
        // words that "non-workflow profiles are unaffected".
        if config.profile.profileType == .workflow, runRegistry == nil {
            logger.error("[WF_RUN] Scheduled WORKFLOW run for conversation \(conversationID.uuidString.prefix(8)) has NO run registry — the coordinator outlived it. CONSEQUENCE: the run is refused BEFORE its question is persisted, so nothing is left unanswered in the conversation; the schedule reports an error and will fire again on its next occurrence. Bot/agent/imageGen schedules are unaffected and are not refused here.")
            return ScheduledRunResult(summary: "Error: run registry unavailable.", outcome: .failed)
        }

        // Create user message via the messaging coordinator's factory (same
        // text/image file classification logic as the UI send path).
        // Same factory the UI send path uses, reached WITHOUT the view model — see
        // `MessagingCoordinator.makeUserMessage` for why that mattered.
        let userMessage = await MessagingCoordinator.makeUserMessage(
            conversationID: conversationID,
            query: prompt,
            files: fileItems,
            fileProcessorService: fileProcessorService,
            deliveryMode: AttachmentDeliveryMode.resolve(for: config.profile)
        )
        // ⚠️ Set BEFORE the send, exactly as QuickAccess and Orb do. Only the AGENT message
        // carried `.scheduled`, so `[STREAM_START]` — which reads the source off the USER message
        // to name the surface that started a run — reported every scheduled run as `localUI`.
        //
        // ⚠️ "Before PERSISTING" is incidental, not a durability requirement: `messageSource` is
        // TRANSIENT (`ChatMessage.swift`, "not persisted"), has no column, and `toChatMessage()`
        // does not restore it — every reloaded row reads `.localUI` regardless. An earlier version
        // of this comment justified the assignment by naming ChatOps mirroring, analytics and the
        // audit trail; none of them read this field. Its only readers are two `[STREAM_START]`-side
        // log interpolations and `OrbAmbientRunWatcher`, all in-process.
        userMessage.messageSource = .scheduled
        await Self.persistScheduledQuestion(
            userMessage: userMessage,
            conversationID: conversationID,
            persistence: persistenceService,
            logger: logger
        )

        // Start stream and await completion.
        // Use a box to break the forward-capture cycle: the closure captures
        // `messageBox` (already declared), and we fill it after the call returns.
        // The run's EXECUTION LIMIT (HITL Waiting Contract, decision C): the profile's
        // `executionTimeout`, else 30 min — COMPUTE, credited to this run's own scope, so time a
        // park it owns stays open is not counted (decision 1) and nothing outside it is touched.
        let runLimit = Self.scheduledRunLimit(for: config.profile, taskLimit: taskLimit)
        let runScope = UUID()
        await ExecutionSuspensionService.shared.registerScope(runScope, conversationID: conversationID, attended: false)
        // Nesting: the run is the outermost budget — a turn, node or tool inside it is shortened to
        // fit, so its own timeout (and a workflow's error branch) fires before the run is cut off.
        let runFrame = await ExecutionBudget.frame(
            owner: "the scheduled run's \(ToolExecutionMediator.describe(runLimit)) limit",
            limit: runLimit, scope: runScope)
        // Workflow bookkeeping (no-op for other profile types). Without it a scheduled workflow
        // run left NO record at all — and history is the only surface an unattended run can be
        // reviewed from. It also flips HITL attribution to `.workflow`, which matters here more
        // than anywhere: a gate in a scheduled run parks under a banner nobody is watching, and
        // the 600 s deadline below kills the run if it goes unanswered.
        // ⚠️ Returns nil for every non-workflow profile, so the registry is untouched on the
        // ordinary scheduled path — which is why a nil registry is refused ABOVE, before the
        // persist, and only for workflow profiles. Reaching here with a nil registry therefore
        // means a non-workflow run, which needs no ticket.
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
            // ⚠️ UNATTENDED. Bound around `startMessageStream` so every task the stream spawns —
            // BOS, AgentConnect, the workflow executor, nested sub-workflows — inherits it. A
            // Router's ambiguity arbitration checks this and takes FIRST MATCH instead of parking:
            // a scheduled run renders no banner, so a park here only ever ended one way — the
            // 600s run deadline cancelling the whole run.
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

                    // ✅ The unguarded shared-slot clear that used to live here was DELETED
                    // 2026-08-17 (design doc increment 1) along with the slot itself. It nil'd the
                    // slot regardless of ownership, orphaning whichever run had superseded this
                    // one. There is nothing to release: the composer derives its state from
                    // ActiveStreamManager, which this run's finalize already updates.
                    self?.logger.info("[RUN_LIFECYCLE] scheduled run ended (\(String(describing: outcome))) for conversation \(conversationID.uuidString.prefix(8)).")

                    continuation.resume(returning: ScheduledRunResult(summary: summary, outcome: outcome))
                }
                )
                } }
            }
            // Attribute the unattended run, exactly as ChatOps and QuickAccess attribute theirs.
            // ⚠️ Must be set AFTER `startMessageStream` returns — every caller assigns here, so
            // the mirror's didStartStream always sees `.localUI` and cannot be used to classify.
            agentMessage.messageSource = .scheduled
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

            // The execution limit. On expiry the run is recorded as TIMED OUT — stamped BEFORE the
            // cancel, because the stream's finalize only writes "Cancelled by user" when no outcome
            // is set yet (the 600 s deadline used to be reported as the user's Stop) — and only
            // THIS run's parks are drained. The old conversation-wide drain also resolved the
            // banners of an attended run this one was queued behind (Timeout inventory D-20).
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
