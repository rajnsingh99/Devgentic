// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MessagingCoordinator.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

/// Owns the message-sending pipeline: local sends, remote (ChatOps) submissions, regeneration, stream cancellation,
/// HITL resolutions and the shared `createUserMessage` factory.
/// Services are injected; shared view-model state is reached through a weak reference to `MainApplicationViewModel`.
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
    /// Exposed read-only so a surface using `makeUserMessage` need not thread a `MessagingCoordinator` just for it.
    /// A convenience, not an invariant: `FileProcessorService` is a stateless struct, so instances behave identically.
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
        registerCompactionActivitySink()
    }

    // MARK: - Compaction Checkpoint Sink

    /// The stream-independent delivery path for background compaction checkpoints.
    /// Registered here, not per stream, because compaction runs off the request path and can outlive its stream.
    /// This coordinator holds both halves of delivery: the persistence store and the live history array.
    private func registerCompactionActivitySink() {
        Task {
            await HistoryCompactionService.shared.setActivitySink(
                begin: { conversationID in
                    await MainActor.run { ManualCompactionActivity.shared.begin(conversationID, automatic: true) }
                },
                finish: { conversationID, outcome in
                    await MainActor.run { ManualCompactionActivity.shared.finish(conversationID, outcome: outcome) }
                }
            )
        }
    }

    private func registerCompactionCheckpointSink() {
        Task { [logger] in
            await HistoryCompactionService.shared.setCheckpointSink { [weak self, logger] checkpoint, conversationID in
                // The weak read must be main-actor isolated, but the delivery below must not be wrapped in `MainActor.run`:
                // that closure is synchronous and would detach the store write from the splice ordering (see `deliverCheckpoint`).
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

    // Why: an unawaited store write leaves the in-memory splice as the only copy;
    // a history read in that window silently loses the compacted turns.
    /// Delivers a compaction checkpoint: durable store first, live splice second.
    /// The write is awaited so the store is authoritative before anything observes the checkpoint; the splice is render-only.
    /// `static` and internal so the ordering is unit-testable without a `MainApplicationViewModel`.
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

        // Code mode: refresh instructions and the project-knowledge display copy, and set selectedProfileID.
        if vm.interfaceMode == .code {
            logger.info("[CODE] ────────── Code mode send initiated ──────────")
            logger.debug("[CODE] Query preview: \(String(plainUserQueryFromEditor.prefix(120)))") // The query is content, so debug only.
            // The return value is load-bearing: refusing here is the only choke point covering every send entry (ChatOps,
            // scheduler, resume), not just the composer's own guard in `ChatInputAreaView.attemptSend`.
            guard vm.prepareCodeProfileForSend() else {
                logger.error("[CODE] Send DROPPED — the Code session could not be prepared (see the [CODE] line above for which of model/folder is missing). CONSEQUENCE: no message was persisted and no stream started; the user's typed text is left in the composer because this returns before the input is cleared, so nothing they wrote is lost.")
                return
            }
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
            // Binds the conversation to its folder on the first send. `codeSendRefusal` has already
            // refused a send whose bound folder differs, so this never re-points a conversation.
            let bound = persistenceService.getConversation(withId: conversationIDToUse)?.projectPath
            if let folder = vm.codeSessionManager?.projectPath?.path {
                if bound == nil {
                    persistenceService.updateProjectPath(for: conversationIDToUse, projectPath: folder)
                } else {
                    logger.debug("[CODE_PROJECT] Session \(conversationIDToUse.uuidString) already bound to '\(URL(fileURLWithPath: bound ?? "").lastPathComponent)' — not re-bound.")
                }
            } else {
                logger.warning("[CODE_PROJECT] Code send for session \(conversationIDToUse.uuidString) with no project selected. CONSEQUENCE: the session is not bound to a project and lists under 'No project'.")
            }
        }

        // Auto-title if empty, through the store, which saves it.
        if persistenceService.getConversation(withId: conversationIDToUse) != nil {
            persistenceService.setTitleIfUntitled(plainUserQueryFromEditor, for: conversationIDToUse)
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
                files: filesForBackend,
                deliveryMode: AttachmentDeliveryMode.resolve(for: config.profile)
            )

            self.chatHistoryViewModel.currentChatMessages.insert(userMessage, at: 0)
            self.logger.debug("Appended user message into UI.")

            // Persist and await the user message (it may carry a large `.externalStorage` image blob) before resolving
            // history or starting the stream, so the write cannot race the stream's first flush save on the same context.
            await self.persistenceService.addMessage(userMessage, toConversation: conversationIDToUse)
            self.logger.debug("User message persisted successfully (awaited before stream start).")

            // Workflow bookkeeping (no-op for every other profile type); see `WorkflowRunBootstrap`.
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

    /// The wake stub in front of `agentMessage` when that message is a background-task report, or nil.
    /// Read off the stub, not the report's `messageSource`: older reports still read `.localUI`; the stub is always stamped.
    func precedingWakeStub(for agentMessage: ChatMessage) -> ChatMessage? {
        Self.precedingWakeStub(for: agentMessage, in: chatHistoryViewModel.currentChatMessages)
    }

    /// `messages` is newest-first, as `currentChatMessages` is: the message in front of index `i`
    /// is at `i + 1`.
    static func precedingWakeStub(for agentMessage: ChatMessage, in messages: [ChatMessage]) -> ChatMessage? {
        guard let index = messages.firstIndex(where: { $0.id == agentMessage.id }),
              let previous = messages[safe: index + 1],
              previous.sender == .user, previous.isSyntheticPrompt,
              previous.messageSource == .backgroundTask
        else { return nil }
        return previous
    }

    /// `RunAdmissionPolicy.admitRegeneration` with the report check filled in — the one rule the
    /// Redo/Retry buttons and both runtime checks share.
    func regenerationRefusal(for agentMessage: ChatMessage) -> RunAdmissionPolicy.Refusal? {
        let stub = precedingWakeStub(for: agentMessage)
        return RunAdmissionPolicy.admitRegeneration(
            in: agentMessage.conversationId,
            attempts: agentMessage.agentResponse?.generationAttempts,
            live: viewModel?.activeStreamManager.liveRunSnapshot() ?? [],
            isReport: stub != nil,
            reportCardSaved: stub.flatMap(BackgroundTaskWakeCoordinator.reportCard(behind:)) != nil,
            runningTaskID: Self.runningTaskID(startedBy: agentMessage)
        )
    }

    /// A background task this message's run started that has not ended, or nil. The card's status
    /// is kept current by `BackgroundTaskObserver` and reconciled on load, so it is read directly.
    static func runningTaskID(startedBy message: ChatMessage) -> String? {
        for event in message.flattenedTimelineEvents {
            if case .backgroundTask(let card) = event, card.status == .running { return card.taskID }
        }
        return nil
    }

    func regenerateResponse(for agentMessage: ChatMessage) {
        // Cheap guard first so a refused Redo never pays for a history fetch.
        // `conversationBusy` enforces one root run per conversation; a second run would orphan the first run's task handle.
        if let refusal = regenerationRefusal(for: agentMessage) {
            logger.warning("[RUN_CLAIM] Redo REFUSED for message \(agentMessage.id.uuidString.prefix(8)) in conversation \(agentMessage.conversationId.uuidString.prefix(8)): \(refusal.logReason)")
            return
        }
        // The hop is load-bearing, the fetch is not: the suspension is the staleness window in which a scheduled task,
        // ChatOps message or second Redo can claim the conversation; the re-check in `continueRegeneration` closes it.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.continueRegeneration(for: agentMessage)
        }
    }

    private func continueRegeneration(for agentMessage: ChatMessage) {
        guard let vm = viewModel else { return }

        // Re-check after the actor hop: it is a staleness window in which a scheduled task, a ChatOps message or
        // another Redo can claim this conversation. Admission is re-validated like the guards below.
        if let refusal = regenerationRefusal(for: agentMessage) {
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

        // A background-task report is redone as a report: its user message is a one-line stub, so the prompt is rebuilt
        // from the card the stub saved and run report-only. Admission above already refused a report with no saved card.
        let reportCard = BackgroundTaskWakeCoordinator.reportCard(behind: userQueryMessage)
        if userQueryMessage.messageSource == .backgroundTask, reportCard == nil {
            logger.error("[RUN_CLAIM] Redo for report \(agentMessage.id.uuidString.prefix(8)) reached the run with no saved task card. CONSEQUENCE: refused — admission should have caught this; nothing starts.")
            return
        }
        let promptOverride = reportCard.map(BackgroundTaskWakeCoordinator.prompt(for:))

        let filesForBackend = (userQueryMessage.attachedTextFiles?.map { FileSystemItem(id: $0.url, name: $0.name, url: $0.url, isDirectory: false) } ?? []) +
                              (userQueryMessage.attachedImageFiles?.map { FileSystemItem(id: $0.url, name: $0.name, url: $0.url, isDirectory: false) } ?? [])

        guard let config = backendConfiguration.getRequestConfig() else {
            logger.error("[regenerateResponse] Could not get backend request config. Is a profile selected?")
            return
        }

        // Single-write mutation via `ChatMessage.beginRegenerationVariant`: inline optional-chained writes trap Swift
        // exclusivity (the right-hand side re-reads `agentResponse` while the left holds modify access).
        guard agentMessage.beginRegenerationVariant(backendEntityId: config.profile.id) else {
            logger.warning("[regenerateResponse] Message \(agentMessage.id.uuidString.prefix(8)) not regenerable (attempt cap or no response) — no mutation performed.")
            return
        }

        // Workflow bookkeeping (no-op for other profile types). Regenerating a workflow answer re-executes the whole DAG
        // with real side effects, so it gets its own run record; not for a report, whose wake starts no workflow run.
        let workflowTicket = reportCard != nil ? nil : WorkflowRunBootstrap.begin(
            config: config,
            conversationID: agentMessage.conversationId,
            userInput: userQuery,
            registry: vm,
            origin: .regenerate
        )

        // Return value intentionally unused: `updating: agentMessage` streams into that same object.
        if let reportCard {
            logger.info("[BGWAKE] Redoing report \(agentMessage.id.uuidString.prefix(8)) for \(reportCard.taskID) from its saved card (\(reportCard.outputTail.count) chars of output). CONSEQUENCE: a report-only run — no profile tools — on the same output the original report saw.")
        }
        // Bound around the call, like the wake: the stream task inherits task-locals from the context that creates it.
        // `false` for every ordinary Redo.
        ReportOnlyRun.$isActive.withValue(reportCard != nil) {
            _ = activeStreamManager.startMessageStream(
                withConfig: config,
                userMessage: userQueryMessage,
                promptOverride: promptOverride,
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
    }

    /// Resumes an interrupted run, streaming back into the same bubble via `startMessageStream(updating:)`.
    /// `.parkedHITL` re-raises and re-runs the dangling tool; `.streaming` drops it (it may have half-run) and re-decides.
    /// Plain-ReAct native agent profiles only; guards refuse a capability-wrapped or drifted provider/dialect.
    func resumeRun(for agentMessage: ChatMessage) {
        // Cheap guard first so a refused resume never pays for a history fetch.
        if let refusal = RunAdmissionPolicy.admitResume(
            in: agentMessage.conversationId,
            live: viewModel?.activeStreamManager.liveRunSnapshot() ?? []
        ) {
            logger.warning("[RUN_CLAIM] Resume REFUSED for message \(agentMessage.id.uuidString.prefix(8)) in conversation \(agentMessage.conversationId.uuidString.prefix(8)): \(refusal.logReason)")
            return
        }

        // Resolve the replay history up front (store-authoritative, so a resume never replays less context than the
        // original run), then run the entire original body synchronously and in order.
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

        // Re-check after the async history resolve: the Resume chip stays live through that hop, so a double-press would
        // land two runs on one message and orphan the first task; nothing suspends from here, so the claim is atomic.
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

        // Plain-ReAct executors only (`.agent` and `.code` without capability wrappers); workflows cannot be resumed.
        // Every unresumable path finalizes the message with a visible reason; a silent return leaves a dead Resume chip.
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

        // Dialect / provider guard: reconstructed native turns are only valid for the same provider family, so refuse
        // if the profile's model was swapped since the park rather than feed mismatched turns to the wrong adapter.
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

        // The timeline must be faithful to drive a resume: an unreadable completed `.toolExecution` is invisible to the
        // reconstructor, so a side-effectful tool would run again. Refusing costs some resumable runs, deliberately.
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

        // Rebuild the in-flight state from the persisted timeline. Streaming resume drops the dangling tool; parked resume
        // keeps it to re-raise. Flattened, because nested capability cards hold events the reconstructor needs.
        let reconstruction = TimelineTurnReconstructor.reconstruct(
            from: agentMessage.flattenedTimelineEvents,
            parkedOperationID: parkedOpID,
            dropDanglingTool: isStreamingResume
        )
        // Parked resume needs the dangling tool to re-raise. Streaming resume drops it and continues from whatever completed
        // work exists (possibly none), so it has no such precondition.
        if !isStreamingResume {
            guard reconstruction.parkedTool != nil else {
                finalizeUnresumable(agentMessage,
                    reason: "The interrupted state is incomplete and can't be resumed — send the request again.")
                return
            }
        }

        // Deliberately not finalized: a transient UI-state guard (the chip renders from the message's own bubble); the run
        // may be resumable from the right conversation view.
        guard let idx = chatHistoryViewModel.currentChatMessages.firstIndex(of: agentMessage) else {
            logger.error("[resumeRun] Message not in the current conversation; aborting resume.")
            return
        }
        // History strictly below this message plus the originating user query (the slice regenerate uses).
        // Prefers the adjacent sender-checked user message, else the last user turn of the resolved history; refuses if none.
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
        // Same cleanup one level down: dangling tools nested inside plan/reflection cards, plus closing any card the
        // interruption left open (the continuation streams new top-level events, never into the old card).
        agentMessage.sanitizeCapabilityCardsForResume()

        // Flip back to a live, streaming state — hides the interrupted chip, re-enables indicators.
        agentMessage.isStreaming = true

        // Reflect the recovery in the durable HITL audit: flip the parked row the launch reconcile stamped "interrupted"
        // to "resumed". Parked-only: a streaming resume has no parked operationID or audit row.
        if let opID = parkedOpID {
            Task { await TraceRecorder.shared.recordHITLResumed(operationID: opID.uuidString) }
        }

        // No `WorkflowRunBootstrap` here: resume refuses workflow profiles up front, so this path is unreachable for them.
        // Return value intentionally unused: `updating: agentMessage` streams into that same object.
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

    /// Marks an interrupted message as definitively non-resumable: visible reason, `.final` lifecycle, persisted.
    /// Every unresumable path in `resumeRun` must route here; a bare `return` leaves a dead Resume chip.
    private func finalizeUnresumable(_ agentMessage: ChatMessage, reason: String) {
        logger.warning("[resumeRun] \(reason) Finalizing interrupted message \(agentMessage.id.uuidString).")
        agentMessage.isStreaming = false
        agentMessage.lifecycleState = .final
        agentMessage.terminalOutcome = .cancelled
        agentMessage.terminalReason = reason
        // This is the last word on the run: nothing will settle a row still marked executing, so close them here.
        // The decode-time repair spares `.parkedHITL` messages (resume re-raises their dangling row); this path ends that.
        let closed = agentMessage.closeDanglingToolRows(outcome: .cancelled)
        if closed > 0 {
            logger.warning("[resumeRun] Closed \(closed) dangling tool row(s) on message \(agentMessage.id.uuidString.prefix(8)) while marking it unresumable. CONSEQUENCE: the rows settle as cancelled instead of animating a spinner forever on a run that can no longer be resumed.")
        }
        let conversationID = agentMessage.conversationId
        Task { await persistenceService.addMessage(agentMessage, toConversation: conversationID) }
    }

    func cancelStreamingResponse() {
        guard let vm = viewModel else { return }

        // Stop targets the run in the conversation on screen, never an app-global slot; a background run in another
        // conversation is stopped by opening it (or from its own panel).
        let live = vm.activeStreamManager.liveRunSnapshot()
        let selected = vm.selectedConversationID
        let candidates = ForegroundRunResolver.liveRuns(in: selected, from: live)

        guard let target = ForegroundRunResolver.foregroundRun(live: live, selectedConversation: selected) else {
            logger.warning("[RUN_STOP] Stop pressed for conversation \(selected?.uuidString.prefix(8) ?? "<none>") but no run is live there (\(live.count) live app-wide). CONSEQUENCE: Stop is a no-op; any run streaming in another conversation is untouched, which is the intended scope boundary.")
            return
        }

        // Queued runs are EXPECTED here — admission serialises arrivals behind the running run — so
        // only two runs that have both STARTED are the anomaly worth an error.
        let started = candidates.filter { !$0.isQueued }
        if started.count > 1 {
            // Should not happen (one root run per conversation); a Redo on an older message while a newer run streams can
            // produce it, so log it rather than pick silently.
            logger.error("[RUN_STOP] ⚠️ conversation \(target.conversationID.uuidString.prefix(8)) holds \(started.count) started runs: \(started.map { $0.messageID.uuidString.prefix(8) }.joined(separator: ", ")). CONSEQUENCE: Stop cancels only \(target.messageID.uuidString.prefix(8)) (most recently started, unparked first); the others keep streaming and must be stopped by pressing Stop again.")
        }

        logger.info("[RUN_STOP] Cancelling run \(target.messageID.uuidString.prefix(8)) in conversation \(target.conversationID.uuidString.prefix(8)) (parked: \(target.isParked), queued: \(target.isQueued), \(candidates.count - 1) other run(s) waiting) — user pressed Stop. CONSEQUENCE: \(candidates.count > 1 ? "the queued run(s) behind it start next" : "nothing else is affected").")
        activeStreamManager.cancelStream(for: target.messageID)

        // A queued target has no park, and the drain below is conversation-wide: it would resolve another run's approval
        // with `false` while that run's task is not cancelled. A queued run is only picked when nothing has started.
        guard !target.isQueued else { return }

        // If a HITL banner is up for this conversation, drain the parked suspension so Stop returns at once (idempotent).
        // Conversation-scoped, not run-scoped: it also drains a sibling workflow node's park in the same conversation.
        let conversationID = target.conversationID
        Task { await ExecutionSuspensionService.shared.cancel(for: conversationID) }
    }

    // MARK: - [HITL] Human-in-the-Loop Permissions

    /// Submits the user's decision (Approve/Deny) for a pending tool execution.
    func submitToolApproval(operationID: UUID, approved: Bool, editedArguments: [String: JSONValue]? = nil) {
        logger.info("[HITL] Submitting approval decision: \(approved) for operation \(operationID)\(editedArguments != nil ? " (edited args)" : "")")
        Task {
            await ExecutionSuspensionService.shared.resume(for: operationID, approved: approved, resolvedBy: .localUI, editedArguments: editedArguments)
        }
    }

    /// Submits the user's text response (or nil for skip) for a pending clarification request.
    func submitClarificationResponse(operationID: UUID, response: String?) {
        logger.info("[ASK_USER] Submitting clarification response for operation \(operationID)")
        Task {
            await ExecutionSuspensionService.shared.resumeClarification(for: operationID, userInput: response, resolvedBy: .localUI)
        }
    }

    /// Submits the user's plan review decision — approved (with edited subtasks) or rejected (nil).
    func submitPlanReview(operationID: UUID, editedPlan: [SubTask]?) {
        logger.info("[PLAN_REVIEW] Submitting plan review for \(operationID), approved: \(editedPlan != nil)")
        Task {
            await ExecutionSuspensionService.shared.resumePlanReview(for: operationID, editedPlan: editedPlan, resolvedBy: .localUI)
        }
    }

    /// [E1] Submits the user's chosen option for a pending workflow Gate — routes to that option's port.
    func submitGateChoice(operationID: UUID, option: String) {
        logger.info("[GATE] Submitting gate choice '\(option)' for operation \(operationID)")
        Task {
            await ExecutionSuspensionService.shared.resumeGate(for: operationID, chosenOption: option, resolvedBy: .localUI)
        }
    }

    // MARK: - Remote Message Submission (ChatOps Single-Path)

    /// Submits a message from a remote transport (Telegram, Discord, ...) through the same flow as `sendMessage()`.
    /// The message shows in Mac UI history and HITL banners work on both surfaces; the reply streams normally.
    /// `RemoteMirrorService` observes the resulting stream and mirrors events back to the transport.
    func submitRemoteMessage(
        prompt: String,
        conversationID: UUID,
        source: MessageSource,
        config: BackendRequestConfig
    ) {
        guard persistenceService.getConversation(withId: conversationID) != nil else {
            logger.error("[ChatOps] Could not find conversation for ID: \(conversationID.uuidString)")
            return
        }
        // An existence check, not a binding: the view model is re-acquired inside the Task below. Kept as an early abort so
        // a deallocated VM is reported here rather than as a silent no-op later.
        guard viewModel != nil else {
            logger.warning("[ChatOps] submitRemoteMessage aborted — view model deallocated. CONSEQUENCE: the remote user's message is not submitted and they receive no reply; nothing retries it.")
            return
        }

        // Auto-title if empty (as in `sendMessage`), saved by the store.
        persistenceService.setTitleIfUntitled(prompt, for: conversationID)

        // Do not move the Mac window: a remote turn must not yank the user to another conversation or repoint the composer.
        // Every step below is keyed by `conversationID` and streams survive a switch, so the run completes without the window.

        Task { @MainActor [weak self] in
            guard let self, let vm = self.viewModel else { return }

            let userMessage = await self.createUserMessage(conversationID: conversationID, query: prompt, files: [])
            userMessage.messageSource = source

            // Only when this conversation is on screen; `ConversationSyncService` injects the reply under the same predicate.
            // `destinationConversationID` is viewer identity (`loadingConversationID ?? viewerOwningConversationID`), not selection.
            if self.chatHistoryViewModel.destinationConversationID == conversationID {
                self.chatHistoryViewModel.currentChatMessages.insert(userMessage, at: 0)
            }

            Task { [persistenceService = self.persistenceService] in
                await persistenceService.addMessage(userMessage, toConversation: conversationID)
            }

            // History is derived by `ActiveStreamManager`, so a remote turn sees the same view of the conversation as the desktop.

            // Workflow bookkeeping (no-op for other profile types): a remote-triggered workflow run leaves the same reviewable
            // record as a desktop one, and its HITL reaches the workflow interface rather than chat.
            let workflowTicket = WorkflowRunBootstrap.begin(
                config: config,
                conversationID: conversationID,
                userInput: prompt,
                registry: vm,
                origin: .chatOps
            )

            // Unattended binding as in the scheduler (a Router takes first-match instead of parking), yet a human is reachable:
            // tool confirmations still park and mirror. Re-applied every turn so a stale autonomous grant is never inherited.
            if let provider = source.remoteProvider {
                let autonomous = ChatOpsConfigManager.shared.isAutonomous(for: provider)
                Task {
                    await SessionToolApprovals.shared.setAutonomous(
                        autonomous, conversationID: conversationID, origin: source)
                }
            }

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

    /// Upper bound on messages pulled from the store for model context.
    /// Downstream trims to the model's real budget, so this only bounds fetch+decode cost on a very long conversation.
    /// The value lives on `BackendHistoryResolver`; this is the coordinator's name for it.
    private static let backendHistoryMessageLimit = BackendHistoryResolver.messageLimit

    // Why: dropping in-memory just-sent or streaming messages silently omits the user's question from its own request.
    /// Resolves the conversation history handed to the backend, oldest-first.
    /// Store-authoritative: the UI's pagination window must not decide what the model remembers.
    /// In-memory messages are merged over stored ones, never replaced; the just-sent user message may not be persisted yet.
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

    /// History strictly older than `message`, oldest-first: the slice a regeneration or resume must replay.
    /// Store-authoritative like the resolver above, so a retry replays the full context of the original send.
    private func resolveBackendHistory(before message: ChatMessage, conversationID: UUID) async -> [ChatMessage] {
        let full = await resolveBackendHistory(conversationID: conversationID)
        let slice = Self.historySlice(before: message, in: full)
        if !full.contains(where: { $0.id == message.id }) {
            logger.info("[HISTORY] Target \(message.id.uuidString.prefix(8)) not in the resolved window — cut history by timestamp instead (\(slice.count) of \(full.count) messages).")
        }
        return slice
    }

    /// Everything strictly before `message` in an oldest-first history.
    /// Cuts by identity when the target is present (timestamps can tie); uses a timestamp cut only when it is absent.
    /// Pure and internal so the slice contract is testable without a coordinator.
    static func historySlice(before message: ChatMessage, in full: [ChatMessage]) -> [ChatMessage] {
        if let index = full.firstIndex(where: { $0.id == message.id }) {
            return Array(full[..<index])
        }
        return full.filter { $0.timestamp < message.timestamp }
    }

    // MARK: - Message Factory

    /// Builds a user `ChatMessage`, classifying attached files into text (read-in content) and image (binary data).
    /// A thin forwarder to `Self.makeUserMessage`.
    func createUserMessage(conversationID: UUID, query: String, files: [FileSystemItem],
                           deliveryMode: AttachmentDeliveryMode? = nil) async -> ChatMessage {
        await Self.makeUserMessage(conversationID: conversationID, query: query, files: files,
                                   fileProcessorService: fileProcessorService, deliveryMode: deliveryMode)
    }

    // Why: constructing a MainApplicationViewModel bootstraps ChatOps and opens real Telegram/Discord/Slack connections.
    /// The same factory, as a free function over its one real dependency, `FileProcessorService`.
    /// Needs no view model, so callers such as `SchedulerCoordinator` stay testable without a `MainApplicationViewModel`.
    static func makeUserMessage(
        conversationID: UUID,
        query: String,
        files: [FileSystemItem],
        fileProcessorService: FileProcessorService,
        deliveryMode: AttachmentDeliveryMode? = nil
    ) async -> ChatMessage {
        // Classification and reads live in `MessageAttachmentBuilder` (testable without the coordinator's VM graph).
        // Senders with files pass `AttachmentDeliveryMode.resolve(for: profile)` so the chip records what the model gets.
        let attachments = await MessageAttachmentBuilder(fileProcessorService: fileProcessorService)
            .build(from: files, deliveryMode: deliveryMode)

        return ChatMessage(
            conversationId: conversationID,
            sender: .user,
            content: .plainText(query),
            attachedTextFiles: attachments.textFiles.isEmpty ? nil : attachments.textFiles,
            attachedImageFiles: attachments.imageFiles.isEmpty ? nil : attachments.imageFiles
        )
    }
}
