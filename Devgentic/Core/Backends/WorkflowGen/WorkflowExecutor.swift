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

private let logger = DGLogger(category: "WorkflowExecutor")

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

    // MARK: - Error Classification

    /// Maps `WorkflowError` cases to the corresponding `AgentErrorCategory` so
    /// `emitAgentError` can stamp spans with workflow-phase categories. Without
    /// this, the 8 `wf*` categories in `AgentErrorCategory` (Workflow Depth
    /// Exceeded, Empty Workflow, Cycle, etc.) sit unused and the workflow phase
    /// slot in TrendsView stays empty.
    nonisolated static func classify(_ error: WorkflowError) -> AgentErrorCategory {
        switch error {
        case .emptyWorkflow:            return .wfEmpty
        case .cycleDetected:            return .wfCycle
        case .profileNotFound:          return .wfProfileNotFound
        case .nodeTimeout:              return .wfNodeFailed
        case .nodeExecutionFailed:      return .wfNodeFailed
        case .allUpstreamsFailed:       return .wfNodeSkipped
        case .loopBodyNotConfigured:    return .wfValidationFailed
        case .validationFailed:         return .wfValidationFailed
        }
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
                // Wrap in incremented depth for sub-workflow recursion guard,
                // and in a LogContext scope so every DGLogger call inside this
                // executor body is auto-tagged with the workflow traceID and
                // `.workflow` phase. Without this, the 49 log lines emitted
                // during a workflow run land in `log_entries` with `traceID = nil`
                // and can't be filtered by trace in the Report Inspector.
                try await WorkflowDepth.$current.withValue(WorkflowDepth.current + 1) {
                await LogContext.with(traceID: traceContext.traceID, phase: .workflow) {
                do {
                    // Guarantee the workflow's root span exists so per-node child
                    // spans have a parent row in `spans` (otherwise fetchFullTrace's
                    // reconstruction orphans them). Idempotent ensure, NOT beginSpan:
                    // in the chat flow `beginTrace` already created this row, and an
                    // unconditional insert collided with it on every run
                    // (UNIQUE constraint failed: spans.spanID).
                    await TraceRecorder.shared.ensureRootSpan(
                        context: traceContext,
                        name: "workflow:\(profileID.uuidString.prefix(8))",
                        kind: .workflow
                    )

                    // Recursion guard — prevent infinite sub-workflow nesting
                    guard WorkflowDepth.current <= WorkflowDepth.maxDepth else {
                        let classified = ClassifiedAgentError.synthetic(
                            category: .wfDepthExceeded,
                            origin: "WorkflowExecutor.executeWorkflow.depthGuard",
                            message: "Maximum workflow nesting depth (\(WorkflowDepth.maxDepth)) exceeded",
                            context: ["profile_id": profileID.uuidString, "depth": "\(WorkflowDepth.current)"]
                        )
                        await TraceRecorder.shared.emitAgentError(span: traceContext, error: classified, iteration: nil)
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

                    let layout: WorkflowLayout
                    if let injectedLayout {
                        layout = injectedLayout
                    } else {
                        // `WorkflowLayoutStore` is `@MainActor`-isolated (SwiftData
                        // ModelContext lives on main). The executor is an actor, so we
                        // hop briefly to load the layout — same pattern used for
                        // `BackendProfileStore.fetchProfile(byId:)` later in this method.
                        layout = await MainActor.run { WorkflowLayoutStore.shared.load(for: profileID) }
                    }

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
                                // P1-11: classify upstream-skip into the workflow phase so
                                // it shows up in TrendsView. Without this, the skip is a
                                // silent control-flow decision invisible to telemetry.
                                let classified = ClassifiedAgentError.synthetic(
                                    category: .wfNodeSkipped,
                                    origin: "WorkflowExecutor.dispatch.upstreamSkip",
                                    message: skipReason,
                                    context: ["node_name": node.displayName, "node_id": nodeID.uuidString]
                                )
                                await TraceRecorder.shared.emitAgentError(span: traceContext, error: classified, iteration: nil)
                                // P0-6: skipped nodes activate the `"error"` port for
                                // downstream routing. Without this, branches wired
                                // exclusively to the `error` port hang waiting for an
                                // activation that never comes — a silent dead-end.
                                // Skip propagates as an upstream-failure signal so error
                                // recovery branches actually fire.
                                state.setActiveOutputPorts(["error"], for: nodeID)
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
                                    // P1-11: classify the profile-not-found dispatch failure.
                                    let classified = ClassifiedAgentError.synthetic(
                                        category: .wfProfileNotFound,
                                        origin: "WorkflowExecutor.dispatch.profileNotFound",
                                        message: error.localizedDescription,
                                        context: ["node_name": node.displayName, "profile_id": profileID.uuidString]
                                    )
                                    await TraceRecorder.shared.emitAgentError(span: traceContext, error: classified, iteration: nil)
                                    continuation.yield(.workflowNodeFailed(nodeID: nodeID, profileName: node.displayName, error: error.localizedDescription))
                                    completedCount += 1
                                    continuation.yield(.workflowProgress(completed: completedCount, total: totalNodes))
                                    continue
                                }
                                profileNodes.append((node, nodeProfile))

                            case .condition, .loop, .code, .gate, .trigger, .action:
                                structuralNodes.append(node)
                            }
                        }

                        if !structuralNodes.isEmpty || !profileNodes.isEmpty {
                            let structNames = structuralNodes.map(\.displayName).joined(separator: ", ")
                            let profNames = profileNodes.map(\.node.displayName).joined(separator: ", ")
                            logger.info("Level \(levelIndex + 1) dispatch: structural=[\(structNames)] profile=[\(profNames)]")
                        }

                        // --- Execute structural nodes ---
                        // Nodes within a level are independent (no same-level edges),
                        // so multiple run in parallel — two HTTP Action nodes on one
                        // level no longer serialize. A single structural node stays on
                        // the simple path. Gate nodes suspend for HITL independently.
                        if structuralNodes.count == 1 {
                            let node = structuralNodes[0]
                            let upstreamResults = state.upstreamResultEnvelopes(for: node.id, edges: layout.edges)
                            let structResult = await Self.executeStructuralNode(
                                node: node,
                                upstreamResults: upstreamResults,
                                state: state,
                                conversationID: conversationID,
                                continuation: continuation,
                                nodeIndex: completedCount + 1,
                                totalNodes: totalNodes,
                                traceContext: traceContext,
                                onTraceUpdate: onTraceUpdate,
                                streamProvider: agentConnect,
                                profileMap: profileMap,
                                workflowConfig: workflowConfig
                            )
                            state.recordResult(from: structResult.envelope)
                            if let ports = structResult.activePorts {
                                state.setActiveOutputPorts(ports, for: node.id)
                            }
                            if case .failed = structResult.envelope.status, structResult.activePorts == nil {
                                state.setActiveOutputPorts(["error"], for: node.id)
                            }
                            for (key, value) in structResult.variableUpdates {
                                state.setVariable(key, value: value)
                            }
                            completedCount += 1
                            continuation.yield(.workflowProgress(completed: completedCount, total: totalNodes))
                            if case .failed = structResult.envelope.status, node.nodeConfig?.onFailure == .stopWorkflow {
                                workflowStopped = true
                            }
                        } else if !structuralNodes.isEmpty {
                            // Parallel — snapshot state before launch (same pattern as
                            // parallel profile nodes); upstream results are read from the
                            // snapshot so child tasks never touch the mutable `state`.
                            let snapshotState = state
                            await withTaskGroup(of: StructuralNodeResult.self) { group in
                                for (nodeOffset, node) in structuralNodes.enumerated() {
                                    let displayIndex = completedCount + nodeOffset + 1
                                    let upstreamResults = snapshotState.upstreamResultEnvelopes(for: node.id, edges: layout.edges)
                                    group.addTask {
                                        await Self.executeStructuralNode(
                                            node: node,
                                            upstreamResults: upstreamResults,
                                            state: snapshotState,
                                            conversationID: conversationID,
                                            continuation: continuation,
                                            nodeIndex: displayIndex,
                                            totalNodes: totalNodes,
                                            traceContext: traceContext,
                                            onTraceUpdate: onTraceUpdate,
                                            streamProvider: agentConnect,
                                            profileMap: profileMap,
                                            workflowConfig: workflowConfig
                                        )
                                    }
                                }
                                // Apply results as they complete (out-of-order is safe —
                                // same-level nodes are independent; variable collisions are
                                // a pre-flight validation error).
                                for await structResult in group {
                                    let sid = structResult.envelope.nodeID
                                    state.recordResult(from: structResult.envelope)
                                    if let ports = structResult.activePorts {
                                        state.setActiveOutputPorts(ports, for: sid)
                                    }
                                    if case .failed = structResult.envelope.status, structResult.activePorts == nil {
                                        state.setActiveOutputPorts(["error"], for: sid)
                                    }
                                    for (key, value) in structResult.variableUpdates {
                                        state.setVariable(key, value: value)
                                    }
                                    completedCount += 1
                                    continuation.yield(.workflowProgress(completed: completedCount, total: totalNodes))

                                    if case .failed = structResult.envelope.status,
                                       layout.nodes.first(where: { $0.id == sid })?.nodeConfig?.onFailure == .stopWorkflow {
                                        workflowStopped = true
                                        group.cancelAll()
                                        logger.notice("Sibling cancellation: structural node failed with stopWorkflow; cancelling remaining parallel tasks.")
                                    }
                                }
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
                                            // P0-9: cancel still-running siblings the moment a
                                            // `.stopWorkflow` failure lands. Without this, the
                                            // TaskGroup keeps draining results from siblings
                                            // that were already launched — wasting compute and
                                            // emitting confusing trailing events after the user
                                            // has been told the run was stopped.
                                            group.cancelAll()
                                            logger.notice("Sibling cancellation: '\(failedNode?.displayName ?? "?")' failed with stopWorkflow policy; cancelling remaining parallel tasks.")
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

                    // Workflow-level terminal outcome. Per-node terminals emitted by inner
                    // executors are swallowed by the forwarder (they're node-scoped); the
                    // workflow as a whole reports its own outcome here so the bubble's
                    // TerminalOutcomeChip reflects workflow-level success vs partial-failure.
                    if successfulTerminals.isEmpty {
                        await TraceRecorder.shared.endSpan(spanID: traceContext.spanID, status: .error)
                        continuation.yield(.executionFinished(
                            outcome: .failed,
                            reason: "All \(terminalOutputs.count) terminal node\(terminalOutputs.count == 1 ? "" : "s") failed"
                        ))
                    } else {
                        await TraceRecorder.shared.endSpan(spanID: traceContext.spanID, status: .completed)
                        continuation.yield(.executionFinished(outcome: .completed, reason: nil))
                    }
                    continuation.finish()

                } catch is CancellationError {
                    logger.notice("Workflow cancelled for conversation: \(conversationID)")
                    await ExecutionSuspensionService.shared.cancel(for: conversationID)
                    let classified = ClassifiedAgentError.synthetic(
                        category: .userCancelled,
                        origin: "WorkflowExecutor.executeWorkflow.cancelled",
                        message: "User stopped the workflow",
                        context: ["conversation_id": conversationID.uuidString]
                    )
                    await TraceRecorder.shared.emitAgentError(span: traceContext, error: classified, iteration: nil)
                    await TraceRecorder.shared.endSpan(spanID: traceContext.spanID, status: .error)
                    continuation.yield(.executionFinished(outcome: .cancelled, reason: "User stopped the workflow"))
                    continuation.finish()
                } catch let wfError as WorkflowError {
                    // Workflow-typed failure: classify with the matching wf* category
                    // (the categories were defined but never emitted — this lights up
                    // the workflow phase in TrendsView and produces actionable error
                    // rows in the Report Inspector).
                    logger.error("Workflow fatal error: \(wfError.localizedDescription)")
                    let category = Self.classify(wfError)
                    let classified = ClassifiedAgentError.synthetic(
                        category: category,
                        origin: "WorkflowExecutor.executeWorkflow.workflowError",
                        message: wfError.localizedDescription,
                        context: ["profile_id": profileID.uuidString]
                    )
                    await TraceRecorder.shared.emitAgentError(span: traceContext, error: classified, iteration: nil)
                    await TraceRecorder.shared.endSpan(spanID: traceContext.spanID, status: .error)
                    continuation.yield(.executionFinished(outcome: .failed, reason: wfError.localizedDescription))
                    continuation.finish(throwing: wfError)
                } catch {
                    logger.error("Workflow fatal error: \(error.localizedDescription)")
                    let classified = ClassifiedAgentError.synthetic(
                        category: .wfNodeFailed,
                        origin: "WorkflowExecutor.executeWorkflow.unexpected",
                        message: error.localizedDescription,
                        context: ["profile_id": profileID.uuidString]
                    )
                    await TraceRecorder.shared.emitAgentError(span: traceContext, error: classified, iteration: nil)
                    await TraceRecorder.shared.endSpan(spanID: traceContext.spanID, status: .error)
                    continuation.yield(.executionFinished(outcome: .failed, reason: error.localizedDescription))
                    continuation.finish(throwing: error)
                }
                } // end LogContext.with
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

        // Persist the per-node span so inner agent iteration spans (which parent
        // off this nodeSpan via `nodeSpan.newSpan()`) actually attach to a parent
        // row in the `spans` table. Without this, fetchFullTrace orphaned them.
        await TraceRecorder.shared.beginSpan(
            context: nodeSpan,
            name: "node:\(displayName)",
            kind: .workflowNode
        )

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
        // `includeFailures: true` lets an error-handler profile node (wired to a
        // failed upstream's `error` port) actually receive that upstream's output
        // + failure reason. This is safe regardless of routing: a failed envelope
        // only reaches `upstreamResults` when port-filtering matched an active
        // `error` port (i.e. genuine error routing) — normal success routing never
        // surfaces failed upstreams here.
        let upstreamInput = ContextCompressor.compileForWorkflow(
            results: upstreamResults,
            budget: workflowConfig.resolvedTotalContextBudget,
            perNodeBudget: workflowConfig.resolvedContextBudgetPerNode,
            includeFailures: true
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

        // Gather media/file artifacts from COMPLETED upstream nodes only. Note the
        // intentional asymmetry with text: `compileForWorkflow(includeFailures:)`
        // surfaces an error-routed failed upstream's text + reason to an error
        // handler, but a failed node's partial/aborted media is rarely safe to
        // forward, so artifacts stay completed-only. (Inactive condition branches,
        // already port-filtered out of `upstreamResults`, contribute neither.)
        // De-duplicated by id so a diamond/OR-join (where two branches each forward
        // the same ancestor artifact) doesn't list it twice or extract it twice.
        let upstreamArtifacts: [MediaArtifact] = Self.forwardedArtifacts(
            own: [],
            upstream: upstreamResults
                .filter { if case .completed = $0.status { return true }; return false }
                .flatMap(\.artifacts)
        )

        // Extract text from `.document` artifacts (PDF/DOCX/…) so a text-only model
        // can read attached files. Report-and-skip (policy b): a doc that can't be
        // read is traced + surfaced as a per-node warning, and the node CONTINUES
        // with whatever extracted (this is enrichment, not a hard dependency).
        let upstreamArtifactText: String
        if upstreamArtifacts.isEmpty {
            upstreamArtifactText = ""
        } else {
            let (extracted, docFailures) = await ContextCompressor.extractDocumentText(
                from: upstreamArtifacts,
                fileProcessor: FileProcessorService()
            )
            upstreamArtifactText = extracted
            for failure in docFailures {
                let classified = ClassifiedAgentError.synthetic(
                    category: failure.category,
                    origin: "WorkflowExecutor.executeNode.extractDocumentText",
                    message: failure.message,
                    context: ["path": failure.path, "node": displayName]
                )
                await TraceRecorder.shared.emitAgentError(span: nodeSpan, error: classified)
                continuation.yield(.warning(category: .resourceUnavailable, message: failure.message, relatedPath: failure.path, sourceNodeID: nodeID))
            }
        }

        let workflowContext = WorkflowExecutionContext(
            taskDescription: effectiveTaskDescription,
            upstreamInput: upstreamInput,
            isFirstNode: isFirstNode,
            nodeName: displayName,
            nodeID: nodeID,
            upstreamArtifacts: upstreamArtifacts,
            upstreamArtifactText: upstreamArtifactText
        )

        if !upstreamArtifacts.isEmpty {
            logger.info("Node '\(displayName)' received \(upstreamArtifacts.count) upstream artifact(s), extracted \(upstreamArtifactText.count) chars of document text")
        }
        logger.info("Node '\(displayName)' context: taskDescription=\(effectiveTaskDescription.count) chars, upstreamInput=\(upstreamInput.count) chars, isFirstNode=\(isFirstNode)")
        if !upstreamInput.isEmpty {
            logger.debug("Node '\(displayName)' upstream preview:\n\(String(upstreamInput.prefix(500)))")
        }

        // --- Execute via AgentConnect (with timeout enforcement) ---
        // Priority: WorkflowNodeConfig.hardTimeout → agent executionTimeout → default 120s
        // `nil` → no timeout (the workflow's node-timeout setting is disabled and the
        // node sets no explicit `hardTimeout`); the node then runs unbounded.
        let nodeTimeout: TimeInterval? = {
            if let hardTimeout = node.nodeConfig?.hardTimeout { return hardTimeout }
            if case .agent(let config) = profile.details, let t = config.executionTimeout { return t }
            return workflowConfig.effectiveNodeTimeout
        }()

        var nodeOutput = ""
        var nodeArtifacts: [ToolOutput] = []
        var nodeMediaArtifacts: [MediaArtifact] = []
        var nodeStatus: NodeExecutionStatus = .completed
        // Degraded success: the inner agent stopped early (circuit breaker / iteration budget)
        // but synthesized a usable best-effort answer. The node still COMPLETES (output flows
        // downstream, joins satisfied, error port untouched); this flag rides the completion
        // event so the UI can badge the node amber instead of green.
        var nodeHasWarnings = false

        do {
            // Race: stream consumption vs timeout (same pattern as AgentConnect).
            //
            // The inner stream now also reports its terminal `ExecutionOutcome` so
            // we can detect "synthesizer laundering" — the case where the inner
            // ReAct/Bot loop emitted `.executionFinished(outcome: .failed)` (e.g.
            // iteration ceiling hit, classified error) but ResponseSynthesizer
            // produced a clean-sounding string. Without this, every such failure
            // becomes a `.completed` workflow node and (a) inflates the success
            // tally and (b) makes node-level retry (`maxNodeRetries`) unreachable.
            let streamResult = try await withThrowingTaskGroup(
                of: (String, [ToolOutput], [MediaArtifact], ExecutionOutcome?, String?).self
            ) { group in
                // Timeout sentinel — only when a timeout is configured. When disabled
                // (`nodeTimeout == nil`) the group runs the stream task alone, unbounded.
                if let nodeTimeout {
                    group.addTask {
                        try await Task.sleep(for: .seconds(nodeTimeout))
                        throw AgentExecutionError(reason: .executionTimeout(
                            elapsed: nodeTimeout, limit: nodeTimeout
                        ))
                    }
                }

                // Actual stream consumption — accumulates state locally
                group.addTask {
                    var output = ""
                    var tools: [ToolOutput] = []
                    var media: [MediaArtifact] = []
                    // Tracks the inner agent/bot's terminal outcome (last
                    // `.executionFinished` event). Surfaces the laundering case:
                    // inner outcome can be `.failed` even when the synthesizer
                    // produced a non-empty `content` value.
                    var innerOutcome: ExecutionOutcome? = nil
                    var innerReason: String? = nil

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

                        case .toolSucceeded(let toolOut, let durationMs, _):
                            tools.append(toolOut)
                            continuation.yield(.toolSucceeded(toolOut, durationMs: durationMs, sourceNodeID: nodeID))

                        case .toolFailed(let toolOut, let category, let suggestion, _):
                            tools.append(toolOut)
                            continuation.yield(.toolFailed(toolOut, category: category, suggestion: suggestion, sourceNodeID: nodeID))

                        case .thought(let msg, let id, _):
                            continuation.yield(.thought("[\(displayName)] \(msg)", id: id, sourceNodeID: nodeID))

                        case .reasoning(let msg, let id, _):
                            continuation.yield(.reasoning("[\(displayName)] \(msg)", id: id, sourceNodeID: nodeID))

                        case .toolCall(let name, let params, _, let stepId):
                            continuation.yield(.toolCall(name: name, params: params, sourceNodeID: nodeID, stepId: stepId))

                        case .requestConfirmation(let toolName, let params, let operationID, _):
                            continuation.yield(.requestConfirmation(toolName: toolName, params: params, operationID: operationID, sourceNodeID: nodeID))

                        case .requestClarification(let question, let operationID, _, let options, let multiline):
                            continuation.yield(.requestClarification(question: "[\(displayName)] \(question)", operationID: operationID, sourceNodeID: nodeID, options: options, multiline: multiline))

                        case .requestGate(let prompt, let options, let operationID, let deadline, _):
                            // Gates are structural nodes, not profile-node output, so this is defensive —
                            // forward it tagged with this node id if it ever surfaces here.
                            continuation.yield(.requestGate(prompt: "[\(displayName)] \(prompt)", options: options, operationID: operationID, deadline: deadline, sourceNodeID: nodeID))

                        case .error(let errMsg):
                            // Prefix the node name but PRESERVE the structured error's
                            // category/path/suggestion (don't flatten via interpolation).
                            continuation.yield(.error(StructuredError(
                                category: errMsg.category,
                                message: "[\(displayName)] \(errMsg.message)",
                                relatedPath: errMsg.relatedPath,
                                suggestion: errMsg.suggestion
                            )))

                        case .warning(let cat, let msg, let relatedPath, _):
                            // Always route to the node's own timeline — detail visibility when
                            // the user drills into the node.
                            continuation.yield(.warning(category: cat, message: "[\(displayName)] \(msg)", relatedPath: relatedPath, sourceNodeID: nodeID))
                            // Additionally surface run-threatening categories at the workflow
                            // level (sourceNodeID = nil). Circuit-breaker / context-pressure
                            // indicate the whole workflow may abort; the user shouldn't need
                            // to drill into a specific node to learn that.
                            if cat.bubblesToWorkflowLevel {
                                continuation.yield(.warning(category: cat, message: "[\(displayName)] \(msg)", relatedPath: relatedPath, sourceNodeID: nil))
                            }

                        case .workflowNodeStarted, .workflowNodeCompleted, .workflowNodeFailed, .workflowProgress, .workflowLoopIteration:
                            break // Ignore nested workflow events

                        case .mediaProgress:
                            continuation.yield(event)

                        case .artifactProduced(let artifact):
                            media.append(artifact)
                            continuation.yield(event)

                        case .requestPlanReview:
                            continuation.yield(event)

                        case .planGenerated, .planApproved, .subtaskStarted, .subtaskCompleted,
                             .reflectionTrialStarted, .reflectionEvaluating, .reflectionRetrying, .reflectionAccepted,
                             .delegationStarted, .delegationCompleted,
                             .compactionCompleted, .compactionFailed,
                             .tokenUsage:
                            continuation.yield(event)

                        case .executionFinished(let outcome, let reason):
                            // Inner executor's terminal event is captured locally
                            // (to derive `nodeStatus` below) but not forwarded to
                            // the outer continuation — the workflow emits its own
                            // `workflowNodeCompleted` / `workflowNodeFailed` and
                            // ultimately one `executionFinished` for the whole run.
                            innerOutcome = outcome
                            innerReason = reason
                        }
                    }
                    return (output, tools, media, innerOutcome, innerReason)
                }

                let result = try await group.next()!
                group.cancelAll()
                return result
            }
            nodeOutput = streamResult.0
            nodeArtifacts = streamResult.1
            nodeMediaArtifacts = streamResult.2

            // Demote `.completed` → `.failed` when the inner agent/bot signalled
            // a non-success terminal outcome. The default nodeStatus (`.completed`)
            // only sticks when the inner stream finished without an `executionFinished`
            // event OR finished with `outcome == .completed`. Treating this as
            // `.modelError` keeps the failure retryable (`AgentFailureReason.isRetryable`
            // is true for `.modelError`), so node-level `maxNodeRetries` now fires
            // for the synthesizer-laundered case.
            if case .completed = nodeStatus, let outcome = streamResult.3 {
                switch outcome {
                case .completed:
                    break
                case .completedWithWarnings:
                    // Degraded success — keep `.completed` so the workflow continues (the
                    // best-effort output is real and flows downstream); surface the warning
                    // on the node instead of killing the run. The evidence (LOOP GUARD card
                    // etc.) is already in the node's timeline.
                    nodeHasWarnings = true
                    logger.notice("Node '\(displayName)' completed with warnings (\(streamResult.4 ?? "degraded run")). Continuing.")
                case .failed:
                    let reasonText = streamResult.4 ?? "Inner agent execution failed"
                    // Classify instead of blanket `.modelError`: a circuit-breaker stale-loop abort
                    // becomes `.repetitiveActionLoop` (correct remediation; NOT retryable — retrying
                    // a deterministic loop-abort would just loop again). Unrecognized text keeps the
                    // retryable `.modelError` behaviour described above.
                    nodeStatus = .failed(AgentFailureReason.classify(agentReasonText: reasonText))
                    logger.warning("Node '\(displayName)' inner outcome=.failed (\(reasonText)). Demoting nodeStatus to .failed.")
                case .cancelled:
                    nodeStatus = .canceled
                    logger.notice("Node '\(displayName)' inner outcome=.cancelled. Demoting nodeStatus to .canceled.")
                }
            }
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

        // Auto-detect structured output: if the agent/bot emitted a JSON object or
        // array (optionally fenced), expose it as `structuredOutput` so downstream
        // nodes can do `{{ input.json.path }}` access and field routing. Plain text
        // stays `nil`. Zero-config — no per-node schema required for the common case.
        let structured = JSONValue.parseStructured(nodeOutput)
        if structured != nil {
            logger.info("Node '\(displayName)' produced structured (JSON) output")
        }

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
            // Forward upstream artifacts alongside this node's own produced media,
            // so artifacts survive multi-hop pipelines (not just producer→consumer).
            artifacts: Self.forwardedArtifacts(own: nodeMediaArtifacts, upstream: upstreamArtifacts),
            metadata: NodeExecutionMetadata(
                startTime: startTime,
                endTime: endTime,
                iterationsUsed: 1,
                toolsInvoked: nodeArtifacts.map(\.toolName),
                tokenEstimate: nodeOutput.count / 4
            ),
            structuredOutput: structured
        )

        // P1-16: persist per-node execution metrics. `NodeResultEnvelope.metadata`
        // (duration, iterationsUsed, toolsInvoked, tokenEstimate) used to live
        // only in memory and get discarded at run end. Emitting each field as a
        // `metric` span event makes them queryable from `span_events` so per-node
        // p50/p95 latency and tool-usage rollups are computable.
        let durationMs = Int(result.metadata.duration * 1000)
        await TraceRecorder.shared.emitMetric(span: nodeSpan, key: "node_duration", valueMs: durationMs)
        await TraceRecorder.shared.emitMetric(span: nodeSpan, key: "tools_invoked", valueMs: result.metadata.toolsInvoked.count)
        await TraceRecorder.shared.emitMetric(span: nodeSpan, key: "token_estimate", valueMs: result.metadata.tokenEstimate)

        // --- Emit Node Completion ---
        switch nodeStatus {
        case .completed:
            // Emit the FULL node output, not a 100-char teaser. The execution UI
            // renders this as the node's Output panel and persists it in the run
            // record — both need the complete text. Card-strip previews clip
            // visually via line limits, and the orchestrator's aggregate thought
            // log truncates its own preview (see ActiveStreamManager).
            await TraceRecorder.shared.endSpan(spanID: nodeSpan.spanID, status: .completed)
            continuation.yield(.workflowNodeCompleted(nodeID: nodeID, profileName: displayName, summary: nodeOutput, hasWarnings: nodeHasWarnings))
            logger.info("Node '\(displayName)' completed. Output: \(nodeOutput.count) chars, Duration: \(String(format: "%.1f", result.metadata.duration))s")

        case .failed(let reason):
            // Classify the per-node failure so it surfaces in TrendsView under
            // the workflow phase rather than as an opaque span-error.
            let classified = ClassifiedAgentError.synthetic(
                category: .wfNodeFailed,
                origin: "WorkflowExecutor.executeNode",
                message: reason.localizedDescription,
                context: ["node_name": displayName, "node_id": nodeID.uuidString]
            )
            await TraceRecorder.shared.emitAgentError(span: nodeSpan, error: classified, iteration: nil)
            await TraceRecorder.shared.endSpan(spanID: nodeSpan.spanID, status: .error)
            continuation.yield(.workflowNodeFailed(nodeID: nodeID, profileName: displayName, error: reason.localizedDescription, suggestion: reason.remediation))

        case .canceled:
            await TraceRecorder.shared.endSpan(spanID: nodeSpan.spanID, status: .error)
            continuation.yield(.workflowNodeFailed(nodeID: nodeID, profileName: displayName, error: "Cancelled"))

        case .skipped(let reason):
            // Skipped here is the "post-execution skip" path (rare in practice;
            // upstream skips are caught earlier with a synthetic envelope). Still
            // emit the category so the workflow phase shows the signal.
            let classified = ClassifiedAgentError.synthetic(
                category: .wfNodeSkipped,
                origin: "WorkflowExecutor.executeNode.skipped",
                message: reason,
                context: ["node_name": displayName, "node_id": nodeID.uuidString]
            )
            await TraceRecorder.shared.emitAgentError(span: nodeSpan, error: classified, iteration: nil)
            await TraceRecorder.shared.endSpan(spanID: nodeSpan.spanID, status: .completed)
            continuation.yield(.workflowNodeFailed(nodeID: nodeID, profileName: displayName, error: "Skipped: \(reason)"))
        }

        return result
    }

    // MARK: - Profile Node Retry Wrapper

    /// Wraps `executeNode()` with WorkflowNodeConfig-driven retry logic.
    /// Retries up to `maxNodeRetries` times with `retryDelay` between attempts.
    ///
    /// Two-layer retry relationship (resilience architecture): this is the OUTER,
    /// "business" retry — it re-runs the whole node task. Inside each attempt, the
    /// node's agent/bot run has its own INNER transport retries (bounded by the
    /// resolved `TransportResiliencePolicy`: ~3 transient + 5 throttle for cloud).
    /// The two compose multiplicatively in the worst case (maxNodeRetries × inner
    /// budget), but the product is bounded — never infinite — and `maxNodeRetries`
    /// defaults to 0 (`WorkflowConfig.resolvedMaxRetries`), so transient transport
    /// recovery is handled by the inner tier and node-level retries only stack when
    /// a user explicitly opts in. Keep `maxNodeRetries` modest for flaky providers.
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

    // MARK: - Artifact Forwarding

    /// Merges a node's own produced artifacts with the artifacts it received from
    /// upstream, de-duplicated by `id` (stable, first occurrence wins).
    ///
    /// This is what makes media/file artifacts flow *end-to-end* rather than one
    /// hop: a node's output envelope carries its own media **plus** everything its
    /// upstreams carried, so a downstream vision node can consume an image produced
    /// several hops earlier — even across intermediate Code/Gate/Agent nodes that
    /// didn't themselves emit media. De-dup by id keeps diamonds (A→B,C→D) from
    /// double-listing the same artifact and bounds growth to the run's distinct set.
    private nonisolated static func forwardedArtifacts(
        own: [MediaArtifact],
        upstream: [MediaArtifact]
    ) -> [MediaArtifact] {
        var seen = Set<UUID>()
        var merged: [MediaArtifact] = []
        for artifact in own + upstream where seen.insert(artifact.id).inserted {
            merged.append(artifact)
        }
        return merged
    }

    /// Runs a resolved tool with a wall-clock timeout. Mirrors the per-node timeout
    /// race used for profile nodes (`executeNode`) — a hung tool throws
    /// `AgentExecutionError.executionTimeout` instead of blocking the level forever.
    /// The thrown timeout is retryable by the Action node's retry loop.
    private nonisolated static func runToolWithTimeout(
        _ tool: AgentTool,
        args: Data,
        timeout: TimeInterval?
    ) async throws -> (output: String, artifacts: [MediaArtifact]) {
        // No timeout configured → run the tool unbounded.
        guard let timeout else {
            return try await tool.run(args)
        }
        return try await withThrowingTaskGroup(of: (String, [MediaArtifact]).self) { group in
            group.addTask { try await tool.run(args) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw AgentExecutionError(reason: .executionTimeout(elapsed: timeout, limit: timeout))
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
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
        // Trace context + callback are threaded through so loop bodies can
        // produce child spans of the parent loop rather than fresh root traces,
        // and so body iterations' onTraceUpdate events reach the same consumer
        // as the parent workflow's. Defaults preserve the prior single-shot
        // behaviour for non-loop structural nodes (condition, gate, code).
        traceContext: TraceContext = TraceContext(subAgentName: "structural", provider: .anthropic),
        onTraceUpdate: @escaping @Sendable (AgentTraceLog) -> Void = { _ in },
        streamProvider: (any WorkflowStreamProvider)? = nil,
        profileMap: [UUID: BackendProfileModel]? = nil,
        // Workflow defaults used by Action nodes for timeout/retry resolution.
        workflowConfig: WorkflowConfig = WorkflowConfig(agentProfileIDs: [])
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
        // Artifacts the node itself produces (only Action nodes, via their tool).
        var producedArtifacts: [MediaArtifact] = []

        // Per-structural-node span so condition/loop/code/gate/action nodes appear in the
        // trace tree (mirrors the profile-node span) and Action-node tool results below
        // attach to a real parent row (Gap #11). Status reflects the node's outcome.
        let structSpan = traceContext.newSpan()
        await TraceRecorder.shared.beginSpan(context: structSpan, name: "node:\(displayName)", kind: .workflowNode)
        defer {
            let spanStatus: SpanStatus = { if case .completed = status { return .completed } else { return .error } }()
            Task { await TraceRecorder.shared.endSpan(spanID: structSpan.spanID, status: spanStatus) }
        }

        let upstreamNames = upstreamResults.map(\.profileName).joined(separator: ", ")
        let upstreamTotalChars = upstreamResults.reduce(0) { $0 + $1.output.count }
        let kindLabel: String = switch node.kind {
        case .profile: "profile"
        case .condition: "condition"
        case .loop: "loop"
        case .code: "code"
        case .gate: "gate"
        case .trigger: "trigger"
        case .action: "action"
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
                        continuation: continuation,
                        traceContext: traceContext
                    )
                } catch {
                    logger.error("Condition LLM fallback failed for '\(displayName)': \(error.localizedDescription)")
                    continuation.yield(.thought("[\(displayName)] AI Classifier failed: \(error.localizedDescription)", sourceNodeID: nodeID))
                    // P1-18: classify the failure into the workflow phase so it
                    // surfaces in TrendsView instead of being a silent thought event.
                    let classified = ClassifiedAgentError.synthetic(
                        category: .wfClassifierFailed,
                        origin: "WorkflowExecutor.evaluateConditionWithLLM",
                        message: error.localizedDescription,
                        context: [
                            "node_name": displayName,
                            "node_id": nodeID.uuidString,
                            "model": config.llmModelName ?? ""
                        ]
                    )
                    await TraceRecorder.shared.emitAgentError(span: traceContext, error: classified, iteration: nil)
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

                // Execute body workflow (thread injected dependencies for testability).
                //
                // P0-4: child span of the parent loop's traceContext (not a fresh root),
                // and forward the parent's `onTraceUpdate` so body-iteration trace events
                // are no longer orphaned in the trace tree.
                let bodyExecutor = WorkflowExecutor(workflowProfileID: bodyProfileID)
                let bodyTrace = traceContext.newSpan()
                let bodyStream = bodyExecutor.executeWorkflow(
                    userInput: iterationInput,
                    chatHistory: [],
                    conversationID: conversationID,
                    ragContext: nil,
                    traceContext: bodyTrace,
                    onTraceUpdate: onTraceUpdate,
                    layout: nil,
                    profileMap: profileMap,
                    streamProvider: streamProvider
                )

                // Consume body stream, accumulate text output.
                //
                // P0-5: body-failure detection now reads the body's
                // `.executionFinished(outcome:)` event — the single source of truth.
                // Previously we keyed off the `.error` event, which only fires when
                // *all* terminals failed; a partial-failure body reported `.completed`
                // and the loop kept iterating against unreliable upstream data.
                var bodyOutput = ""
                var bodyOutcome: ExecutionOutcome? = nil
                var bodyFailureReason: String? = nil
                do {
                    for try await event in bodyStream {
                        switch event {
                        case .content(let text):
                            bodyOutput += text
                        case .thought(let msg, let id, _):
                            continuation.yield(.thought("[\(displayName) iter \(iteration)] \(msg)", id: id, sourceNodeID: nodeID))
                        case .error(let errMsg):
                            // Surface in the node timeline but don't decide outcome here —
                            // wait for the body's `.executionFinished` to make the call.
                            continuation.yield(.thought("[\(displayName) iter \(iteration)] Error: \(errMsg.message)", sourceNodeID: nodeID))
                            bodyFailureReason = errMsg.message
                        case .executionFinished(let outcome, let reason):
                            bodyOutcome = outcome
                            if let reason { bodyFailureReason = reason }

                        // ⚠️ HITL requests MUST be forwarded, not suppressed. Each carries an
                        // `operationID` that the inner execution is already suspended on, waiting
                        // for `ExecutionSuspensionService` to resume it. Swallowing the event
                        // means no banner is ever shown, so nobody can answer, so the suspension
                        // never resolves — the whole workflow hangs, with no error and no
                        // timeout. Before 2026-07-31 `default: break` caught all three, so a Gate
                        // node inside a loop body hung the run silently. Action nodes began
                        // requesting confirmation the same day, which made the reachable surface
                        // much larger.
                        //
                        // `sourceNodeID` keeps the INNER node's id when it has one: it is the
                        // node actually asking, it is what the approval scope is keyed on, and
                        // collapsing it to the loop's id would pool approvals across every node
                        // in the body. Falls back to the loop node so the banner is always
                        // attributable to something on the canvas.
                        case .requestConfirmation(let toolName, let params, let operationID, let innerNode):
                            // Logged because a FORWARDED request and a SWALLOWED one look
                            // identical from outside — both leave the run sitting still. This
                            // line is what distinguishes "waiting for the user" from "hung".
                            logger.notice("[WF_HITL] loop '\(displayName)' iter \(iteration) forwarding confirmation for '\(toolName)' [op \(operationID) node \(innerNode?.uuidString ?? nodeID.uuidString)] — run is now WAITING on the user")
                            continuation.yield(.requestConfirmation(
                                toolName: toolName, params: params,
                                operationID: operationID, sourceNodeID: innerNode ?? nodeID))

                        case .requestGate(let prompt, let options, let operationID, let deadline, let innerNode):
                            logger.notice("[WF_HITL] loop '\(displayName)' iter \(iteration) forwarding GATE [op \(operationID)] — run is now WAITING on the user")
                            continuation.yield(.requestGate(
                                prompt: prompt, options: options, operationID: operationID,
                                deadline: deadline, sourceNodeID: innerNode ?? nodeID))

                        case .requestClarification(let question, let operationID, let innerNode, let options, let multiline):
                            logger.notice("[WF_HITL] loop '\(displayName)' iter \(iteration) forwarding clarification [op \(operationID)] — run is now WAITING on the user")
                            continuation.yield(.requestClarification(
                                question: "[\(displayName) iter \(iteration)] \(question)",
                                operationID: operationID, sourceNodeID: innerNode ?? nodeID,
                                options: options, multiline: multiline))

                        default:
                            break // Suppress inner workflow orchestration events
                        }
                    }
                    // Outcome-based failure detection. `.failed` is authoritative;
                    // `.cancelled` propagates as a cancel-shaped failure (consistent
                    // with the prior catch behavior). `.completed` is success.
                    if bodyOutcome == .failed {
                        let reasonText = bodyFailureReason ?? "Loop body reported failure"
                        logger.error("Loop '\(displayName)' iteration \(iteration) body outcome=.failed (\(reasonText))")
                        output = iterationOutput.isEmpty ? upstreamText : iterationOutput
                        status = .failed(.modelError(provider: "workflow", error: "Loop body failed at iteration \(iteration): \(reasonText)"))
                        break
                    }
                    if bodyOutcome == .cancelled {
                        logger.notice("Loop '\(displayName)' iteration \(iteration) body outcome=.cancelled")
                        output = iterationOutput.isEmpty ? upstreamText : iterationOutput
                        status = .canceled
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
            // Template transform via WorkflowTemplate (single-pass, injection-safe).
            // Supports {{ input }}, {{ input.json.path }}, {{ var.name }}, and
            // {{ var.name.path }}. `input.json` reads the first upstream node that
            // produced structured (JSON) output.
            let upstreamText = upstreamResults.map(\.output).joined(separator: "\n")
            let upstreamJSON = upstreamResults.compactMap(\.structuredOutput).first

            logger.debug("Code node '\(displayName)' template before substitution:\n\(String(config.template.prefix(300)))")
            logger.debug("Code node '\(displayName)' upstream input preview:\n\(String(upstreamText.prefix(300)))")
            if upstreamJSON != nil {
                logger.debug("Code node '\(displayName)' has upstream structured JSON available for {{ input.json.* }}")
            }

            output = WorkflowTemplate.render(
                config.template,
                input: upstreamText,
                inputJSON: upstreamJSON,
                variables: state.variables
            )
            logger.debug("Code node '\(displayName)' output after substitution:\n\(String(output.prefix(300)))")

            // Write to shared variable if configured
            if let varName = config.outputVariable, !varName.isEmpty {
                variableUpdates[varName] = output
                logger.info("Code node '\(displayName)' wrote variable '\(varName)': \(output.prefix(100))")
            }
            logger.info("Code node '\(displayName)' template transform: \(output.count) chars")

        case .gate(let config):
            // [E1] HITL Gate — suspend until the user picks an option; that choice routes the workflow
            // to the matching output port (per-option branching, like a Condition node but human-decided).
            let operationID = UUID()
            let upstreamText = upstreamResults.map(\.output).joined(separator: "\n")
            logger.debug("Gate '\(displayName)' upstream content preview:\n\(String(upstreamText.prefix(300)))")

            // [HITL/P5] A user-configured gate timeout is an explicit per-gate auto-decision — honor it
            // as-is. With no configured timeout the gate waits INDEFINITELY: the execution container owns
            // the deadline — Stop (cancel(for:)) for an attended run, the 10-min deadline for a scheduled
            // run, or sibling cancelAll on stopWorkflow. Same model as chat.
            let gateTimeout = config.timeout
            let deadline = gateTimeout.map { Date().addingTimeInterval($0) }

            // Emit the structured gate request — options render as one-tap buttons, `deadline` drives a
            // live countdown in the banner.
            continuation.yield(.requestGate(
                prompt: config.prompt,
                options: config.options,
                operationID: operationID,
                deadline: deadline,
                sourceNodeID: nodeID
            ))

            logger.info("Gate node '\(displayName)' suspending for choice (operationID: \(operationID), options: [\(config.options.joined(separator: " | "))], timeout: \(gateTimeout.map { "\($0)s" } ?? "indefinite — container-bounded"))")

            let chosenOption: String?
            if let timeout = gateTimeout {
                // User-configured timeout: race the suspension against a sleep timer that auto-rejects.
                do {
                    chosenOption = try await withThrowingTaskGroup(of: String?.self) { group in
                        group.addTask {
                            await ExecutionSuspensionService.shared.suspendForGate(
                                for: operationID, conversationID: conversationID
                            )
                        }
                        group.addTask {
                            try await Task.sleep(for: .seconds(timeout))
                            await ExecutionSuspensionService.shared.resumeGate(for: operationID, chosenOption: nil)
                            return nil
                        }
                        let result = try await group.next()!
                        group.cancelAll()
                        return result
                    }
                } catch {
                    chosenOption = nil
                }
            } else {
                chosenOption = await ExecutionSuspensionService.shared.suspendForGate(
                    for: operationID, conversationID: conversationID
                )
            }

            if let chosen = chosenOption {
                // Route to the chosen option's output port; pass the upstream payload to that branch.
                activePorts = [chosen]
                output = upstreamText
                logger.info("Gate node '\(displayName)' → option '\(chosen)' (routing to its port)")
            } else {
                // No choice (timeout / cancel / Stop) — the gate fails; no branch is taken.
                output = "Gate not answered (timed out or cancelled)"
                status = .failed(.modelError(provider: "workflow", error: "Gate '\(displayName)' was not answered"))
                logger.info("Gate node '\(displayName)' unanswered — failing (no branch taken)")
            }

            // Gate HITL is now a first-class `.gate` interaction, traced uniformly by ActiveStreamManager
            // (raise + resolve, with the chosen option as the outcome) — the manual span here is removed
            // to avoid a double-emit.

        case .trigger:
            output = ""
            logger.info("Trigger node '\(displayName)' skipped (entry-point only)")

        case .action(let config):
            // Deterministic tool invocation — no LLM. Resolve the configured tool,
            // bind its arguments from upstream data, run it (with timeout + retry),
            // and surface the tool's output + artifacts. Failures route through the
            // node's `error` port.
            guard let toolRef = config.tool else {
                output = "Action node has no tool configured"
                status = .failed(.modelError(provider: "workflow", error: "Action node '\(displayName)' has no tool configured"))
                logger.error("Action node '\(displayName)' has no tool configured")
                break
            }

            guard let provider = streamProvider,
                  let agentTool = await provider.resolveWorkflowTool(toolRef, conversationID: conversationID) else {
                output = "Could not resolve tool '\(toolRef.name)'"
                status = .failed(.modelError(provider: "workflow", error: "Action node '\(displayName)': tool '\(toolRef.name)' could not be resolved (removed, disabled, or MCP server offline)"))
                logger.error("Action node '\(displayName)': failed to resolve tool '\(toolRef.name)'")
                break
            }

            // Emit a tool-call timeline event up front so the node shows a proper
            // tool card. Argument *names* only (not resolved values) so a binding
            // like `{{ var.api_key }}` never leaks a secret into the trace/UI.
            let argKeys = config.argumentBindings.keys.sorted().joined(separator: ", ")
            let toolParams = "args: [\(argKeys)]"
            let toolStart = Date()
            continuation.yield(.toolCall(name: toolRef.name, params: toolParams, sourceNodeID: nodeID))

            // (#4) Permission pre-flight. Action nodes bypass ToolExecutionMediator,
            // so we run the same TCC check it does — triggering the macOS prompt if
            // undetermined and failing with an actionable message if denied (rather
            // than letting the tool fail opaquely deep inside its own call).
            let requiredPermissions = ToolExecutionMediator.getRequiredPermissions(for: toolRef.name)
            if !requiredPermissions.isEmpty {
                let granted = await PermissionManager.shared.ensurePermissions(for: requiredPermissions)
                if !granted {
                    let permList = requiredPermissions.map { String(describing: $0) }.joined(separator: ", ")
                    output = "Missing macOS permission for '\(toolRef.name)'. Grant access in System Settings › Privacy & Security, then re-run."
                    status = .failed(.modelError(provider: "tool", error: "Missing permission(s): \(permList)"))
                    continuation.yield(.toolFailed(
                        ToolOutput(toolName: toolRef.name, params: toolParams, output: output, isSuccess: false),
                        category: .permissionRejected, sourceNodeID: nodeID
                    ))
                    logger.warning("Action node '\(displayName)': permission denied for '\(toolRef.name)' (\(permList))")
                    break
                }
            }

            // Resolve each argument binding against the upstream data. Structural
            // nodes read all port-active upstreams (consistent with Code/Gate).
            // Computed once — stable across retries.
            let upstreamText = upstreamResults.map(\.output).joined(separator: "\n")
            let upstreamJSON = upstreamResults.compactMap(\.structuredOutput).first
            var argsData = WorkflowActionArgs.build(
                bindings: config.argumentBindings,
                schema: toolRef.parameters,
                input: upstreamText,
                inputJSON: upstreamJSON,
                variables: state.variables
            )

            // (#5) Confirmation. Action nodes bypass `ToolExecutionMediator`, which is what
            // raises HITL for the agent path — so until 2026-07-31 a tool the user had
            // configured to ASK ran silently here, and the `requiresConfirmation: false` in
            // `resolveWorkflowTool` was not even the reason: nothing on this path ever read the
            // flag. The node's own tool configuration is the authority, exactly as in chat.
            //
            // Resolved arguments (not the argument NAMES the timeline shows) are what the user
            // is asked to approve — approving "args: [command]" without seeing the command is
            // not consent. This matches the agent path, which has always surfaced real arguments
            // in the banner; the trace event above stays names-only because it is exportable.
            if toolRef.requiresConfirmation {
                // Scoped to THIS node: a grant given in another node of the same run is not an
                // answer here, because nodes configure their tools independently.
                let alreadyAllowed = await SessionToolApprovals.shared.isAllowed(
                    toolName: toolRef.name, conversationID: conversationID, nodeID: nodeID
                )
                if alreadyAllowed {
                    logger.info("Action node '\(displayName)': '\(toolRef.name)' auto-approved via this node's allowlist — no banner.")
                } else {
                    let confirmParams = String(data: argsData, encoding: .utf8) ?? toolParams
                    let operationID = UUID()
                    continuation.yield(.requestConfirmation(
                        toolName: toolRef.name, params: confirmParams,
                        operationID: operationID, sourceNodeID: nodeID
                    ))
                    logger.info("Action node '\(displayName)': awaiting user confirmation for '\(toolRef.name)' [op \(operationID)]")

                    let approved = await ExecutionSuspensionService.shared.suspend(
                        for: operationID, conversationID: conversationID
                    )

                    // Honour argument edits made in the banner. Offering an editor and then
                    // running the ORIGINAL arguments would be worse than offering none.
                    if approved,
                       let edited = await ExecutionSuspensionService.shared.consumeEditedArguments(for: operationID),
                       let reEncoded = try? JSONEncoder().encode(edited) {
                        argsData = reEncoded
                        logger.info("Action node '\(displayName)': running '\(toolRef.name)' with user-edited arguments.")
                    }

                    if !approved {
                        output = "User denied '\(toolRef.name)'."
                        status = .failed(.modelError(provider: "tool", error: "User denied tool '\(toolRef.name)' in node '\(displayName)'"))
                        continuation.yield(.toolFailed(
                            ToolOutput(toolName: toolRef.name, params: toolParams, output: output, isSuccess: false),
                            category: .userDenied, sourceNodeID: nodeID
                        ))
                        logger.notice("Action node '\(displayName)': '\(toolRef.name)' DENIED by user — routing through the node's error port.")
                        break
                    }
                }
            }

            // (#1) Per-node timeout — a hung tool can't block the workflow forever.
            // (#2) Retry — transient failures (network/MCP/timeout) retry up to
            // `maxNodeRetries`. Defaults: hardTimeout → workflow default (120s),
            // retries → workflow default (0). Both honor per-node overrides.
            let nodeTimeout: TimeInterval? = node.nodeConfig?.hardTimeout ?? workflowConfig.effectiveNodeTimeout
            let maxRetries = node.nodeConfig?.maxNodeRetries ?? workflowConfig.resolvedMaxRetries
            let retryDelay = node.nodeConfig?.retryDelay ?? 0
            logger.info("Action node '\(displayName)': invoking tool '\(toolRef.name)' (\(config.argumentBindings.count) binding(s), timeout \(nodeTimeout.map { "\(Int($0))s" } ?? "off"), retries \(maxRetries))")

            var attempt = 0
            while true {
                do {
                    let (toolOutput, toolArtifacts) = try await Self.runToolWithTimeout(agentTool, args: argsData, timeout: nodeTimeout)
                    output = toolOutput
                    producedArtifacts = toolArtifacts
                    let durationMs = Int(Date().timeIntervalSince(toolStart) * 1000)
                    // Route through reliability stats — Action-node tools were invisible
                    // to per-tool stats (they bypass ToolExecutionMediator) (Gap #11).
                    await TraceRecorder.shared.emitToolResult(span: structSpan, name: toolRef.name, success: true, output: toolOutput, durationMs: durationMs)
                    continuation.yield(.toolSucceeded(
                        ToolOutput(toolName: toolRef.name, params: toolParams, output: toolOutput, isSuccess: true),
                        durationMs: durationMs, sourceNodeID: nodeID
                    ))
                    logger.info("Action node '\(displayName)': tool '\(toolRef.name)' returned \(toolOutput.count) chars, \(toolArtifacts.count) artifact(s)")
                    break
                } catch is CancellationError {
                    status = .canceled
                    output = "Action cancelled"
                    continuation.yield(.toolFailed(
                        ToolOutput(toolName: toolRef.name, params: toolParams, output: output, isSuccess: false),
                        category: .cancelled, sourceNodeID: nodeID
                    ))
                    logger.notice("Action node '\(displayName)': cancelled")
                    break
                } catch {
                    // Retry transient failures (timeout, network, MCP) up to the cap.
                    if attempt < maxRetries {
                        attempt += 1
                        logger.notice("Action node '\(displayName)': tool '\(toolRef.name)' failed (\(error.localizedDescription)); retry \(attempt)/\(maxRetries)")
                        continuation.yield(.thought("[\(displayName)] Tool failed — retrying (\(attempt)/\(maxRetries))...", sourceNodeID: nodeID))
                        if retryDelay > 0 { try? await Task.sleep(for: .seconds(retryDelay)) }
                        continue
                    }
                    output = "Tool '\(toolRef.name)' failed: \(error.localizedDescription)"
                    status = .failed(.modelError(provider: "tool", error: error.localizedDescription))
                    // Distinguish timeout from a generic throw for the timeline icon.
                    let failureCategory: ToolFailureCategory
                    if let agentErr = error as? AgentExecutionError, case .executionTimeout = agentErr.reason {
                        failureCategory = .timeout
                    } else {
                        failureCategory = .executionThrew
                    }
                    let durationMs = Int(Date().timeIntervalSince(toolStart) * 1000)
                    await TraceRecorder.shared.emitToolResult(span: structSpan, name: toolRef.name, success: false, output: error.localizedDescription, durationMs: durationMs)
                    continuation.yield(.toolFailed(
                        ToolOutput(toolName: toolRef.name, params: toolParams, output: output, isSuccess: false),
                        category: failureCategory, sourceNodeID: nodeID
                    ))
                    logger.error("Action node '\(displayName)': tool '\(toolRef.name)' failed after \(attempt + 1) attempt(s): \(error.localizedDescription)")
                    break
                }
            }
        }

        let endTime = Date()

        // Emit completion/failure
        switch status {
        case .completed:
            // Full output (see executeNode) — the display renders & persists it in
            // full; previews clip downstream.
            var summary = output
            // Enrich summary for loop nodes with iteration count
            if case .loop = node.kind,
               let counterStr = variableUpdates["__loop_\(nodeID.uuidString)_counter"] {
                let earlyExit = variableUpdates["__loop_\(nodeID.uuidString)_exited_early"] == "true" ? " (early exit)" : ""
                summary = "[\(counterStr) iter\(earlyExit)] " + summary
            }
            continuation.yield(.workflowNodeCompleted(nodeID: nodeID, profileName: displayName, summary: summary))
        case .failed(let reason):
            continuation.yield(.workflowNodeFailed(nodeID: nodeID, profileName: displayName, error: reason.localizedDescription, suggestion: reason.remediation))
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
            // Structural nodes (Code/Gate/Loop/Condition) are pipeline plumbing —
            // they forward upstream artifacts so media survives the hop (a Gate or
            // Code node between an image producer and a vision consumer no longer
            // drops the image). Action nodes additionally contribute any artifacts
            // their tool produced (`producedArtifacts`); the rest produce none.
            // Uses the same port-active upstream set the node sees text from.
            artifacts: Self.forwardedArtifacts(own: producedArtifacts, upstream: upstreamResults.flatMap(\.artifacts)),
            metadata: NodeExecutionMetadata(
                startTime: startTime,
                endTime: endTime,
                iterationsUsed: 1,
                toolsInvoked: [],
                tokenEstimate: output.count / 4
            ),
            // Auto-detect structured output (mirrors the profile-node path): a Code
            // node emitting JSON, or a Loop/Gate passing JSON through, exposes it as
            // `structuredOutput` for downstream `{{ input.json.path }}` access.
            structuredOutput: JSONValue.parseStructured(output)
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
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation,
        traceContext: TraceContext
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
        // Off-actor scan: wait for it rather than fail the node on an empty list.
        await MLXModelService.shared.ensureLoaded()
        let modelItem: MLXModelItem? = await MainActor.run {
            MLXModelService.shared.installedModel(named: modelName)
        }
        guard let modelItem else {
            throw WorkflowError.nodeExecutionFailed(nodeID: nodeID, profileName: displayName, underlyingError: "MLX model '\(modelName)' not found on this machine.")
        }

        // Load model and get cognitive profile
        try await MLXService.shared.loadModel(from: modelItem.localPath)
        let cogProfile = await MainActor.run { MLXModelService.shared.cachedCognitiveProfile(for: modelItem) }

        let model: any LLMProvider = MLXLLMProvider(
            modelName: modelName,
            // ⚠️ Critical here specifically: workflow nodes run in parallel via
            // `withTaskGroup`, so two branches can hold different MLX models. Without this
            // pin, a branch that paused between iterations resumed on whichever model the
            // other branch had loaded and produced its answer from the wrong one.
            modelDirectory: modelItem.localPath,
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

        // P1-13: instrument the classifier LLM call. The classifier was previously
        // invisible to telemetry — no model, no latency, no token count — despite
        // being a real cost center. Each classifier call now emits a child span
        // so per-classifier-node latency and reliability is queryable.
        let classifierSpan = traceContext.newSpan()
        await TraceRecorder.shared.beginSpan(
            context: classifierSpan,
            name: "classifier:\(displayName)",
            kind: .llmCall
        )
        await TraceRecorder.shared.emitLLMRequest(
            span: classifierSpan,
            model: model.modelName,
            messageCount: messages.count
        )
        let callStart = Date()

        let response: String
        do {
            response = try await model.generate(messages: messages, tools: nil, responseSchema: nil)
        } catch {
            await TraceRecorder.shared.endSpan(spanID: classifierSpan.spanID, status: .error)
            throw error
        }

        let durationMs = Int(Date().timeIntervalSince(callStart) * 1000)
        await TraceRecorder.shared.emitLLMResponse(
            span: classifierSpan,
            durationMs: durationMs,
            preview: response.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        await TraceRecorder.shared.emitMetric(span: classifierSpan, key: "classifier_latency", valueMs: durationMs)
        await TraceRecorder.shared.endSpan(spanID: classifierSpan.spanID, status: .completed)

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
