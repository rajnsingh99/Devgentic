//
//  ActiveStreamManager.swift
//  Devgentic
//
//  Created by Raj Singh on 19/08/25.
//

import Foundation
import AppKit
import os


private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ActiveStreamManager")

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
    @ObservationIgnored nonisolated(unsafe) private var permissionResolvedObserver: Any?
    @ObservationIgnored nonisolated(unsafe) private var clarificationResolvedObserver: Any?
    @ObservationIgnored nonisolated(unsafe) private var planReviewResolvedObserver: Any?

    @ObservationIgnored private let persistenceService: ChatPersistenceProtocol
    @ObservationIgnored private let fileProcessorService: FileProcessorService
    @ObservationIgnored private let backendOrchestrationService: BackendOrchestrationService

    /// Delegate for RemoteMirrorService to observe stream lifecycle without Combine.
    weak var mirrorDelegate: ActiveStreamMirrorDelegate?

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
            MainActor.assumeIsolated {
                guard let self, let conversationID else { return }
                // Find the active stream for this conversation and clear its pending confirmation
                for (_, message) in self.activeStreams where message.conversationId == conversationID {
                    if case .toolConfirmation = message.pendingInteraction {
                        message.pendingInteraction = nil
                        message.agentState = .thinking(.reflecting)
                        message.thinkingHeadline = "Processing..."
                        logger.info("Cleared stale tool confirmation banner for conversation \(conversationID) (resolved externally).")
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
            MainActor.assumeIsolated {
                guard let self, let conversationID else { return }
                // Find the active stream for this conversation and clear its pending clarification
                for (_, message) in self.activeStreams where message.conversationId == conversationID {
                    if case .clarification = message.pendingInteraction {
                        message.pendingInteraction = nil
                        message.agentState = .thinking(.reflecting)
                        message.thinkingHeadline = "Processing..."
                        logger.info("Cleared stale clarification banner for conversation \(conversationID) (resolved externally).")
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
            MainActor.assumeIsolated {
                guard let self, let conversationID else { return }
                // Find the active stream for this conversation and clear its pending plan review
                for (_, message) in self.activeStreams where message.conversationId == conversationID {
                    if case .planReview = message.pendingInteraction {
                        message.pendingInteraction = nil
                        message.agentState = .thinking(.planning)
                        message.thinkingHeadline = "Executing plan..."
                        logger.info("Cleared stale plan review banner for conversation \(conversationID) (resolved externally).")
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
        onComplete: @escaping () -> Void
    ) -> ChatMessage {
        
        let agentMessage: ChatMessage
        let isRegeneration = existingMessage != nil

        if let messageToUpdate = existingMessage {
            agentMessage = messageToUpdate
            logger.notice("🚀 [STREAM_REGENERATE] Updating message \(agentMessage.id.uuidString) in conversation \(conversationID.uuidString).")
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
        
        activeStreams[agentMessage.id] = agentMessage
        mirrorDelegate?.activeStreamManager(self, didStartStream: agentMessage, for: conversationID)

        // Defer initial state mutations to the next run loop tick.
        // This prevents "Modifying state during view update" warnings when the returned
        // ChatMessage is immediately assigned to SwiftUI state within a view update cycle.
        Task { @MainActor in
            agentMessage.agentState = .thinking(.reasoning)
            agentMessage.thinkingHeadline = "Processing..."
        }
        
        let streamTask = Task { [weak self] in
            guard let self = self else { return }
            
            do {
                let traceContext = TraceContext(profile: config.profile, messageID: agentMessage.id)
                agentMessage.traceID = traceContext.traceID

                let profileType = config.profile.profileType.rawValue
                logger.info("[TRACE_INIT] traceID: \(traceContext.traceID), spanID: \(traceContext.spanID), profileType: \(profileType), messageID: \(agentMessage.id.uuidString.prefix(8)), conversationID: \(conversationID.uuidString.prefix(8))")

                Task {
                    await TraceRecorder.shared.beginTrace(
                        context: traceContext,
                        conversationID: conversationID,
                        messageID: agentMessage.id,
                        modelName: nil
                    )
                }

                logger.info("[STREAM_HANDOFF] Passing to BackendOrchestrationService — traceID: \(traceContext.traceID), query: \(String(userQuery.prefix(80))), history: \(history.count) msgs, files: \(files.count)")

                let stream = self.backendOrchestrationService.streamMessage(
                    withConfig: config,
                    conversationID: conversationID,
                    userQuery: userQuery,
                    history: history,
                    files: files,
                    context: traceContext,
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
                        agentMessage.thinkingHeadline = thoughtText
                        agentMessage.agentState = .thinking(.reasoning)
                        let thoughtEvent = TimelineEvent.thought(id: id, text: thoughtText)
                        if let wfState = workflowExecutionState, let nodeID = sourceNodeID {
                            wfState.appendNodeTimelineEvent(thoughtEvent, for: nodeID)
                            logger.debug("[WF_ROUTE] Thought → node timeline [\(nodeID)], count=\(wfState.nodeTimelines[nodeID]?.count ?? 0)")
                        } else {
                            agentMessage.appendTimelineEvent(thoughtEvent)
                        }

                    case .toolCall(let name, let params, let sourceNodeID):
                        agentMessage.thinkingHeadline = "Using tool: \(name)"
                        agentMessage.agentState = .acting(.tool(name: name))
                        let toolEvent = TimelineEvent.toolExecution(
                            ToolExecutionData(id: UUID(), name: name, params: params, output: nil, isSuccess: nil, isExecuting: true)
                        )
                        if let wfState = workflowExecutionState, let nodeID = sourceNodeID {
                            wfState.appendNodeTimelineEvent(toolEvent, for: nodeID)
                            logger.debug("[WF_ROUTE] ToolCall '\(name)' → node timeline [\(nodeID)], count=\(wfState.nodeTimelines[nodeID]?.count ?? 0)")
                        } else {
                            agentMessage.appendTimelineEvent(toolEvent)
                        }
                        
                    // [HITL] Phase 3: Handle Permission Requests
                    case .requestConfirmation(let toolName, let params, let operationID, let sourceNodeID):
                        if let wfState = workflowExecutionState, let nodeID = sourceNodeID {
                            // Workflow mode — route to WorkflowInteractionPanel
                            let runningNode = wfState.nodeResults.first(where: { $0.nodeID == nodeID })
                            let recentTimeline = Array(wfState.nodeTimelines[nodeID]?.suffix(3) ?? [])
                            let request = WorkflowInteractionRequest(
                                id: operationID,
                                nodeID: nodeID,
                                nodeName: runningNode?.profileName ?? toolName,
                                nodeKind: .gate(GateNodeConfig(prompt: toolName, options: [], timeout: nil)),
                                requestType: .toolConfirmation(toolName: toolName, params: params),
                                timestamp: Date(),
                                recentTimeline: recentTimeline,
                                upstreamNodeNames: []
                            )
                            wfState.addPendingInteraction(request)
                            agentMessage.thinkingHeadline = "[\(runningNode?.profileName ?? "Node")] Waiting for approval..."
                            agentMessage.agentState = .interaction(.permission(toolName: toolName))
                        } else {
                            // Normal agent mode
                            agentMessage.thinkingHeadline = "Waiting for approval: \(toolName)"
                            agentMessage.agentState = .interaction(.permission(toolName: toolName))
                            agentMessage.pendingInteraction = .toolConfirmation(
                                PendingToolConfirmation(id: operationID, toolName: toolName, params: params)
                            )
                        }

                    // [ASK_USER] Handle Clarification Requests
                    case .requestClarification(let question, let operationID, let sourceNodeID):
                        if let wfState = workflowExecutionState, let nodeID = sourceNodeID {
                            // Workflow mode — route to WorkflowInteractionPanel
                            let runningNode = wfState.nodeResults.first(where: { $0.nodeID == nodeID })
                            let recentTimeline = Array(wfState.nodeTimelines[nodeID]?.suffix(3) ?? [])
                            let request = WorkflowInteractionRequest(
                                id: operationID,
                                nodeID: nodeID,
                                nodeName: runningNode?.profileName ?? "Agent",
                                nodeKind: .profile(profileID: UUID(), profileType: .agent),
                                requestType: .askUser(question: question),
                                timestamp: Date(),
                                recentTimeline: recentTimeline,
                                upstreamNodeNames: []
                            )
                            wfState.addPendingInteraction(request)
                            agentMessage.thinkingHeadline = "[\(runningNode?.profileName ?? "Node")] Asking you a question..."
                            agentMessage.agentState = .interaction(.clarification)
                        } else {
                            // Normal agent mode
                            agentMessage.thinkingHeadline = "Asking you a question..."
                            agentMessage.agentState = .interaction(.clarification)
                            agentMessage.pendingInteraction = .clarification(
                                PendingClarification(id: operationID, question: question)
                            )
                        }

                    case .toolSucceeded(let output, let durationMs, let sourceNodeID):
                        agentMessage.agentState = .thinking(.reflecting)
                        agentMessage.thinkingHeadline = "Processed \(output.toolName)"
                        Self.completeToolTimelineEvent(
                            output: output,
                            failureCategory: nil,
                            durationMs: durationMs,
                            sourceNodeID: sourceNodeID,
                            agentMessage: agentMessage,
                            workflowExecutionState: workflowExecutionState
                        )
                        Self.clearMatchingPendingInteraction(toolName: output.toolName, agentMessage: agentMessage)

                    case .toolFailed(let output, let category, let suggestion, let sourceNodeID):
                        agentMessage.agentState = .thinking(.reflecting)
                        agentMessage.thinkingHeadline = "\(category.displayName): \(output.toolName)"
                        Self.completeToolTimelineEvent(
                            output: output,
                            failureCategory: category,
                            durationMs: nil,
                            sourceNodeID: sourceNodeID,
                            agentMessage: agentMessage,
                            workflowExecutionState: workflowExecutionState
                        )
                        Self.clearMatchingPendingInteraction(toolName: output.toolName, agentMessage: agentMessage)
                        if let s = suggestion {
                            logger.debug("[TOOL_FAILED] \(output.toolName) [\(category.rawValue)] suggestion: \(s)")
                        }


                    case .content(let textChunk):
                        // 3. Handle Final Text (Buffered)
                        if agentMessage.agentState != .thinking(.finalizing) {
                            agentMessage.agentState = .thinking(.finalizing)
                            agentMessage.thinkingHeadline = "Finalizing..."
                        }
                        
                        tokenBuffer += textChunk
                        tokensReceivedInWindow += textChunk.count

                        let elapsed = -lastUpdateTime.timeIntervalSinceNow
                        if elapsed >= adaptiveInterval || tokenBuffer.count > 50 {
                            self.updateMessageContent(agentMessage, with: tokenBuffer, isRegeneration: isRegeneration)

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
                        
                    case .error(let errorMsg):
                        logger.error("Stream Error Event: \(errorMsg)")

                    case .warning(let category, let message, _, let sourceNodeID):
                        agentMessage.thinkingHeadline = "⚠️ \(message)"
                        let warningEvent = TimelineEvent.warning(id: UUID(), category: category, text: message)
                        if let wfState = workflowExecutionState, let nodeID = sourceNodeID {
                            wfState.appendNodeTimelineEvent(warningEvent, for: nodeID)
                            logger.debug("[WF_ROUTE] Warning[\(category.rawValue)] → node timeline [\(nodeID)]")
                        } else {
                            agentMessage.appendTimelineEvent(warningEvent)
                        }
                        logger.warning("Stream Warning [\(category.rawValue)]: \(message)")

                    // MARK: Workflow Orchestration Events
                    case .workflowNodeStarted(let nodeID, let profileName, let idx, let total):
                        agentMessage.thinkingHeadline = "Running \(profileName) (\(idx)/\(total))..."
                        agentMessage.agentState = .acting(.subtask(current: idx, total: total))
                        logger.info("[WF_EVENT] NodeStarted: '\(profileName)' [\(nodeID)] (\(idx)/\(total))")
                        workflowExecutionState?.handleNodeStarted(nodeID: nodeID, profileName: profileName, index: idx, total: total)

                    case .workflowNodeCompleted(let nodeID, let profileName, let summary):
                        agentMessage.thinkingHeadline = "\(profileName) completed"
                        let completedId = UUID()
                        agentMessage.appendTimelineEvent(.thought(id: completedId, text: "✅ \(profileName): \(summary)"))
                        logger.info("[WF_EVENT] NodeCompleted: '\(profileName)' [\(nodeID)] summary=\(String(summary.prefix(200)))")
                        workflowExecutionState?.handleNodeCompleted(nodeID: nodeID, profileName: profileName, summary: summary)

                    case .workflowNodeFailed(let nodeID, let profileName, let error):
                        agentMessage.thinkingHeadline = "\(profileName) failed"
                        let failedId = UUID()
                        agentMessage.appendTimelineEvent(.thought(id: failedId, text: "❌ \(profileName): \(error)"))
                        logger.info("[WF_EVENT] NodeFailed: '\(profileName)' [\(nodeID)] error=\(error)")
                        workflowExecutionState?.handleNodeFailed(nodeID: nodeID, profileName: profileName, error: error)

                    case .workflowProgress(let completed, let total):
                        agentMessage.thinkingHeadline = "Workflow progress: \(completed)/\(total)"
                        logger.info("[WF_EVENT] Progress: \(completed)/\(total)")
                        workflowExecutionState?.handleProgress(completed: completed, total: total)

                    case .workflowLoopIteration(let nodeID, let profileName, let iteration, let maxIterations):
                        agentMessage.thinkingHeadline = "Loop \(profileName): iteration \(iteration)/\(maxIterations)"
                        let iterationId = UUID()
                        agentMessage.appendTimelineEvent(.thought(id: iterationId, text: "🔄 \(profileName): iteration \(iteration)/\(maxIterations)"))
                        logger.info("[WF_EVENT] LoopIteration: '\(profileName)' [\(nodeID)] \(iteration)/\(maxIterations)")
                        workflowExecutionState?.handleLoopIteration(nodeID: nodeID, profileName: profileName, iteration: iteration, maxIterations: maxIterations)

                    // MARK: Capability Events (Planning, Self-Reflection, Delegation)

                    case .planGenerated(let count):
                        agentMessage.thinkingHeadline = "Planned \(count) subtask\(count == 1 ? "" : "s")"
                        agentMessage.agentState = .thinking(.planning)
                        agentMessage.appendTimelineEvent(.capabilityMilestone(
                            id: UUID(), kind: .planGenerated, detail: "Planned \(count) subtask\(count == 1 ? "" : "s")"
                        ))

                    case .requestPlanReview(let subtasks, let operationID):
                        agentMessage.thinkingHeadline = "Plan ready for review"
                        agentMessage.agentState = .interaction(.planReview)
                        agentMessage.pendingInteraction = .planReview(
                            PendingPlanReview(id: operationID, subtasks: subtasks)
                        )
                        agentMessage.appendTimelineEvent(.capabilityMilestone(
                            id: UUID(), kind: .planReviewRequested,
                            detail: "Plan with \(subtasks.count) subtask\(subtasks.count == 1 ? "" : "s") awaiting approval"
                        ))

                    case .subtaskStarted(let index, let total, let description):
                        agentMessage.thinkingHeadline = "Subtask \(index)/\(total): \(description)"
                        agentMessage.agentState = .acting(.subtask(current: index, total: total))
                        agentMessage.appendTimelineEvent(.capabilityMilestone(
                            id: UUID(), kind: .subtaskStarted, detail: "Subtask \(index)/\(total): \(description)"
                        ))

                    case .subtaskCompleted(let index, let total, let summary):
                        agentMessage.thinkingHeadline = "Subtask \(index)/\(total) complete"
                        agentMessage.appendTimelineEvent(.capabilityMilestone(
                            id: UUID(), kind: .subtaskCompleted, detail: "Subtask \(index)/\(total): \(summary)"
                        ))

                    case .reflectionTrialStarted(let trial, let maxTrials):
                        agentMessage.thinkingHeadline = "Attempt \(trial)/\(maxTrials)"
                        agentMessage.agentState = .thinking(.reasoning)
                        agentMessage.appendTimelineEvent(.capabilityMilestone(
                            id: UUID(), kind: .reflectionTrialStarted, detail: "Trial \(trial) of \(maxTrials)"
                        ))

                    case .reflectionEvaluating(let trial):
                        agentMessage.thinkingHeadline = "Evaluating attempt \(trial)..."
                        agentMessage.agentState = .thinking(.reflecting)
                        agentMessage.appendTimelineEvent(.capabilityMilestone(
                            id: UUID(), kind: .reflectionEvaluating, detail: "Evaluating trial \(trial)"
                        ))

                    case .reflectionRetrying(let trial, let critique):
                        let shortCritique = String(critique.prefix(80))
                        agentMessage.thinkingHeadline = "Retrying with feedback (\(trial + 1))..."
                        agentMessage.agentState = .thinking(.reflecting)
                        agentMessage.appendTimelineEvent(.capabilityMilestone(
                            id: UUID(), kind: .reflectionRetrying, detail: "Retry: \(shortCritique)"
                        ))

                    case .reflectionAccepted(let trial):
                        agentMessage.thinkingHeadline = "Result accepted (attempt \(trial))"
                        agentMessage.appendTimelineEvent(.capabilityMilestone(
                            id: UUID(), kind: .reflectionAccepted, detail: "Accepted on trial \(trial)"
                        ))

                    case .delegationStarted(let task):
                        let shortTask = String(task.prefix(60))
                        agentMessage.thinkingHeadline = "Delegating: \(shortTask)…"
                        agentMessage.agentState = .acting(.tool(name: "call_agent"))
                        agentMessage.appendTimelineEvent(.capabilityMilestone(
                            id: UUID(), kind: .delegationStarted, detail: shortTask
                        ))

                    case .delegationCompleted(let summary):
                        let shortSummary = String(summary.prefix(80))
                        agentMessage.thinkingHeadline = "Agent completed"
                        agentMessage.appendTimelineEvent(.capabilityMilestone(
                            id: UUID(), kind: .delegationCompleted, detail: shortSummary
                        ))

                    // MARK: History Compaction Events
                    case .compactionStarted(let turns, let checkpoint):
                        agentMessage.thinkingHeadline = "Compacting history (\(turns) turns)..."
                        agentMessage.appendTimelineEvent(.capabilityMilestone(
                            id: UUID(), kind: .compactionStarted,
                            detail: "Compacting \(turns) turns into checkpoint #\(checkpoint)"
                        ))

                    case .compactionCompleted(let turns, let preview):
                        let shortPreview = String(preview.prefix(100))
                        agentMessage.thinkingHeadline = nil
                        agentMessage.appendTimelineEvent(.capabilityMilestone(
                            id: UUID(), kind: .compactionCompleted,
                            detail: "History compacted \u{2014} \(turns) turns summarized: \(shortPreview)"
                        ))

                    // MARK: Multimodal Events
                    case .mediaProgress(let toolName, let percent, let status):
                        agentMessage.thinkingHeadline = "\(toolName): \(status) (\(Int(percent * 100))%)"

                    case .artifactProduced(let artifact):
                        agentMessage.appendTimelineEvent(.mediaGeneration(
                            id: UUID(),
                            toolName: artifact.label ?? artifact.kind.rawValue,
                            artifact: artifact,
                            isComplete: true
                        ))

                    // MARK: Token Usage
                    case .tokenUsage(let usage):
                        agentMessage.tokenUsage = usage

                    // MARK: Terminal Outcome
                    case .executionFinished(let outcome, let reason):
                        agentMessage.terminalOutcome = outcome
                        agentMessage.terminalReason = reason
                        logger.info("[STREAM_TERMINAL] outcome=\(outcome.rawValue), reason=\(reason ?? "nil")")
                    }
                }
                
                // Flush remaining text tokens
                if !tokenBuffer.isEmpty {
                    self.updateMessageContent(agentMessage, with: tokenBuffer, isRegeneration: isRegeneration)
                }
                
                logger.info("[STREAM_LOOP_END] Finished — traceID: \(traceContext.traceID), messageID: \(agentMessage.id.uuidString.prefix(8)), profileType: \(profileType)")

                // Forward final output to workflow execution state
                if let wfState = workflowExecutionState {
                    let finalText = agentMessage.content.textContent ?? ""
                    logger.info("[WF_EVENT] FinalOutput: \(finalText.count) chars, nodeTimelines=\(wfState.nodeTimelines.count) nodes tracked")
                    logger.debug("[WF_EVENT] FinalOutput preview: \(String(finalText.prefix(300)))")
                    wfState.handleFinalOutput(finalText)
                }

                await self.finalizeMessage(agentMessage, conversationID: conversationID, error: nil)

            } catch is CancellationError {
                logger.info("[STREAM_CANCELLED] traceID: \(agentMessage.traceID ?? "?"), messageID: \(agentMessage.id.uuidString.prefix(8))")
                workflowExecutionState?.handleError("Cancelled")
                await self.finalizeMessage(agentMessage, conversationID: conversationID, error: nil)
            } catch {
                logger.error("[STREAM_ERROR] traceID: \(agentMessage.traceID ?? "?"), messageID: \(agentMessage.id.uuidString.prefix(8)), error: \(error.localizedDescription)")
                workflowExecutionState?.handleError(error.localizedDescription)
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
        let updater: (inout ToolExecutionData) -> Void = { data in
            data.output = output.output
            data.isSuccess = output.isSuccess
            data.failureCategory = failureCategory
            data.durationMs = durationMs
            data.isExecuting = false
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

    /// Clears a pending HITL interaction iff it matches the tool that just completed.
    /// Blanket clearing would deadlock sequential interactive tools.
    private static func clearMatchingPendingInteraction(toolName: String, agentMessage: ChatMessage) {
        switch agentMessage.pendingInteraction {
        case .clarification where toolName == "ask_user":
            agentMessage.pendingInteraction = nil
        case .toolConfirmation(let pending) where pending.toolName == toolName:
            agentMessage.pendingInteraction = nil
        default:
            break
        }
    }

    private func updateMessageContent(_ agentMessage: ChatMessage, with newTextChunk: String, isRegeneration: Bool) {
        if isRegeneration {
            guard let agentResponse = agentMessage.agentResponse,
                  agentResponse.variants.indices.contains(agentResponse.selectedVariantIndex) else {
                return
            }
            var targetVariant = agentResponse.variants[agentResponse.selectedVariantIndex]
            if var currentText = targetVariant.content.textContent {
                currentText += newTextChunk
                targetVariant.content = .markdownText(currentText)
                agentMessage.agentResponse?.variants[agentResponse.selectedVariantIndex] = targetVariant
            }
        } else {
            if var currentText = agentMessage.content.textContent {
                currentText += newTextChunk
                let newContent = MessageContent.markdownText(currentText)
                agentMessage.content = newContent
                agentMessage.agentResponse?.variants[0].content = newContent
            }
        }
        // Invalidate cached markdown blocks so the next body evaluation reparses
        // with the updated content. This works with getOrCreateMarkdownBlocks() to
        // provide O(1) no-ops when body re-evaluates without new content.
        agentMessage.invalidateMarkdownCache()
    }
    
    public func cancelStream(for messageId: UUID) {
        guard let taskToCancel = activeTasks[messageId] else {
            logger.warning("Attempted to cancel a stream for message ID \(messageId.uuidString), but no active task was found.")
            return
        }
        
        logger.info("Cancelling stream task for message ID: \(messageId.uuidString)")
        taskToCancel.cancel()
    }
    
    
    private func finalizeMessage(_ message: ChatMessage, conversationID: UUID, error: Error?) async {
        message.isStreaming = false
        message.thinkingHeadline = nil // Clear the headline
        message.agentState = .idle
        message.pendingInteraction = nil

        // Terminal-outcome safety net: if no executor emitted `.executionFinished`
        // (legacy code path, early `continuation.finish()` in a catch block, or a
        // third-party executor), infer the outcome from whether an error reached us.
        // Without this, the UI would silently show a polished-looking bubble for what
        // was actually a failed run — exactly the trust-breaking mismatch we're fixing.
        if message.terminalOutcome == nil {
            message.terminalOutcome = (error != nil) ? .failed : .completed
            if message.terminalReason == nil, let err = error {
                message.terminalReason = err.localizedDescription
            }
        }

        if let traceID = message.traceID {
            let traceStatus: TraceStatus = error != nil ? .error : .completed
            logger.info("[TRACE_END] traceID: \(traceID), status: \(traceStatus == .completed ? "completed" : "error"), messageID: \(message.id.uuidString.prefix(8))")
            await TraceRecorder.shared.endTrace(traceID: traceID, status: traceStatus, error: error?.localizedDescription)
        }
        
        if let error = error {
            let errorContent = MessageContent.error(title: "Response Error", details: error.localizedDescription)
            message.content = errorContent
            
            if let agentResponse = message.agentResponse,
               agentResponse.variants.indices.contains(agentResponse.selectedVariantIndex) {
                message.agentResponse?.variants[agentResponse.selectedVariantIndex].content = errorContent
            }
        } else {
            if let currentAgentContent = message.currentAgentContent,
               let text = currentAgentContent.textContent,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Stream produced content before finishing/cancellation — keep it
                message.content = currentAgentContent
            } else {
                // No meaningful content was streamed (cancelled before response,
                // or response was empty whitespace). Show a placeholder so the
                // user knows the operation was stopped rather than seeing an
                // empty bubble with action buttons as if it completed normally.
                let placeholderContent = MessageContent.markdownText("*Operation was stopped before a response could be generated.*")
                message.content = placeholderContent
                // Also update the agentResponse variant to stay in sync —
                // without this, `currentAgentContent` could return a stale
                // empty variant that the UI reads instead of message.content.
                if let agentResponse = message.agentResponse,
                   agentResponse.variants.indices.contains(agentResponse.selectedVariantIndex) {
                    message.agentResponse?.variants[agentResponse.selectedVariantIndex].content = placeholderContent
                }
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
        mirrorDelegate?.activeStreamManager(self, didEndStream: message)

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
            let isAppActive = await MainActor.run { NSApp.isActive }
            guard !isAppActive else { return }

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
