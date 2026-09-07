//
//  MessagingCoordinator.swift
//  Devgentic
//
//  Owns the message-sending pipeline: local sends, remote (ChatOps) submissions,
//  response regeneration, stream cancellation, HITL resolutions, and the shared
//  `createUserMessage` factory. Extracted from `MainApplicationViewModel` as the
//  biggest piece of the Gap C god-object split — before extraction these methods
//  accounted for ~360 of the VM's lines.
//
//  Dependency posture:
//
//  - Services used directly (persistence, streaming, file processing, backend
//    config) are injected explicitly. The coordinator calls them without going
//    through the VM, which keeps intent legible and unit-testable.
//
//  - Shared VM state (interfaceMode, selectedConversationID, attachedFiles,
//    streaming properties, query history, workflow state) still lives on
//    `MainApplicationViewModel`. The coordinator reaches back via a weak
//    reference because moving those state properties into the coordinator
//    would be a bigger refactor (observable-binding churn across views).
//    That's deliberate scope: this pass is about *method* extraction.
//
//  A future pass could lift the stream/workflow state here, at which point
//  the weak back-reference would shrink to just interfaceMode + helpers.
//

import Foundation
import os

@MainActor
final class MessagingCoordinator {

    private let logger = DGLogger(category: "MessagingCoordinator")

    // MARK: - Dependencies

    /// Weak back-reference to the VM for the shared state it still owns
    /// (see file header). Never accessed for anything the coordinator could
    /// do on its own.
    private weak var viewModel: MainApplicationViewModel?

    private let chatHistoryViewModel: ChatHistoryViewModel
    private let activeStreamManager: ActiveStreamManager
    private let persistenceService: ChatPersistenceProtocol
    private let fileProcessorService: FileProcessorService

    /// The attachment processor this coordinator builds user messages with.
    ///
    /// Exposed so a surface that builds its own message through `makeUserMessage` can reach the
    /// one the main send path uses, rather than threading a `MessagingCoordinator` it does not
    /// otherwise need. Read-only on purpose.
    ///
    /// ⚠️ This claimed "a second instance would mean two classification paths for the same file".
    /// It would not: `FileProcessorService` is a `struct` with NO stored properties and no static
    /// state, so instances are behaviourally identical — Jarvis constructs its own at its call
    /// site, and both dispatch test files do the same. Sharing is a convenience, not an
    /// invariant. If the type ever gains state, THAT is when a real rule has to be written, and
    /// it has to be written at every construction site, not here.
    var fileProcessor: FileProcessorService { fileProcessorService }
    private let backendConfiguration: BackendConfiguration

    // MARK: - Init

    init(
        viewModel: MainApplicationViewModel,
        chatHistoryViewModel: ChatHistoryViewModel,
        activeStreamManager: ActiveStreamManager,
        persistenceService: ChatPersistenceProtocol,
        fileProcessorService: FileProcessorService,
        backendConfiguration: BackendConfiguration
    ) {
        self.viewModel = viewModel
        self.chatHistoryViewModel = chatHistoryViewModel
        self.activeStreamManager = activeStreamManager
        self.persistenceService = persistenceService
        self.fileProcessorService = fileProcessorService
        self.backendConfiguration = backendConfiguration
        registerCompactionCheckpointSink()
    }

    // MARK: - Compaction Checkpoint Sink

    /// The stream-independent delivery path for background compaction checkpoints.
    ///
    /// This coordinator is the one app-lifetime object holding BOTH halves of delivery:
    /// the persistence store and the live history array. Registered here (not per stream)
    /// because compaction runs off the request path now and can finish after the
    /// originating stream — and its events — are gone.
    private func registerCompactionCheckpointSink() {
        Task { [logger] in
            await HistoryCompactionService.shared.setCheckpointSink { [weak self, logger] checkpoint, conversationID in
                // The weak read must be main-actor isolated, but the delivery below must NOT be
                // wrapped in `MainActor.run` — that closure is SYNCHRONOUS, which is precisely
                // why the store write used to be flung into a detached `Task` and lost its
                // ordering against the splice. See `deliverCheckpoint`.
                let deps = await MainActor.run {
                    self.map { ($0.persistenceService, $0.chatHistoryViewModel) }
                }
                guard let deps else {
                    // App-teardown race only; the store write never ran, so say so.
                    logger.error("[COMPACTION] Checkpoint sink fired after coordinator teardown — checkpoint \(checkpoint.id.uuidString.prefix(8)) NOT persisted; the next launch will re-plan the same batch.")
                    return
                }
                await Self.deliverCheckpoint(
                    checkpoint,
                    conversationID: conversationID,
                    persistence: deps.0,
                    viewModel: deps.1,
                    logger: logger
                )
            }
        }
    }

    /// Delivers a compaction checkpoint: durable store FIRST, live splice SECOND.
    ///
    /// ⚠️ THE ORDER IS LOAD-BEARING, and it is the reason this is a separate function.
    ///
    /// It used to be the other way round — an UNAWAITED `Task` around `addMessage` with the
    /// splice running immediately after — and the splice's own comment said it existed "so the
    /// NEXT turn's history resolution sees it in memory too". That made
    /// `currentChatMessages` a DATA channel rather than a render window: for the width of that
    /// write it was the only copy of the checkpoint. Any history resolution that read the store
    /// alone in that window got neither the compacted turns (already removed from the batch)
    /// nor the summary standing in for them — silent context loss, with no log line. It also
    /// blocks deriving history from `ActiveStreamManager`'s own state, because a checkpoint is
    /// neither a live stream nor the message being sent (`DerivedHistorySourceTests`).
    ///
    /// With the write awaited, the store is authoritative before anything can observe the
    /// checkpoint, and the splice is RENDER-ONLY. `addMessage` is an upsert-by-id, so a repeat
    /// updates one row rather than duplicating; `insertCheckpoint` guards against a different
    /// conversation being open and against duplicate ids, and a skipped splice costs only a
    /// bubble that appears on reopen.
    ///
    /// Awaiting is free here: the sink is already invoked from a background task off the
    /// request path (`HistoryCompactionService.swift:133-139`), and holding it open until the
    /// row lands also tightens that service's duplicate-run guard — `backgroundRuns` now stays
    /// set until the checkpoint is durably stored, so a turn arriving mid-compaction cannot
    /// re-plan the same batch against a store that does not yet have it.
    ///
    /// `static` + internal so the ordering is unit-testable without a `MainApplicationViewModel`,
    /// the same reason `ChatHistoryViewModel.descendingInsertionIndex` is pure.
    /// Pinned by `CompactionCheckpointDeliveryTests`.
    static func deliverCheckpoint(
        _ checkpoint: ChatMessage,
        conversationID: UUID,
        persistence: ChatPersistenceProtocol,
        viewModel: ChatHistoryViewModel,
        logger: DGLogger
    ) async {
        await persistence.addMessage(checkpoint, toConversation: conversationID)
        logger.info("[COMPACTION] Checkpoint persisted \u{2014} messageID: \(checkpoint.id.uuidString.prefix(8)), conversationID: \(conversationID.uuidString.prefix(8)). The store is authoritative from here; the splice below is render-only.")
        viewModel.insertCheckpoint(checkpoint)
    }

