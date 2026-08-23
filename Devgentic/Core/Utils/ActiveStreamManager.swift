//
//  ActiveStreamManager.swift
//  Devgentic
//
//  Created by Raj Singh on 19/08/25.
//

import Foundation
import AppKit
import os


private let logger = DGLogger(category: "ActiveStreamManager")

/// Delegate protocol for RemoteMirrorService to observe stream lifecycle.
@MainActor
protocol ActiveStreamMirrorDelegate: AnyObject {
    func activeStreamManager(_ manager: ActiveStreamManager, didStartStream message: ChatMessage, for conversationID: UUID)
    func activeStreamManager(_ manager: ActiveStreamManager, didEndStream message: ChatMessage)
}

@Observable @MainActor
final class ActiveStreamManager {

    private(set) var activeStreams: [UUID: ChatMessage] = [:]

    // MARK: - Dependencies
    @ObservationIgnored private var activeTasks: [UUID: Task<Void, Never>] = [:]

    /// When each live run CLAIMED its stream. Written and removed in lockstep with
    /// `activeStreams` (the only two sites are the insert below and `finalizeMessage`), so it
    /// cannot outlive the run it describes.
    ///
    /// Needed because a run's start time is NOT `ChatMessage.timestamp`: Redo and Resume stream
    /// into a pre-existing message whose timestamp is hours old. `ForegroundRunResolver` uses this
    /// to break a tie deterministically when a conversation somehow holds two live runs.
    @ObservationIgnored private var streamStartedAt: [UUID: Date] = [:]
    @ObservationIgnored nonisolated(unsafe) private var permissionResolvedObserver: Any?
    @ObservationIgnored nonisolated(unsafe) private var clarificationResolvedObserver: Any?
    @ObservationIgnored nonisolated(unsafe) private var planReviewResolvedObserver: Any?
    @ObservationIgnored nonisolated(unsafe) private var gateResolvedObserver: Any?

    @ObservationIgnored private let persistenceService: ChatPersistenceProtocol

    /// [G1 Piece 1] Per-message timestamp of the last in-flight flush, used to rate-limit the
    /// token-path coalesced flush. Boundary flushes (tool start/finish, HITL park) pass
    /// `immediate: true` and bypass this. Cleared when the message finalizes to bound the map.
    @ObservationIgnored private var lastInFlightFlush: [UUID: Date] = [:]
    private static let inFlightFlushInterval: TimeInterval = 2.0
    @ObservationIgnored private let fileProcessorService: FileProcessorService
    @ObservationIgnored private let backendOrchestrationService: BackendOrchestrationService

    /// [D2] Multicast stream-lifecycle delegates. Each active ChatOps transport (Telegram/Discord/Slack)
    /// owns its own RemoteMirrorService and registers here. A single `weak var` let the last-started
    /// transport clobber the others, so only ONE actually mirrored. Weak refs so a torn-down service
    /// auto-clears.
    private struct WeakMirror { weak var delegate: ActiveStreamMirrorDelegate? }
    @ObservationIgnored private var mirrorDelegates: [WeakMirror] = []

    /// Registers a mirror delegate (idempotent; prunes any dead refs).
    func addMirrorDelegate(_ delegate: ActiveStreamMirrorDelegate) {
        mirrorDelegates.removeAll { $0.delegate == nil || $0.delegate === delegate }
        mirrorDelegates.append(WeakMirror(delegate: delegate))
    }

    /// Unregisters a mirror delegate (e.g. when a transport stops); also prunes dead refs.
    func removeMirrorDelegate(_ delegate: ActiveStreamMirrorDelegate) {
        mirrorDelegates.removeAll { $0.delegate == nil || $0.delegate === delegate }
    }

    /// The currently-live delegates (dead weak refs filtered out).
    private var liveMirrorDelegates: [ActiveStreamMirrorDelegate] {
        mirrorDelegates.compactMap { $0.delegate }
    }

    /// [HITL/P1] Unified pending-interaction queue, owned by MainApplicationViewModel and
    /// injected after init. P1 only holds the reference (no writers yet); P2 wires enqueue.
    @ObservationIgnored var interactionCenter: InteractionCenter?

    init(
        persistenceService: ChatPersistenceProtocol,
        fileProcessorService: FileProcessorService
    ) {
        self.persistenceService = persistenceService
        self.fileProcessorService = fileProcessorService
        self.backendOrchestrationService = BackendOrchestrationService(
            fileProcessorService: fileProcessorService
        )
        setupHITLResolvedObservers()
        logger.info("ActiveStreamManager initialized.")
    }

