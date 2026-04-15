//
//  WorkflowExecutor.swift
//  Devgentic
//
//  Created by Raj Singh on 13/03/26.
//
//  The centralized DAG orchestrator for visual workflow execution.
//  Reads the canvas layout, groups nodes into dependency levels, and executes
//  independent nodes in parallel via TaskGroup. Each node delegates to AgentConnect
//  for per-node model/tool resolution with per-node timeout enforcement.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "WorkflowExecutor")

/// TaskLocal depth counter for sub-workflow recursion protection.
enum WorkflowDepth {
    @TaskLocal static var current: Int = 0
    static let maxDepth: Int = 5
}

actor WorkflowExecutor: Executor {

    // MARK: - Properties

    nonisolated let executorLabel: String = "Workflow"
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
        return executeWorkflow(
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
    /// Delegates to the testable overload using production singletons.
    nonisolated func executeWorkflow(
        userInput: String,
        chatHistory: [ChatMessage],
        conversationID: UUID,
        ragContext: String?,
        traceContext: TraceContext,
        onTraceUpdate: @escaping @Sendable (AgentTraceLog) -> Void
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        executeWorkflow(
            userInput: userInput, chatHistory: chatHistory,
            conversationID: conversationID, ragContext: ragContext,
            traceContext: traceContext, onTraceUpdate: onTraceUpdate,
            layout: nil, profileMap: nil, streamProvider: nil
        )
    }

    /// Testable workflow execution entry point with optional dependency injection.
    /// Pass `nil` for any parameter to use production singletons.
    nonisolated func executeWorkflow(
        userInput: String,
        chatHistory: [ChatMessage],
        conversationID: UUID,
        ragContext: String?,
        traceContext: TraceContext,
        onTraceUpdate: @escaping @Sendable (AgentTraceLog) -> Void,
        layout injectedLayout: WorkflowLayout?,
        profileMap injectedProfileMap: [UUID: BackendProfileModel]?,
        streamProvider injectedStreamProvider: (any WorkflowStreamProvider)?
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {

        let profileID = workflowProfileID

        return AsyncThrowingStream<AgentStreamEvent, Error> { continuation in
            let task = Task {
                // Wrap in incremented depth for sub-workflow recursion guard
                try await WorkflowDepth.$current.withValue(WorkflowDepth.current + 1) {
                do {
                    // Recursion guard — prevent infinite sub-workflow nesting
                    guard WorkflowDepth.current <= WorkflowDepth.maxDepth else {
                        throw WorkflowError.nodeExecutionFailed(
                            nodeID: profileID,
                            profileName: "Workflow",
                            underlyingError: "Maximum workflow nesting depth (\(WorkflowDepth.maxDepth)) exceeded"
                        )
                    }

                    logger.info("Workflow execution initiated for profile: \(profileID) (depth: \(WorkflowDepth.current))")

                    // =============================================================
                    // 1. LOAD & VALIDATE DAG
                    // =============================================================

                    let layout = injectedLayout ?? WorkflowLayoutStore.shared.load(for: profileID)

                    guard !layout.nodes.isEmpty else {
                        throw WorkflowError.emptyWorkflow
                    }

                    guard let levels = layout.computeExecutionLevels() else {
                        throw WorkflowError.cycleDetected
                    }

                    let totalNodes = layout.nodes.count
                    let flatOrder = levels.flatMap { $0 }
                    logger.info("DAG validated: \(totalNodes) nodes, \(layout.edges.count) edges, \(levels.count) levels. Order: \(flatOrder.map(\.uuidString).joined(separator: " → "))")

                    // =============================================================
                    // 2. BUILD PROFILE LOOKUP (resolve UUIDs → snapshots)
                    // =============================================================

                    let profileMap: [UUID: BackendProfileModel]
                    if let injected = injectedProfileMap {
                        profileMap = injected
                    } else {
                        let layoutProfileIDs = Set(layout.nodes.map(\.profileID))
                        let resolvedProfiles = await MainActor.run { (try? BackendProfileStore.shared.fetchProfiles()) ?? [] }
                        profileMap = Dictionary(
                            resolvedProfiles.filter { layoutProfileIDs.contains($0.id) }.map { ($0.id, $0) },
                            uniquingKeysWith: { first, _ in first }
                        )
                    }

                    // =============================================================
                    // 2b. EXTRACT WORKFLOW-LEVEL CONFIG
                    // =============================================================

                    let workflowConfig: WorkflowConfig
                    if let injectedProfile = injectedProfileMap?[profileID],
                       case .workflow(let config) = injectedProfile.details {
                        workflowConfig = config
                    } else if let workflowProfile = profileMap[profileID],
                              case .workflow(let config) = workflowProfile.details {
                        workflowConfig = config
                    } else {
                        // Fetch workflow's own profile (it's not in the node profile map)
                        let wfProfile = await MainActor.run { try? BackendProfileStore.shared.fetchProfile(byId: profileID) }
                        if case .workflow(let config) = wfProfile?.details {
                            workflowConfig = config
                        } else {
                            workflowConfig = WorkflowConfig(agentProfileIDs: [])
                        }
                    }

                    // Configurable nesting depth check (may be lower than hard ceiling)
                    guard WorkflowDepth.current <= workflowConfig.resolvedMaxNestingDepth else {
                        throw WorkflowError.nodeExecutionFailed(
                            nodeID: profileID,
                            profileName: "Workflow",
                            underlyingError: "Maximum workflow nesting depth (\(workflowConfig.resolvedMaxNestingDepth)) exceeded"
                        )
                    }

                    // =============================================================
                    // 2c. PRE-FLIGHT CONFIGURATION VALIDATION
                    // =============================================================

                    let validationIssues = WorkflowValidator.validate(layout: layout, profileMap: profileMap)
                    let validationErrors = validationIssues.filter { $0.severity == .error }
                    if !validationErrors.isEmpty {
                        let summary = validationErrors
                            .map { "[\($0.nodeName)] \($0.message)" }
                            .joined(separator: "\n")
                        logger.error("Workflow blocked by \(validationErrors.count) configuration error(s):\n\(summary)")
                        throw WorkflowError.validationFailed(errors: validationErrors, summary: summary)
                    }

                    let validationWarnings = validationIssues.filter { $0.severity == .warning }
                    if !validationWarnings.isEmpty {
                        logger.notice("Workflow has \(validationWarnings.count) configuration warning(s)")
                    }

                    // =============================================================
                    // 3. EXECUTE DAG (Leveled Parallel Execution)
                    // =============================================================

                    var state = WorkflowState()
                    let agentConnect: any WorkflowStreamProvider = injectedStreamProvider ?? AgentConnect()
                    var completedCount = 0
                    var workflowStopped = false

                    continuation.yield(.thought("Starting workflow with \(totalNodes) node(s) across \(levels.count) level(s)..."))

                    for (levelIndex, level) in levels.enumerated() {
                        try Task.checkCancellation()
                        if workflowStopped { break }

                        let levelNodeNames = level.compactMap { id in layout.nodes.first(where: { $0.id == id })?.displayName ?? id.uuidString }
                        logger.info("--- Level \(levelIndex + 1)/\(levels.count): [\(levelNodeNames.joined(separator: ", "))] ---")

                        // --- Pre-flight: resolve nodes, check dependencies, dispatch by kind ---
                        typealias ProfileNode = (node: WorkflowNode, profile: BackendProfileModel)
                        var profileNodes: [ProfileNode] = []
                        var structuralNodes: [WorkflowNode] = []

                        for nodeID in level {
                            guard let node = layout.nodes.first(where: { $0.id == nodeID }) else {
                                logger.warning("Orphan nodeID in level \(levelIndex): \(nodeID). Skipping.")
                                continue
                            }

                            // --- Check upstream dependencies (respects NodeFailurePolicy) ---
                            if !state.shouldExecuteNode(nodeID, edges: layout.edges, nodes: layout.nodes) {
                                let skipReason = "Upstream dependency failed"
                                logger.notice("Skipping node '\(node.displayName)': \(skipReason)")
                                let skipResult = NodeResultEnvelope(
                                    taskID: UUID(), nodeID: nodeID,
                                    sourceProfileID: node.profileID ?? UUID(), profileName: node.displayName,
                                    profileType: node.profileType ?? .bot,
                                    status: .skipped(reason: skipReason),
                                    output: "", artifacts: [],
                                    metadata: .simple(start: Date(), end: Date(), output: "")
                                )
                                state.recordResult(from: skipResult)
                                continuation.yield(.workflowNodeFailed(nodeID: nodeID, profileName: node.displayName, error: skipReason))
                                completedCount += 1
                                continuation.yield(.workflowProgress(completed: completedCount, total: totalNodes))
                                continue
                            }

                            // --- Dispatch by node kind ---
                            switch node.kind {
                            case .profile(let profileID, let profileType):
                                guard let nodeProfile = profileMap[profileID] else {
                                    let error = WorkflowError.profileNotFound(profileID: profileID, nodeName: node.displayName)
                                    logger.error("Profile not found for node '\(node.displayName)': \(profileID)")
                                    let failResult = NodeResultEnvelope(
                                        taskID: UUID(), nodeID: nodeID,
                                        sourceProfileID: profileID, profileName: node.displayName,
                                        profileType: profileType,
                                        status: .failed(.modelError(provider: "workflow", error: error.localizedDescription)),
                                        output: "", artifacts: [],
                                        metadata: .simple(start: Date(), end: Date(), output: "")
                                    )
                                    state.recordResult(from: failResult)
                                    continuation.yield(.workflowNodeFailed(nodeID: nodeID, profileName: node.displayName, error: error.localizedDescription))
                                    completedCount += 1
                                    continuation.yield(.workflowProgress(completed: completedCount, total: totalNodes))
                                    continue
                                }
                                profileNodes.append((node, nodeProfile))

                            case .condition, .loop, .code, .gate, .trigger:
                                structuralNodes.append(node)
                            }
                        }

                        if !structuralNodes.isEmpty || !profileNodes.isEmpty {
                            let structNames = structuralNodes.map(\.displayName).joined(separator: ", ")
                            let profNames = profileNodes.map(\.node.displayName).joined(separator: ", ")
                            logger.info("Level \(levelIndex + 1) dispatch: structural=[\(structNames)] profile=[\(profNames)]")
                        }

                        // --- Execute structural nodes (gate nodes are async — HITL suspension) ---
                        for node in structuralNodes {
                            let upstreamResults = state.upstreamResultEnvelopes(for: node.id, edges: layout.edges)
                            let structResult = await Self.executeStructuralNode(
                                node: node,
                                upstreamResults: upstreamResults,
                                state: state,
                                conversationID: conversationID,
                                continuation: continuation,
                                nodeIndex: completedCount + 1,
                                totalNodes: totalNodes,
                                streamProvider: agentConnect,
                                profileMap: profileMap
                            )
                            state.recordResult(from: structResult.envelope)
                            if let ports = structResult.activePorts {
                                state.setActiveOutputPorts(ports, for: node.id)
                            }
                            // Activate error port on structural node failure (mirrors profile node behavior)
                            if case .failed = structResult.envelope.status, structResult.activePorts == nil {
                                state.setActiveOutputPorts(["error"], for: node.id)
                            }
                            for (key, value) in structResult.variableUpdates {
                                state.setVariable(key, value: value)
                            }
                            completedCount += 1
                            continuation.yield(.workflowProgress(completed: completedCount, total: totalNodes))

                            // Check stopWorkflow policy
                            if case .failed = structResult.envelope.status, node.nodeConfig?.onFailure == .stopWorkflow {
                                workflowStopped = true
                                break
                            }
                        }

                        if workflowStopped { break }
                        guard !profileNodes.isEmpty else { continue }

                        // --- Execute profile nodes (with optional retry) ---
                        if profileNodes.count == 1 {
                            let (node, profile) = profileNodes[0]
                            let result = await Self.executeProfileNodeWithRetry(
                                node: node, profile: profile,
                                userInput: userInput,
                                state: state, edges: layout.edges,
                                nodeIndex: completedCount + 1, totalNodes: totalNodes,
                                conversationID: conversationID,
                                agentConnect: agentConnect,
                                traceContext: traceContext, onTraceUpdate: onTraceUpdate,
                                continuation: continuation,
                                workflowConfig: workflowConfig
                            )
                            state.recordResult(from: result)
                            // Activate error port on failure for error routing
                            if case .failed = result.status {
                                state.setActiveOutputPorts(["error"], for: node.id)
                            }
                            completedCount += 1
                            continuation.yield(.workflowProgress(completed: completedCount, total: totalNodes))

                            if case .failed = result.status, node.nodeConfig?.onFailure == .stopWorkflow {
                                workflowStopped = true
                            }
                        } else {
                            // Parallel profile nodes — snapshot state before launch
                            let snapshotState = state

                            await withTaskGroup(of: NodeResultEnvelope.self) { group in
                                for (nodeOffset, (node, profile)) in profileNodes.enumerated() {
                                    let displayIndex = completedCount + nodeOffset + 1
                                    group.addTask {
                                        await Self.executeProfileNodeWithRetry(
                                            node: node, profile: profile,
                                            userInput: userInput,
                                            state: snapshotState, edges: layout.edges,
                                            nodeIndex: displayIndex, totalNodes: totalNodes,
                                            conversationID: conversationID,
                                            agentConnect: agentConnect,
                                            traceContext: traceContext, onTraceUpdate: onTraceUpdate,
                                            continuation: continuation,
                                            workflowConfig: workflowConfig
                                        )
                                    }
                                }
                                for await result in group {
                                    state.recordResult(from: result)
                                    if case .failed = result.status {
                                        state.setActiveOutputPorts(["error"], for: result.nodeID)
                                        let failedNode = layout.nodes.first(where: { $0.id == result.nodeID })
                                        if failedNode?.nodeConfig?.onFailure == .stopWorkflow {
                                            workflowStopped = true
                                        }
                                    }
                                    completedCount += 1
                                    continuation.yield(.workflowProgress(completed: completedCount, total: totalNodes))
                                }
                            }
                        }
                    }

                    // =============================================================
                    // 4. SYNTHESIZE FINAL OUTPUT (Terminal Nodes)
                    // =============================================================

                    let allNodeIDs = flatOrder
                    let terminalOutputs = state.terminalOutputs(edges: layout.edges, allNodeIDs: allNodeIDs)

                    let successfulTerminals = terminalOutputs.filter {
                        if case .completed = $0.status { return true }
                        return false
                    }

                    if !successfulTerminals.isEmpty {
                        let finalOutput = successfulTerminals.map(\.text).joined(separator: "\n\n")
                        if !finalOutput.isEmpty {
                            continuation.yield(.content(finalOutput))
                        }
                        let terminalNames = successfulTerminals.map(\.profileName).joined(separator: ", ")
                        logger.info("Workflow completed. \(successfulTerminals.count)/\(terminalOutputs.count) terminal nodes succeeded: [\(terminalNames)]")
                        logger.debug("Final output preview (\(finalOutput.count) chars):\n\(String(finalOutput.prefix(500)))")
                    } else {
                        continuation.yield(.error("Workflow completed but all terminal nodes failed."))
                        logger.warning("Workflow completed but all terminal nodes failed.")
                    }

                    let executionLog = state.executionLog
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
                } // end WorkflowDepth.withValue
            }

            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Per-Node Execution

    /// Executes a single workflow node with timeout enforcement.
    /// Never throws — errors are captured in the returned envelope's `.failed` status.
    /// This method is `nonisolated` and `static` to enable parallel execution via TaskGroup
    /// without actor-isolation serialisation.
    private nonisolated static func executeNode(
        node: WorkflowNode,
        profile: BackendProfileModel,
        userInput: String,
        upstreamResults: [NodeResultEnvelope],
        nodeIndex: Int,
        totalNodes: Int,
        conversationID: UUID,
        agentConnect: any WorkflowStreamProvider,
        traceContext: TraceContext,
        onTraceUpdate: @escaping @Sendable (AgentTraceLog) -> Void,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation,
        workflowConfig: WorkflowConfig
    ) async -> NodeResultEnvelope {

        let nodeID = node.id
        let displayName = node.displayName

        // --- Emit Node Started ---
        continuation.yield(.workflowNodeStarted(
            nodeID: nodeID,
            profileName: displayName,
            index: nodeIndex,
            total: totalNodes
        ))

        let startTime = Date()
        let nodeSpan = traceContext.newSpan()

        onTraceUpdate(AgentTraceLog(
            traceID: nodeSpan.traceID,
            spanID: nodeSpan.spanID,
            parentSpanID: nodeSpan.parentSpanID,
            stepNumber: nodeIndex,
            state: .acting(.subtask(current: nodeIndex, total: totalNodes)),
            content: "Executing workflow node: \(displayName) (\(node.profileType?.rawValue ?? "Node"))"
        ))

        // --- Build Workflow Execution Context ---
        let baseTaskDescription = node.nodeConfig?.taskDescription ?? ""
        let isFirstNode = upstreamResults.isEmpty
        let upstreamInput = ContextCompressor.compileForWorkflow(
            results: upstreamResults,
            budget: workflowConfig.resolvedTotalContextBudget,
            perNodeBudget: workflowConfig.resolvedContextBudgetPerNode
        )

        // For first nodes: merge userInput into taskDescription as a single directive.
        // Downstream nodes only use their own taskDescription — userInput is not propagated.
        let effectiveTaskDescription: String
        let trimmedUserInput = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFirstNode && !trimmedUserInput.isEmpty {
            effectiveTaskDescription = baseTaskDescription.isEmpty
                ? trimmedUserInput
                : baseTaskDescription + "\n\n---\nUser Query: " + trimmedUserInput
            logger.info("Node '\(displayName)' first node: merged userInput (\(trimmedUserInput.count) chars) into taskDescription")
        } else {
            effectiveTaskDescription = baseTaskDescription
        }

        let workflowContext = WorkflowExecutionContext(
            taskDescription: effectiveTaskDescription,
            upstreamInput: upstreamInput,
            isFirstNode: isFirstNode,
            nodeName: displayName
        )

        logger.info("Node '\(displayName)' context: taskDescription=\(effectiveTaskDescription.count) chars, upstreamInput=\(upstreamInput.count) chars, isFirstNode=\(isFirstNode)")
        if !upstreamInput.isEmpty {
            logger.debug("Node '\(displayName)' upstream preview:\n\(String(upstreamInput.prefix(500)))")
        }

        // --- Execute via AgentConnect (with timeout enforcement) ---
        // Priority: WorkflowNodeConfig.hardTimeout → agent executionTimeout → default 120s
        let nodeTimeout: TimeInterval = {
            if let hardTimeout = node.nodeConfig?.hardTimeout { return hardTimeout }
            if case .agent(let config) = profile.details, let t = config.executionTimeout { return t }
            return workflowConfig.resolvedNodeTimeout
        }()

        var nodeOutput = ""
        var nodeArtifacts: [ToolOutput] = []
        var nodeMediaArtifacts: [MediaArtifact] = []
        var nodeStatus: NodeExecutionStatus = .completed

        do {
            // Race: stream consumption vs timeout (same pattern as AgentConnect)
            let streamResult = try await withThrowingTaskGroup(
                of: (String, [ToolOutput], [MediaArtifact]).self
            ) { group in
                // Timeout sentinel
                group.addTask {
                    try await Task.sleep(for: .seconds(nodeTimeout))
                    throw AgentExecutionError(reason: .executionTimeout(
                        elapsed: nodeTimeout, limit: nodeTimeout
                    ))
                }

                // Actual stream consumption — accumulates state locally
                group.addTask {
                    var output = ""
                    var tools: [ToolOutput] = []
                    var media: [MediaArtifact] = []

                    let nodeStream = agentConnect.streamWorkflowNodeResponse(
                        for: profile,
                        workflowContext: workflowContext,
                        conversationID: conversationID,
                        traceContext: nodeSpan,
                        onTraceUpdate: onTraceUpdate
                    )

                    // Event prefixing convention:
                    // - Text events (.thought, .error, .requestClarification): prefixed with [NodeName]
                    // - Structured events (.toolCall, .toolOutput, .artifactProduced): unprefixed
                    for try await event in nodeStream {
                        switch event {
                        case .content(let text):
                            output += text

                        case .toolOutput(let toolOut, _):
                            tools.append(toolOut)
                            continuation.yield(.toolOutput(toolOut, sourceNodeID: nodeID))

                        case .thought(let msg, let id, _):
                            continuation.yield(.thought("[\(displayName)] \(msg)", id: id, sourceNodeID: nodeID))

                        case .toolCall(let name, let params, _):
                            continuation.yield(.toolCall(name: name, params: params, sourceNodeID: nodeID))

                        case .requestConfirmation(let toolName, let params, let operationID, _):
                            continuation.yield(.requestConfirmation(toolName: toolName, params: params, operationID: operationID, sourceNodeID: nodeID))

                        case .requestClarification(let question, let operationID, _):
                            continuation.yield(.requestClarification(question: "[\(displayName)] \(question)", operationID: operationID, sourceNodeID: nodeID))

                        case .error(let errMsg):
                            continuation.yield(.error("[\(displayName)] \(errMsg)"))

                        case .workflowNodeStarted, .workflowNodeCompleted, .workflowNodeFailed, .workflowProgress, .workflowLoopIteration:
                            break // Ignore nested workflow events

                        case .mediaProgress:
                            continuation.yield(event)

                        case .artifactProduced(let artifact):
                            media.append(artifact)
                            continuation.yield(event)

                        case .requestPlanReview:
                            continuation.yield(event)

                        case .planGenerated, .subtaskStarted, .subtaskCompleted,
                             .reflectionTrialStarted, .reflectionEvaluating, .reflectionRetrying, .reflectionAccepted,
                             .delegationStarted, .delegationCompleted,
                             .compactionStarted, .compactionCompleted,
                             .tokenUsage:
                            continuation.yield(event)
                        }
                    }
                    return (output, tools, media)
                }

                let result = try await group.next()!
                group.cancelAll()
                return result
            }
            nodeOutput = streamResult.0
            nodeArtifacts = streamResult.1
            nodeMediaArtifacts = streamResult.2
            logger.debug("Node '\(displayName)' raw output preview:\n\(String(nodeOutput.prefix(300)))")
        } catch is CancellationError {
            nodeStatus = .canceled
            logger.notice("Node '\(displayName)' cancelled")
        } catch let agentError as AgentExecutionError {
            nodeStatus = .failed(agentError.reason)
            logger.error("Node '\(displayName)' failed: \(agentError.reason.localizedDescription)")
        } catch {
            nodeStatus = .failed(.modelError(provider: "unknown", error: error.localizedDescription))
            logger.error("Node '\(displayName)' failed: \(error.localizedDescription)")
        }

        let endTime = Date()

        // --- Build Result Envelope ---
        // Safe to force-unwrap: callers guarantee only profile-backed nodes reach executeNode()
        let result = NodeResultEnvelope(
            taskID: UUID(),
            nodeID: nodeID,
            sourceProfileID: node.profileID!,
            profileName: displayName,
            profileType: node.profileType ?? .bot,
            status: nodeStatus,
            output: nodeOutput,
            artifacts: nodeMediaArtifacts,
            metadata: NodeExecutionMetadata(
                startTime: startTime,
                endTime: endTime,
                iterationsUsed: 1,
                toolsInvoked: nodeArtifacts.map(\.toolName),
                tokenEstimate: nodeOutput.count / 4
            )
        )

        // --- Emit Node Completion ---
        switch nodeStatus {
        case .completed:
            let summary = String(nodeOutput.prefix(100)) + (nodeOutput.count > 100 ? "..." : "")
            continuation.yield(.workflowNodeCompleted(nodeID: nodeID, profileName: displayName, summary: summary))
            logger.info("Node '\(displayName)' completed. Output: \(nodeOutput.count) chars, Duration: \(String(format: "%.1f", result.metadata.duration))s")

        case .failed(let reason):
            continuation.yield(.workflowNodeFailed(nodeID: nodeID, profileName: displayName, error: reason.localizedDescription))

        case .canceled:
            continuation.yield(.workflowNodeFailed(nodeID: nodeID, profileName: displayName, error: "Cancelled"))

        case .skipped(let reason):
            continuation.yield(.workflowNodeFailed(nodeID: nodeID, profileName: displayName, error: "Skipped: \(reason)"))
        }

        return result
    }

    // MARK: - Profile Node Retry Wrapper

    /// Wraps `executeNode()` with WorkflowNodeConfig-driven retry logic.
    /// Retries up to `maxNodeRetries` times with `retryDelay` between attempts.
    private nonisolated static func executeProfileNodeWithRetry(
        node: WorkflowNode,
        profile: BackendProfileModel,
        userInput: String,
        state: WorkflowState,
        edges: [WorkflowEdge],
        nodeIndex: Int,
        totalNodes: Int,
        conversationID: UUID,
        agentConnect: any WorkflowStreamProvider,
        traceContext: TraceContext,
        onTraceUpdate: @escaping @Sendable (AgentTraceLog) -> Void,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation,
        workflowConfig: WorkflowConfig
    ) async -> NodeResultEnvelope {

        let maxRetries = node.nodeConfig?.maxNodeRetries ?? workflowConfig.resolvedMaxRetries
        let retryDelay = node.nodeConfig?.retryDelay ?? 0
        let upstreamResults = state.upstreamResultEnvelopes(for: node.id, edges: edges)

        var lastResult: NodeResultEnvelope?

        for attempt in 0...maxRetries {
            if attempt > 0 {
                logger.info("Node '\(node.displayName)' retry \(attempt)/\(maxRetries) after \(retryDelay)s delay")
                continuation.yield(.thought("[\(node.displayName)] Retrying (attempt \(attempt + 1)/\(maxRetries + 1))..."))
                if retryDelay > 0 {
                    try? await Task.sleep(for: .seconds(retryDelay))
                }
            }

            let result = await executeNode(
                node: node, profile: profile,
                userInput: userInput,
                upstreamResults: upstreamResults,
                nodeIndex: nodeIndex, totalNodes: totalNodes,
                conversationID: conversationID,
                agentConnect: agentConnect,
                traceContext: traceContext, onTraceUpdate: onTraceUpdate,
                continuation: continuation,
                workflowConfig: workflowConfig
            )
            lastResult = result

            // Success or non-retryable failure → stop
            if case .completed = result.status { return result }
            if case .failed(let reason) = result.status, !reason.isRetryable { return result }
            if case .canceled = result.status { return result }
        }

        return lastResult!
    }

    // MARK: - Structural Node Result

    /// Result from a structural node execution, including port activation and variable updates.
    struct StructuralNodeResult {
        let envelope: NodeResultEnvelope
        let activePorts: Set<String>?
        let variableUpdates: [String: String]
    }

    // MARK: - Structural Node Execution

    /// Executes a non-profile (structural) workflow node.
    /// Async because gate nodes suspend for HITL approval.
    /// `streamProvider` and `profileMap` are threaded for loop body sub-executor injection.
    private nonisolated static func executeStructuralNode(
        node: WorkflowNode,
        upstreamResults: [NodeResultEnvelope],
        state: WorkflowState,
        conversationID: UUID,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation,
        nodeIndex: Int,
        totalNodes: Int,
        streamProvider: (any WorkflowStreamProvider)? = nil,
        profileMap: [UUID: BackendProfileModel]? = nil
    ) async -> StructuralNodeResult {

        let nodeID = node.id
        let displayName = node.displayName
        let startTime = Date()

        continuation.yield(.workflowNodeStarted(
            nodeID: nodeID, profileName: displayName,
            index: nodeIndex, total: totalNodes
        ))

        // --- Kind-Based Dispatch ---
        var output: String = ""
        var activePorts: Set<String>? = nil
        var variableUpdates: [String: String] = [:]
        var status: NodeExecutionStatus = .completed

        let upstreamNames = upstreamResults.map(\.profileName).joined(separator: ", ")
        let upstreamTotalChars = upstreamResults.reduce(0) { $0 + $1.output.count }
        let kindLabel: String = switch node.kind {
        case .profile: "profile"
        case .condition: "condition"
        case .loop: "loop"
        case .code: "code"
        case .gate: "gate"
        case .trigger: "trigger"
        }
        logger.info("Structural node '\(displayName)' (\(kindLabel)): \(upstreamResults.count) upstream results [\(upstreamNames)], total \(upstreamTotalChars) chars")

        switch node.kind {
        case .profile:
            break // Should never reach here

        case .condition(let config):
            let upstreamText = upstreamResults.map(\.output).joined(separator: "\n")
            logger.debug("Condition '\(displayName)' input preview: \(String(upstreamText.prefix(300)))")

            // Step 1: Pattern matching — always runs first
            var matchedLabel: String?
            for rule in config.rules {
                let fieldValue: String
                switch rule.field {
                case .upstreamOutput: fieldValue = upstreamText
                case .variable:       fieldValue = state.variables[rule.variableName ?? ""] ?? ""
                }

                // Split comma-separated values (trimmed). Single value = array of 1.
                let values = rule.value
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }

                let matches: Bool
                switch rule.op {
                case .contains:
                    // ANY value matches → true
                    matches = values.contains { fieldValue.localizedCaseInsensitiveContains($0) }
                case .notContains:
                    // ALL values must be absent → true (if any is found → false)
                    matches = !values.contains { fieldValue.localizedCaseInsensitiveContains($0) }
                case .equals:
                    // ANY value equals → true
                    matches = values.contains { fieldValue == $0 }
                case .notEquals:
                    // ALL values must differ → true
                    matches = !values.contains { fieldValue == $0 }
                case .isEmpty:     matches = fieldValue.isEmpty
                case .isNotEmpty:  matches = !fieldValue.isEmpty
                }

                logger.debug("Condition '\(displayName)' rule: field=\(String(describing: rule.field)) op=\(String(describing: rule.op)) value='\(rule.value)' → \(matches ? "MATCH" : "no match") (label: '\(rule.label)')")
                if matches {
                    matchedLabel = rule.label
                    logger.info("Condition '\(displayName)': pattern rule matched → '\(rule.label)' (field=\(String(describing: rule.field)), op=\(String(describing: rule.op)), value='\(rule.value)')")
                    break
                }
            }

            // Step 2: LLM fallback — only fires when no pattern rule matched
            if matchedLabel == nil && config.llmFallbackEnabled {
                logger.info("Condition '\(displayName)': no pattern match, delegating to AI Classifier")
                do {
                    matchedLabel = try await Self.evaluateConditionWithLLM(
                        config: config,
                        upstreamText: upstreamText,
                        displayName: displayName,
                        nodeID: nodeID,
                        continuation: continuation
                    )
                } catch {
                    logger.error("Condition LLM fallback failed for '\(displayName)': \(error.localizedDescription)")
                    continuation.yield(.thought("[\(displayName)] AI Classifier failed: \(error.localizedDescription)", sourceNodeID: nodeID))
                }
            }

            // Step 3: Static fallback — last resort
            let activatedPort = matchedLabel ?? config.fallbackLabel
            activePorts = [activatedPort]
            let method = matchedLabel != nil ? (config.llmFallbackEnabled && !config.rules.contains(where: { $0.label == matchedLabel }) ? "classifier" : "pattern") : "fallback"
            // When passthroughContent is true, downstream nodes receive the original content.
            // When false, they receive only the routing label — useful for branching without forwarding payload.
            output = config.passthroughContent ? upstreamText : "Condition (\(method)): route \u{2192} \(activatedPort)"
            logger.info("Condition node '\(displayName)' activated port: '\(activatedPort)' via \(method), passthrough=\(config.passthroughContent), output \(output.count) chars")

        case .loop(let config):
            // --- Loop Node: iterate a sub-workflow body ---
            guard let bodyProfileID = config.bodyWorkflowID else {
                output = "Loop node has no body workflow configured"
                status = .failed(.modelError(provider: "workflow", error: "Loop '\(displayName)' has no body workflow assigned. Double-click to configure."))
                logger.error("Loop node '\(displayName)' has no bodyWorkflowID configured")
                break
            }

            let maxIter = max(1, min(config.maxIterations, 50))
            let upstreamText = upstreamResults.map(\.output).joined(separator: "\n")
            var iterationInput = upstreamText
            var iterationOutput = ""
            var loopCounter = 0
            var exitedEarly = false

            logger.info("Loop node '\(displayName)' starting: max \(maxIter) iterations, body: \(bodyProfileID)")
            logger.debug("Loop '\(displayName)' initial input preview:\n\(String(upstreamText.prefix(300)))")

            for iteration in 1...maxIter {
                if Task.isCancelled {
                    logger.info("Loop '\(displayName)' detected cancellation before iteration \(iteration)")
                    output = iterationOutput.isEmpty ? upstreamText : iterationOutput
                    status = .canceled
                    break
                }

                continuation.yield(.workflowLoopIteration(
                    nodeID: nodeID, profileName: displayName,
                    iteration: iteration, maxIterations: maxIter
                ))

                // Execute body workflow (thread injected dependencies for testability)
                let bodyExecutor = WorkflowExecutor(workflowProfileID: bodyProfileID)
                let bodyTrace = TraceContext(subAgentName: "\(displayName) iter \(iteration)", provider: .anthropic)
                let bodyStream = bodyExecutor.executeWorkflow(
                    userInput: iterationInput,
                    chatHistory: [],
                    conversationID: conversationID,
                    ragContext: nil,
                    traceContext: bodyTrace,
                    onTraceUpdate: { _ in },
                    layout: nil,
                    profileMap: profileMap,
                    streamProvider: streamProvider
                )

                // Consume body stream, accumulate text output
                var bodyOutput = ""
                var bodyFailed = false
                do {
                    for try await event in bodyStream {
                        switch event {
                        case .content(let text):
                            bodyOutput += text
                        case .thought(let msg, let id, _):
                            continuation.yield(.thought("[\(displayName) iter \(iteration)] \(msg)", id: id, sourceNodeID: nodeID))
                        case .error(let errMsg):
                            // Body workflow emits .error when all terminals failed — treat as body failure
                            continuation.yield(.thought("[\(displayName) iter \(iteration)] Error: \(errMsg)", sourceNodeID: nodeID))
                            bodyFailed = true
                        default:
                            break // Suppress inner workflow orchestration events
                        }
                    }
                    // If body reported failure via .error event (not exception), break the loop
                    if bodyFailed {
                        logger.error("Loop '\(displayName)' iteration \(iteration) body reported failure")
                        output = iterationOutput.isEmpty ? upstreamText : iterationOutput
                        status = .failed(.modelError(provider: "workflow", error: "Loop body failed at iteration \(iteration)"))
                        break
                    }
                } catch is CancellationError {
                    logger.info("Loop '\(displayName)' cancelled at iteration \(iteration)")
                    output = iterationOutput.isEmpty ? upstreamText : iterationOutput
                    status = .failed(.modelError(provider: "workflow", error: "Loop cancelled at iteration \(iteration)"))
                    break
                } catch {
                    logger.error("Loop '\(displayName)' iteration \(iteration) body failed: \(error.localizedDescription)")
                    output = "Loop failed at iteration \(iteration): \(error.localizedDescription)"
                    status = .failed(.modelError(provider: "workflow", error: "Loop body failed at iteration \(iteration): \(error.localizedDescription)"))
                    break
                }

                loopCounter = iteration
                iterationOutput = bodyOutput
                iterationInput = bodyOutput // Chain: next iteration gets this iteration's output

                logger.info("Loop '\(displayName)' iteration \(iteration)/\(maxIter) completed: \(bodyOutput.count) chars")
                logger.debug("Loop '\(displayName)' iteration \(iteration) output preview:\n\(String(bodyOutput.prefix(300)))")

                // Evaluate exit condition (if configured)
                if let exitRule = config.exitCondition {
                    let fieldValue: String
                    switch exitRule.field {
                    case .upstreamOutput: fieldValue = bodyOutput
                    case .variable:       fieldValue = state.variables[exitRule.variableName ?? ""] ?? ""
                    }

                    let shouldExit: Bool
                    switch exitRule.op {
                    case .contains:    shouldExit = fieldValue.localizedCaseInsensitiveContains(exitRule.value)
                    case .notContains: shouldExit = !fieldValue.localizedCaseInsensitiveContains(exitRule.value)
                    case .equals:      shouldExit = fieldValue == exitRule.value
                    case .notEquals:   shouldExit = fieldValue != exitRule.value
                    case .isEmpty:     shouldExit = fieldValue.isEmpty
                    case .isNotEmpty:  shouldExit = !fieldValue.isEmpty
                    }

                    if shouldExit {
                        logger.info("Loop '\(displayName)' exit condition met after iteration \(iteration)")
                        exitedEarly = true
                        break
                    }
                }
            }

            // Set final output if we didn't break due to failure
            if case .completed = status {
                output = iterationOutput.isEmpty ? upstreamText : iterationOutput
                let exitLabel = exitedEarly ? " (exit condition met)" : ""
                logger.info("Loop '\(displayName)' completed after \(loopCounter) iteration(s)\(exitLabel). Output: \(output.count) chars")
            }

            variableUpdates["__loop_\(nodeID.uuidString)_counter"] = "\(loopCounter)"
            variableUpdates["__loop_\(nodeID.uuidString)_exited_early"] = exitedEarly ? "true" : "false"
            // Expose the final iteration output as a variable so downstream nodes can reference it
            variableUpdates["__loop_\(nodeID.uuidString)_output"] = output
            if loopCounter > 0 {
                logger.notice("Loop '\(displayName)': variables written by Code nodes inside the loop body are scoped to the sub-workflow and do not propagate to the parent. Use the loop's text output for downstream context instead.")
            }

        case .code(let config):
            // Template transform: replace {{ var.name }} FIRST, then {{ input }} LAST.
            // This order prevents template injection — upstream text won't be re-scanned
            // for {{ var.X }} patterns that happen to appear in upstream output.
            let upstreamText = upstreamResults.map(\.output).joined(separator: "\n")
            var result = config.template

            logger.debug("Code node '\(displayName)' template before substitution:\n\(String(config.template.prefix(300)))")
            logger.debug("Code node '\(displayName)' upstream input preview:\n\(String(upstreamText.prefix(300)))")

            // Step 1: Replace {{ var.name }} with workflow variables
            for (key, value) in state.variables {
                result = result.replacingOccurrences(of: "{{ var.\(key) }}", with: value)
                result = result.replacingOccurrences(of: "{{var.\(key)}}", with: value)
            }

            // Step 2: Replace {{ input }} with upstream text LAST (prevents injection)
            result = result.replacingOccurrences(of: "{{ input }}", with: upstreamText)
            result = result.replacingOccurrences(of: "{{input}}", with: upstreamText)

            output = result
            logger.debug("Code node '\(displayName)' output after substitution:\n\(String(output.prefix(300)))")

            // Write to shared variable if configured
            if let varName = config.outputVariable, !varName.isEmpty {
                variableUpdates[varName] = output
                logger.info("Code node '\(displayName)' wrote variable '\(varName)': \(output.prefix(100))")
            }
            logger.info("Code node '\(displayName)' template transform: \(output.count) chars")

        case .gate(let config):
            // HITL Gate — suspend execution and wait for user approval
            let operationID = UUID()
            let upstreamText = upstreamResults.map(\.output).joined(separator: "\n")
            logger.debug("Gate '\(displayName)' upstream content preview:\n\(String(upstreamText.prefix(300)))")

            // Format gate params with options and upstream preview
            let optionsDisplay = config.options.isEmpty ? "" : "\nOptions: \(config.options.joined(separator: " | "))"
            let timeoutDisplay = config.timeout.map { "\nAuto-rejects in \(Int($0))s" } ?? ""
            let gateParams = config.prompt + optionsDisplay + timeoutDisplay + "\n\nUpstream: " + String(upstreamText.prefix(200))

            // Emit confirmation request with gate prompt and options
            continuation.yield(.requestConfirmation(
                toolName: "Workflow Gate: \(displayName)",
                params: gateParams,
                operationID: operationID,
                sourceNodeID: nodeID
            ))

            // Clamp gate timeout below the suspension service's internal timeout (300s)
            // to avoid a race where the service's timeout fires first.
            // If user configured a shorter timeout, use that; otherwise let the service's
            // own 300s timeout handle it (no external timeout task needed).
            let serviceTimeout: TimeInterval = 300
            let gateTimeout = config.timeout.map { min($0, serviceTimeout - 1) }
            logger.info("Gate node '\(displayName)' suspending for approval (operationID: \(operationID), timeout: \(gateTimeout.map { "\($0)s" } ?? "service default"))")

            let approved: Bool
            if let timeout = gateTimeout {
                // User-configured timeout: race suspension against a sleep timer
                do {
                    approved = try await withThrowingTaskGroup(of: Bool.self) { group in
                        group.addTask {
                            await ExecutionSuspensionService.shared.suspend(
                                for: operationID,
                                conversationID: conversationID
                            )
                        }
                        group.addTask {
                            try await Task.sleep(for: .seconds(timeout))
                            // Timeout reached — force-resume with rejection
                            await ExecutionSuspensionService.shared.resume(for: operationID, approved: false)
                            return false
                        }
                        let result = try await group.next()!
                        group.cancelAll()
                        return result
                    }
                } catch {
                    approved = false
                }
            } else {
                // No user timeout — rely on the service's built-in 300s timeout
                approved = await ExecutionSuspensionService.shared.suspend(
                    for: operationID,
                    conversationID: conversationID
                )
            }

            if approved {
                output = upstreamText
                logger.info("Gate node '\(displayName)' approved — passing through upstream text")
            } else {
                output = "Gate rejected by user"
                status = .failed(.modelError(provider: "workflow", error: "Gate '\(displayName)' rejected by user"))
                logger.info("Gate node '\(displayName)' rejected")
            }

        case .trigger:
            output = ""
            logger.info("Trigger node '\(displayName)' skipped (entry-point only)")
        }

        let endTime = Date()

        // Emit completion/failure
        switch status {
        case .completed:
            var summary = String(output.prefix(100)) + (output.count > 100 ? "..." : "")
            // Enrich summary for loop nodes with iteration count
            if case .loop = node.kind,
               let counterStr = variableUpdates["__loop_\(nodeID.uuidString)_counter"] {
                let earlyExit = variableUpdates["__loop_\(nodeID.uuidString)_exited_early"] == "true" ? " (early exit)" : ""
                summary = "[\(counterStr) iter\(earlyExit)] " + summary
            }
            continuation.yield(.workflowNodeCompleted(nodeID: nodeID, profileName: displayName, summary: summary))
        case .failed(let reason):
            continuation.yield(.workflowNodeFailed(nodeID: nodeID, profileName: displayName, error: reason.localizedDescription))
        case .canceled:
            continuation.yield(.workflowNodeFailed(nodeID: nodeID, profileName: displayName, error: "Cancelled"))
        case .skipped(let reason):
            continuation.yield(.workflowNodeFailed(nodeID: nodeID, profileName: displayName, error: "Skipped: \(reason)"))
        }

        let envelope = NodeResultEnvelope(
            taskID: UUID(),
            nodeID: nodeID,
            sourceProfileID: UUID(),
            profileName: displayName,
            profileType: .bot,
            status: status,
            output: output,
            artifacts: [],
            metadata: NodeExecutionMetadata(
                startTime: startTime,
                endTime: endTime,
                iterationsUsed: 1,
                toolsInvoked: [],
                tokenEstimate: output.count / 4
            )
        )

        return StructuralNodeResult(envelope: envelope, activePorts: activePorts, variableUpdates: variableUpdates)
    }

    // MARK: - AI Classifier Evaluation

    /// Evaluates a condition node using an LLM call. Fetches the evaluator profile,
    /// initializes the model, sends the upstream text with a routing prompt, and
    /// parses the response to match a port label.
    private nonisolated static func evaluateConditionWithLLM(
        config: ConditionNodeConfig,
        upstreamText: String,
        displayName: String,
        nodeID: UUID,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) async throws -> String {

        let classificationLabels = config.rules.map(\.label)

        guard !config.llmPrompt.isEmpty else {
            throw WorkflowError.nodeExecutionFailed(nodeID: nodeID, profileName: displayName, underlyingError: "LLM condition has no routing prompt configured.")
        }
        guard !classificationLabels.isEmpty else {
            throw WorkflowError.nodeExecutionFailed(nodeID: nodeID, profileName: displayName, underlyingError: "AI Classifier has no labels (no pattern rules configured).")
        }
        guard let modelName = config.llmModelName, !modelName.isEmpty else {
            throw WorkflowError.nodeExecutionFailed(nodeID: nodeID, profileName: displayName, underlyingError: "LLM condition has no MLX model selected.")
        }

        // Resolve MLX model from installed models
        let modelItem: MLXModelItem? = await MainActor.run {
            let service = MLXModelService.shared
            if service.installedModels.isEmpty { service.refreshInstalledModels() }
            return service.installedModels.first(where: { $0.displayName == modelName })
        }
        guard let modelItem else {
            throw WorkflowError.nodeExecutionFailed(nodeID: nodeID, profileName: displayName, underlyingError: "MLX model '\(modelName)' not found on this machine.")
        }

        // Load model and get cognitive profile
        try await MLXService.shared.loadModel(from: modelItem.localPath)
        let cogProfile = await MainActor.run { MLXModelService.shared.cachedCognitiveProfile(for: modelItem) }

        let model: any LLMProvider = MLXLLMProvider(
            modelName: modelName,
            dialect: cogProfile.dialect,
            chatTemplateSource: cogProfile.chatTemplateSource,
            stopSequences: cogProfile.stopSequences,
            advancedConfig: .default()
        )

        // Build opaque token mapping (fresh per invocation, prevents content collision)
        let tokenMapper = ClassificationTokenMapper(
            labels: classificationLabels,
            fallbackLabel: config.fallbackLabel
        )

        let tokenMapDebug = tokenMapper.labelToToken
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key) → \($0.value)" }
            .joined(separator: ", ")
        logger.debug("AI Classifier '\(displayName)' token map: [\(tokenMapDebug)]")

        // XML-structured prompt with opaque tokens — optimized for small MLX models
        let systemPrompt = """
        You are a strict routing classifier. You receive a classification task in XML format.
        Your ONLY job is to output exactly ONE label ID from the task.

        RULES:
        - Respond with ONLY a label ID (a 4-character code like \(tokenMapper.tokenList)).
        - Do NOT output the label name, only the ID.
        - Do NOT add explanation, punctuation, quotes, or any other text.
        - If the text does not clearly fit any category, respond with: \(tokenMapper.fallbackToken)

        EXAMPLE:
        <classification_task>
        <labels>
        <label id="AB12">Positive</label>
        <label id="CD34">Negative</label>
        </labels>
        <instruction>Classify the sentiment</instruction>
        <fallback_id>CD34</fallback_id>
        <input>The product arrived damaged and late.</input>
        </classification_task>

        Correct response: CD34

        REMEMBER: Output ONLY the 4-character label ID. Nothing else.
        """

        let userPrompt = """
        <classification_task>
        <labels>
        \(tokenMapper.xmlLabelBlock)
        </labels>
        <instruction>\(config.llmPrompt)</instruction>
        <fallback_id>\(tokenMapper.fallbackToken)</fallback_id>
        <input>\(String(upstreamText.prefix(4000)))</input>
        </classification_task>

        Respond with exactly one label ID from: \(tokenMapper.tokenList)
        If unsure: \(tokenMapper.fallbackToken)
        """

        let messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userPrompt]
        ]

        continuation.yield(.thought("[\(displayName)] Classifying with AI (\(model.modelName))...", sourceNodeID: nodeID))

        let response = try await model.generate(messages: messages, tools: nil, responseSchema: nil)
        logger.debug("AI Classifier '\(displayName)' raw response: \"\(response)\"")

        // Immediately reclaim GPU RAM — classifier is a one-shot task,
        // no need to keep the model loaded until the idle timer fires.
        // The next workflow node will load whatever model it needs.
        await MLXService.shared.unloadModel()
        logger.debug("AI Classifier '\(displayName)': unloaded MLX model after classification")

        // Parse response using token mapper — handles clean, wrapped, and lowercased responses
        let matched = tokenMapper.parseResponse(response)

        let result = matched ?? config.fallbackLabel
        let responsePreview = response.trimmingCharacters(in: .whitespacesAndNewlines).prefix(50)
        continuation.yield(.thought("[\(displayName)] AI Classifier: \"\(responsePreview)\" → route: \(result)", sourceNodeID: nodeID))
        logger.info("Condition AI Classifier '\(displayName)': response=\"\(responsePreview)\", resolved=\(result)")

        return result
    }

}