    // MARK: - Message Sending

    func sendMessage(attributedString: NSAttributedString, withConfig config: BackendRequestConfig) {
        let plainUserQueryFromEditor = attributedString.string.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !chatHistoryViewModel.isSending else {
            logger.warning("[sendMessage] Message sending already in progress. Ignoring new request.")
            return
        }
        guard let vm = viewModel else {
            logger.warning("[sendMessage] view model deallocated — aborting.")
            return
        }
        guard !plainUserQueryFromEditor.isEmpty || !vm.attachedFiles.isEmpty else {
            return
        }

        // Code mode: refresh instructions (picks up context.md changes) and set selectedProfileID.
        if vm.interfaceMode == .code {
            logger.info("[CODE] ────────── Code mode send initiated ──────────")
            logger.info("[CODE] Query preview: \(String(plainUserQueryFromEditor.prefix(120)))")
            vm.prepareCodeProfileForSend()
        }

        guard let config = backendConfiguration.getRequestConfig() else {
            logger.error("[sendMessage] CRITICAL: Could not get backend request config. Is a profile selected? (interfaceMode: \(vm.interfaceMode.rawValue), selectedProfileID: \(self.backendConfiguration.selectedProfileID?.uuidString ?? "nil"))")
            return
        }

        chatHistoryViewModel.isSending = true
        let profileType: String
        switch config.profile.details {
        case .bot: profileType = "bot"
        case .agent: profileType = "agent"
        case .workflow: profileType = "workflow"
        case .imageGen: profileType = "imageGen"
        case .code: profileType = "code"
        }
        logger.info("[sendMessage] Profile: \(config.profile.displayName) (type: \(profileType), id: \(config.profile.id.uuidString.prefix(8)))")

        // Add to query history
        if !plainUserQueryFromEditor.isEmpty, vm.queryHistory.last != plainUserQueryFromEditor {
            vm.appendToQueryHistory(plainUserQueryFromEditor)
        }
        vm.resetQueryHistoryIndex() // Reset index after sending a new message

        let conversationIDToUse = vm.selectedConversationID ?? vm.createAndSelectNewConversation()

        // Persist the selected profile to the conversation at send time.
        vm.updateBackendForCurrentConversation(conversationID: conversationIDToUse, profileID: backendConfiguration.selectedProfileID)

        // Tag Code mode conversations with profileTypeRaw for sidebar filtering
        if vm.interfaceMode == .code {
            persistenceService.updateProfileType(for: conversationIDToUse, profileTypeRaw: ProfileType.code.rawValue)
        }

        // Auto-title if empty
        if let conversationSD = persistenceService.getConversation(withId: conversationIDToUse) {
            if conversationSD.userDefinedTitle == nil || conversationSD.userDefinedTitle?.isEmpty == true {
                conversationSD.userDefinedTitle = plainUserQueryFromEditor
                logger.info("Auto-setting conversation title to: \(plainUserQueryFromEditor)")
            }
        } else {
            logger.error("[sendMessage] CRITICAL: Could not find conversation for ID: \(conversationIDToUse.uuidString)")
            chatHistoryViewModel.isSending = false
            return
        }

        let filesForBackend = vm.attachedFiles
        vm.clearAttachedFiles()
        logger.debug("Cleared user input and attachments from UI.")

        Task { @MainActor [weak self] in
            guard let self, let vm = self.viewModel else { return }

            let userMessage = await self.createUserMessage(
                conversationID: conversationIDToUse,
                query: plainUserQueryFromEditor,
                files: filesForBackend
            )

            self.chatHistoryViewModel.currentChatMessages.insert(userMessage, at: 0)
            self.logger.debug("Appended user message into UI.")

            // [IMG-PERSIST] Persist the user message — which may carry a large
            // `@Attribute(.externalStorage)` image blob — and AWAIT it here, before resolving
            // history / starting the stream, rather than the old fire-and-forget Task. That
            // detached Task let this INSERT's save land LATE (only when the actor next freed at
            // the `resolveBackendHistory` await), temporally adjacent to the agent stream's first
            // flush save on the SAME autosave-enabled `mainContext` — so CoreData's async
            // external-file maintenance for the two nearby commits raced, producing the benign
            // but noisy "Failed to clone external data reference … .interim doesn't exist" log.
            // Awaiting separates the image write from the stream's first flush (the model's
            // first-token latency now sits between them) and makes the durable write ordered
            // before the run begins. History still merges the in-memory copy inserted just above,
            // so the backend sees no difference. Conversation-memory indexing happens inside
            // addMessage (ChatPersistenceStore.addMessages — the funnel all surfaces share).
            await self.persistenceService.addMessage(userMessage, toConversation: conversationIDToUse)
            self.logger.debug("User message persisted successfully (awaited before stream start).")

            // Workflow bookkeeping (no-op for every other profile type). See
            // `WorkflowRunBootstrap` for what this buys and what breaks without it — it was
            // inline here and missing from every other `startMessageStream` caller.
            let workflowTicket = WorkflowRunBootstrap.begin(
                config: config,
                conversationID: conversationIDToUse,
                userInput: plainUserQueryFromEditor,
                registry: vm,
                origin: .chat
            )

            self.logger.info("[sendMessage] Handing off to ActiveStreamManager — conversationID: \(conversationIDToUse.uuidString.prefix(8)), messageID: \(userMessage.id.uuidString.prefix(8)), files: \(filesForBackend.count). History is DERIVED by ActiveStreamManager, not passed from here.")

            // Log-only: the id is not known until `startMessageStream` returns, and the
            // completion closure is built before that. Nothing behavioural reads it.
            var agentMessageIDForLog: UUID?
            let agentMessage = self.activeStreamManager.startMessageStream(
                withConfig: config,
                userMessage: userMessage,
                promptOverride: nil,
                files: filesForBackend,
                updating: nil,
                workflowExecutionState: workflowTicket?.state,
                onComplete: { [weak self] in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.logger.info("[RUN_LIFECYCLE] send stream completed for message \(agentMessageIDForLog?.uuidString.prefix(8) ?? "?") — no slot to clear; the composer derives its state from ActiveStreamManager.")
                        workflowTicket?.finalize()
                    }
                }
            )

            agentMessageIDForLog = agentMessage.id
            self.chatHistoryViewModel.currentChatMessages.insert(agentMessage, at: 0)
            self.logger.debug("Appended agent's streaming message placeholder into UI for real-time updates.")

            await self.chatHistoryViewModel.resetSendingState()
        }
    }

    // MARK: - Response Regeneration

    func regenerateResponse(for agentMessage: ChatMessage) {
        // Cheap guard first so a refused Redo never pays for a history fetch.
        //
        // ⚠️ The `conversationBusy` arm is the INTERIM one-root-run-per-conversation rule. Without
        // it, Redo on an older message while another run streams starts a second root run whose
        // `startMessageStream` overwrites `activeTasks[messageID]`, orphaning the first run's task
        // handle permanently. The Redo button is gated per-message (`message.isStreaming`), so it
        // stays live on older messages and this is reachable with one click and no automation.
        if let refusal = RunAdmissionPolicy.admitRegeneration(
            in: agentMessage.conversationId,
            attempts: agentMessage.agentResponse?.generationAttempts,
            live: viewModel?.activeStreamManager.liveRunSnapshot() ?? []
        ) {
            logger.warning("[RUN_CLAIM] Redo REFUSED for message \(agentMessage.id.uuidString.prefix(8)) in conversation \(agentMessage.conversationId.uuidString.prefix(8)): \(refusal.logReason)")
            return
        }
        // ⚠️ THE HOP IS LOAD-BEARING, THE FETCH IS NOT. This used to `await` a full
        // store-authoritative history resolve here and hand the result to `continueRegeneration`.
        // `ActiveStreamManager` derives history now, so that result was read by nothing — a
        // discarded 300-row fetch and decode on every Redo.
        //
        // The SUSPENSION stays: the admission re-check at the top of `continueRegeneration`
        // exists precisely because this hop is a staleness window in which a scheduled task, a
        // ChatOps message or a second Redo can claim the conversation. Removing the await
        // entirely would close that window silently and make the re-check look redundant, which
        // is how it would get deleted next.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.continueRegeneration(for: agentMessage)
        }
    }

    private func continueRegeneration(for agentMessage: ChatMessage) {
        guard let vm = viewModel else { return }

        // Re-check after the actor hop — that hop is a staleness window in which a scheduled task,
        // a ChatOps message or another Redo can claim this conversation. The guards below already
        // re-validate for the same reason; admission is no different.
        //
        // ⚠️ This said "after the async history resolve". There is no resolve on this path any
        // more — only `await Task.yield()`, kept because the HOP is what creates the window the
        // guard closes, while the fetch it used to sit behind was read by nothing. `resumeRun`
        // still does resolve, so the identical wording in `continueResume` remains accurate there.
        if let refusal = RunAdmissionPolicy.admitRegeneration(
            in: agentMessage.conversationId,
            attempts: agentMessage.agentResponse?.generationAttempts,
            live: vm.activeStreamManager.liveRunSnapshot()
        ) {
            logger.warning("[RUN_CLAIM] Redo REFUSED for message \(agentMessage.id.uuidString.prefix(8)) after the actor hop (a run claimed conversation \(agentMessage.conversationId.uuidString.prefix(8)) during the hop): \(refusal.logReason)")
            return
        }

        guard let agentMessageIndex = chatHistoryViewModel.currentChatMessages.firstIndex(of: agentMessage) else {
            logger.error("Could not find agent message in chat history to regenerate.")
            return
        }

        guard let userQueryMessage = chatHistoryViewModel.currentChatMessages[safe: agentMessageIndex + 1],
              userQueryMessage.sender == .user else {
            logger.error("Could not find the preceding user query for regeneration.")
            return
        }
        let userQuery = userQueryMessage.content.textContent ?? ""

        let filesForBackend = (userQueryMessage.attachedTextFiles?.map { FileSystemItem(id: $0.url, name: $0.name, url: $0.url, isDirectory: false) } ?? []) +
                              (userQueryMessage.attachedImageFiles?.map { FileSystemItem(id: $0.url, name: $0.name, url: $0.url, isDirectory: false) } ?? [])

        guard let config = backendConfiguration.getRequestConfig() else {
            logger.error("[regenerateResponse] Could not get backend request config. Is a profile selected?")
            return
        }

        // [P0 crash fix] Single-write mutation via ChatMessage.beginRegenerationVariant —
        // the inline optional-chained writes here trapped Swift exclusivity (the
        // selectedVariantIndex line re-READ agentResponse on its RHS while the LHS
        // held the modify access) and killed the app on Retry, on-device 2026-07-19.
        guard agentMessage.beginRegenerationVariant(backendEntityId: config.profile.id) else {
            logger.warning("[regenerateResponse] Message \(agentMessage.id.uuidString.prefix(8)) not regenerable (attempt cap or no response) — no mutation performed.")
            return
        }

        // Workflow bookkeeping (no-op for other profile types). Regenerating a workflow answer
        // RE-EXECUTES the whole DAG with real side effects, so it is a genuinely new run and gets
        // its own record — without this the transcript showed a second execution that run history
        // had no trace of.
        let workflowTicket = WorkflowRunBootstrap.begin(
            config: config,
            conversationID: agentMessage.conversationId,
            userInput: userQuery,
            registry: vm,
            origin: .regenerate
        )

        // Return value intentionally unused: `updating: agentMessage` streams into that same
        // object, so the returned reference is `agentMessage` itself.
        _ = activeStreamManager.startMessageStream(
            withConfig: config,
            userMessage: userQueryMessage,
            promptOverride: nil,
            files: filesForBackend,
            updating: agentMessage,
            workflowExecutionState: workflowTicket?.state,
            onComplete: { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.logger.info("[RUN_LIFECYCLE] regeneration stream completed for message \(agentMessage.id.uuidString.prefix(8)).")
                    workflowTicket?.finalize()
                }
            }
        )
    }

    /// [G1 Piece 2] Resume an interrupted run after the app last closed. Rebuilds the in-flight reasoning
    /// state from the persisted message timeline (`TimelineTurnReconstructor`) and re-enters the agent loop
    /// by streaming back into the SAME bubble via `startMessageStream(updating:)`. Two cases:
    ///   • `.parkedHITL` — the run was idle on a HITL banner; the dangling tool is re-raised + re-run.
    ///   • `.streaming` — the run died mid-compute; the dangling (mid-execution) tool is DROPPED (its side
    ///     effect may have partially happened, so it is not replayed or re-run) and the agent re-decides
    ///     from the completed work.
    /// Scope: plain-ReAct native agent profiles only; guards refuse a capability-wrapped profile or a
    /// provider/dialect that drifted since the run started.
    func resumeRun(for agentMessage: ChatMessage) {
        // Cheap guard first so a refused resume never pays for a history fetch.
        if let refusal = RunAdmissionPolicy.admitResume(
            in: agentMessage.conversationId,
            live: viewModel?.activeStreamManager.liveRunSnapshot() ?? []
        ) {
            logger.warning("[RUN_CLAIM] Resume REFUSED for message \(agentMessage.id.uuidString.prefix(8)) in conversation \(agentMessage.conversationId.uuidString.prefix(8)): \(refusal.logReason)")
            return
        }

        // Resolve the replay history up front (store-authoritative — a resume must not
        // replay less context than the original run had), then run the ENTIRE original
        // body synchronously and in order. Splitting it this way keeps every guard and
        // mutation of this G1 path exactly where it was.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let resolved = await self.resolveBackendHistory(
                before: agentMessage,
                conversationID: agentMessage.conversationId
            )
            self.continueResume(for: agentMessage, resolvedHistory: resolved)
        }
    }

    private func continueResume(for agentMessage: ChatMessage, resolvedHistory: [ChatMessage]) {
        guard let vm = viewModel else { return }

        // ⚠️ THE LOAD-BEARING GUARD. Re-check after the async history resolve: the Resume chip
        // stays live throughout that hop (the message has not started streaming yet), so a
        // double-press lands two runs on ONE message. The second `startMessageStream(updating:)`
        // would overwrite `activeTasks[messageID]` and leave the first run's Task unreachable by
        // `cancelStream(for:)` forever. From here to `startMessageStream` there is no suspension
        // point, so the claim is atomic on the main actor.
        if let refusal = RunAdmissionPolicy.admitResume(
            in: agentMessage.conversationId,
            live: vm.activeStreamManager.liveRunSnapshot()
        ) {
            logger.warning("[RUN_CLAIM] Resume REFUSED for message \(agentMessage.id.uuidString.prefix(8)) after the history resolve (a run claimed conversation \(agentMessage.conversationId.uuidString.prefix(8)) during the hop): \(refusal.logReason)")
            return
        }

        // Resume kind from the persisted lifecycle: parked (re-raise the dangling tool) vs streaming
        // (drop the dangling tool). `.final` is not interrupted → nothing to resume.
        let parkedOpID: UUID?
        let isStreamingResume: Bool
        switch agentMessage.lifecycleState {
        case .parkedHITL(let opID):
            parkedOpID = opID
            isStreamingResume = false
        case .streaming:
            parkedOpID = nil
            isStreamingResume = true
        case .final:
            logger.warning("[resumeRun] Message \(agentMessage.id.uuidString) is not interrupted — nothing to resume.")
            return
        }

        // Recover the profile that produced this run (the per-variant backendEntityId, matching the
        // selected variant — survives restart inside the persisted agentResponse).
        guard let resp = agentMessage.agentResponse,
              resp.variants.indices.contains(resp.selectedVariantIndex),
              let profileID = resp.variants[resp.selectedVariantIndex].backendEntityId,
              let profile = try? BackendProfileStore.shared.fetchProfile(byId: profileID) else {
            finalizeUnresumable(agentMessage,
                reason: "This run's profile could no longer be found — it may have been deleted. Send the request again.")
            return
        }

        // Scope: plain-ReAct executors only — .agent AND .code without capability wrappers
        // (Code sessions are always plain ReAct; the check is defensive). Capability-wrapped
        // Planning/Reflexion agents stay excluded: their wrapper owns iter-1 seeding + episode
        // lifecycle, which the resume preamble would corrupt. Workflow-resume is not
        // implemented (deferred). EVERY unresumable path FINALIZES the message with a visible
        // reason — a silent return leaves a permanently dead Resume chip.
        let resumeRefusalReason: String? = {
            switch profile.details {
            case .agent(let config), .code(let config):
                return (config.capabilities.planning == nil && config.capabilities.selfReflection == nil)
                    ? nil
                    : "Resume isn't supported for Planning/Reflexion-wrapped agents — send the request again."
            case .workflow:
                return "Workflow runs can't be resumed after an interruption yet — start the run again."
            case .bot, .imageGen:
                return "Resume isn't supported for this profile type — send the request again."
            }
        }()
        if let resumeRefusalReason {
            finalizeUnresumable(agentMessage, reason: resumeRefusalReason)
            return
        }

        // Dialect / provider guard: the reconstructed native turns are only valid for the same provider
        // family. If the profile's model was swapped since the park, refuse rather than feed mismatched
        // turns to the wrong adapter.
        guard let llm = profile.resolvedLLMConfig else {
            finalizeUnresumable(agentMessage,
                reason: "The profile no longer has a usable model configuration — send the request again.")
            return
        }
        if let stampedProvider = agentMessage.apiProvider, stampedProvider != llm.apiProvider.rawValue {
            finalizeUnresumable(agentMessage,
                reason: "The profile's provider changed since this run was interrupted (\(stampedProvider) → \(llm.apiProvider.rawValue)) — send the request again.")
            return
        }
        if let stampedDialect = agentMessage.modelDialect, stampedDialect != llm.modelDialect.rawValue {
            finalizeUnresumable(agentMessage,
                reason: "The profile's model changed since this run was interrupted — send the request again.")
            return
        }

        // ⚠️ The timeline must be a FAITHFUL record before it can drive a resume. Resuming rebuilds
        // the model's view of what already happened, so an event this build could not read is not a
        // cosmetic gap — a completed `.toolExecution` that survived only as `.unknown` is invisible
        // to the reconstructor, so the model has no record it already ran that tool and will run it
        // AGAIN. For a side-effectful tool (a shell command, a file write) that is a real-world
        // repeat, not a display glitch.
        //
        // Refusing costs some runs that would in fact have resumed fine — an unrecognised
        // warning-class event is harmless. That trade is deliberate: the alternative is silently
        // repeating work, and the refusal gives the user a full sentence instead of a dead end.
        if agentMessage.timelineIsDegraded {
            logger.error(
                "[resumeRun] Refusing resume for message \(agentMessage.id.uuidString.prefix(8)): the "
                + "timeline is not a faithful record (decodeFailed=\(agentMessage.timelineDecodeFailed), "
                + "unreadableEvents=\(agentMessage.flattenedTimelineEvents.filter(\.isUnknown).count)). "
                + "CONSEQUENCE: the reconstructed prefix would omit completed tool calls, so resuming "
                + "could re-run side-effectful tools that already ran. The run is finalized instead."
            )
            finalizeUnresumable(agentMessage,
                reason: "Part of this run's record can't be read by this version, so resuming might repeat work that already happened — send the request again.")
            return
        }

        // Rebuild the in-flight state from the persisted timeline. Streaming resume DROPS the dangling
        // tool; parked resume keeps it to re-raise.
        // Flattened: a run parked inside a plan subtask / reflection trial keeps its tool
        // and reasoning events nested in the capability card — the reconstructor needs them.
        let reconstruction = TimelineTurnReconstructor.reconstruct(
            from: agentMessage.flattenedTimelineEvents,
            parkedOperationID: parkedOpID,
            dropDanglingTool: isStreamingResume
        )
        // Parked resume needs the dangling tool to re-raise. Streaming resume drops it and continues from
        // whatever completed work exists (possibly none → effectively a clean re-run of the task), so it
        // has no such precondition.
        if !isStreamingResume {
            guard reconstruction.parkedTool != nil else {
                finalizeUnresumable(agentMessage,
                    reason: "The interrupted state is incomplete and can't be resumed — send the request again.")
                return
            }
        }

        // Deliberately NOT finalized: this is a transient UI-state guard (the chip
        // renders from the message's own bubble, so this shouldn't fire) — the run
        // may be perfectly resumable from the right conversation view.
        guard let idx = chatHistoryViewModel.currentChatMessages.firstIndex(of: agentMessage) else {
            logger.error("[resumeRun] Message not in the current conversation; aborting resume.")
            return
        }
        // History strictly below this message + the originating user query (same slice regenerate uses).
        // The user query is normally the adjacent resident message; fall back to the last
        // user turn in the resolved history when the pair straddles the residency cap.
        // ⚠️ OPTION A (decided 2026-09-06): resume REFUSES when it cannot identify the question,
        // rather than replaying with an empty one.
        //
        // This used to fall through to `?? ""`, which asked the model to redo a turn with no
        // question attached — a silent degradation of the very feature resume exists to provide.
        // It also cannot survive the derived-history contract: `startMessageStream` needs the
        // user's MESSAGE (for its id and conversation), and there is no honest message to
        // synthesize when none was found.
        //
        // The adjacent-resident lookup is kept as the fast path but is POSITIONAL, so it is now
        // sender-checked; the resolved-history scan is the reliable fallback for a pair that
        // straddles the residency cap. A run being resumed has a question by definition, so
        // reaching the refusal means the transcript is genuinely inconsistent.
        let adjacentResident = chatHistoryViewModel.currentChatMessages[safe: idx + 1]
        let userQueryMessage = (adjacentResident?.sender == .user ? adjacentResident : nil)
            ?? resolvedHistory.last(where: { $0.sender == .user })
        guard let userQueryMessage else {
            logger.error("[resumeRun] No user message found for \(agentMessage.id.uuidString.prefix(8)) — neither the adjacent resident row nor the resolved history holds one. CONSEQUENCE: the resume is refused and the chip is retired rather than re-running the turn with an empty query.")
            finalizeUnresumable(agentMessage, reason: String(localized: "This run can’t be resumed — its original question is no longer in the conversation."))
            return
        }

        // Drop the stale dangling tool card (the parked tool, still marked isExecuting from before the
        // quit) so the re-raised tool renders fresh instead of duplicating. Completed cards stay.
        agentMessage.timelineEvents.removeAll { event in
            if case .toolExecution(let data) = event { return data.isExecuting || data.output == nil }
            return false
        }
        // Same cleanup one level down: dangling tools nested inside plan/reflection cards,
        // plus closing any card the interruption left open (the resumed continuation streams
        // new top-level events, never back into the old card).
        agentMessage.sanitizeCapabilityCardsForResume()

        // Flip back to a live, streaming state — hides the interrupted chip, re-enables indicators.
        agentMessage.isStreaming = true

        // [G1] Reflect the recovery in the durable HITL audit: the parked HITL the launch reconcile
        // stamped "interrupted" is now being resumed, so flip its row to "resumed". Parked-only — a
        // streaming resume has no parked operationID and no HITL audit row to update.
        if let opID = parkedOpID {
            Task { await TraceRecorder.shared.recordHITLResumed(operationID: opID.uuidString) }
        }

        // ⚠️ No `WorkflowRunBootstrap` here, deliberately: resume REFUSES workflow profiles up
        // front ("Workflow runs can't be resumed after an interruption yet", :399-400), so this
        // path is unreachable for them. If workflow resume is ever implemented, bootstrap here
        // too — `ActiveStreamManager`'s [WF_RUN] guard-rail will say so loudly in the meantime.
        // Return value intentionally unused: `updating: agentMessage` streams into that same
        // object, so the returned reference is `agentMessage` itself.
        _ = activeStreamManager.startMessageStream(
            withConfig: BackendRequestConfig(profile: profile),
            userMessage: userQueryMessage,
            promptOverride: nil,
            files: [],
            updating: agentMessage,
            resumeState: reconstruction,
            onComplete: { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.logger.info("[RUN_LIFECYCLE] [resumeRun] resume stream completed for message \(agentMessage.id.uuidString.prefix(8)).")
                }
            }
        )
    }

    /// Marks an interrupted message as definitively non-resumable: visible reason on
    /// the bubble, `.final` lifecycle (removes the Resume chip), persisted. Every
    /// unresumable path in `resumeRun` must route here — a bare `return` leaves a
    /// permanently dead Resume chip that does nothing when clicked.
    private func finalizeUnresumable(_ agentMessage: ChatMessage, reason: String) {
        logger.warning("[resumeRun] \(reason) Finalizing interrupted message \(agentMessage.id.uuidString).")
        agentMessage.isStreaming = false
        agentMessage.lifecycleState = .final
        agentMessage.terminalOutcome = .cancelled
        agentMessage.terminalReason = reason
        // [CF-44] This is the LAST word on the run — no resume will follow, so any row still
        // marked executing would spin forever with nothing left to settle it. The decode-time
        // repair deliberately spares `.parkedHITL` messages (their dangling row is what resume
        // re-raises); this is the path where that sparing ends, so close them here.
        let closed = agentMessage.closeDanglingToolRows(outcome: .cancelled)
        if closed > 0 {
            logger.warning("[resumeRun] Closed \(closed) dangling tool row(s) on message \(agentMessage.id.uuidString.prefix(8)) while marking it unresumable. CONSEQUENCE: the rows settle as cancelled instead of animating a spinner forever on a run that can no longer be resumed.")
        }
        let conversationID = agentMessage.conversationId
        Task { await persistenceService.addMessage(agentMessage, toConversation: conversationID) }
    }

    func cancelStreamingResponse() {
        guard let vm = viewModel else { return }

        // Stop targets the run in the conversation ON SCREEN — never an app-global slot. A
        // background scheduled / ChatOps / QuickAccess run in another conversation is deliberately
        // out of reach here; it is stopped by opening its conversation (or from its own panel).
        let live = vm.activeStreamManager.liveRunSnapshot()
        let selected = vm.selectedConversationID
        let candidates = ForegroundRunResolver.liveRuns(in: selected, from: live)

        guard let target = ForegroundRunResolver.foregroundRun(live: live, selectedConversation: selected) else {
            logger.warning("[RUN_STOP] Stop pressed for conversation \(selected?.uuidString.prefix(8) ?? "<none>") but no run is live there (\(live.count) live app-wide). CONSEQUENCE: Stop is a no-op; any run streaming in another conversation is untouched, which is the intended scope boundary.")
            return
        }

        if candidates.count > 1 {
            // Should be impossible under the product model (one root run per conversation) and
            // will be refused at claim time by admission control. Until then Redo on an older
            // message while a newer run streams can produce it, so say so rather than pick silently.
            logger.error("[RUN_STOP] ⚠️ conversation \(target.conversationID.uuidString.prefix(8)) holds \(candidates.count) live runs: \(candidates.map { $0.messageID.uuidString.prefix(8) }.joined(separator: ", ")). CONSEQUENCE: Stop cancels only \(target.messageID.uuidString.prefix(8)) (most recently started, unparked first); the others keep streaming and must be stopped by pressing Stop again.")
        }

        logger.info("[RUN_STOP] Cancelling run \(target.messageID.uuidString.prefix(8)) in conversation \(target.conversationID.uuidString.prefix(8)) (parked: \(target.isParked)) — user pressed Stop.")
        activeStreamManager.cancelStream(for: target.messageID)

        // [HITL/P0] If a HITL banner is up for this conversation, drain the parked suspension
        // immediately so Stop returns at once. The suspend* cancellation handlers cover the
        // task-cancellation path; this also covers a suspension whose owning task isn't the one
        // we just cancelled (defensive, idempotent — resume on a resolved op is a no-op).
        //
        // ⚠️ Still CONVERSATION-scoped, not run-scoped: it drains every park in the target's
        // conversation. Acceptable while one root run per conversation holds, but it does reach a
        // sibling workflow NODE's park within the same run. Run-scoping is design-doc increment 2,
        // deferred with per-node stop.
        let conversationID = target.conversationID
        Task { await ExecutionSuspensionService.shared.cancel(for: conversationID) }
    }

    // MARK: - [HITL] Human-in-the-Loop Permissions

    /// Submits the user's decision (Approve/Deny) for a pending tool execution.
    func submitToolApproval(operationID: UUID, approved: Bool, editedArguments: [String: JSONValue]? = nil) {
        logger.info("[HITL] Submitting approval decision: \(approved) for operation \(operationID)\(editedArguments != nil ? " (edited args)" : "")")
        Task {
            await ExecutionSuspensionService.shared.resume(for: operationID, approved: approved, editedArguments: editedArguments)
        }
    }

    /// Submits the user's text response (or nil for skip) for a pending clarification request.
    func submitClarificationResponse(operationID: UUID, response: String?) {
        logger.info("[ASK_USER] Submitting clarification response for operation \(operationID)")
        Task {
            await ExecutionSuspensionService.shared.resumeClarification(for: operationID, userInput: response)
        }
    }

    /// Submits the user's plan review decision — approved (with edited subtasks) or rejected (nil).
    func submitPlanReview(operationID: UUID, editedPlan: [SubTask]?) {
        logger.info("[PLAN_REVIEW] Submitting plan review for \(operationID), approved: \(editedPlan != nil)")
        Task {
            await ExecutionSuspensionService.shared.resumePlanReview(for: operationID, editedPlan: editedPlan)
        }
    }

    /// [E1] Submits the user's chosen option for a pending workflow Gate — routes to that option's port.
    func submitGateChoice(operationID: UUID, option: String) {
        logger.info("[GATE] Submitting gate choice '\(option)' for operation \(operationID)")
        Task {
            await ExecutionSuspensionService.shared.resumeGate(for: operationID, chosenOption: option)
        }
    }

    // MARK: - Remote Message Submission (ChatOps Single-Path)

    /// Submits a message from a remote transport (Telegram, Discord, etc.) through the SAME
    /// flow as the Mac UI's `sendMessage()`. This ensures:
    /// - The message appears in Mac UI chat history
    /// - HITL banners work identically on both surfaces
    /// - The agent response streams through ActiveStreamManager (not a truncated summary)
    ///
    /// The `RemoteMirrorService` observes the resulting stream and mirrors events back to the transport.
    func submitRemoteMessage(
        prompt: String,
        conversationID: UUID,
        source: MessageSource,
        config: BackendRequestConfig
    ) {
        guard let conversationSD = persistenceService.getConversation(withId: conversationID) else {
            logger.error("[ChatOps] Could not find conversation for ID: \(conversationID.uuidString)")
            return
        }
        guard let vm = viewModel else {
            logger.warning("[ChatOps] submitRemoteMessage aborted — view model deallocated.")
            return
        }

        // Auto-title if empty (same as sendMessage)
        if conversationSD.userDefinedTitle == nil || conversationSD.userDefinedTitle?.isEmpty == true {
            conversationSD.userDefinedTitle = prompt
        }

        // Auto-navigate Mac UI to this conversation so the user can see remote activity,
        // HITL banners, and agent responses in real-time. Setting selectedConversationID
        // triggers the conversation loader which loads messages and merges active streams.
        if vm.selectedConversationID != conversationID {
            logger.info("[ChatOps] Auto-navigating Mac UI to conversation \(conversationID.uuidString).")
            vm.selectedConversationID = conversationID
        }

        Task { @MainActor [weak self] in
            guard let self, let vm = self.viewModel else { return }

            let userMessage = await self.createUserMessage(conversationID: conversationID, query: prompt, files: [])
            userMessage.messageSource = source

            // Insert into Mac UI — the conversation is now guaranteed to be selected
            self.chatHistoryViewModel.currentChatMessages.insert(userMessage, at: 0)

            Task { [persistenceService = self.persistenceService] in
                await persistenceService.addMessage(userMessage, toConversation: conversationID)
            }

            // History is DERIVED by ActiveStreamManager now, so a remote turn gets exactly the
            // same view of the conversation as the desktop UI by construction rather than by
            // this call site remembering to ask for it.

            // Workflow bookkeeping (no-op for other profile types) — a remote-triggered workflow
            // run must leave the same reviewable record a desktop one does, and its HITL must
            // reach the workflow interface rather than chat.
            let workflowTicket = WorkflowRunBootstrap.begin(
                config: config,
                conversationID: conversationID,
                userInput: prompt,
                registry: vm,
                origin: .chatOps
            )

            // ⚠️ UNATTENDED — same binding as the scheduler's, for the same reason: a Router's
            // ambiguity arbitration must take first-match instead of parking, because a bridge
            // run has NO container deadline at all and an unanswered park is forever.
            //
            // ⚠️ …BUT A HUMAN IS REACHABLE (WF-SE6/SE11). `RemoteMirrorService` mirrors this run's
            // HITL requests to Telegram/Slack/Discord with tappable Approve/Deny and resolves them
            // through `handleApproval`, so a tool CONFIRMATION here must still park and mirror —
            // refusing it would delete a shipped capability whose only remedy for a plain agent
            // chat is disabling Ask-first globally. The two flags answer different questions; see
            // `WorkflowRunAttendance.hasRemoteResponder`.
            let agentMessage = WorkflowRunAttendance.$hasRemoteResponder.withValue(true) {
            WorkflowRunAttendance.$isAttended.withValue(false) {
                self.activeStreamManager.startMessageStream(
                withConfig: config,
                userMessage: userMessage,
                promptOverride: nil,
                files: [],
                updating: nil,
                workflowExecutionState: workflowTicket?.state,
                onComplete: { [weak self] in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.logger.info("[RUN_LIFECYCLE] [ChatOps] Remote stream completed for conversation \(conversationID.uuidString.prefix(8)).")
                        workflowTicket?.finalize()
                    }
                }
                )
            }
            }

            agentMessage.messageSource = source

            // Insert agent streaming message into Mac UI
            self.chatHistoryViewModel.currentChatMessages.insert(agentMessage, at: 0)
        }
    }

    // MARK: - Backend History Resolution

    /// Upper bound on messages pulled from the store for model context. Downstream already
    /// trims to the model's real budget (`charBudget`, the `recentHistory` /
    /// `nativeHistoryTurns` limits), so this only bounds fetch+decode cost on a very long
    /// conversation — it is not the context policy.
    /// Kept as the coordinator's own name for the shared limit so existing call sites and
    /// log copy stay put; the value lives on `BackendHistoryResolver`.
    private static let backendHistoryMessageLimit = BackendHistoryResolver.messageLimit

    /// Resolves the conversation history handed to the backend, oldest-first.
    ///
    /// STORE-AUTHORITATIVE, ALWAYS. `currentChatMessages` is the UI's *pagination window*
    /// (20 messages on open, +10 per scroll upward, capped at `maxResidentMessages`), so
    /// deriving history from it makes the model's memory depend on how far the user
    /// happened to scroll. What the model sees is a context concern; what the list renders
    /// is a rendering concern, and the two must not be the same value.
    ///
    /// This previously short-circuited to the in-memory window whenever
    /// `canLoadMorePages == false` ("the whole conversation is loaded, so the window IS the
    /// conversation"). That held only while nothing could shrink the window — it made
    /// `canLoadMorePages` silently load-bearing for model memory, so any future eviction or
    /// residency cap would have truncated the model's history with no visible symptom. The
    /// fetch is bounded and conversation-scoped; correctness beats saving it.
    ///
    /// In-memory messages are merged OVER the stored ones, never replaced by them: the
    /// just-sent user message is persisted in a DETACHED task that may not have landed yet,
    /// and in-flight streaming messages are never in the store. Dropping either would
    /// silently omit the user's own question from the request that answers it.
    private func resolveBackendHistory(conversationID: UUID) async -> [ChatMessage] {
        let inMemory = chatHistoryViewModel.currentChatMessages
        let resolved = await BackendHistoryResolver.resolve(
            conversationID: conversationID,
            inMemory: inMemory,
            persistence: persistenceService
        )
        logger.info("[HISTORY] Resolved backend history — stored: \(resolved.storedCount), in-memory: \(inMemory.count), merged: \(resolved.history.count)\(resolved.capHit ? ", CAP HIT (\(BackendHistoryResolver.messageLimit)) → older turns are omitted from direct context and rely on RAG retrieval" : ""), conversationID: \(conversationID.uuidString.prefix(8))")
        return resolved.history
    }

    /// History strictly OLDER than `message`, oldest-first — the slice a regeneration or a
    /// resume must replay. Store-authoritative for the same reason as above: regenerating
    /// the newest message of a freshly-opened long conversation previously replayed only
    /// the ~19 messages that happened to be loaded, so a retry silently ran with less
    /// context than the original send.
    private func resolveBackendHistory(before message: ChatMessage, conversationID: UUID) async -> [ChatMessage] {
        let full = await resolveBackendHistory(conversationID: conversationID)
        let slice = Self.historySlice(before: message, in: full)
        if !full.contains(where: { $0.id == message.id }) {
            logger.info("[HISTORY] Target \(message.id.uuidString.prefix(8)) not in the resolved window — cut history by timestamp instead (\(slice.count) of \(full.count) messages).")
        }
        return slice
    }

    /// Everything strictly before `message` in an oldest-first history.
    ///
    /// Cuts by IDENTITY when the target is present — timestamps can tie (a message and its
    /// reply persisted in the same instant), and an identity cut is exact. Falls back to a
    /// timestamp cut only when the target isn't in the resolved window at all, which beats
    /// replaying the entire conversation past it.
    ///
    /// Pure + internal so the slice contract is testable without building a coordinator.
    static func historySlice(before message: ChatMessage, in full: [ChatMessage]) -> [ChatMessage] {
        if let index = full.firstIndex(where: { $0.id == message.id }) {
            return Array(full[..<index])
        }
        return full.filter { $0.timestamp < message.timestamp }
    }

    // MARK: - Message Factory

    /// Builds a `ChatMessage` for the user, classifying attached files into
    /// text (with read-in content) vs. image (with binary data).
    ///
    /// ⚠️ The instance method is now a thin forwarder to `Self.makeUserMessage`, and its only
    /// callers are inside this file. Its stated reason for being internal rather than private —
    /// "`MainApplicationViewModel`'s scheduler path also needs this factory; that scheduler code
    /// still lives on the VM for now" — is gone twice over: the scheduler body moved to
    /// `SchedulerCoordinator` before this change, and on 2026-09-06 that coordinator stopped
    /// calling this at all in favour of the static factory. Left internal because nothing depends
    /// on tightening it; it is no longer part of any cross-type contract.
    func createUserMessage(conversationID: UUID, query: String, files: [FileSystemItem]) async -> ChatMessage {
        await Self.makeUserMessage(conversationID: conversationID, query: query, files: files,
                                   fileProcessorService: fileProcessorService)
    }

    /// The same factory, as a free function over its one real dependency.
    ///
    /// `SchedulerCoordinator` used to reach this through `viewModel!.messagingCoordinator`, which
    /// made its whole send path untestable: constructing a `MainApplicationViewModel` runs
    /// `ChatOpsCoordinator.bootstrap()`, which opens REAL Telegram/Discord/Slack connections when
    /// the developer has them enabled. Nothing about building a user message needs a view model —
    /// only a `FileProcessorService` — so it no longer asks for one.
    static func makeUserMessage(
        conversationID: UUID,
        query: String,
        files: [FileSystemItem],
        fileProcessorService: FileProcessorService
    ) async -> ChatMessage {
        // Classification + reads live in MessageAttachmentBuilder (testable
        // without the coordinator's VM graph — see ATT-1 contract note there).
        let attachments = await MessageAttachmentBuilder(fileProcessorService: fileProcessorService).build(from: files)

        return ChatMessage(
            conversationId: conversationID,
            sender: .user,
            content: .plainText(query),
            attachedTextFiles: attachments.textFiles.isEmpty ? nil : attachments.textFiles,
            attachedImageFiles: attachments.imageFiles.isEmpty ? nil : attachments.imageFiles
        )
    }
}
