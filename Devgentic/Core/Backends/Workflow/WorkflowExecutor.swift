//
//  WorkflowExecutor.swift
//  Devgentic
//
//  Created by Raj Singh on 13/03/26.
//
//  The centralized DAG orchestrator for visual workflow execution.
//  Reads the canvas layout, topologically sorts nodes, and executes each
//  node sequentially by delegating to AgentConnect for per-node model/tool resolution.
//  Upstream results are injected as structured context into downstream nodes.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "WorkflowExecutor")

actor WorkflowExecutor: Executor {

    // MARK: - Properties

    nonisolated let architecture: AgentArchitecture = .workflow
    nonisolated let workflowProfileID: UUID

    // MARK: - Initialization

    init(workflowProfileID: UUID = UUID()) {
        self.workflowProfileID = workflowProfileID
    }

    // MARK: - Standard Executor Conformance

    /// Standard Executor protocol entry point.
    /// For workflows, this is a no-op fallback — real execution goes through `executeWorkflow()`.
    nonisolated func execute(
        model: any LLMProvider,
        input: AgentInput,
        onTraceUpdate: @escaping @Sendable (AgentTraceLog) -> Void
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        // Delegate to the workflow-specific entry point with empty agents.
        // In practice, this path is never hit — AgentConnect calls executeWorkflow() directly.
        return executeWorkflow(
            agentProfileIDs: [],
            userInput: input.userInput,
            chatHistory: input.chatHistory,
            conversationID: input.conversationID,
            ragContext: nil,
            traceContext: input.traceContext,
            onTraceUpdate: onTraceUpdate
        )
    }

    // MARK: - Workflow Execution

    /// The primary workflow execution entry point.
    /// Loads the canvas DAG, resolves profiles, and orchestrates sequential node execution.
    ///
    /// - Parameters:
    ///   - agents: The `BackendProfileModel` array embedded in `ProfileDetails.workflow`.
    ///   - userInput: The original user query.
    ///   - chatHistory: The conversation history (passed through to each node).
    ///   - conversationID: The active conversation's UUID.
    ///   - ragContext: Optional RAG retrieval context (passed through to each node).
    ///   - traceContext: The parent trace context for distributed tracing.
    ///   - onTraceUpdate: Callback for trace log events.
    /// - Returns: An `AsyncThrowingStream` of `AgentStreamEvent` for UI consumption.
    nonisolated func executeWorkflow(
        agentProfileIDs: [UUID],
        userInput: String,
        chatHistory: [ChatMessage],
        conversationID: UUID,
        ragContext: String?,
        traceContext: TraceContext,
        onTraceUpdate: @escaping @Sendable (AgentTraceLog) -> Void
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {

        let profileID = workflowProfileID

        return AsyncThrowingStream<AgentStreamEvent, Error> { continuation in
            let task = Task {
                do {
                    logger.info("Workflow execution initiated for profile: \(profileID)")

                    // =====================================================================
                    // 1. LOAD & VALIDATE DAG
                    // =====================================================================

                    let layout = WorkflowLayoutStore.shared.load(for: profileID)

                    guard !layout.nodes.isEmpty else {
                        throw WorkflowError.emptyWorkflow
                    }

                    guard let sortedNodeIDs = layout.topologicalSort() else {
                        throw WorkflowError.cycleDetected
                    }

                    logger.info("DAG validated: \(layout.nodes.count) nodes, \(layout.edges.count) edges. Execution order: \(sortedNodeIDs.map(\.uuidString).joined(separator: " → "))")

                    // =====================================================================
                    // 2. BUILD PROFILE LOOKUP (resolve UUIDs → snapshots)
                    // =====================================================================

                    // Resolve agent profile UUIDs to live snapshots from the profile store.
                    let resolvedProfiles = await MainActor.run { (try? BackendProfileStore.shared.fetchProfiles()) ?? [] }
                    let profileMap = Dictionary(
                        resolvedProfiles.filter { agentProfileIDs.contains($0.id) }.map { ($0.id, $0) },
                        uniquingKeysWith: { first, _ in first }
                    )

                    // =====================================================================
                    // 3. EXECUTE DAG (Sequential Topological Order)
                    // =====================================================================

                    let totalNodes = sortedNodeIDs.count
                    var memory = WorkflowMemoryStrategy()
                    let agentConnect = AgentConnect()

                    continuation.yield(.thought("Starting workflow with \(totalNodes) node(s)..."))

                    for (index, nodeID) in sortedNodeIDs.enumerated() {
                        try Task.checkCancellation()

                        // --- Resolve Node ---
                        guard let node = layout.nodes.first(where: { $0.id == nodeID }) else {
                            logger.warning("Orphan nodeID in topological sort: \(nodeID). Skipping.")
                            continue
                        }

                        guard let nodeProfile = profileMap[node.profileID] else {
                            // Profile was deleted after canvas save
                            let error = WorkflowError.profileNotFound(profileID: node.profileID, nodeName: node.displayName)
                            logger.error("Profile not found for node '\(node.displayName)': \(node.profileID)")

                            memory.recordNodeResult(NodeResultEnvelope(
                                taskID: UUID(),
                                nodeID: nodeID,
                                sourceProfileID: node.profileID,
                                profileName: node.displayName,
                                profileType: node.profileType,
                                status: .failed(error.localizedDescription ?? "Profile not found"),
                                output: "",
                                artifacts: [],
                                metadata: .simple(start: Date(), end: Date(), output: "")
                            ))
                            continuation.yield(.workflowNodeFailed(nodeID: nodeID, profileName: node.displayName, error: error.localizedDescription ?? "Profile not found"))
                            continuation.yield(.workflowProgress(completed: index + 1, total: totalNodes))
                            continue
                        }

                        // --- Check Upstream Dependencies ---
                        if !memory.allUpstreamsSucceeded(for: nodeID, edges: layout.edges) {
                            let skipReason = "Upstream dependency failed"
                            logger.notice("Skipping node '\(node.displayName)': \(skipReason)")

                            memory.recordNodeResult(NodeResultEnvelope(
                                taskID: UUID(),
                                nodeID: nodeID,
                                sourceProfileID: node.profileID,
                                profileName: node.displayName,
                                profileType: node.profileType,
                                status: .skipped(reason: skipReason),
                                output: "",
                                artifacts: [],
                                metadata: .simple(start: Date(), end: Date(), output: "")
                            ))
                            continuation.yield(.workflowNodeFailed(nodeID: nodeID, profileName: node.displayName, error: skipReason))
                            continuation.yield(.workflowProgress(completed: index + 1, total: totalNodes))
                            continue
                        }

                        // --- Emit Node Started ---
                        continuation.yield(.workflowNodeStarted(
                            nodeID: nodeID,
                            profileName: node.displayName,
                            index: index + 1,
                            total: totalNodes
                        ))

                        let startTime = Date()
                        let nodeSpan = traceContext.newSpan()

                        onTraceUpdate(AgentTraceLog(
                            traceID: nodeSpan.traceID,
                            spanID: nodeSpan.spanID,
                            parentSpanID: nodeSpan.parentSpanID,
                            stepNumber: index + 1,
                            state: .acting(.subtask(current: index + 1, total: totalNodes)),
                            content: "Executing workflow node: \(node.displayName) (\(node.profileType.rawValue))"
                        ))

                        // --- Compile Upstream Context ---
                        let upstreamResults = memory.upstreamResults(for: nodeID, edges: layout.edges)
                        let contextPreamble = ContextCompressor.compile(results: upstreamResults)

                        // Build the query with upstream context injection
                        let nodeQuery: String
                        if contextPreamble.isEmpty {
                            nodeQuery = userInput
                        } else {
                            nodeQuery = contextPreamble + "\n\n---\nUser Request: " + userInput
                        }

                        logger.info("Node '\(node.displayName)' query assembled. Upstream context: \(contextPreamble.isEmpty ? "None" : "\(contextPreamble.count) chars")")

                        // --- Execute Node via AgentConnect ---
                        var nodeOutput = ""
                        var nodeArtifacts: [ToolOutput] = []
                        var nodeStatus: NodeExecutionStatus = .completed

                        do {
                            let nodeStream = agentConnect.streamAgentResponse(
                                for: nodeProfile,
                                userInput: nodeQuery,
                                chatHistory: chatHistory,
                                conversationID: conversationID,
                                ragContext: ragContext,
                                traceContext: nodeSpan,
                                onTraceUpdate: onTraceUpdate
                            )

                            for try await event in nodeStream {
                                switch event {
                                case .content(let text):
                                    // Accumulate content — don't forward individual tokens
                                    // during workflow. Terminal node outputs are emitted at the end.
                                    nodeOutput += text

                                case .toolOutput(let output):
                                    nodeArtifacts.append(output)
                                    continuation.yield(.toolOutput(output))

                                case .thought(let msg, let id):
                                    continuation.yield(.thought("[\(node.displayName)] \(msg)", id: id))

                                case .toolCall(let name, let params):
                                    continuation.yield(.toolCall(name: name, params: params))

                                case .requestConfirmation(let toolName, let params, let operationID):
                                    // Bubble up HITL permission requests (preserve operationID)
                                    continuation.yield(.requestConfirmation(toolName: toolName, params: params, operationID: operationID))

                                case .requestClarification(let question, let operationID):
                                    // Prefix clarification with node name for context (preserve operationID)
                                    continuation.yield(.requestClarification(question: "[\(node.displayName)] \(question)", operationID: operationID))

                                case .error(let errMsg):
                                    continuation.yield(.error("[\(node.displayName)] \(errMsg)"))

                                case .workflowNodeStarted, .workflowNodeCompleted, .workflowNodeFailed, .workflowProgress:
                                    // Ignore nested workflow events (shouldn't happen, but safety)
                                    break

                                case .mediaProgress, .artifactProduced:
                                    continuation.yield(event)

                                case .requestPlanReview:
                                    // Bubble up plan review HITL requests (preserve operationID)
                                    continuation.yield(event)

                                case .planGenerated, .subtaskStarted, .subtaskCompleted,
                                     .reflectionTrialStarted, .reflectionEvaluating, .reflectionRetrying, .reflectionAccepted,
                                     .delegationStarted, .delegationCompleted:
                                    // Forward capability events from inner node execution
                                    continuation.yield(event)
                                }
                            }
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            nodeStatus = .failed(error.localizedDescription)
                            logger.error("Node '\(node.displayName)' failed: \(error.localizedDescription)")
                        }

                        let endTime = Date()

                        // --- Record Node Result ---
                        let result = NodeResultEnvelope(
                            taskID: UUID(),
                            nodeID: nodeID,
                            sourceProfileID: node.profileID,
                            profileName: node.displayName,
                            profileType: node.profileType,
                            status: nodeStatus,
                            output: nodeOutput,
                            artifacts: [],
                            metadata: NodeExecutionMetadata(
                                startTime: startTime,
                                endTime: endTime,
                                iterationsUsed: 1,
                                toolsInvoked: nodeArtifacts.map(\.toolName),
                                tokenEstimate: nodeOutput.count / 4
                            )
                        )
                        memory.recordNodeResult(result)

                        // --- Emit Node Completion ---
                        switch nodeStatus {
                        case .completed:
                            let summary = String(nodeOutput.prefix(100)) + (nodeOutput.count > 100 ? "..." : "")
                            continuation.yield(.workflowNodeCompleted(
                                nodeID: nodeID,
                                profileName: node.displayName,
                                summary: summary
                            ))
                            logger.info("Node '\(node.displayName)' completed. Output: \(nodeOutput.count) chars, Duration: \(String(format: "%.1f", result.metadata.duration))s")

                        case .failed(let errorMsg):
                            continuation.yield(.workflowNodeFailed(
                                nodeID: nodeID,
                                profileName: node.displayName,
                                error: errorMsg
                            ))

                        case .canceled:
                            continuation.yield(.workflowNodeFailed(
                                nodeID: nodeID,
                                profileName: node.displayName,
                                error: "Cancelled"
                            ))

                        case .skipped(let reason):
                            continuation.yield(.workflowNodeFailed(
                                nodeID: nodeID,
                                profileName: node.displayName,
                                error: "Skipped: \(reason)"
                            ))
                        }

                        continuation.yield(.workflowProgress(completed: index + 1, total: totalNodes))
                    }

                    // =====================================================================
                    // 4. SYNTHESIZE FINAL OUTPUT (Terminal Nodes)
                    // =====================================================================

                    let terminalResults = memory.terminalResults(
                        edges: layout.edges,
                        allNodeIDs: sortedNodeIDs
                    )

                    let successfulTerminals = terminalResults.filter {
                        if case .completed = $0.status { return true }
                        return false
                    }

                    if !successfulTerminals.isEmpty {
                        let finalOutput = successfulTerminals
                            .map(\.output)
                            .joined(separator: "\n\n")

                        if !finalOutput.isEmpty {
                            continuation.yield(.content(finalOutput))
                        }

                        logger.info("Workflow completed. \(successfulTerminals.count)/\(terminalResults.count) terminal nodes succeeded.")
                    } else {
                        continuation.yield(.error("Workflow completed but all terminal nodes failed."))
                        logger.warning("Workflow completed but all terminal nodes failed.")
                    }

                    // Log execution summary
                    let executionLog = memory.executionLog
                    let totalDuration = executionLog.reduce(0.0) { $0 + $1.duration }
                    logger.notice("Workflow execution summary: \(executionLog.count) nodes processed in \(String(format: "%.1f", totalDuration))s")

                    continuation.finish()

                } catch is CancellationError {
                    logger.notice("Workflow cancelled for conversation: \(conversationID)")
                    await ExecutionSuspensionService.shared.cancel(for: conversationID)
                    continuation.finish()
                } catch {
                    logger.error("Workflow fatal error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