    deinit {
        if let observer = permissionResolvedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = clarificationResolvedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = planReviewResolvedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = gateResolvedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Cross-Surface HITL Sync

    /// Observes resolved notifications so the Mac UI clears stale banners
    /// when Telegram (or a timeout) handles the HITL interaction.
    private func setupHITLResolvedObservers() {
        permissionResolvedObserver = NotificationCenter.default.addObserver(
            forName: .hitlPermissionResolved,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let conversationID = notification.userInfo?[HITLResolvedKey.conversationID] as? UUID
            let operationID = notification.userInfo?[HITLResolvedKey.operationID] as? UUID
            MainActor.assumeIsolated {
                guard let self else { return }
                // [HITL/P5] InteractionCenter is the single source of truth — clear by operationID.
                if let operationID { self.interactionCenter?.resolve(operationID: operationID) }
                // [HITL/C1] Emit the resolution trace span (precise decision + wait duration).
                let outcome = notification.userInfo?[HITLResolvedKey.outcome] as? String ?? "resolved"
                self.emitHITLTraceSpan(operationID: operationID, outcome: outcome)
                // [HITL/C2] Stamp the durable audit row with the same outcome (covers chat/code/workflow incl. gates).
                if let operationID {
                    Task { await TraceRecorder.shared.recordHITLResolved(operationID: operationID.uuidString, outcome: outcome, resolvedAt: Date()) }
                }
                // Nudge the active stream's thinking island forward immediately (subsequent stream
                // events refine it) so the UI doesn't briefly look stuck on "waiting".
                guard let conversationID else { return }
                for (_, message) in self.activeStreams where message.conversationId == conversationID && message.isStreaming {
                    // Only nudge a message that was actually awaiting input — don't clobber a
                    // concurrent stream's accurate state in the same conversation.
                    if case .interaction = message.agentState {
                        message.agentState = .thinking(.reflecting)
                    }
                }
            }
        }

        clarificationResolvedObserver = NotificationCenter.default.addObserver(
            forName: .hitlClarificationResolved,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let conversationID = notification.userInfo?[HITLResolvedKey.conversationID] as? UUID
            let operationID = notification.userInfo?[HITLResolvedKey.operationID] as? UUID
            MainActor.assumeIsolated {
                guard let self else { return }
                if let operationID { self.interactionCenter?.resolve(operationID: operationID) }
                // [HITL/C1] Emit the resolution trace span (precise decision + wait duration).
                let outcome = notification.userInfo?[HITLResolvedKey.outcome] as? String ?? "resolved"
                self.emitHITLTraceSpan(operationID: operationID, outcome: outcome)
                // [HITL/C2] Stamp the durable audit row with the same outcome (covers chat/code/workflow incl. gates).
                if let operationID {
                    Task { await TraceRecorder.shared.recordHITLResolved(operationID: operationID.uuidString, outcome: outcome, resolvedAt: Date()) }
                }
                guard let conversationID else { return }
                for (_, message) in self.activeStreams where message.conversationId == conversationID && message.isStreaming {
                    // Only nudge a message that was actually awaiting input — don't clobber a
                    // concurrent stream's accurate state in the same conversation.
                    if case .interaction = message.agentState {
                        message.agentState = .thinking(.reflecting)
                    }
                }
            }
        }

        planReviewResolvedObserver = NotificationCenter.default.addObserver(
            forName: .hitlPlanReviewResolved,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let conversationID = notification.userInfo?[HITLResolvedKey.conversationID] as? UUID
            let operationID = notification.userInfo?[HITLResolvedKey.operationID] as? UUID
            MainActor.assumeIsolated {
                guard let self else { return }
                if let operationID { self.interactionCenter?.resolve(operationID: operationID) }
                // [HITL/C1] Emit the resolution trace span (precise decision + wait duration).
                let outcome = notification.userInfo?[HITLResolvedKey.outcome] as? String ?? "resolved"
                self.emitHITLTraceSpan(operationID: operationID, outcome: outcome)
                // [HITL/C2] Stamp the durable audit row with the same outcome (covers chat/code/workflow incl. gates).
                if let operationID {
                    Task { await TraceRecorder.shared.recordHITLResolved(operationID: operationID.uuidString, outcome: outcome, resolvedAt: Date()) }
                }
                guard let conversationID else { return }
                for (_, message) in self.activeStreams where message.conversationId == conversationID && message.isStreaming {
                    if case .interaction = message.agentState {
                        message.agentState = .thinking(.planning)
                    }
                }
            }
        }

        // [E1] Gate resolved (chosen option / cancelled) → clear banner + trace + audit, like the others.
        gateResolvedObserver = NotificationCenter.default.addObserver(
            forName: .hitlGateResolved,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let conversationID = notification.userInfo?[HITLResolvedKey.conversationID] as? UUID
            let operationID = notification.userInfo?[HITLResolvedKey.operationID] as? UUID
            MainActor.assumeIsolated {
                guard let self else { return }
                if let operationID { self.interactionCenter?.resolve(operationID: operationID) }
                // [HITL/C1] Emit the resolution trace span (chosen option / cancelled + wait duration).
                let outcome = notification.userInfo?[HITLResolvedKey.outcome] as? String ?? "resolved"
                self.emitHITLTraceSpan(operationID: operationID, outcome: outcome)
                // [HITL/C2] Stamp the durable audit row with the chosen option.
                if let operationID {
                    Task { await TraceRecorder.shared.recordHITLResolved(operationID: operationID.uuidString, outcome: outcome, resolvedAt: Date()) }
                }
                guard let conversationID else { return }
                for (_, message) in self.activeStreams where message.conversationId == conversationID && message.isStreaming {
                    if case .interaction = message.agentState {
                        message.agentState = .thinking(.reflecting)
                    }
                }
            }
        }
    }


    func startMessageStream(
        withConfig config: BackendRequestConfig,
        conversationID: UUID,
        userQuery: String,
        history: [ChatMessage],
        files: [FileSystemItem],
        updating existingMessage: ChatMessage? = nil,
        workflowExecutionState: WorkflowExecutionState? = nil,
        resumeState: TimelineReconstruction? = nil,
        onComplete: @escaping () -> Void
    ) -> ChatMessage {
        
        // ⚠️ GUARD-RAIL: a workflow profile started without workflow bookkeeping.
        //
        // Six of the seven callers of this method used to do exactly that. The run still
        // EXECUTES, which is why it went unnoticed — but with no `WorkflowExecutionState` there is
        // no run record (no stub, no freeze, no per-node timelines — that detail lives only in
        // the state and is never captured), HITL attributes to `.chat` instead of `.workflow`
        // (`enqueueHITL` keys on `workflowState != nil`), and the capability-card router stays on
        // even though parallel nodes interleave segments it cannot separate.
        //
        // `WorkflowRunBootstrap.begin(...)` is the fix; this line exists because a helper can be
        // forgotten by the NEXT new call site and a loud log cannot.
        if config.profile.profileType == .workflow && workflowExecutionState == nil {
            logger.error("""
                [WF_RUN] ⚠️ Workflow '\(config.profile.displayName)' (\(config.profile.id)) started \
                with NO WorkflowExecutionState — conv \(conversationID). CONSEQUENCE: this run \
                leaves no run record (nothing in run history, the run picker or the badge; per-node \
                timelines are never captured), any HITL it raises is attributed to the CHAT \
                interface instead of the workflow view, and capability-card routing stays enabled. \
                The run itself will execute normally. FIX: call WorkflowRunBootstrap.begin(...) at \
                this call site and pass its `state` + call `finalize()` in onComplete.
                """)
        }

        let agentMessage: ChatMessage
        let isRegeneration = existingMessage != nil

        if let messageToUpdate = existingMessage {
            agentMessage = messageToUpdate
            if resumeState != nil {
                // [ASM-3] A resumed run RE-GENERATES the assistant turn from the
                // reconstructed history — it does not continue the interrupted text
                // mid-sentence. Streaming into the old variant appended the new answer
                // onto the stale partial ("…partial sentenceHere is the full answer…").
                // Clear the streamed text; the timeline (tool rows, cards) survives —
                // resumeRun already sanitized it.
                let staleChars = agentMessage.currentAgentContent?.textContent?.count
                    ?? agentMessage.content.textContent?.count ?? 0
                if let agentResponse = agentMessage.agentResponse,
                   agentResponse.variants.indices.contains(agentResponse.selectedVariantIndex) {
                    agentMessage.agentResponse?.variants[agentResponse.selectedVariantIndex].content = .markdownText("")
                }
                agentMessage.content = .markdownText("")
                agentMessage.invalidateMarkdownCache()
                logger.notice("🚀 [STREAM_RESUME] Resuming message \(agentMessage.id.uuidString) — cleared \(staleChars) chars of interrupted partial prose before re-generation (ASM-3).")
            } else {
                logger.notice("🚀 [STREAM_REGENERATE] Updating message \(agentMessage.id.uuidString) in conversation \(conversationID.uuidString).")
            }
        } else {
            agentMessage = ChatMessage(
                conversationId: conversationID,
                sender: .agent,
                content: .markdownText(""),
                isStreaming: true,
                backendEntityId: config.profile.id
            )
            agentMessage.profileType = config.profile.profileType
            logger.notice("🚀 [STREAM_START] Created message \(agentMessage.id.uuidString) for conversation \(conversationID.uuidString).")
        }

        // [G1 Piece 1] Mark the run in-flight and stamp the model identity that's about to run.
        // The lifecycle marker makes an interrupted (force-quit / crash) run distinguishable from a
        // finished one after restart; the run-identity stamp records which model actually produced
        // this message — the resume-safety guard plus an honest "which model ran" UI label even
        // after the originating profile is later edited.
        agentMessage.lifecycleState = .streaming
        if let llm = config.profile.resolvedLLMConfig {
            agentMessage.apiProvider = llm.apiProvider.rawValue
            agentMessage.modelName = llm.modelName
            agentMessage.modelDialect = llm.modelDialect.rawValue
        }

        activeStreams[agentMessage.id] = agentMessage
        streamStartedAt[agentMessage.id] = Date()
        for delegate in liveMirrorDelegates {
            delegate.activeStreamManager(self, didStartStream: agentMessage, for: conversationID)
        }

        // Defer initial state mutations to the next run loop tick.
        // This prevents "Modifying state during view update" warnings when the returned
        // ChatMessage is immediately assigned to SwiftUI state within a view update cycle.
        Task { @MainActor in
            agentMessage.agentState = .thinking(.reasoning)
        }
        
        let streamTask = Task { [weak self] in
            guard let self = self else { return }

            // Structured Plan & Execute / Reflexion cards (chat + code agents only).
            // Workflow runs keep the legacy flat milestone chips: their capability
            // events carry no node attribution, and parallel workflow nodes would
            // interleave segments the ordering-based router can't separate.
            let capabilityRouter = CapabilityCardRouter(message: agentMessage)
            let capabilityCardsEnabled = (workflowExecutionState == nil)

            do {
                let traceContext = TraceContext(profile: config.profile, messageID: agentMessage.id)
                agentMessage.traceID = traceContext.traceID
                // Run-Report Phase 5: the workflow run record carries the same join key,
                // so run history and the trace store stop being unlinkable (old Seam 4).
                workflowExecutionState?.traceID = traceContext.traceID

                let profileType = config.profile.profileType.rawValue
                logger.info("[TRACE_INIT] traceID: \(traceContext.traceID), spanID: \(traceContext.spanID), profileType: \(profileType), messageID: \(agentMessage.id.uuidString.prefix(8)), conversationID: \(conversationID.uuidString.prefix(8))")

                Task {
                    await TraceRecorder.shared.beginTrace(
                        context: traceContext,
                        conversationID: conversationID,
                        messageID: agentMessage.id,
                        // The resolved model for single-model profiles (bot/agent/code/imageGen);
                        // nil for workflows, which have no single model. This column is what
                        // `recordTokenUsage` prices against — passing nil here was why
                        // `traces.estimatedCostUSD` had been NULL on every run ever recorded.
                        modelName: config.profile.resolvedLLMConfig?.modelName
                    )

                    // Phase B: capture the complete request configuration so the
                    // Report Inspector can show exactly which profile/model/tools/
                    // capabilities/retry-policy/hardware were in effect. Writes one
                    // row to `trace_configs` cascading on `traces.traceID`.
                    //
                    // TODO: pass `codeMemoryContent` from MainApplicationViewModel
                    // (reads from CodeSessionManager.projectMemoryContent) for a
                    // complete Code-mode snapshot. Current capture records only
                    // the project path — memory length/hash stay nil.
                    let snapshot = TraceConfigSnapshot.capture(
                        traceID: traceContext.traceID,
                        config: config,
                        historyTurnCount: history.count,
                        files: files,
                        codeMemoryContent: nil
                    )
                    await TraceRecorder.shared.captureConfigSnapshot(snapshot)
                }

                // [M6] Log the query LENGTH, not its text — the raw prompt is user content and this
                // line goes to the unified OS log (readable via Console / sysdiagnose). traceID +
                // history/file counts are enough to correlate the handoff.
                logger.info("[STREAM_HANDOFF] Passing to BackendOrchestrationService — traceID: \(traceContext.traceID), query: \(userQuery.count) chars, history: \(history.count) msgs, files: \(files.count)")

                let stream = self.backendOrchestrationService.streamMessage(
                    withConfig: config,
                    conversationID: conversationID,
                    userQuery: userQuery,
                    history: history,
                    files: files,
                    context: traceContext,
                    resumeState: resumeState,
                    onTraceUpdate: { _ in } // Trace logs are handled by events now
                )

                logger.info("[STREAM_LISTEN] Awaiting events — traceID: \(traceContext.traceID), messageID: \(agentMessage.id.uuidString.prefix(8))")
                
                var tokenBuffer = ""
                var lastUpdateTime = Date()
                var tokensReceivedInWindow = 0
                var adaptiveInterval: TimeInterval = 0.1 // Start with default

                for try await event in stream {
                    try Task.checkCancellation()

                    switch event {
                    case .thought(let thoughtText, let id, let sourceNodeID):
                        // 1. Handle Thoughts (Update Headline + Append to History using structured ID)
                        agentMessage.agentState = .thinking(.reasoning)
                        let thoughtEvent = TimelineEvent.thought(id: id, text: thoughtText)
                        if let wfState = workflowExecutionState, let nodeID = sourceNodeID {
                            wfState.appendNodeTimelineEvent(thoughtEvent, for: nodeID)
                            logger.debug("[WF_ROUTE] Thought → node timeline [\(nodeID)], count=\(wfState.nodeTimelines[nodeID]?.count ?? 0)")
                        } else if !(capabilityCardsEnabled && capabilityRouter.route(thoughtEvent)) {
                            agentMessage.appendTimelineEvent(thoughtEvent)
                        }

                    case .reasoning(let text, let id, let sourceNodeID):
                        // Model-authored monologue (step.reasoning). Same UI handling as
                        // .thought for now (shared ThinkingDynamicIsland + timeline rendering),
                        // but persisted as .reasoning so downstream consumers can distinguish.
                        agentMessage.agentState = .thinking(.reasoning)
                        let reasoningEvent = TimelineEvent.reasoning(id: id, text: text)
                        if let wfState = workflowExecutionState, let nodeID = sourceNodeID {
                            wfState.appendNodeTimelineEvent(reasoningEvent, for: nodeID)
                            logger.debug("[WF_ROUTE] Reasoning → node timeline [\(nodeID)], count=\(wfState.nodeTimelines[nodeID]?.count ?? 0)")
                        } else if !(capabilityCardsEnabled && capabilityRouter.route(reasoningEvent)) {
                            agentMessage.appendTimelineEvent(reasoningEvent)
                        }

                    case .toolCall(let name, let params, let sourceNodeID, let stepId):
                        agentMessage.agentState = .acting(.tool(name: name))
                        // Live agent tabs (badge-only): announce a STARTING file write so
                        // the Code Viewer can open/update a background tab.
                        if let payload = AgentLiveWriteEvent.began(toolName: name, params: params, conversationID: conversationID) {
                            NotificationCenter.default.post(name: AgentLiveWriteEvent.began, object: nil,
                                                            userInfo: [AgentLiveWriteEvent.payloadKey: payload])
                        }
                        let toolEvent = TimelineEvent.toolExecution(
                            ToolExecutionData(id: UUID(), name: name, params: params, output: nil, isSuccess: nil, isExecuting: true, stepId: stepId)
                        )
                        if let wfState = workflowExecutionState, let nodeID = sourceNodeID {
                            wfState.appendNodeTimelineEvent(toolEvent, for: nodeID)
                            logger.debug("[WF_ROUTE] ToolCall '\(name)' → node timeline [\(nodeID)], count=\(wfState.nodeTimelines[nodeID]?.count ?? 0)")
                        } else if !(capabilityCardsEnabled && capabilityRouter.route(toolEvent)) {
                            agentMessage.appendTimelineEvent(toolEvent)
                        }
                        // [G1 Piece 1] Boundary flush — a tool just started; persist so an interrupted
                        // run shows it ran (and, when this is the parked tool, that it was in flight).
                        await self.flushInFlight(agentMessage, conversationID: conversationID, immediate: true)

                    // [HITL] Permission request → unified InteractionCenter (single source of truth).
                    // Node attribution rides in the banner via the origin; the thinking-island
                    // headline stays generic (the banner carries which node/agent is asking).
                    case .requestConfirmation(let toolName, let params, let operationID, let sourceNodeID, let sourceNodeName):
                        agentMessage.agentState = .interaction(.permission(toolName: toolName))
                        // [G1 Piece 1] Park marker + the operationID join key, flushed immediately:
                        // a run parked on approval can sit indefinitely, so this is the prime
                        // restart case. Resume (Piece 2) re-raises the HITL from this persisted opID.
                        agentMessage.lifecycleState = .parkedHITL(operationID: operationID)
                        await self.flushInFlight(agentMessage, conversationID: conversationID, immediate: true)
                        self.enqueueHITL(
                            operationID: operationID,
                            kind: .toolConfirmation(PendingToolConfirmation(
                                id: operationID,
                                toolName: toolName,
                                params: params,
                                risk: HITLRiskTier.classify(toolName: toolName),
                                arguments: JSONValue.parseStructured(params)
                            )),
                            conversationID: conversationID,
                            profileType: config.profile.profileType,
                            workflowState: workflowExecutionState,
                            sourceNodeID: sourceNodeID,
                            sourceNodeName: sourceNodeName,
                            profileID: config.profile.id,
                            traceContext: traceContext
                        )

                    // [ASK_USER] Clarification request → unified InteractionCenter.
                    case .requestClarification(let question, let operationID, let sourceNodeID, let options, let multiline, let sourceNodeName):
                        agentMessage.agentState = .interaction(.clarification)
                        agentMessage.lifecycleState = .parkedHITL(operationID: operationID)
                        await self.flushInFlight(agentMessage, conversationID: conversationID, immediate: true)
                        self.enqueueHITL(
                            operationID: operationID,
                            kind: .clarification(PendingClarification(id: operationID, question: question, options: options, multiline: multiline)),
                            conversationID: conversationID,
                            profileType: config.profile.profileType,
                            workflowState: workflowExecutionState,
                            sourceNodeID: sourceNodeID,
                            sourceNodeName: sourceNodeName,
                            profileID: config.profile.id,
                            traceContext: traceContext
                        )

                    // [E1] Workflow Gate request → unified InteractionCenter as a `.gate` interaction.
                    case .requestGate(let prompt, let options, let operationID, let deadline, let sourceNodeID, let inputText, let highlights, let sourceNodeName):
                        agentMessage.agentState = .interaction(.gate)
                        agentMessage.lifecycleState = .parkedHITL(operationID: operationID)
                        await self.flushInFlight(agentMessage, conversationID: conversationID, immediate: true)
                        self.enqueueHITL(
                            operationID: operationID,
                            kind: .gate(PendingGate(id: operationID, prompt: prompt, options: options, deadline: deadline, inputText: inputText, highlights: highlights)),
                            conversationID: conversationID,
                            profileType: config.profile.profileType,
                            workflowState: workflowExecutionState,
                            sourceNodeID: sourceNodeID,
                            sourceNodeName: sourceNodeName,
                            profileID: config.profile.id,
                            traceContext: traceContext
                        )

                    case .toolSucceeded(let output, let durationMs, let sourceNodeID):
                        agentMessage.agentState = .thinking(.reflecting)
                        if let payload = AgentLiveWriteEvent.completed(toolName: output.toolName, params: output.params, isSuccess: true, preWriteContent: output.preWriteContent, conversationID: conversationID) {
                            NotificationCenter.default.post(name: AgentLiveWriteEvent.completed, object: nil,
                                                            userInfo: [AgentLiveWriteEvent.payloadKey: payload])
                        }
                        // Card-nested rows first (plan step / reflection attempt); fall back
                        // to the top-level / workflow-node completion path.
                        if !(capabilityCardsEnabled && sourceNodeID == nil
                             && capabilityRouter.completeTool(output: output, failureCategory: nil, durationMs: durationMs)) {
                            Self.completeToolTimelineEvent(
                                output: output,
                                failureCategory: nil,
                                durationMs: durationMs,
                                sourceNodeID: sourceNodeID,
                                agentMessage: agentMessage,
                                workflowExecutionState: workflowExecutionState
                            )
                        }
                        // [G1 Piece 1] Boundary flush — capture the completed tool's output durably.
                        await self.flushInFlight(agentMessage, conversationID: conversationID, immediate: true)

                    case .toolFailed(let output, let category, let suggestion, let sourceNodeID):
                        agentMessage.agentState = .thinking(.reflecting)
                        if let payload = AgentLiveWriteEvent.completed(toolName: output.toolName, params: output.params, isSuccess: false, preWriteContent: output.preWriteContent, conversationID: conversationID) {
                            NotificationCenter.default.post(name: AgentLiveWriteEvent.completed, object: nil,
                                                            userInfo: [AgentLiveWriteEvent.payloadKey: payload])
                        }
                        if !(capabilityCardsEnabled && sourceNodeID == nil
                             && capabilityRouter.completeTool(output: output, failureCategory: category, durationMs: nil)) {
                            Self.completeToolTimelineEvent(
                                output: output,
                                failureCategory: category,
                                durationMs: nil,
                                sourceNodeID: sourceNodeID,
                                agentMessage: agentMessage,
                                workflowExecutionState: workflowExecutionState
                            )
                        }
                        // [G1 Piece 1] Boundary flush — capture the failed tool's outcome durably.
                        await self.flushInFlight(agentMessage, conversationID: conversationID, immediate: true)
                        if let s = suggestion {
                            logger.debug("[TOOL_FAILED] \(output.toolName) [\(category.rawValue)] suggestion: \(s)")
                        }


                    case .content(let textChunk):
                        // 3. Handle Final Text (Buffered)
                        if agentMessage.agentState != .thinking(.finalizing) {
                            agentMessage.agentState = .thinking(.finalizing)
                        }
                        
                        tokenBuffer += textChunk
                        tokensReceivedInWindow += textChunk.count

                        // Flush on TIME only.
                        //
                        // There used to be an `|| tokenBuffer.count > 50` escape hatch, which
                        // inverted the whole throttle for fast producers: an in-process MLX
                        // model fills 50 chars far quicker than `adaptiveInterval`, so the
                        // buffer clause won every time and forced a re-render every ~50 chars
                        // (~54 for a 2.7k reply) no matter how far behind the UI already was.
                        // The producer would finish while the consumer was still draining
                        // buffered tokens one render at a time — the model completed in 15s
                        // and the bubble kept dripping for ~a minute.
                        //
                        // The time clause alone already bounds latency to <= adaptiveInterval
                        // (0.2s worst case), and it degrades the RIGHT way: the further behind
                        // we fall, the more tokens coalesce into a single render.
                        let elapsed = -lastUpdateTime.timeIntervalSinceNow
                        if elapsed >= adaptiveInterval {
                            self.updateMessageContent(agentMessage, with: tokenBuffer, isRegeneration: isRegeneration)
                            // [G1 Piece 1] Coalesced flush — persist streamed prose at most every
                            // `inFlightFlushInterval`, so a long final answer isn't lost if interrupted.
                            await self.flushInFlight(agentMessage, conversationID: conversationID)

                            // Adapt interval based on token throughput:
                            // High throughput (fast local models) → shorter interval (0.05s) for smooth streaming
                            // Low throughput (slow remote APIs)  → longer interval (0.2s) to reduce UI churn
                            if elapsed > 0 {
                                let charsPerSecond = Double(tokensReceivedInWindow) / elapsed
                                if charsPerSecond > 500 {
                                    adaptiveInterval = 0.05   // Fast: flush frequently for smooth UX
                                } else if charsPerSecond > 100 {
                                    adaptiveInterval = 0.1    // Normal: balanced default
                                } else {
                                    adaptiveInterval = 0.2    // Slow: batch more to reduce rerenders
                                }
                            }

                            tokenBuffer = ""
                            tokensReceivedInWindow = 0
                            lastUpdateTime = Date()
                        }
                        
                    case .error(let structuredError):
                        // Surface the failure as a distinct error card in the bubble
                        // instead of leaving it buried in streaming prose. Without this,
                        // capability/system failures render as plain text that mimics
                        // the agent's own output and misleads users into thinking the
                        // run is still in progress.
                        // (Phase 4: category-aware title + actionable suggestion +
                        // category icon, rendered by ErrorMessageView.)
                        logger.error("Stream Error Event [\(structuredError.category.rawValue)]: \(structuredError.message)")
                        agentMessage.content = MessageContent.error(
                            title: structuredError.title,
                            details: structuredError.message,
                            category: structuredError.category,
                            suggestion: structuredError.suggestion
                        )
                        agentMessage.invalidateMarkdownCache()
                        if let agentResponse = agentMessage.agentResponse,
                           agentResponse.variants.indices.contains(agentResponse.selectedVariantIndex) {
                            agentMessage.agentResponse?.variants[agentResponse.selectedVariantIndex].content = agentMessage.content
                        }

                    case .warning(let category, let message, _, let sourceNodeID):
                        let warningEvent = TimelineEvent.warning(id: UUID(), category: category, text: message)
                        if let wfState = workflowExecutionState, let nodeID = sourceNodeID {
                            wfState.appendNodeTimelineEvent(warningEvent, for: nodeID)
                            logger.debug("[WF_ROUTE] Warning[\(category.rawValue)] → node timeline [\(nodeID)]")
                        } else if !(capabilityCardsEnabled && capabilityRouter.route(warningEvent)) {
                            agentMessage.appendTimelineEvent(warningEvent)
                        }
                        logger.warning("Stream Warning [\(category.rawValue)]: \(message)")

                    // MARK: Workflow Orchestration Events
                    case .workflowNodeStarted(let nodeID, let profileName, let idx, let total):
                        agentMessage.agentState = .acting(.subtask(current: idx, total: total))
                        logger.info("[WF_EVENT] NodeStarted: '\(profileName)' [\(nodeID)] (\(idx)/\(total))")
                        workflowExecutionState?.handleNodeStarted(nodeID: nodeID, profileName: profileName, index: idx, total: total)

                    case .workflowNodeCompleted(let nodeID, let profileName, let summary, let nodeHasWarnings):
                        let completedId = UUID()
                        // `summary` now carries the node's FULL output (for the per-node
                        // Output panel + persistence via handleNodeCompleted). Keep the
                        // orchestrator's aggregate thought log a brief milestone so it
                        // isn't bloated by full node outputs.
                        let summaryPreview = summary.count > 200 ? String(summary.prefix(200)) + "…" : summary
                        agentMessage.appendTimelineEvent(.thought(id: completedId, text: "✅ \(profileName): \(summaryPreview)"))
                        // [M6] Log the summary LENGTH, not the node's output text (model content) —
                        // this line reaches the unified OS log. The full output is in the per-node
                        // Output panel + persisted via handleNodeCompleted for real inspection.
                        logger.info("[WF_EVENT] NodeCompleted: '\(profileName)' [\(nodeID)] summary=\(summary.count) chars")
                        workflowExecutionState?.handleNodeCompleted(nodeID: nodeID, profileName: profileName, summary: summary, hasWarnings: nodeHasWarnings)

                    case .workflowNodeFailed(let nodeID, let profileName, let error, let suggestion):
                        let failedId = UUID()
                        agentMessage.appendTimelineEvent(.thought(id: failedId, text: "❌ \(profileName): \(error)"))
                        logger.info("[WF_EVENT] NodeFailed: '\(profileName)' [\(nodeID)] error=\(error)")
                        workflowExecutionState?.handleNodeFailed(nodeID: nodeID, profileName: profileName, error: error, suggestion: suggestion)

                    case .workflowNodeSkipped(let nodeID, let profileName, let reason, let ranBeforeSkip):
                        workflowExecutionState?.handleNodeSkipped(nodeID: nodeID, profileName: profileName, reason: reason, ranBeforeSkip: ranBeforeSkip)

                    case .workflowNodeCancelled(let nodeID, let profileName):
                        workflowExecutionState?.handleNodeCancelled(nodeID: nodeID, profileName: profileName)

                    case .workflowProgress(let completed, let total):
                        logger.info("[WF_EVENT] Progress: \(completed)/\(total)")
                        workflowExecutionState?.handleProgress(completed: completed, total: total)

                    // MARK: Capability Events (Planning, Self-Reflection, Delegation)

                    case .planGenerated(let subtasks):
                        let count = subtasks.count
                        agentMessage.agentState = .thinking(.planning)
                        if capabilityCardsEnabled {
                            capabilityRouter.handlePlanGenerated(subtasks)
                        } else {
                            agentMessage.appendTimelineEvent(.capabilityMilestone(
                                id: UUID(), kind: .planGenerated, detail: "Planned \(count) subtask\(count == 1 ? "" : "s")"
                            ))
                        }

                    case .planApproved(let subtasks):
                        agentMessage.agentState = .thinking(.planning)
                        if capabilityCardsEnabled {
                            capabilityRouter.handlePlanApproved(subtasks)
                        } else {
                            agentMessage.appendTimelineEvent(.capabilityMilestone(
                                id: UUID(), kind: .planGenerated, detail: "Plan approved (\(subtasks.count) subtask\(subtasks.count == 1 ? "" : "s"))"
                            ))
                        }

                    case .requestPlanReview(let subtasks, let operationID, let sourceNodeID, let sourceNodeName):
                        agentMessage.agentState = .interaction(.planReview)
                        // [ASM-5] Park + immediate boundary flush — every other HITL case
                        // (tool confirmation, clarification, gate) does exactly this. Without
                        // the marker a plan-review park reloaded as `.streaming` after a quit
                        // (resume couldn't re-raise the review), and the run never reached the
                        // parked state the local-model release keys off — the loaded MLX model
                        // stayed pinned in memory for as long as the banner sat unanswered.
                        agentMessage.lifecycleState = .parkedHITL(operationID: operationID)
                        await self.flushInFlight(agentMessage, conversationID: conversationID, immediate: true)
                        if capabilityCardsEnabled {
                            capabilityRouter.handlePlanReviewRequested()
                        } else {
                            agentMessage.appendTimelineEvent(.capabilityMilestone(
                                id: UUID(), kind: .planReviewRequested,
                                detail: "Plan with \(subtasks.count) subtask\(subtasks.count == 1 ? "" : "s") awaiting approval"
                            ))
                        }
                        self.enqueueHITL(
                            operationID: operationID,
                            kind: .planReview(PendingPlanReview(id: operationID, subtasks: subtasks)),
                            conversationID: conversationID,
                            profileType: config.profile.profileType,
                            workflowState: workflowExecutionState,
                            sourceNodeID: sourceNodeID,
                            sourceNodeName: sourceNodeName,
                            profileID: config.profile.id,
                            traceContext: traceContext
                        )

                    case .subtaskStarted(let id, let index, let total, let description):
                        agentMessage.agentState = .acting(.subtask(current: index, total: total))
                        if capabilityCardsEnabled {
                            capabilityRouter.handleSubtaskStarted(id: id, description: description)
                        } else {
                            agentMessage.appendTimelineEvent(.capabilityMilestone(
                                id: UUID(), kind: .subtaskStarted, detail: "Subtask \(index)/\(total): \(description)"
                            ))
                        }
                        // [G1 Piece 1] Boundary flush — persist the step transition durably.
                        await self.flushInFlight(agentMessage, conversationID: conversationID, immediate: true)

                    case .subtaskCompleted(let id, let index, let total, let summary, let outcome, let durationMs):
                        if capabilityCardsEnabled {
                            capabilityRouter.handleSubtaskCompleted(id: id, summary: summary, outcome: outcome, durationMs: durationMs)
                        } else {
                            agentMessage.appendTimelineEvent(.capabilityMilestone(
                                id: UUID(), kind: .subtaskCompleted, detail: "Subtask \(index)/\(total): \(summary)"
                            ))
                        }
                        await self.flushInFlight(agentMessage, conversationID: conversationID, immediate: true)

                    case .reflectionTrialStarted(let trial, let maxTrials):
                        agentMessage.agentState = .thinking(.reasoning)
                        if capabilityCardsEnabled {
                            capabilityRouter.handleTrialStarted(trial: trial, maxTrials: maxTrials)
                        } else {
                            agentMessage.appendTimelineEvent(.capabilityMilestone(
                                id: UUID(), kind: .reflectionTrialStarted, detail: "Trial \(trial) of \(maxTrials)"
                            ))
                        }

                    case .reflectionEvaluating(let trial):
                        agentMessage.agentState = .thinking(.reflecting)
                        if capabilityCardsEnabled {
                            capabilityRouter.handleTrialEvaluating(trial: trial)
                        } else {
                            agentMessage.appendTimelineEvent(.capabilityMilestone(
                                id: UUID(), kind: .reflectionEvaluating, detail: "Evaluating trial \(trial)"
                            ))
                        }

                    case .reflectionRetrying(let trial, let critique):
                        agentMessage.agentState = .thinking(.reflecting)
                        if capabilityCardsEnabled {
                            // Full critique — the card is the critique's home now; the old
                            // 80-char milestone truncation lost the evaluator's reasoning.
                            capabilityRouter.handleTrialRejected(trial: trial, critique: critique)
                        } else {
                            agentMessage.appendTimelineEvent(.capabilityMilestone(
                                id: UUID(), kind: .reflectionRetrying, detail: "Retry: \(String(critique.prefix(80)))"
                            ))
                        }

                    case .reflectionAccepted(let trial):
                        if capabilityCardsEnabled {
                            capabilityRouter.handleTrialAccepted(trial: trial)
                        } else {
                            agentMessage.appendTimelineEvent(.capabilityMilestone(
                                id: UUID(), kind: .reflectionAccepted, detail: "Accepted on trial \(trial)"
                            ))
                        }

                    case .delegationStarted(let task):
                        let shortTask = String(task.prefix(60))
                        agentMessage.agentState = .acting(.tool(name: "call_agent"))
                        agentMessage.appendTimelineEvent(.capabilityMilestone(
                            id: UUID(), kind: .delegationStarted, detail: shortTask
                        ))

                    case .delegationCompleted(let summary):
                        let shortSummary = String(summary.prefix(80))
                        agentMessage.appendTimelineEvent(.capabilityMilestone(
                            id: UUID(), kind: .delegationCompleted, detail: shortSummary
                        ))

                    // MARK: History Compaction Events
                    case .compactionCompleted(let turns, let preview, let checkpoint):
                        // Chip ONLY. Persistence + live-array splice moved to
                        // HistoryCompactionService's checkpoint sink (registered by
                        // MessagingCoordinator): compaction runs in the background now, so
                        // it can complete after this stream has finished — at which point
                        // this event is never delivered. Data must not depend on it.
                        let shortPreview = String(preview.prefix(100))
                        agentMessage.appendTimelineEvent(.capabilityMilestone(
                            id: UUID(), kind: .compactionCompleted,
                            detail: "History compacted \u{2014} \(turns) turns summarized: \(shortPreview)"
                        ))
                        logger.info("[COMPACTION] Completed chip shown \u{2014} checkpoint \(checkpoint.id.uuidString.prefix(8)), conversationID: \(conversationID.uuidString.prefix(8))")

                    case .compactionFailed(let reason):
                        // Best-effort chip from the background run. The run continues
                        // with uncompacted history, so this is a warning, not an error.
                        agentMessage.appendTimelineEvent(.capabilityMilestone(
                            id: UUID(), kind: .compactionFailed,
                            detail: "History compaction didn't finish (\(reason)) \u{2014} continuing with full history"
                        ))
                        logger.warning("[COMPACTION] Reported to user as failed \u{2014} \(reason), conversationID: \(conversationID.uuidString.prefix(8))")

                    // MARK: Multimodal Events
                    case .mediaProgress:
                        // Deliberately dropped. This only ever drove the dynamic island's headline
                        // ("imageGen: Step 12/30"), and the island is gone.
                        //
                        // Generation is still visible: its only emitter (ImageGenExecutor) yields
                        // `.thought("Generating image with <model>…")` immediately before the first
                        // progress event, and that reaches the timeline — followed by the artifact
                        // itself. What's lost is the live step counter, nothing else.
                        //
                        // Restoring it isn't a one-liner and would be a NEW feature rather than a
                        // repair: the timeline has no progress concept at all, `TimelineEvent`
                        // carries no percent, and `appendTimelineEvent` only appends — so ticking
                        // events would either flood the action group ("Produced 47 artifacts") or
                        // need an upsert plus a change to a persisted enum.
                        break

                    case .artifactProduced(let artifact):
                        let mediaEvent = TimelineEvent.mediaGeneration(
                            id: UUID(),
                            toolName: artifact.label ?? artifact.kind.rawValue,
                            artifact: artifact,
                            isComplete: true
                        )
                        if !(capabilityCardsEnabled && capabilityRouter.route(mediaEvent)) {
                            agentMessage.appendTimelineEvent(mediaEvent)
                        }

                    // MARK: Token Usage
                    case .tokenUsage(let usage):
                        // Accumulate (don't overwrite): a multi-node workflow emits one
                        // event per node, so we want the run total, not just the last (D1).
                        agentMessage.tokenUsage = (agentMessage.tokenUsage ?? TokenUsage()).accumulated(with: usage)

                    // MARK: Terminal Outcome
                    case .executionFinished(let outcome, let reason):
                        agentMessage.terminalOutcome = outcome
                        agentMessage.terminalReason = reason
                        if capabilityCardsEnabled {
                            capabilityRouter.handleExecutionFinished(outcome: outcome)
                        }
                        logger.info("[STREAM_TERMINAL] outcome=\(outcome.rawValue), reason=\(reason ?? "nil")")
                    }
                }
                
                // Flush remaining text tokens
                if !tokenBuffer.isEmpty {
                    self.updateMessageContent(agentMessage, with: tokenBuffer, isRegeneration: isRegeneration)
                }
                
                logger.info("[STREAM_LOOP_END] Finished — traceID: \(traceContext.traceID), messageID: \(agentMessage.id.uuidString.prefix(8)), profileType: \(profileType)")

                // Forward the stream's end to the workflow execution state.
                //
                // ⚠️ `Task.isCancelled` is load-bearing here, not decoration. A workflow Stop
                // tears this loop down WITHOUT throwing (see `handleStreamEnd`), so the
                // `catch is CancellationError` arm below never runs for one — this is the only
                // place the workflow state can learn the run was stopped. Passing the flag
                // through is what keeps the frozen record's status agreeing with the trace
                // status stamped a few lines down.
                if let wfState = workflowExecutionState {
                    let finalText = agentMessage.content.textContent ?? ""
                    let stopped = Task.isCancelled
                    logger.info("[WF_EVENT] StreamEnd: cancelled=\(stopped), \(finalText.count) chars, nodeTimelines=\(wfState.nodeTimelines.count) nodes tracked")
                    logger.debug("[WF_EVENT] FinalOutput preview: \(String(finalText.prefix(300)))")
                    wfState.handleStreamEnd(finalText: finalText, cancelled: stopped)
                    if stopped {
                        logger.info("[WF_EVENT] Run STOPPED by user — state latched wasCancelled. CONSEQUENCE: the frozen record persists .cancelled with its in-flight node settled .cancelled, instead of a red 'Failed' reporting the user's own action back as an error.")
                    }
                }

                // Stop-button race: cancelling the consumer tears the stream down before
                // the producer's `.executionFinished(.cancelled)` can be consumed, so the
                // outcome arrives as nil and the safety net would record `.completed`
                // (audit #2). Stamp the honest outcome here.
                if Task.isCancelled, agentMessage.terminalOutcome == nil {
                    agentMessage.terminalOutcome = .cancelled
                    agentMessage.terminalReason = agentMessage.terminalReason ?? "Cancelled by user"
                }
                // Close any open capability cards so a persisted card never claims to
                // still be executing (mirrors the terminalOutcome safety net above).
                if capabilityCardsEnabled {
                    capabilityRouter.handleExecutionFinished(outcome: agentMessage.terminalOutcome ?? .completed)
                }
                await self.finalizeMessage(agentMessage, conversationID: conversationID, error: nil)

            } catch is CancellationError {
                logger.info("[STREAM_CANCELLED] traceID: \(agentMessage.traceID ?? "?"), messageID: \(agentMessage.id.uuidString.prefix(8))")
                workflowExecutionState?.handleError("Cancelled", cancelled: true)
                if agentMessage.terminalOutcome == nil {
                    agentMessage.terminalOutcome = .cancelled
                    agentMessage.terminalReason = agentMessage.terminalReason ?? "Cancelled by user"
                }
                if capabilityCardsEnabled {
                    capabilityRouter.handleExecutionFinished(outcome: .cancelled)
                }
                await self.finalizeMessage(agentMessage, conversationID: conversationID, error: nil)
            } catch {
                logger.error("[STREAM_ERROR] traceID: \(agentMessage.traceID ?? "?"), messageID: \(agentMessage.id.uuidString.prefix(8)), error: \(error.localizedDescription)")
                workflowExecutionState?.handleError(error.localizedDescription)
                if capabilityCardsEnabled {
                    capabilityRouter.handleExecutionFinished(outcome: .failed)
                }
                await self.finalizeMessage(agentMessage, conversationID: conversationID, error: error)
            }
            
            self.removeTask(for: agentMessage.id)
            onComplete()
        }
        
        activeTasks[agentMessage.id] = streamTask
        
        return agentMessage
    }
    
    /// Mutates the matching executing `.toolExecution` timeline event into its completed state.
    /// Routes to the workflow node's per-node timeline when `sourceNodeID` is present,
    /// else falls back to the message's root timeline. `failureCategory == nil` means success.
    private static func completeToolTimelineEvent(
        output: ToolOutput,
        failureCategory: ToolFailureCategory?,
        durationMs: Int?,
        sourceNodeID: UUID?,
        agentMessage: ChatMessage,
        workflowExecutionState: WorkflowExecutionState?
    ) {
        // Bound what enters the timeline. `output` is an UNCAPPED string that lands in the
        // message's timeline blob — re-encoded whole on every flush and decoded eagerly on
        // every conversation load — so one verbose command (a build log, a large file dump)
        // could balloon a conversation permanently. Truncation is explicit: the marker is
        // visible to the user AND to a resumed run's LLM history, which
        // `TimelineTurnReconstructor` rebuilds from this field.
        let cappedOutput = ToolExecutionData.cappedOutput(output.output)
        if cappedOutput.count != output.output.count {
            logger.warning("[TOOL_OUTPUT] '\(output.toolName)' returned \(output.output.count) chars — truncated to \(ToolExecutionData.maxPersistedOutputLength) for the timeline. The full text reached the model on THIS run; a resumed run sees the truncation marker instead.")
        }

        let updater: (inout ToolExecutionData) -> Void = { data in
            // Refresh params to what ACTUALLY executed — when the user edits args in the HITL banner
            // (A3), output.params carries the corrected values; the card was built from the originals.
            data.params = output.params
            data.output = cappedOutput
            data.isSuccess = output.isSuccess
            data.failureCategory = failureCategory
            data.durationMs = durationMs
            data.isExecuting = false
            data.preWriteContent = output.preWriteContent
            data.postWriteContent = output.postWriteContent
            // Derive the change ONCE, here, while the snapshots are in hand. The episodic
            // formatter runs per request; deriving it there re-diffed every historical
            // write on every prompt build.
            data.effect = ActionEffect.from(toolExecution: data)
            // Same reasoning, same seam: parsed once here rather than re-scanned on every
            // prompt build. Nil for every tool that doesn't annotate a status.
            data.exitCode = ShellExitStatus.parse(cappedOutput)
        }

        if let wfState = workflowExecutionState, let nodeID = sourceNodeID {
            if let idx = wfState.nodeTimelines[nodeID]?.lastIndex(where: {
                if case .toolExecution(let data) = $0 {
                    return data.name == output.toolName && data.isExecuting
                }
                return false
            }) {
                if case .toolExecution(var data) = wfState.nodeTimelines[nodeID]![idx] {
                    updater(&data)
                    wfState.nodeTimelines[nodeID]![idx] = .toolExecution(data)
                    logger.debug("[WF_ROUTE] Tool '\(output.toolName)' completed → node [\(nodeID)] success=\(output.isSuccess) category=\(failureCategory?.rawValue ?? "nil")")
                }
            }
            return
        }

        if let index = agentMessage.timelineEvents.lastIndex(where: {
            if case .toolExecution(let data) = $0 {
                return data.name == output.toolName && data.isExecuting
            }
            return false
        }) {
            if case .toolExecution(var data) = agentMessage.timelineEvents[index] {
                updater(&data)
                agentMessage.timelineEvents[index] = .toolExecution(data)
            }
        }
    }

    /// [HITL/P5] Enqueue a HITL request into the unified `InteractionCenter` — the single source
    /// of truth across chat / code / workflow / scheduled. Builds the source-attributed origin
    /// (interface + workflow node identity + banner title). Replaces the retired per-message
    /// `ChatMessage.pendingInteraction` and per-workflow `WorkflowExecutionState.pendingInteractions`.
    private func enqueueHITL(
        operationID: UUID,
        kind: PendingInteraction,
        conversationID: UUID,
        profileType: ProfileType,
        workflowState: WorkflowExecutionState?,
        sourceNodeID: UUID?,
        /// Producer-supplied display name, defaulted so existing call sites are unaffected.
        /// See the resolution comment below for why the id alone is not enough.
        sourceNodeName: String? = nil,
        profileID: UUID?,
        traceContext: TraceContext
    ) {
        guard let interactionCenter else {
            // A park with no center means the run waits on an interaction NOBODY can
            // ever answer — that must never be silent.
            logger.error("[HITL] enqueue DROPPED — no InteractionCenter wired (op: \(operationID.uuidString.prefix(8)), conversation: \(conversationID.uuidString.prefix(8))). The run will hang parked.")
            return
        }

        let isWorkflow = workflowState != nil && sourceNodeID != nil
        let interface: HITLOrigin.Interface = isWorkflow
            ? .workflow
            : (profileType == .code ? .code : .chat)

        // Prefer a name the PRODUCER supplied. The `nodeResults` lookup below only works for a
        // node of the CURRENT canvas; for a request forwarded out of a sub-workflow, `sourceNodeID`
        // names an inner node this state has never heard of (the child's node events are
        // suppressed), so it always missed and the banner rendered a bare kind label — with two
        // nodes parked at once the user could not tell which was asking.
        let nodeName: String? = sourceNodeName ?? sourceNodeID.flatMap { id in
            workflowState?.nodeResults.first(where: { $0.nodeID == id })?.profileName
        }

        let kindLabel: String = {
            switch kind {
            case .toolConfirmation: return "Permission required"
            case .clarification:    return "Question"
            case .planReview:       return "Plan review"
            case .gate:             return "Decision required"
            }
        }()
        let title = nodeName.map { "\($0) · \(kindLabel)" } ?? kindLabel

        // Logged HERE (not at function entry) so it can reuse `kindLabel` — the first
        // version stringified the enum and truncated it to 40 chars, emitting the
        // half-word "toolConfirmation(devgentic.PendingToolCo".
        logger.log("[HITL] Parked op \(operationID.uuidString.prefix(8)) — \(kindLabel), conversation: \(conversationID.uuidString.prefix(8)), interface: \(interface.rawValue), profile: \(profileType.rawValue), node: \(nodeName ?? "none"). Awaiting user.")

        let origin = HITLOrigin(
            interface: interface,
            conversationID: conversationID,
            nodeID: sourceNodeID,
            nodeName: nodeName,
            title: title,
            profileID: profileID
        )
        interactionCenter.enqueue(PendingHITL(id: operationID, origin: origin, kind: kind))

        // [HITL/C1] Record the raise for the trace span emitted on resolve — chat, code, and ALL workflow
        // HITL including gates. Gates are now a first-class `.gate` interaction (WorkflowExecutor no longer
        // emits its own span), so they are traced uniformly here with no double-emit to guard against.
        let kindType: String
        let kindToolName: String?
        switch kind {
        case .toolConfirmation(let c): kindType = "permission";    kindToolName = c.toolName
        case .clarification:           kindType = "clarification"; kindToolName = nil
        case .planReview:              kindType = "plan_review";   kindToolName = nil
        case .gate:                    kindType = "gate";          kindToolName = nil
        }

        // Sample the raise instant ONCE, synchronously, so the C1 span and C2 audit share the exact
        // same timestamp and neither drifts to whenever its deferred Task happens to run.
        let raisedAt = Date()

        hitlTraceInfo[operationID] = HITLTraceRecord(
            context: traceContext, raisedAt: raisedAt, type: kindType, toolName: kindToolName
        )

        // [HITL/C2] Durable audit row, written at RAISE for EVERY HITL (incl. gates). A request still
        // pending at quit/crash survives as resolvedAt=nil, which the launch reconcile stamps `interrupted`.
        Task { await TraceRecorder.shared.recordHITLRaised(
            operationID: operationID.uuidString,
            conversationID: conversationID.uuidString,
            interface: interface.rawValue,
            type: kindType,
            toolName: kindToolName,
            nodeName: nodeName,
            title: title,
            raisedAt: raisedAt,
            // v8 join keys: the audit row now names its run exactly, so the Run
            // Report stops guessing approvals into runs by time window.
            traceID: traceContext.traceID,
            spanID: traceContext.spanID
        ) }
    }

    /// [HITL/C1] In-flight HITL requests awaiting resolution, for the userInteraction trace span.
    private struct HITLTraceRecord {
        let context: TraceContext
        let raisedAt: Date
        let type: String
        let toolName: String?
    }
    @ObservationIgnored private var hitlTraceInfo: [UUID: HITLTraceRecord] = [:]

    /// [HITL/C1] Emit a `userInteraction` trace span when a HITL resolves — captures decision +
    /// wait duration so chat HITL (previously span-less) is visible in the Report Inspector.
    private func emitHITLTraceSpan(operationID: UUID?, outcome: String) {
        guard let opID = operationID, let rec = hitlTraceInfo.removeValue(forKey: opID) else { return }
        let waitMs = Int(Date().timeIntervalSince(rec.raisedAt) * 1000)
        let context = rec.context
        let type = rec.type
        let tool = rec.toolName
        let detailed = "\(outcome) · \(waitMs)ms"
        Task { await TraceRecorder.shared.emitUserInteraction(span: context, type: type, toolName: tool, outcome: detailed) }
    }

    private func updateMessageContent(_ agentMessage: ChatMessage, with newTextChunk: String, isRegeneration: Bool) {
        // Merge decision lives in `ChatMessage.resolveStreamedChunkMerge` (pure,
        // testable). ASM-1: when current content is an `.error` card and prose
        // streams afterwards (workflow node failure + surviving terminal nodes;
        // planning subtask failure), the merge starts the answer fresh and hands
        // back a demoted timeline event so the failure stays discoverable instead
        // of being laundered into the answer's opening words.
        if isRegeneration {
            guard let agentResponse = agentMessage.agentResponse,
                  agentResponse.variants.indices.contains(agentResponse.selectedVariantIndex) else {
                return
            }
            var targetVariant = agentResponse.variants[agentResponse.selectedVariantIndex]
            if let merged = ChatMessage.resolveStreamedChunkMerge(current: targetVariant.content, chunk: newTextChunk) {
                targetVariant.content = merged.content
                agentMessage.agentResponse?.variants[agentResponse.selectedVariantIndex] = targetVariant
                if let demoted = merged.demotedError {
                    agentMessage.appendTimelineEvent(demoted)
                }
            }
        } else {
            if let merged = ChatMessage.resolveStreamedChunkMerge(current: agentMessage.content, chunk: newTextChunk) {
                agentMessage.content = merged.content
                agentMessage.agentResponse?.variants[0].content = merged.content
                if let demoted = merged.demotedError {
                    agentMessage.appendTimelineEvent(demoted)
                }
            }
        }
        // Invalidate cached markdown blocks so the next body evaluation reparses
        // with the updated content. This works with getOrCreateMarkdownBlocks() to
        // provide O(1) no-ops when body re-evaluates without new content.
        agentMessage.invalidateMarkdownCache()
    }
    
    /// [P8] Whether any stream is live for `conversationID` RIGHT NOW. Drives the
    /// sidebar's `StreamingPulseIndicator` — which had never rendered once: it read a
    /// persisted `isStreaming` that has no column, so every decode said `false`.
    /// "Streaming" is a live-process property (after a crash, nothing is streaming),
    /// so the live dictionary is the honest source; reading it from a view body
    /// auto-updates rows on stream start/end (`activeStreams` is observable).
    func hasActiveStream(inConversation conversationID: UUID) -> Bool {
        activeStreams.values.contains { $0.conversationId == conversationID }
    }

    /// Every live run, reduced to the fields the foreground decision needs.
    ///
    /// This is the authoritative answer to "what is running?" — it replaced
    /// `MainApplicationViewModel.streamingMessageID` / `.streamingMessage`, two stored `var`s that
    /// five surfaces overwrote and five completions nil'd with no ownership guard. `activeStreams`
    /// was always correctly keyed and always observable; the slot was a lossy copy of it.
    /// See `ForegroundRunResolver` for the full history and `LLM_Execution_Concurrency_Design.md`.
    ///
    /// Reading this inside a SwiftUI view body or an `ObservationStream` registers on
    /// `activeStreams`, so the composer's Send/Stop state updates on every stream start and end
    /// exactly as the sidebar's pulse already does.
    func liveRunSnapshot() -> [ForegroundRunResolver.LiveRun] {
        activeStreams.values.map { message in
            let parked: Bool
            if case .parkedHITL = message.lifecycleState { parked = true } else { parked = false }
            return ForegroundRunResolver.LiveRun(
                messageID: message.id,
                conversationID: message.conversationId,
                // `.distantPast` only if the two maps ever diverge; it degrades the tie-break to
                // "loses to everything", never the candidacy itself.
                startedAt: streamStartedAt[message.id] ?? .distantPast,
                isParked: parked
            )
        }
    }

    public func cancelStream(for messageId: UUID) {
        guard let taskToCancel = activeTasks[messageId] else {
            logger.warning("Attempted to cancel a stream for message ID \(messageId.uuidString), but no active task was found.")
            return
        }
        
        logger.info("Cancelling stream task for message ID: \(messageId.uuidString)")
        taskToCancel.cancel()
    }

    /// [HITL/P5] Cancel any active stream(s) for a conversation. Used on conversation deletion so a
    /// run parked on a HITL (which no longer has a per-HITL watchdog) doesn't strand — cancellation
    /// cascades to the suspension's withTaskCancellationHandler (deny / nil) and then finalizes.
    public func cancelStreams(forConversation conversationID: UUID) {
        let messageIDs = activeStreams.filter { $0.value.conversationId == conversationID }.map(\.key)
        for messageID in messageIDs {
            cancelStream(for: messageID)
        }
    }
    
    
    /// [G1 Piece 1] Durably persist the in-flight agent message mid-run so an interrupted run
    /// (force-quit / crash) survives with its partial timeline instead of vanishing on restart.
    /// `addMessage` is an upsert-by-id, so repeated calls update one row rather than duplicating.
    /// Boundary flushes (tool start/finish, HITL park) pass `immediate: true`; the token path
    /// coalesces behind `inFlightFlushInterval`. No-ops if the task was cancelled (e.g. a
    /// delete-conversation cascade is tearing the run down) so a late flush can't re-insert a row
    /// that is being deleted.
    private func flushInFlight(_ message: ChatMessage, conversationID: UUID, immediate: Bool = false) async {
        if Task.isCancelled { return }
        if !immediate, let last = lastInFlightFlush[message.id], -last.timeIntervalSinceNow < Self.inFlightFlushInterval {
            return
        }
        lastInFlightFlush[message.id] = Date()
        await persistenceService.addMessage(message, toConversation: conversationID)
    }

    private func finalizeMessage(_ message: ChatMessage, conversationID: UUID, error: Error?) async {
        message.isStreaming = false
        // [G1 Piece 1] A finalized run (success, error, or user Stop) is a clean terminal state —
        // mark it `.final` so it is NOT mistaken for an interrupted run on restart. Only a process
        // death that skips finalize leaves a persisted `.streaming` / `.parkedHITL` row behind.
        message.lifecycleState = .final
        lastInFlightFlush.removeValue(forKey: message.id)
        message.agentState = .idle
        // [HITL/P5] No center drain here: a normally-finalized stream has no parked HITL (the agent
        // can't complete while waiting), and cancel/error paths route through
        // ExecutionSuspensionService.cancel(for:) which posts .hitl*Resolved → op-id resolve.
        // A coarse resolveAll(conversationID:) here would wrongly clear a *concurrent* stream's
        // still-parked HITL in the same conversation, so it is intentionally omitted.

        // NOTE: per-conversation "Allow for this chat" grants are deliberately NOT cleared here. They
        // persist for the conversation's lifetime (and across restarts via SessionToolApprovals' durable
        // store), so a later message in the same chat isn't re-prompted; they're dropped only when the
        // conversation is deleted (ConversationManagementCoordinator.drainLiveExecution).

        // Terminal-outcome safety net: if no executor emitted `.executionFinished`
        // (legacy code path, early `continuation.finish()` in a catch block, or a
        // third-party executor), infer the outcome from how the run actually ended.
        // [ASM-4] Keying only on "did a throw reach us" stamped `.completed` (green
        // chip + `completed` trace status) over an ERROR CARD whenever a producer
        // yielded `.error` and then finished without throwing. The resolver also
        // inspects the content (pure + tested: `ChatMessage.resolveFallbackOutcome`).
        if message.terminalOutcome == nil {
            let fallback = ChatMessage.resolveFallbackOutcome(
                threwError: error,
                content: message.currentAgentContent ?? message.content
            )
            message.terminalOutcome = fallback.outcome
            if message.terminalReason == nil {
                message.terminalReason = fallback.reason
            }
            if error == nil, fallback.outcome == .failed {
                logger.warning("[STREAM_FINALIZE] messageID: \(message.id.uuidString.prefix(8)) — no .executionFinished received; inferred .failed from error-card content (previously recorded .completed) (ASM-4).")
            }
        }

        // [TL-1] Close any tool row still spinning at end-of-run — cancel and failure
        // mid-tool used to persist rows with `isExecuting == true`, so the spinner
        // survived reload forever.
        let danglingClosed = message.closeDanglingToolRows(outcome: message.terminalOutcome)
        if danglingClosed > 0 {
            logger.warning("[STREAM_FINALIZE] messageID: \(message.id.uuidString.prefix(8)) — closed \(danglingClosed) dangling tool row(s) at finalize (outcome: \(message.terminalOutcome?.rawValue ?? "nil")); a persisted row must never claim to still be executing (TL-1).")
        }

        if let traceID = message.traceID {
            // Derive the persisted trace status from how the run *actually* ended, not
            // merely from whether an error was thrown. A thrown exception reaching this
            // boundary is the most severe signal and always wins; otherwise we honor the
            // `terminalOutcome` the executor reported via `.executionFinished` (set just
            // above), so graceful failures (circuit-breaker, exhaustion, all-nodes-failed,
            // ImageGen) and cancellations stop being recorded as `.completed`.
            // `terminalReason` carries the human-readable cause for non-thrown failures;
            // it is sanitized inside `endTrace`.
            let traceStatus = TraceStatus.resolve(thrownError: error != nil, terminalOutcome: message.terminalOutcome)
            let endErrorSummary = error?.localizedDescription ?? message.terminalReason
            logger.info("[TRACE_END] traceID: \(traceID), status: \(traceStatus.rawValue), messageID: \(message.id.uuidString.prefix(8))")
            await TraceRecorder.shared.endTrace(traceID: traceID, status: traceStatus, error: endErrorSummary)
            if let usage = message.tokenUsage {
                await TraceRecorder.shared.recordTokenUsage(traceID: traceID, usage: usage)
            }
        }
        
        if let error = error {
            // Render typed retrieval failures (e.g. an attached image that couldn't
            // be loaded for a vision turn) with their category icon + remediation,
            // symmetric with the streaming `.error(StructuredError)` path, instead of
            // the generic "Response Error" card this chokepoint would otherwise force.
            let errorCard: MessageContent
            if let fre = error as? FileRetrievalError {
                let se = fre.structuredError
                errorCard = .error(title: se.title, details: se.message, category: se.category, suggestion: se.suggestion)
            } else {
                errorCard = .error(title: "Response Error", details: error.localizedDescription)
            }

            // [ASM-2] Don't discard prose the user watched stream: if real partial text
            // exists it stays as content and the error demotes to a timeline warning
            // (failure remains loud via the `.failed` chip + retry). No prose → the
            // error card replaces as before. Pure + tested: `resolveThrownFinalContent`.
            let resolved = ChatMessage.resolveThrownFinalContent(
                streamed: message.currentAgentContent ?? message.content,
                errorCard: errorCard
            )
            message.content = resolved.content
            if let demoted = resolved.demotedError {
                message.appendTimelineEvent(demoted)
                let kept = resolved.content.textContent?.count ?? 0
                logger.log("[STREAM_FINALIZE] messageID: \(message.id.uuidString.prefix(8)) — preserved \(kept) chars of partial streamed prose; terminal error demoted to timeline (ASM-2).")
            }

            if let agentResponse = message.agentResponse,
               agentResponse.variants.indices.contains(agentResponse.selectedVariantIndex) {
                message.agentResponse?.variants[agentResponse.selectedVariantIndex].content = resolved.content
            }
        } else {
            // Resolve the display content: streamed text if any; else a generated
            // image (image runs stream NO text — without this promotion the artifact
            // stayed only in the timeline as a `.mediaGeneration` event, which the
            // bubble can't render, so a successful generation showed the placeholder
            // and the image was invisible — audit gap #2); else the "stopped"
            // placeholder so an empty/cancelled run doesn't masquerade as a clean
            // completion. Logic lives in `ChatMessage.resolveFinalizedContent` so it's
            // unit-testable (GeneratedImageRenderGapTests).
            let resolvedContent = ChatMessage.resolveFinalizedContent(
                streamed: message.currentAgentContent,
                imageArtifact: message.lastCompletedImageArtifact
            )
            message.content = resolvedContent
            // Keep the selected variant in sync so `currentAgentContent` (which the UI
            // reads) doesn't return a stale empty variant. A no-op when `resolvedContent`
            // IS the streamed content; load-bearing for the promoted-image / placeholder
            // cases.
            if let agentResponse = message.agentResponse,
               agentResponse.variants.indices.contains(agentResponse.selectedVariantIndex) {
                message.agentResponse?.variants[agentResponse.selectedVariantIndex].content = resolvedContent
            }
        }
        
        // Persist final message
        await persistenceService.addMessage(message, toConversation: conversationID)
        
        // [RAG UPGRADE] Event-Driven Vectorization
        // Fire-and-forget: Index the final message into the vector database without blocking the UI.
        Task.detached(priority: .background) {
            // Brief pause to ensure UI settles and CoreData write completes
            try? await Task.sleep(nanoseconds: 500_000_000)
            await RAGIndexingService.shared.indexSingleMessage(message)
        }
        
        activeStreams.removeValue(forKey: message.id)
        streamStartedAt.removeValue(forKey: message.id)
        for delegate in liveMirrorDelegates {
            delegate.activeStreamManager(self, didEndStream: message)
        }

        // Dispatch notification if app is in background
        let notifConversationID = conversationID
        let hasError = error != nil
        let summaryText: String = {
            switch message.content {
            case .plainText(let text), .markdownText(let text):
                return String(text.prefix(100))
            default:
                return hasError ? "An error occurred." : "Response complete."
            }
        }()

        Task.detached(priority: .utility) {
            // [C6] Suppress when the user is actively viewing — app frontmost OR the
            // non-activating QuickAccess panel is key (which NSApp.isActive alone misses,
            // so a completion the user watches in the panel would otherwise double-notify).
            let userIsViewing = await MainActor.run { NSApp.isActive || (AppDelegate.shared?.isQuickAccessPanelKey ?? false) }
            guard !userIsViewing else { return }

            let config = await NotificationConfiguration.shared
            guard await config.isNotificationEnabled(for: notifConversationID) else { return }

            let payload = AppNotificationPayload(
                title: hasError ? "Query Failed" : "Query Completed",
                body: summaryText,
                conversationID: notifConversationID
            )
            await NotificationDispatcher.shared.dispatch(payload)
        }
    }
    
    
    private func removeTask(for messageId: UUID) {
        if activeTasks.removeValue(forKey: messageId) != nil {
            logger.debug("Cleaned up and removed completed task for message ID: \(messageId.uuidString)")
        }
    }
}
