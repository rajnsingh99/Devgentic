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

    /// How many workflows may be nested inside one another, INCLUDING the outermost.
    ///
    /// ⚠️ The counter is incremented BEFORE its guard, so the outermost workflow is already level 1.
    /// A limit of 3 means this workflow plus two nested levels; the 4th is refused.
    ///
    /// ⚠️ Lowered 5 → 3 on 2026-08-13 (user decision). Each level multiplies cost and latency — five
    /// nodes per workflow at five levels is ~3,000 node executions from one click — and nesting that
    /// deep is nearly always a mistake rather than a design.
    ///
    /// ⚠️ This is now a BACKSTOP, not the primary guard. `WorkflowValidator` reports cycles and
    /// over-deep chains at design time and again at pre-flight, so a user should never reach this.
    /// It is kept because validating A can be invalidated by editing B while A's canvas is closed,
    /// and it costs one integer.
    static let maxDepth: Int = 3
}

/// TaskLocal marking whether a HUMAN is watching this run.
///
/// `true` (the default) for chat/QuickAccess/Jarvis/regenerate sends; bound `false` by the
/// SCHEDULER and the CHATOPS bridges around `startMessageStream`, and inherited by every child
/// task from there — through BOS, AgentConnect, the executor's stream task, and into nested
/// sub-workflow executors — exactly like `WorkflowDepth`.
///
/// ⚠️ Why it exists (2026-08-16, user decision): Router ambiguity arbitration parks INDEFINITELY,
/// and an unattended run renders no banner — a scheduled run parked until the scheduler's run
/// deadline cancelled the WHOLE run, and a ChatOps run (which has no deadline at all) parked
/// forever. An unattended run now never arbitrates: it takes the FIRST MATCH immediately, which is
/// byte-identical to what an unanswered arbitration resolves to anyway.
enum WorkflowRunAttendance {
    @TaskLocal static var isAttended: Bool = true
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
        case .validationFailed:         return .wfValidationFailed
        case .layoutUnreadable:         return .wfValidationFailed
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
        attachmentContext: String? = nil,
        traceContext: TraceContext,
        onTraceUpdate: @escaping @Sendable (AgentTraceLog) -> Void
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        executeWorkflow(
            userInput: userInput, chatHistory: chatHistory,
            conversationID: conversationID, ragContext: ragContext,
            attachmentContext: attachmentContext,
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
        attachmentContext: String? = nil,
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
                        //
                        // ⚠️ Unreadability is asked BEFORE the load, same as the canvas does
                        // (WF-OB4). `load(for:)` deliberately returns `.empty` for a missing row
                        // AND an undecodable blob — by the time we hold the layout the two are
                        // indistinguishable, and the `.empty` guard below would tell the user
                        // "The workflow has no nodes. Add profiles…" about a canvas that HAS
                        // nodes and refuses every save. The denormalized counts live outside the
                        // blob, so they are trustworthy evidence even when the blob is not.
                        let (unreadable, counts) = await MainActor.run {
                            (WorkflowLayoutStore.shared.isLayoutUnreadable(for: profileID),
                             WorkflowLayoutStore.shared.storedCounts(for: profileID))
                        }
                        if unreadable {
                            logger.error("[PERSISTENCE] Run REFUSED for profile \(profileID) conv \(conversationID): the stored canvas blob could not be decoded (last successful save held \(counts.nodes) node(s), \(counts.edges) edge(s)). CONSEQUENCE: the run is blocked BEFORE dispatch with an honest error naming the counts, instead of 'The workflow has no nodes' — the blob is left byte-intact and the canvas overlay owns the repair path.")
                            throw WorkflowError.layoutUnreadable(nodeCount: counts.nodes, edgeCount: counts.edges)
                        }
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

                    // The map is what pre-flight validation and dispatch both resolve profile
                    // nodes against, so a shortfall here presents to the user as "Profile not
                    // found — it may have been deleted" on a profile that exists. Name the
                    // source and the shortfall explicitly: without this, a body executor handed
                    // the wrong map was indistinguishable in the log from genuinely deleted
                    // profiles, and the suggested remediation (recreate the profile) is
                    // destructive.
                    let requiredProfileIDs = Set(layout.nodes.compactMap(\.profileID))
                    let missingProfileIDs = requiredProfileIDs.subtracting(profileMap.keys)
                    if missingProfileIDs.isEmpty {
                        logger.info("[WF_PROFILES] profile \(profileID) conv \(conversationID): profile map \(injectedProfileMap == nil ? "resolved from store" : "INJECTED by caller") — \(profileMap.count) entr(ies), all \(requiredProfileIDs.count) referenced profile(s) present.")
                    } else {
                        logger.error("[WF_PROFILES] profile \(profileID) conv \(conversationID): profile map \(injectedProfileMap == nil ? "resolved from store" : "INJECTED by caller") is MISSING \(missingProfileIDs.count) of \(requiredProfileIDs.count) referenced profile(s): \(missingProfileIDs.map(\.uuidString).sorted().joined(separator: ", ")). CONSEQUENCE: pre-flight validation will report each of those nodes as 'Profile not found — it may have been deleted' and the whole run is blocked before any node executes.")
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
                        // Fetch workflow's own profile (it's not in the node profile map).
                        //
                        // ⚠️ The fallback below is SILENT no more. This was `try?` into
                        // `WorkflowConfig(agentProfileIDs: [])`, so a failed fetch — an unreadable
                        // profile blob, or a container not yet configured — produced a run that
                        // looked completely normal (the layout still loads from its own store) but
                        // executed against hard-coded defaults: a 120 s node timeout although the
                        // user turned timeouts OFF, a different context budget, a different failure
                        // policy and retry count. The only trace was "Node X exceeded the 120s
                        // timeout", which names a symptom that the user's own settings say cannot
                        // happen — an unfalsifiable field report.
                        //
                        // Reachable for any sub-workflow child, which builds
                        // its own executor for a profile it must fetch itself.
                        let fetched: BackendProfileModel?
                        do {
                            fetched = try await MainActor.run { try BackendProfileStore.shared.fetchProfile(byId: profileID) }
                        } catch {
                            fetched = nil
                            logger.error("[WF_CONFIG] profile \(profileID) conv \(conversationID): fetching the workflow's own profile FAILED (\(error.localizedDescription)). CONSEQUENCE: the run continues on hard-coded defaults — node timeout \(WorkflowConfig(agentProfileIDs: []).effectiveNodeTimeout.map { "\(Int($0))s" } ?? "off"), max nesting \(WorkflowDepth.maxDepth), retries \(WorkflowConfig(agentProfileIDs: []).resolvedMaxRetries) — and the user's saved execution settings are NOT in effect for this run.")
                        }

                        if case .workflow(let config) = fetched?.details {
                            workflowConfig = config
                        } else {
                            let defaults = WorkflowConfig(agentProfileIDs: [])
                            if fetched != nil {
                                // Found, but it is not a workflow profile — a different failure
                                // from "could not read it", and worth separating.
                                logger.error("[WF_CONFIG] profile \(profileID) conv \(conversationID): resolved profile is '\(fetched?.profileType.rawValue ?? "unknown")', not a workflow, so it carries no workflow config. CONSEQUENCE: the run uses hard-coded defaults; the user's saved execution settings are NOT in effect.")
                            } else {
                                logger.error("[WF_CONFIG] profile \(profileID) conv \(conversationID): no workflow profile resolved. CONSEQUENCE: the run uses hard-coded defaults — node timeout \(defaults.effectiveNodeTimeout.map { "\(Int($0))s" } ?? "off"), max nesting \(WorkflowDepth.maxDepth), retries \(defaults.resolvedMaxRetries).")
                            }
                            workflowConfig = defaults
                        }
                    }

                    logger.info("[WF_CONFIG] profile \(profileID) conv \(conversationID): node timeout \(workflowConfig.effectiveNodeTimeout.map { "\(Int($0))s" } ?? "OFF"), max nesting \(WorkflowDepth.maxDepth), max retries \(workflowConfig.resolvedMaxRetries).")

                    // =============================================================
                    // 2c. PRE-FLIGHT CONFIGURATION VALIDATION
                    // =============================================================

                    // Retired per-node failure policies, reported once per run.
                    //
                    // The stored value is decoded (it must be — an unknown rawValue would take the
                    // whole layout unreadable, WF24) and then IGNORED. A user who set "Stop
                    // Workflow" is getting materially different behaviour now, so say so rather
                    // than change it silently.
                    let nodesWithRetiredPolicy = layout.nodes.compactMap { node -> (String, NodeFailurePolicy)? in
                        guard let policy = node.nodeConfig?.onFailure, policy != .skipDependents else { return nil }
                        return (node.displayName, policy)
                    }
                    if !nodesWithRetiredPolicy.isEmpty {
                        let described = nodesWithRetiredPolicy.map { "\($0.0) → \($0.1.rawValue)" }.joined(separator: ", ")
                        logger.notice("[WF_ROUTE] \(nodesWithRetiredPolicy.count) node(s) carry a RETIRED per-node failure policy, which is ignored: \(described). CONSEQUENCE: failure routing now comes from the canvas — an unwired `error` port stops that branch, a wired one runs the handler. `stopWorkflow` in particular no longer cancels parallel branches; they run to completion and their results still reach the final answer.")
                    }

                    // Same shape as the failure-policy line above: a stored `joinMode` from a
                    // pre-2026-08-13 layout is honoured by neither branch of the derived join, and
                    // a value silently ignored is exactly the kind of thing a field report blames.
                    // ⚠️ `.all` is NOT reported — it was the default, so its presence says nothing
                    // about intent, and logging every node on every run would bury the real signal.
                    let nodesWithStoredJoinMode = layout.nodes.filter { $0.nodeConfig?.joinMode == .any }
                    if !nodesWithStoredJoinMode.isEmpty {
                        let named = nodesWithStoredJoinMode.map(\.displayName).joined(separator: ", ")
                        logger.notice("[WF_ROUTE] \(nodesWithStoredJoinMode.count) node(s) carry a RETIRED 'Any one' fan-in setting, which is ignored: \(named). CONSEQUENCE: the join is now DERIVED from the graph — every incoming branch is required except a dead one whose live sibling is a mutually-exclusive alternative (different ports of a common Condition/Gate). For a merge under a Condition the behaviour is unchanged; for genuinely independent branches the node now SKIPS on a dead branch instead of running on partial input.")
                    }

                    // The node-timeout settings were retired with the whole Workflow Settings sheet
                    // (2026-08-13). Stored values are still honoured so existing workflows keep
                    // behaving identically — say so, since there is no longer any UI that reveals it.
                    if workflowConfig.nodeTimeoutEnabled == false {
                        logger.notice("[WF_CONFIG] This workflow carries a RETIRED 'node timeout OFF' setting, still honoured: its nodes run UNBOUNDED. CONSEQUENCE: a hung node is never stopped automatically. The Workflow Settings sheet was removed 2026-08-13 and there is no UI to change this — set a per-node hard timeout, or an `executionTimeout` on the bound profile, to bound the nodes that matter.")
                    } else if let stored = workflowConfig.defaultNodeTimeout {
                        logger.notice("[WF_CONFIG] This workflow carries a RETIRED workflow-level node timeout of \(Int(stored))s, still honoured. CONSEQUENCE: none — behaviour is unchanged. The control was removed 2026-08-13; per-node `hardTimeout` and the bound profile's `executionTimeout` both override it.")
                    }

                    // Same shape as the retired-policy lines above. A workflow-level retry default
                    // is still honoured so an existing workflow keeps its resilience, but the
                    // control is gone and the node-level equivalent is named here.
                    if workflowConfig.resolvedMaxRetries > 0 {
                        let affected = layout.nodes.filter { $0.nodeConfig?.maxNodeRetries == nil }
                            .filter { node in
                                if case .profile = node.kind { return true }
                                if case .action = node.kind { return true }
                                return false
                            }
                        logger.notice("[WF_CONFIG] This workflow carries a RETIRED workflow-level 'Default Max Retries' of \(workflowConfig.resolvedMaxRetries), still honoured by \(affected.count) node(s) that set no retry count of their own: \(affected.map(\.displayName).joined(separator: ", ")). CONSEQUENCE: none today — behaviour is unchanged. The control was removed 2026-08-13 because retry SAFETY differs by node kind; set Retries on those individual nodes to express it on the canvas. ⚠️ Only Profile and Action nodes retry at all — a Code, Router or Gate node never did.")
                    }

                    // ⚠️ Resolved on the MainActor because `WorkflowLayoutStore` is isolated there
                    // — the same hop the layout load above already makes. The validator stays pure.
                    let nestedLayouts = await MainActor.run {
                        WorkflowLayoutStore.shared.resolveNestedLayouts(from: layout)
                    }
                    let validationIssues = WorkflowValidator.validate(
                        layout: layout,
                        profileMap: profileMap,
                        subWorkflowLayouts: nestedLayouts,
                        rootProfileID: profileID
                    )
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

                    continuation.yield(.thought("Starting workflow with \(totalNodes) node(s) across \(levels.count) level(s)..."))

                    // Phase A per-node SKIP (D2.1): start-of-run clear, ROOT runs only. A request left
                    // over from a previous run must never skip a node in this one. Nested sub-workflow
                    // runs share the conversationID, so clearing there would wipe the OUTER run's pending
                    // requests — the depth guard is load-bearing, not defensive.
                    if WorkflowDepth.current == 1 {
                        await MainActor.run { WorkflowNodeSkipStore.shared.clear(conversationID: conversationID, reason: "run start") }
                    }
                    for (levelIndex, level) in levels.enumerated() {
                        try Task.checkCancellation()

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
                            if case .skip(let skipCause) = state.runDecision(for: nodeID, edges: layout.edges, nodes: layout.nodes) {
                                let skipReason = skipCause.displayText
                                // Name the upstream(s) that caused it and what is now unreachable.
                                // Nothing is cancelled when a branch dies (parallel branches are
                                // independent by construction and keep their results), so a run
                                // CAN spend tokens on work that a dead join will discard — this
                                // line is what makes that visible in the log rather than silent.
                                let deadUpstreams = layout.edges
                                    .filter { $0.targetNodeID == nodeID }
                                    .compactMap { edge in layout.nodes.first(where: { $0.id == edge.sourceNodeID })?.displayName }
                                    .joined(separator: ", ")
                                // Decided BEFORE the result is recorded — `recordResult` does not touch
                                // `activeOutputPorts`, but reading the upstreams first keeps this
                                // independent of that and of this node's own (about to be written) entry.
                                let propagatesError = state.upstreamSignalledError(for: nodeID, edges: layout.edges)
                                logger.notice("[WF_ROUTE] Skipping '\(node.displayName)': \(skipReason) (upstream: \(deadUpstreams)). \(propagatesError ? "An upstream FAILED, so this node activates its `error` port and a branch wired there still runs." : "Nothing upstream failed, so NO port is activated and the whole subtree below this node stays dead.") CONSEQUENCE: this branch stops here — wire the failing node's `error` port if it should be handled instead. Parallel branches are unaffected and keep running.")
                                let skipResult = NodeResultEnvelope(
                                    taskID: UUID(), nodeID: nodeID,
                                    sourceProfileID: node.profileID ?? UUID(), profileName: node.displayName,
                                    profileType: node.profileType ?? .bot,
                                    status: .skipped(reason: skipCause),
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
                                    // The Run Report reads these to say WHICH kind of skip this was
                                    // instead of hedging "by you, or by routing" at every skip.
                                    context: ["node_name": node.displayName, "node_id": nodeID.uuidString,
                                              "skip_reason": skipCause.rawValue, "ran_before_skip": "false"]
                                )
                                // Phase 5: a pre-dispatch skip gets a REAL span (begun and
                                // immediately closed `.skipped`) instead of vanishing — the node
                                // used to have no row at all, so the report's tree showed a
                                // 5-node run with 3 nodes and no explanation. The skip event
                                // attaches to THAT span rather than floating at the root.
                                let skipInstant = Date()
                                let skipSpan = traceContext.newSpan()
                                await TraceRecorder.shared.beginSpan(context: skipSpan, name: "node:\(node.displayName)", kind: .workflowNode, at: skipInstant)
                                await TraceRecorder.shared.emitAgentError(span: skipSpan, error: classified, iteration: nil, at: skipInstant)
                                await TraceRecorder.shared.endSpan(spanID: skipSpan.spanID, status: .skipped, at: skipInstant)
                                // P0-6: a skipped node activates the `"error"` port so a recovery
                                // chain does not dead-end — branches wired exclusively to `error`
                                // would otherwise hang waiting for an activation that never comes.
                                //
                                // ⚠️ CONDITIONAL since WF-EX2, and the condition is the whole point.
                                // This used to fire on EVERY skip, including the two causes where
                                // nothing went wrong (`.notChosen`, `.errorPortNotTaken`), so an
                                // error handler hanging off a merely-routed-past node RAN on a
                                // perfectly healthy run — and the run still reported success. If that
                                // handler posts a webhook or sends a message, the workflow reported a
                                // failure that never happened.
                                //
                                // `upstreamSignalledError` keys off the upstreams' active ports, NOT
                                // this node's skip reason: `error` only ever gets there from a node
                                // that actually failed, or from a skip that inherited it here, so the
                                // signal carries its own provenance and stays correct however many
                                // hops the dead branch runs. See that method for why the skip reason
                                // is the wrong test.
                                if propagatesError {
                                    state.setActiveOutputPorts([WorkflowEdge.errorPortLabel], for: nodeID)
                                }
                                // ⚠️ `workflowNodeSkipped`, NOT `workflowNodeFailed`. This node did
                                // not fail — in the `.notChosen` and `.errorPortNotTaken` cases
                                // nothing in the run failed at all. Reporting it as a failure was
                                // what forced every consumer to string-match its way back to the
                                // truth, and what made `.skipped` unreachable in both the live and
                                // the persisted status enums.
                                continuation.yield(.workflowNodeSkipped(nodeID: nodeID, profileName: node.displayName, reason: skipCause, ranBeforeSkip: false))
                                completedCount += 1
                                continuation.yield(.workflowProgress(completed: completedCount, total: totalNodes))
                                continue
                            }

                            // --- Phase A per-node SKIP (owner design §0.6 D2.1, ratified 2026-08-21) ---
                            //
                            // Consulted AFTER the cascade decision on purpose: a dead branch has no
                            // input to pass through, so the cascade wins and the user's request is
                            // left unconsumed (harmless — cleared at run end).
                            //
                            // PROFILE NODES ONLY — bot, agent, sub-workflow. Condition/Router bypass
                            // is ill-defined (which port fires?), a Gate's skip IS a decision, and a
                            // Trigger's skip makes the run meaningless. The UI never renders the
                            // button on those kinds; this guard is the engine-side twin so a stray
                            // store entry cannot skip them either.
                            if case .profile = node.kind {
                                let userSkipRequested = await MainActor.run {
                                    WorkflowNodeSkipStore.shared.consume(nodeID: nodeID, conversationID: conversationID)
                                }
                                if userSkipRequested {
                                    // Pass-through: the SAME aggregated input this node would have
                                    // received. An entry node's input is the user's query itself —
                                    // forwarding "" there would hand downstream a blank task.
                                    //
                                    // ⚠️ `includeFailures: true` — MIRRORS THE DISPATCH PATH (`executeNode`
                                    // compiles with it unconditionally). This shipped as the default `false`,
                                    // which quietly broke one shape: skipping an ERROR-HANDLER node (its only
                                    // upstream is a `.failed` envelope on a live error edge) filtered that
                                    // envelope out and forwarded "" — downstream recovery got a blank instead
                                    // of the annotated failure the handler itself would have received.
                                    let upstream = state.upstreamResultEnvelopes(for: nodeID, edges: layout.edges)
                                    let passThrough = upstream.isEmpty
                                        ? userInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                        : WorkflowInputAssembler.compileForWorkflow(results: upstream, includeFailures: true)
                                    let passedArtifacts = upstream.flatMap(\.artifacts)
                                    // Forward structured JSON by the SAME rule every consumer reads it with
                                    // (`upstreamResults.compactMap(\.structuredOutput).first` — Code/Action
                                    // nodes' `{{ input.json.path }}`). Omitting it silently defaulted the
                                    // field to nil, so a skip between a JSON producer and a Code node broke
                                    // the template's json access with no error anywhere.
                                    let passedStructured = upstream.compactMap(\.structuredOutput).first
                                    // ⚠️ The transformer caveat, SURFACED (never gated): if this
                                    // node's task transforms data, downstream now operates on the
                                    // untransformed input. That is the user's call to make — this
                                    // line is what makes the consequence visible in the log.
                                    logger.notice("[WF_ROUTE] Skipping '\(node.displayName)' BY USER REQUEST — its input (\(passThrough.count) chars, \(passedArtifacts.count) artifact(s)) is forwarded downstream unchanged and NO port is activated: default edges below it stay LIVE, error branches do not fire (a user skip is an instruction, not a failure). CONSEQUENCE: downstream receives this node's INPUT, not its output.")
                                    let skipResult = NodeResultEnvelope(
                                        taskID: UUID(), nodeID: nodeID,
                                        sourceProfileID: node.profileID ?? UUID(), profileName: node.displayName,
                                        profileType: node.profileType ?? .bot,
                                        status: .skipped(reason: .byUser),
                                        output: passThrough, artifacts: passedArtifacts,
                                        metadata: .simple(start: Date(), end: Date(), output: passThrough),
                                        structuredOutput: passedStructured
                                    )
                                    state.recordResult(from: skipResult)
                                    let classified = ClassifiedAgentError.synthetic(
                                        category: .wfNodeSkipped,
                                        origin: "WorkflowExecutor.dispatch.userSkip",
                                        message: NodeSkipReason.byUser.displayText,
                                        context: ["node_name": node.displayName, "node_id": nodeID.uuidString,
                                                  "skip_reason": NodeSkipReason.byUser.rawValue, "ran_before_skip": "false"]
                                    )
                                    // Phase 5: same real-span treatment as the upstream-skip arm
                                    // above — a user-skipped node appears in the tree as
                                    // `.skipped`, and its event attaches to it, not the root.
                                    let skipInstant = Date()
                                    let skipSpan = traceContext.newSpan()
                                    await TraceRecorder.shared.beginSpan(context: skipSpan, name: "node:\(node.displayName)", kind: .workflowNode, at: skipInstant)
                                    await TraceRecorder.shared.emitAgentError(span: skipSpan, error: classified, iteration: nil, at: skipInstant)
                                    await TraceRecorder.shared.endSpan(spanID: skipSpan.spanID, status: .skipped, at: skipInstant)
                                    continuation.yield(.workflowNodeSkipped(nodeID: nodeID, profileName: node.displayName, reason: .byUser, ranBeforeSkip: false))
                                    completedCount += 1
                                    continuation.yield(.workflowProgress(completed: completedCount, total: totalNodes))
                                    continue
                                }
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
                                // A workflow-backed profile node is a NESTED SUB-WORKFLOW, not an
                                // agent turn. It cannot go down the profile path: that path ends at
                                // `streamWorkflowNodeResponse`, whose `case .workflow, .imageGen`
                                // arm yields an error and finishes — and because the executor's
                                // `.error` arm never sets `nodeStatus`, and no `.executionFinished`
                                // arrives, the default `.completed` used to stick. The node went
                                // GREEN with empty output, downstream consumed nothing, joins were
                                // satisfied, the error port never fired and the run reported
                                // success. It is dispatched structurally instead, where a child
                                // executor runs its canvas (see `executeStructuralNode`).
                                if profileType == .workflow {
                                    logger.info("[WF_EXEC] node '\(node.displayName)' [node \(nodeID.uuidString.prefix(8))] is a nested sub-workflow (profile \(profileID)) — dispatching to the child executor, not the agent stream path.")
                                    structuralNodes.append(node)
                                } else {
                                    profileNodes.append((node, nodeProfile))
                                }

                            case .condition, .code, .gate, .trigger, .action:
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
                            let structResult = await Self.executeStructuralNodeBounded(
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
                                injectedProfileMap: injectedProfileMap,
                                workflowConfig: workflowConfig
                            )
                            state.recordResult(from: structResult.envelope)
                            if let ports = structResult.activePorts {
                                state.setActiveOutputPorts(ports, for: node.id)
                            }
                            if case .failed = structResult.envelope.status, structResult.activePorts == nil {
                                state.setActiveOutputPorts([WorkflowEdge.errorPortLabel], for: node.id)
                            }
                            for (key, value) in structResult.variableUpdates {
                                state.setVariable(key, value: value)
                            }
                            completedCount += 1
                            continuation.yield(.workflowProgress(completed: completedCount, total: totalNodes))
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
                                        await Self.executeStructuralNodeBounded(
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
                                            injectedProfileMap: injectedProfileMap,
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
                                        state.setActiveOutputPorts([WorkflowEdge.errorPortLabel], for: sid)
                                    }
                                    for (key, value) in structResult.variableUpdates {
                                        state.setVariable(key, value: value)
                                    }
                                    completedCount += 1
                                    continuation.yield(.workflowProgress(completed: completedCount, total: totalNodes))

                                }
                            }
                        }

                        guard !profileNodes.isEmpty else { continue }

                        // --- Execute profile nodes (with optional retry) ---
                        if profileNodes.count == 1 {
                            let (node, profile) = profileNodes[0]
                            let result = await Self.executeProfileNodeWithRetry(
                                node: node, profile: profile,
                                userInput: userInput, attachmentContext: attachmentContext,
                                state: state, edges: layout.edges, nodes: layout.nodes,
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
                                state.setActiveOutputPorts([WorkflowEdge.errorPortLabel], for: node.id)
                            }
                            completedCount += 1
                            continuation.yield(.workflowProgress(completed: completedCount, total: totalNodes))
                        } else {
                            // --- WF-CC2: MLX-aware dispatch ---
                            // Same-level profile nodes are split into lanes that run one after
                            // another; every lane is still fully parallel inside itself. Nodes are
                            // separated ONLY when this level demands two or more DIFFERENT MLX
                            // models: `MLXService` keeps exactly ONE model container resident, and
                            // `loadModel` calls `performUnload()` (MLXService.swift:246) before
                            // loading a different directory while EARLY-RETURNING for the one
                            // already resident (:215-219). Two siblings on different models
                            // therefore evict each other on every generation call — i.e. every
                            // ReAct iteration — and `container(expecting:)` gives up after two
                            // attempts and throws `modelIdentityMismatch`. Two siblings on the
                            // SAME model share one container and cost nothing, so they are
                            // deliberately left parallel. See `profileDispatchLanes`.
                            let lanes = Self.profileDispatchLanes(profileNodes)

                            if lanes.count > 1 {
                                let shape = lanes
                                    .map { "\($0.slot ?? "unconstrained") ← [\($0.members.map(\.node.displayName).joined(separator: ", "))]" }
                                    .joined(separator: " THEN ")
                                logger.notice("[WF_EXEC] profile \(profileID) conv \(conversationID) level \(levelIndex + 1)/\(levels.count): \(profileNodes.count) profile node(s) demand \(lanes.count) DIFFERENT local MLX models, so they are dispatched in \(lanes.count) sequential lane(s) — \(shape). CONSEQUENCE: this level's wall clock is now the SUM of the lanes instead of the slowest node. Only ONE MLX model container is resident at a time, so running them together would unload and re-read multi-GB weights on every generation call and can fail a node outright with a model-identity mismatch.")
                            }

                            for (laneIndex, lane) in lanes.enumerated() {
                                // ⚠️ NO `try Task.checkCancellation()` between lanes, deliberately.
                                // Skipping a later lane on cancel would leave its nodes with NO
                                // `workflowNodeStarted` and no envelope at all, and
                                // `WorkflowExecutionState.settleInFlightWork` can only repair rows
                                // that are already `.running` — those nodes would vanish from the
                                // run instead of being reported cancelled. Letting the lane be
                                // created inside an already-cancelled parent reproduces today's
                                // behaviour exactly: each child starts cancelled and emits
                                // `workflowNodeStarted` then `workflowNodeCancelled`.

                                // ⚠️ Re-snapshotted PER LANE, and provably equivalent to one
                                // level-wide snapshot: `executeProfileNodeWithRetry` reads `state`
                                // ONLY via `upstreamResultEnvelopes(for:edges:)`, which filters on
                                // INCOMING edges, and `computeExecutionLevels` peels only in-degree
                                // zero nodes, so no same-level edge can exist. Re-snapshotting
                                // keeps that argument local instead of resting on an invariant
                                // enforced in another file.
                                let snapshotState = state
                                // ⚠️ Captured BEFORE the drain loop below mutates `completedCount`,
                                // so lane 2's display indices continue lane 1's instead of
                                // restarting or colliding. Indices stay contiguous 1…N.
                                let indexBase = completedCount

                                if lanes.count > 1 {
                                    logger.info("[WF_EXEC] profile \(profileID) conv \(conversationID) level \(levelIndex + 1) lane \(laneIndex + 1)/\(lanes.count) [\(lane.slot ?? "unconstrained")]: starting \(lane.members.count) node(s) — [\(lane.members.map(\.node.displayName).joined(separator: ", "))]. CONSEQUENCE: nodes in later lanes have NOT started and emit no workflowNodeStarted until this lane drains — their cards stay 'Waiting' and progress holds at \(completedCount)/\(totalNodes). This is a queue, not a hang.")
                                }

                                await withTaskGroup(of: NodeResultEnvelope.self) { group in
                                    for (nodeOffset, (node, profile)) in lane.members.enumerated() {
                                        let displayIndex = indexBase + nodeOffset + 1
                                        group.addTask {
                                            await Self.executeProfileNodeWithRetry(
                                                node: node, profile: profile,
                                                userInput: userInput, attachmentContext: attachmentContext,
                                                state: snapshotState, edges: layout.edges, nodes: layout.nodes,
                                                nodeIndex: displayIndex, totalNodes: totalNodes,
                                                conversationID: conversationID,
                                                agentConnect: agentConnect,
                                                traceContext: traceContext, onTraceUpdate: onTraceUpdate,
                                                continuation: continuation,
                                                workflowConfig: workflowConfig
                                            )
                                        }
                                    }
                                    // ⚠️ BYTE-IDENTICAL to the pre-WF-CC2 drain body: the
                                    // 2026-08-12 sibling-not-cancelled decision lives here and the
                                    // lane split does not touch it.
                                    for await result in group {
                                        state.recordResult(from: result)
                                        if case .failed = result.status {
                                            // ⚠️ Siblings are NOT cancelled. A parallel branch is
                                            // independent by construction — nothing connects it to
                                            // this one — so its work stays valid and its output still
                                            // reaches the final answer. Aborting them destroyed usable
                                            // results to save tokens (design decision 2026-08-12); a
                                            // doomed branch is reported by the unreachable-branch log
                                            // instead.
                                            state.setActiveOutputPorts([WorkflowEdge.errorPortLabel], for: result.nodeID)
                                        }
                                        completedCount += 1
                                        continuation.yield(.workflowProgress(completed: completedCount, total: totalNodes))
                                    }
                                }
                            }
                        }
                    }

                    // ⚠️ Cancellation is checked at the TOP of each level, so a run stopped during
                    // its FINAL level had no later checkpoint: the loop ended normally and the
                    // synthesis below ran as though the run had finished (WF-EX3). Nothing reached
                    // the user — the consumer is already torn down and `ActiveStreamManager` stamps
                    // `cancelled` itself — but the TELEMETRY lied: the root span closed `.completed`
                    // and no `.userCancelled` was recorded, so Stop was under-counted in Trends at
                    // the single most common moment people press it. This lands in the
                    // `catch is CancellationError` arm below, which already drains suspensions,
                    // classifies the error, closes the span `.error` and emits `.cancelled`.
                    try Task.checkCancellation()

                    // =============================================================
                    // 4. SYNTHESIZE FINAL OUTPUT (Terminal Nodes)
                    // =============================================================

                    let allNodeIDs = flatOrder
                    let terminalOutputs = state.terminalOutputs(edges: layout.edges, allNodeIDs: allNodeIDs)

                    let successfulTerminals = terminalOutputs.filter {
                        if case .completed = $0.status { return true }
                        return false
                    }

                    // Terminals the user SKIPPED. Their `output` is the aggregated upstream input,
                    // forwarded by the D2.1 pass-through contract — real content, produced by the
                    // run, that simply did not come from this node's own execution.
                    let passThroughTerminals = terminalOutputs.filter {
                        if case .skipped(reason: .byUser) = $0.status { return true }
                        return false
                    }

                    /// Terminals that have an answer to show — completed, or user-skipped.
                    ///
                    /// ⚠️ SEPARATE FROM `successfulTerminals`, which keeps meaning `.completed` so
                    /// the log line "N terminal node(s) succeeded" stays true. A skipped node did
                    /// NOT succeed; it also did not fail, and it is holding content. Before this,
                    /// skipping the only terminal of a linear workflow dropped BOTH: zero successes
                    /// and zero failures fell through to branch 3 and answered "The workflow
                    /// finished without producing an answer" while the pass-through sat unused in
                    /// the envelope. The composer Skip button (Phase B) makes that the easiest thing
                    /// in the feature to hit, because a linear run's running node usually IS the
                    /// terminal.
                    let answeringTerminals = successfulTerminals + passThroughTerminals

                    // ⚠️ The run verdict is decided by whether anything FAILED, not by whether a
                    // terminal succeeded. Those are different questions, and conflating them is what
                    // reported a healthy branching run as a total failure.
                    let failedNodes = state.failedNodeSummaries()

                    // Terminals that CONTRIBUTE to the answer. A cascade `.skipped` terminal is an
                    // untaken branch — normal condition/gate routing, not a result — so it is
                    // excluded entirely; listing it would put "## Fallback Handler — not run" in the
                    // answer of every branching workflow, which is noise, not information.
                    //
                    // ⚠️ `.byUser` IS INCLUDED, and it is the only skip that is. It carries the
                    // forwarded upstream input as its output, so excluding it ends the pass-through
                    // contract one node short of the answer.
                    let ranTerminals = terminalOutputs.filter {
                        switch $0.status {
                        case .completed, .failed: return true
                        case .skipped(reason: .byUser): return true
                        case .canceled, .skipped: return false
                        }
                    }

                    if !answeringTerminals.isEmpty {
                        // Labeled, per-terminal output — successes AND failures together, so a
                        // partially-successful run shows what worked next to what didn't, each
                        // attributed to its node. Previously only successful terminals were joined
                        // with "\n\n", so with several terminals you could not tell which node
                        // produced which half, and a failed one contributed nothing at all.
                        //
                        // Markdown headings rather than a structured payload: the Final Outcome
                        // card already renders `finalOutput` as markdown, so attribution costs no
                        // schema change and no view work. A structured `[TerminalOutput]` is the
                        // eventual shape and is filed separately.
                        //
                        // ONE terminal stays bare — the common single-answer case must not grow a
                        // heading it never had.
                        let finalOutput: String
                        if ranTerminals.count <= 1 {
                            finalOutput = ranTerminals.first?.text ?? ""
                        } else {
                            finalOutput = ranTerminals.map { terminal -> String in
                                let body: String
                                if case .failed(let reason) = terminal.status {
                                    body = "**Failed:** \(reason.localizedDescription)"
                                } else if case .skipped(reason: .byUser) = terminal.status {
                                    // ⚠️ MARKED, because the heading names a node that never ran.
                                    // This terminal's text is its INPUT, forwarded by the skip
                                    // contract — printing it bare under "## Research Agent" would
                                    // attribute an upstream node's words to one the user skipped,
                                    // which is the "never fabricate" rule broken by omission.
                                    // `NodeSkipReason.byUser.displayText` is deliberately NOT reused
                                    // here: it says "passed downstream unchanged", and a terminal
                                    // has no downstream — the content became the answer instead.
                                    body = terminal.text.isEmpty
                                        ? "_(skipped by you — it had no input to pass on)_"
                                        : "_(skipped by you — this is the input it would have processed)_\n\n" + terminal.text
                                } else {
                                    body = terminal.text.isEmpty ? "_(no output)_" : terminal.text
                                }
                                return "## \(terminal.profileName)\n\n\(body)"
                            }.joined(separator: "\n\n")
                        }

                        if !finalOutput.isEmpty {
                            continuation.yield(.content(finalOutput))
                        } else {
                            // ⚠️ NO `.content` here, deliberately — do not "fix" this into an
                            // explanatory sentence. A terminal can succeed with empty TEXT and still
                            // have done its job: an Action node that wrote a file, or a node whose
                            // result is an artifact rather than prose. Announcing "finished without
                            // producing an answer" would be false for exactly those runs, and
                            // `testTerminalNode_EmptyOutput_NotInFinalContent` pins the silence.
                            // (Branch 3 below is different: there NO terminal succeeded at all.)
                            // Logged so a genuinely blank reply is still diagnosable.
                            logger.notice("[WF_EXEC] Run completed with an EMPTY final answer: \(successfulTerminals.count) successful terminal(s) produced no text. CONSEQUENCE: no `.content` is emitted — correct when the result is an artifact or a side effect, but if the user expected prose, check whether the terminal node's chosen output port is wired.")
                        }
                        let terminalNames = successfulTerminals.map(\.profileName).joined(separator: ", ")
                        let passThroughNote = passThroughTerminals.isEmpty
                            ? ""
                            : " \(passThroughTerminals.count) terminal(s) were SKIPPED BY THE USER and contributed their forwarded INPUT instead of their own output: [\(passThroughTerminals.map(\.profileName).joined(separator: ", "))]. CONSEQUENCE: the answer contains upstream content that this node never processed."
                        logger.info("[WF_EXEC] Workflow completed. \(successfulTerminals.count)/\(terminalOutputs.count) terminal node(s) succeeded: [\(terminalNames)]. Final output \(finalOutput.count) chars\(ranTerminals.count > 1 ? ", labeled per terminal" : "").\(passThroughNote)")
                        logger.debug("Final output preview:\n\(String(finalOutput.prefix(500)))")
                    } else if !failedNodes.isEmpty {
                        // Something genuinely failed. Report the ACTUAL reasons rather than the flat
                        // "all terminal nodes failed", which named neither the node nor the cause —
                        // the run's own error message was the one place the failure wasn't visible.
                        // Still an `.error` event, not `.content`: the event type is what the chat
                        // surfaces as a failure, and changing it would silently alter that contract.
                        //
                        // ⚠️ Reported over FAILED NODES, not terminals. The failing node is usually
                        // mid-graph, so listing terminals described the symptom ("did not run") and
                        // hid the cause. Terminals are appended for context, not used as the reason.
                        let terminalDetail = terminalOutputs.map { terminal -> String in
                            switch terminal.status {
                            case .failed(let reason):     return "\(terminal.profileName): \(reason.localizedDescription)"
                            case .canceled:               return "\(terminal.profileName): cancelled"
                            case .skipped(let cause):     return "\(terminal.profileName): \(cause.displayText)"
                            case .completed:              return "\(terminal.profileName): completed"
                            }
                        }.joined(separator: "\n")
                        let message = "The workflow failed.\n\n\(failedNodes.joined(separator: "\n"))"
                            + (terminalDetail.isEmpty ? "" : "\n\nBranch endings:\n\(terminalDetail)")
                        continuation.yield(.error(StructuredError(message: message)))
                        logger.error("[WF_EXEC] Run FAILED — \(failedNodes.count) node(s) failed: \(failedNodes.joined(separator: " | ")). Terminals: \(terminalDetail.replacingOccurrences(of: "\n", with: " | ")). CONSEQUENCE: the run is reported failed and the answer names the nodes that actually failed rather than the branches that merely did not run.")
                    } else {
                        // ⚠️ DEFENSIVE — believed UNREACHABLE, and deliberately kept.
                        //
                        // Reaching here needs zero successful terminals AND zero failures. Since
                        // WF-EX1 made terminality a function of LIVE edges, a completed node either
                        // feeds a live edge or IS a terminal — so "no successful terminal" implies
                        // "nothing completed at all", which for a graph whose entry nodes always run
                        // means everything was skipped or cancelled. The derived fan-in join then
                        // excuses exactly the dead branches that could otherwise strand a merge, so
                        // no purely-skipped shape I could construct lands here (attempted:
                        // unwired-router-port, two-router cross-skip, and a stranded join — each
                        // leaves a completed terminal or a failure behind). Cancellation used to be
                        // the one live route and now throws to `catch is CancellationError` first
                        // (WF-EX3).
                        //
                        // ⚠️ A mutation check CONFIRMED the gap rather than the coverage: deleting
                        // `&& !failedNodes.isEmpty` from the failure branch above fails NO test,
                        // because no test reaches this branch. Keep it anyway — an unreachable
                        // branch that reports honestly costs nothing, and the alternative (falling
                        // into the failure branch with an empty failure list) is the WF-EX1 defect.
                        //
                        // Nothing succeeded AND nothing failed — every branch that was taken ended in
                        // a node that did not run. That is an odd workflow, but it is NOT a failure,
                        // and calling it one was the second half of the same bug: a run where a Gate
                        // or Router legitimately routed into a dead end was reported red with the
                        // sentence "all terminal nodes failed", asserting failures that never
                        // happened. Reported as a completed run that produced no answer, which is
                        // exactly what it is.
                        let detail = terminalOutputs.map { terminal -> String in
                            if case .skipped(let cause) = terminal.status {
                                return "\(terminal.profileName): \(cause.displayText)"
                            }
                            return "\(terminal.profileName): \(WorkflowState.statusLabel(terminal.status))"
                        }.joined(separator: "\n")
                        continuation.yield(.content(String(
                            localized: "The workflow finished without producing an answer — every branch it took ended in a node that did not run.")))
                        logger.notice("[WF_EXEC] Run produced NO output and NO failures — \(terminalOutputs.count) terminal node(s), none completed: \(detail.replacingOccurrences(of: "\n", with: " | ")). CONSEQUENCE: reported as COMPLETED with an explanatory answer, not as a failure — nothing in this run failed.")
                    }

                    let executionLog = state.executionLog
                    let totalDuration = executionLog.reduce(0.0) { $0 + $1.duration }
                    // Phase A per-node SKIP (D2.1): end-of-run hygiene clear, ROOT runs only (same depth
                    // guard as the start clear). Un-consumed requests must not survive into a later run.
                    if WorkflowDepth.current == 1 {
                        await MainActor.run { WorkflowNodeSkipStore.shared.clear(conversationID: conversationID, reason: "run end") }
                    }
                                        logger.notice("Workflow execution summary: \(executionLog.count) nodes processed in \(String(format: "%.1f", totalDuration))s")

                    // Workflow-level terminal outcome. Per-node terminals emitted by inner
                    // executors are swallowed by the forwarder (they're node-scoped); the
                    // workflow as a whole reports its own outcome here so the bubble's
                    // TerminalOutcomeChip reflects workflow-level success vs partial-failure.
                    if successfulTerminals.isEmpty && !failedNodes.isEmpty {
                        await TraceRecorder.shared.endSpan(spanID: traceContext.spanID, status: .error)
                        continuation.yield(.executionFinished(
                            outcome: .failed,
                            reason: "\(failedNodes.count) node\(failedNodes.count == 1 ? "" : "s") failed"
                        ))
                    } else {
                        await TraceRecorder.shared.endSpan(spanID: traceContext.spanID, status: .completed)
                        continuation.yield(.executionFinished(outcome: .completed, reason: nil))
                    }
                    continuation.finish()

                } catch is CancellationError {
                    logger.notice("Workflow cancelled for conversation: \(conversationID)")
                    // ⚠️ ROOT RUNS ONLY (N3). A nested sub-workflow child is constructed with the
                    // PARENT's conversationID, so this sweep — running in the CHILD on its own
                    // cancellation, e.g. its node timeout — force-denied every park in the OUTER
                    // run as well. At nested depth the child's own parks are structurally inside the
                    // cancelled task tree and each suspend's `onCancel` handler resolves them, so
                    // draining here adds nothing and costs the parent its banners.
                    if WorkflowDepth.current == 1 {
                        await ExecutionSuspensionService.shared.cancel(for: conversationID)
                    } else {
                        logger.info("[WF_HITL] Nested sub-workflow cancelled at depth \(WorkflowDepth.current) — NOT draining conversation \(conversationID.uuidString.prefix(8)). CONSEQUENCE: this child's own parks resolve through their own cancellation handlers; the parent run's parked banners are left alone instead of being force-denied on the user's behalf.")
                    }
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
        attachmentContext: String? = nil,
        upstreamResults: [NodeResultEnvelope],
        isEntryNode: Bool,
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
        let isFirstNode = isEntryNode
        // `includeFailures: true` lets a downstream profile node actually receive a failed
        // upstream's output + failure reason. A failed envelope reaches `upstreamResults` by
        // exactly TWO sanctioned routes, and the annotation is wanted on both:
        //   1. an active `error` port (a dedicated error-handler branch), and
        //   2. a DEFAULT edge from an upstream whose policy is Continue All — n8n-style
        //      continue-on-error, where the failure rides the main output with its data.
        // Normal success routing never surfaces failed upstreams here.
        // ⚠️ No budgets — upstream output passes through in full (user decision 2026-08-13).
        // Fitting it is a function of which model this node runs, which is the author's choice.
        let upstreamInput = WorkflowInputAssembler.compileForWorkflow(
            results: upstreamResults,
            includeFailures: true
        )

        // For first nodes: merge userInput into taskDescription as a single directive.
        // Downstream nodes only use their own taskDescription — userInput is not propagated.
        let effectiveTaskDescription: String
        let trimmedUserInput = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFirstNode && !trimmedUserInput.isEmpty {
            // ⚠️ USER QUERY FIRST, node task second, NO inline label (owner decision 2026-08-20).
            //
            // This was `baseTaskDescription + "\n\n---\nUser Query: " + trimmedUserInput`, and that
            // ordering plus that label is what made a single-node workflow fail where the same
            // profile succeeded in chat. `AgentConnect` prepended the knowledge/attachment payloads
            // onto `userInput` (they had no other route to a node), so `<task>` — the FIRST and most
            // heavily attended section of the system prompt — opened with
            // "User Query: ### MCP server guidance" followed by ~2,000 chars of instructions for
            // tools the node did not have, with the real 61-char question at the very end. A 3B
            // model derailed on it identically five times and the run aborted on consecutive parse
            // failures. Those payloads now travel their own sections (`<attachments>`,
            // `<tool_guidance>`), so this carries only the query and the node's own task.
            effectiveTaskDescription = baseTaskDescription.isEmpty
                ? trimmedUserInput
                : trimmedUserInput + "\n\n" + baseTaskDescription
            logger.info("Node '\(displayName)' first node: task = user query (\(trimmedUserInput.count) chars) + node task (\(baseTaskDescription.count) chars), query first.")
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
            let (extracted, docFailures) = await WorkflowInputAssembler.extractDocumentText(
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

        var workflowContext = WorkflowExecutionContext(
            taskDescription: effectiveTaskDescription,
            upstreamInput: upstreamInput,
            isFirstNode: isFirstNode,
            nodeName: displayName,
            nodeID: nodeID,
            upstreamArtifacts: upstreamArtifacts,
            upstreamArtifactText: upstreamArtifactText
        )
        // ENTRY NODE ONLY — mirrors how `userInput` reaches the graph. Downstream nodes consume
        // their upstream's OUTPUT, not the run's original attachments; forwarding the file text to
        // every node would re-pay its whole token cost per node for data most of them never use.
        if isFirstNode, let attachmentContext, !attachmentContext.isEmpty {
            workflowContext.attachmentContext = attachmentContext
            logger.info("Node '\(displayName)' entry node: \(attachmentContext.count) chars of attachments travel as <attachments>, NOT fused into the task.")
        }

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
            // ⚠️ register B44 — routed through the shared accessor rather than a sixth private
            // `if case .agent`. No behaviour change for anything reachable here (a workflow node
            // binds a STORED profile and `.code` is ephemeral, never persisted), but leaving the
            // pattern in place is how this defect kept reproducing itself across five call sites.
            if let t = profile.details.executionTimeout { return t }
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
                of: (String, [ToolOutput], [MediaArtifact], ExecutionOutcome?, String?, String?).self
            ) { group in
                // Timeout sentinel — only when a timeout is configured. When disabled
                // (`nodeTimeout == nil`) the group runs the stream task alone, unbounded.
                //
                // ⚠️ The clock excludes time parked awaiting a human (2026-08-13). This used to be a
                // raw `Task.sleep(nodeTimeout)`, which meant an agent that asked for a tool
                // confirmation killed its own node at 120s if the user was slow to answer — a live
                // defect, not a hypothetical. `withComputeTimeout` re-checks parked time when it
                // wakes and extends by the shortfall.
                if let nodeTimeout {
                    let convID = conversationID
                    let name = displayName
                    group.addTask {
                        try await Self.computeTimeoutSentinel(nodeTimeout, conversationID: convID, nodeName: name)
                    }
                }

                // Running-skip sentinel — Phase B increment 5 (D2.1). Parks on the skip store and
                // throws the typed `WorkflowNodeSkipRequested` when the user skips this RUNNING
                // node; when the node finishes first the group cancels it and the await resolves
                // as a plain CancellationError, absorbed by group teardown.
                //
                // ⚠️ UNCONDITIONAL, deliberately unlike the timeout sentinel above: copying that
                // `if let` shape would make Skip silently dead on exactly the nodes most worth
                // skipping — the unbounded ones (timeout disabled), which are the ones that can
                // run away. Sub-workflow nodes never reach this group (they dispatch down the
                // structural path), so a running-skip cannot fire for them — increment 8's
                // deferral is enforced by construction, not by a guard.
                do {
                    let convID = conversationID
                    let nid = nodeID
                    group.addTask {
                        try await Self.runningSkipSentinel(nodeID: nid, conversationID: convID)
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
                    /// The last `.error` the inner stream emitted.
                    ///
                    /// Needed because an inner stream may report a fatal error and then simply
                    /// FINISH, never emitting `.executionFinished` — which is exactly what
                    /// `streamWorkflowNodeResponse` does for a profile type it cannot run
                    /// (`case .workflow, .imageGen`). Without this the error was forwarded to the
                    /// timeline for display and then dropped from the OUTCOME decision.
                    var innerErrorMessage: String? = nil

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
                            // ⚠️ Keyed to the OWNING node (`nodeID`), never `innerNode` (WF-UI2).
                            // The inner id is a node of the CHILD's canvas: no view queries
                            // `nodeTimelines` for it, and freeze persists timelines only for outer
                            // result nodes — so every tool card forwarded under an inner id fell
                            // into a keyed void: no card in the Timeline tab, nothing persisted,
                            // debug-only logs. The HITL arms below deliberately KEEP the inner id —
                            // approval scope is keyed on it and the suspension resumes against it.
                            continuation.yield(.toolCall(name: name, params: params, sourceNodeID: nodeID, stepId: stepId))

                        case .requestConfirmation(let toolName, let params, let operationID, _, _):
                            continuation.yield(.requestConfirmation(toolName: toolName, params: params, operationID: operationID, sourceNodeID: nodeID))

                        case .requestClarification(let question, let operationID, _, let options, let multiline, _):
                            continuation.yield(.requestClarification(question: "[\(displayName)] \(question)", operationID: operationID, sourceNodeID: nodeID, options: options, multiline: multiline))

                        case .requestGate(let prompt, let options, let operationID, let deadline, _, let inputText, let highlights, _):
                            // Gates are structural nodes, not profile-node output, so this is defensive —
                            // forward it tagged with this node id if it ever surfaces here.
                            continuation.yield(.requestGate(prompt: "[\(displayName)] \(prompt)", options: options, operationID: operationID, deadline: deadline, sourceNodeID: nodeID, inputText: inputText, highlights: highlights))

                        case .error(let errMsg):
                            // Prefix the node name but PRESERVE the structured error's
                            // category/path/suggestion (don't flatten via interpolation).
                            continuation.yield(.error(StructuredError(
                                category: errMsg.category,
                                message: "[\(displayName)] \(errMsg.message)",
                                relatedPath: errMsg.relatedPath,
                                suggestion: errMsg.suggestion
                            )))
                            // Remember it for the outcome decision below. Forwarding an error for
                            // DISPLAY is not the same as recording that the node failed, and this
                            // arm used to do only the former — so an inner stream that errored and
                            // finished without `.executionFinished` kept `nodeStatus`'s default
                            // `.completed`. `.executionFinished(.failed)` still wins over this;
                            // it is the authority when both are present.
                            innerErrorMessage = errMsg.message

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

                        case .workflowNodeStarted, .workflowNodeCompleted, .workflowNodeFailed,
                             .workflowNodeSkipped, .workflowNodeCancelled,
                             .workflowProgress:
                            break // Ignore nested workflow events

                        case .mediaProgress:
                            continuation.yield(event)

                        case .artifactProduced(let artifact):
                            media.append(artifact)
                            continuation.yield(event)

                        case .requestPlanReview(let subtasks, let operationID, _, _):
                            // Stamp the node, exactly like the three HITL kinds above. This used to
                            // be a bare `continuation.yield(event)` pass-through, and the producer
                            // (`PlanningCapability`) never sets `sourceNodeID` — so a plan review
                            // raised by a workflow node arrived with nil, which flipped
                            // `enqueueHITL`'s `isWorkflow = workflowState != nil && sourceNodeID != nil`
                            // to false. CONSEQUENCE, all attribution and none of it fatal: the banner
                            // was labelled `.chat` (speech-bubble icon on a workflow request), had no
                            // node name, produced no "awaiting input" badge on the canvas
                            // (`awaitingNodeIDs` compactMaps the nil away), and the cross-conversation
                            // chip switched the whole interface to CHAT mode instead of the canvas the
                            // run belongs to. Fixing N2 made the nested sub-workflow path attribute
                            // this correctly, which left the direct path as the odd one out.
                            continuation.yield(.requestPlanReview(
                                subtasks: subtasks, operationID: operationID,
                                sourceNodeID: nodeID, sourceNodeName: displayName))

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
                    return (output, tools, media, innerOutcome, innerReason, innerErrorMessage)
                }

                let result = try await group.next()!
                group.cancelAll()
                return result
            }
            nodeOutput = streamResult.0
            nodeArtifacts = streamResult.1
            nodeMediaArtifacts = streamResult.2

            // An inner stream that reported an ERROR and then finished with no terminal event
            // must not be reported as a success.
            //
            // ⚠️ This is the shape `streamWorkflowNodeResponse` produces for a profile type it
            // cannot run — `case .workflow, .imageGen` yields `.error` and finishes — so an
            // ImageGen node used to go GREEN with empty output: downstream consumed nothing,
            // joins were satisfied, the error port never activated, node retry could never fire,
            // and the whole run reported success. The `.error` arm above forwarded the message
            // for DISPLAY only; nothing carried it into this decision.
            //
            // Deliberately narrow: it fires only when NO `.executionFinished` arrived at all.
            // A stream that errors mid-run and then reports `.completed` has recovered, and an
            // explicit terminal event stays the authority — the branch below still owns that
            // case. Treating "no terminal event" as failure ON ITS OWN would be wrong: a clean
            // stream legitimately ends without one, which is why the default is `.completed`.
            if case .completed = nodeStatus, streamResult.3 == nil, let errorMessage = streamResult.5 {
                logger.error("[WF_EXEC] node '\(displayName)' [node \(nodeID.uuidString.prefix(8))] emitted an error and finished with NO terminal outcome: \(errorMessage). CONSEQUENCE: the node is failed rather than reported as an empty success, so its error port activates, dependents skip per its failure policy, and node retry can fire — instead of downstream nodes running on nothing while the run claims success.")
                nodeStatus = .failed(.modelError(provider: "workflow", error: errorMessage))
            }

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
        } catch is WorkflowNodeSkipRequested {
            // ⚠️ ABOVE `catch is CancellationError`, load-bearing: the group teardown that follows
            // this throw cancels the work child, and inherited cancellation must never be
            // classified as a skip — the policy re-checks `Task.isCancelled` so Stop wins even
            // when it lands mid-skip.
            let verdict = UserSkipTeardownPolicy.classify(
                caughtSkipSignal: true, externallyCancelled: Task.isCancelled, skipFired: true)
            let settled = await Self.settleUserSkipTeardown(
                verdict: verdict, nodeID: nodeID, displayName: displayName,
                conversationID: conversationID,
                passThrough: upstreamResults.isEmpty ? trimmedUserInput : upstreamInput)
            nodeStatus = settled.status
            if let output = settled.output { nodeOutput = output }
        } catch is CancellationError {
            // Verdict repair — the race where a fired skip's typed signal LOST `group.next()` to
            // the work child's own CancellationError. Near-unreachable (the skip child completes
            // its throw before anything cancels the work child), kept because misclassifying it
            // silently turns a Skip into a Stop. The decision is `UserSkipTeardownPolicy`, tested
            // exhaustively where this race cannot be staged.
            let fired = await MainActor.run {
                WorkflowNodeSkipStore.shared.runningSkipFired(nodeID: nodeID, conversationID: conversationID)
            }
            let verdict = UserSkipTeardownPolicy.classify(
                caughtSkipSignal: false, externallyCancelled: Task.isCancelled, skipFired: fired)
            if verdict == .cancelled {
                nodeStatus = .canceled
                logger.notice("Node '\(displayName)' cancelled")
            } else {
                let settled = await Self.settleUserSkipTeardown(
                    verdict: verdict, nodeID: nodeID, displayName: displayName,
                    conversationID: conversationID,
                    passThrough: upstreamResults.isEmpty ? trimmedUserInput : upstreamInput)
                nodeStatus = settled.status
                if let output = settled.output { nodeOutput = output }
            }
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
        //
        // A user-skipped node did not PRODUCE anything: its output is the pass-through input, so
        // structured JSON is FORWARDED from upstream by the same rule every consumer reads it
        // with (`compactMap(\.structuredOutput).first`) — re-parsing the joined pass-through text
        // would drop upstream JSON whenever more than one upstream contributed.
        let structured: JSONValue?
        if case .skipped(reason: .byUser) = nodeStatus {
            structured = upstreamResults.compactMap(\.structuredOutput).first
        } else {
            structured = JSONValue.parseStructured(nodeOutput)
            if structured != nil {
                logger.info("Node '\(displayName)' produced structured (JSON) output")
            }
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
            continuation.yield(.workflowNodeCancelled(nodeID: nodeID, profileName: displayName))

        case .skipped(let reason):
            // Skipped here is the "post-execution skip" path (rare in practice;
            // upstream skips are caught earlier with a synthetic envelope). Still
            // emit the category so the workflow phase shows the signal.
            //
            // ⚠️ This arm used to yield `workflowNodeFailed(error: "Skipped: …")`, whose wording did
            // NOT match the prefix every consumer string-matched on — so the first node kind to
            // return `.skipped` from `executeNode` would have been counted as a genuine failure
            // everywhere. The typed event removes the trap rather than fixing the literal.
            let classified = ClassifiedAgentError.synthetic(
                category: .wfNodeSkipped,
                origin: "WorkflowExecutor.executeNode.skipped",
                message: reason.displayText,
                context: ["node_name": displayName, "node_id": nodeID.uuidString,
                          "skip_reason": reason.rawValue, "ran_before_skip": "true"]
            )
            await TraceRecorder.shared.emitAgentError(span: nodeSpan, error: classified, iteration: nil)
            // `.skipped`, not `.completed` (Phase 5): this arm used to close the span
            // GREEN while yielding `.workflowNodeSkipped` — the report showed a node
            // that "ran clean" next to a stream event saying it didn't run at all.
            await TraceRecorder.shared.endSpan(spanID: nodeSpan.spanID, status: .skipped)
            continuation.yield(.workflowNodeSkipped(nodeID: nodeID, profileName: displayName, reason: reason, ranBeforeSkip: true))
        }

        return result
    }

    // MARK: - WF-CC2: MLX-aware profile-node dispatch

    /// The single global runtime slot a model name binds to, or `nil` for "binds none".
    ///
    /// ⚠️ `WorkflowValidator` calls this too, so the design-time warning and the runtime
    /// partition CANNOT disagree about which nodes contend. Change one, you change both.
    nonisolated static func mlxSlotKey(modelName: String) -> String? {
        let model = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? nil : "mlx:\(model)"
    }

    /// The MLX slot this profile's LLM binds to, or `nil` when it binds none.
    ///
    /// ⚠️ `.mlx` ONLY — never `ApiProvider.isLocal`, which also covers `.ollama`. Ollama speaks
    /// HTTP to a separate server that keeps several models resident and queues server-side; it has
    /// no in-process slot to contend for.
    ///
    /// ⚠️ Keyed on the MODEL, not merely on the provider. `MLXService.loadModel(from:)`
    /// EARLY-RETURNS without unloading when the requested directory is already resident
    /// (MLXService.swift:215-219) and coalesces concurrent loads of the same directory (:210-212),
    /// so N nodes on ONE model share a single container and evict nothing. `performUnload()`
    /// (:246) runs only on a genuine model SWITCH. Serializing same-model siblings would cost
    /// parallelism for no benefit whatsoever.
    ///
    /// ⚠️ The NAME is a safe key even though `MLXService` compares DIRECTORIES: the name is
    /// resolved by `MLXModelService.installedModel(named:)`, which is deterministic, so equal
    /// names always mean one path. Two different names CAN collapse onto one path, which makes
    /// this key over-partition in that case — costing parallelism, never correctness. Do NOT "fix"
    /// that by resolving paths here: `MLXModelService` is `@MainActor`, and a main-actor hop per
    /// node inside this `nonisolated` dispatch loop buys a rare speedup at the price of a new
    /// failure mode.
    ///
    /// `resolvedLLMConfig` (BackendProfile.swift:30) is already nil for `.workflow` (dispatched
    /// structurally) and `.imageGen`, which is exactly right — neither can reach `MLXService`.
    nonisolated static func mlxSlotKey(for profile: BackendProfileModel) -> String? {
        guard let config = profile.resolvedLLMConfig, config.apiProvider == .mlx else { return nil }
        return mlxSlotKey(modelName: config.modelName)
    }

    /// Splits one level's profile nodes into lanes dispatched one AFTER another. Every lane is
    /// still fully parallel inside itself.
    ///
    /// ⚠️ Returns ONE lane containing everything unless the level demands TWO OR MORE DISTINCT MLX
    /// models. A level with no MLX node, or with one MLX node beside any number of cloud/Ollama
    /// nodes, is byte-for-byte today's behaviour — nothing can evict anything.
    ///
    /// ⚠️ When it does split, the unconstrained (cloud / Ollama / unconfigured) nodes ride along
    /// with the FIRST MLX lane rather than forming a lane of their own: they never touch the MLX
    /// slot, so they are exactly as safe beside MLX-A as they are alone, and this way they still
    /// overlap real work instead of extending the level by their own duration.
    ///
    /// ⚠️ Reordering is safe BY CONSTRUCTION, not by convention. `computeExecutionLevels` peels
    /// only nodes whose in-degree has reached zero, so two nodes on one level can never be joined
    /// by an edge; and `executeProfileNodeWithRetry` reads `state` exactly once, via
    /// `upstreamResultEnvelopes(for:edges:)`, which filters on INCOMING edges only. A node in lane
    /// 2 therefore sees byte-identical upstream input to what it would have seen in lane 1.
    nonisolated static func profileDispatchLanes(
        _ nodes: [(node: WorkflowNode, profile: BackendProfileModel)]
    ) -> [(slot: String?, members: [(node: WorkflowNode, profile: BackendProfileModel)])] {
        typealias Entry = (node: WorkflowNode, profile: BackendProfileModel)
        var unconstrained: [Entry] = []
        var bySlot: [String: [Entry]] = [:]
        var slotOrder: [String] = []

        for entry in nodes {
            guard let slot = mlxSlotKey(for: entry.profile) else {
                unconstrained.append(entry)
                continue
            }
            if bySlot[slot] == nil { slotOrder.append(slot) }
            bySlot[slot, default: []].append(entry)
        }

        guard slotOrder.count > 1 else {
            return nodes.isEmpty ? [] : [(slotOrder.first, nodes)]
        }

        return slotOrder.enumerated().map { index, slot in
            (slot, index == 0 ? unconstrained + bySlot[slot]! : bySlot[slot]!)
        }
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
        attachmentContext: String? = nil,
        state: WorkflowState,
        edges: [WorkflowEdge],
        nodes: [WorkflowNode],
        nodeIndex: Int,
        totalNodes: Int,
        conversationID: UUID,
        agentConnect: any WorkflowStreamProvider,
        traceContext: TraceContext,
        onTraceUpdate: @escaping @Sendable (AgentTraceLog) -> Void,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation,
        workflowConfig: WorkflowConfig
    ) async -> NodeResultEnvelope {

        // ⚠️ `resolvedMaxRetries` is a LEGACY fallback — the workflow-level stepper was retired
        // 2026-08-13. It stays honoured so an existing workflow keeps its resilience; new workflows
        // leave it nil, so a node with no `maxNodeRetries` of its own does not retry.
        let maxRetries = node.nodeConfig?.maxNodeRetries ?? workflowConfig.resolvedMaxRetries
        let retryDelay = node.nodeConfig?.retryDelay ?? 0
        let upstreamResults = state.upstreamResultEnvelopes(for: node.id, edges: edges)
        // "First node" is a GRAPH property, not a data property. It was derived from
        // `upstreamResults.isEmpty`, which broke the moment routing and data disagreed: a
        // continueAll downstream whose only upstream failed got zero envelopes and was handed the
        // user's chat query as if it were an entry node (WF13). The two gates agree again now,
        // but deriving from the graph makes the misclassification unrepresentable either way.
        let isEntryNode = !edges.contains { $0.targetNodeID == node.id }

        var lastResult: NodeResultEnvelope?

        for attempt in 0...maxRetries {
            if attempt > 0 {
                // Name the REASON, not just the attempt number. A retry log that says only
                // "retry 2/3" cannot answer "why is this node costing so much?" after the fact.
                let priorReason: AgentFailureReason? = {
                    if case .failed(let r) = lastResult?.status { return r }
                    return nil
                }()
                if case .iterationBudgetExhausted(let iterations) = priorReason {
                    logger.notice("[WF_EXEC] Node '\(node.displayName)' retry \(attempt)/\(maxRetries) after the agent used all \(iterations) iterations WITHOUT producing an answer. CONSEQUENCE: this attempt costs another full \(iterations)-iteration budget, and exhaustion is a capacity limit rather than bad luck — if it recurs, raise Max Iterations or simplify the node's task instead of adding retries.")
                } else {
                    logger.info("[WF_EXEC] Node '\(node.displayName)' retry \(attempt)/\(maxRetries) after \(retryDelay)s delay — prior failure: \(priorReason?.localizedDescription ?? "unknown").")
                }
                continuation.yield(.thought("[\(node.displayName)] Retrying (attempt \(attempt + 1)/\(maxRetries + 1))..."))
                if retryDelay > 0 {
                    try? await Task.sleep(for: .seconds(retryDelay))
                }
            }

            let result = await executeNode(
                node: node, profile: profile,
                userInput: userInput, attachmentContext: attachmentContext,
                upstreamResults: upstreamResults,
                isEntryNode: isEntryNode,
                nodeIndex: nodeIndex, totalNodes: totalNodes,
                conversationID: conversationID,
                agentConnect: agentConnect,
                traceContext: traceContext, onTraceUpdate: onTraceUpdate,
                continuation: continuation,
                workflowConfig: workflowConfig
            )
            lastResult = result

            // Success, non-retryable failure, cancellation, or a skip → stop.
            //
            // ⚠️ The decision is `WorkflowRetryPolicy.stopsRetrying`, not inline `if case` lines.
            // It used to be inline and was MISSING the `.skipped` arm entirely, which had no test
            // surface to notice — the same gap that produced this file. The policy's switch is
            // exhaustive, so a new status case cannot be added without deciding this at compile
            // time. See `WorkflowRetryPolicyTests` for why the skip arm matters to Phase B.
            if WorkflowRetryPolicy.stopsRetrying(after: result.status) { return result }
        }

        return lastResult!
    }


    /// Character spans of every place `rule` matched `text`, for the arbitration highlight.
    ///
    /// ⚠️ Runs ONLY when an arbitration is about to be shown, as a separate read-only pass AFTER the
    /// routing decision — so it can never influence which branch is taken, however wrong it is.
    ///
    /// ⚠️ Uses `range(of:options:.caseInsensitive)`, which is exactly what
    /// `localizedCaseInsensitiveContains` delegates to. That is the point: the highlight is produced
    /// by the same comparison that routed, so it can never show a match the router did not make (or
    /// miss one it did). ⚠️ Do NOT reuse `SearchHighlighter.matchOffsets` here — it lowercases both
    /// sides and uses plain `range(of:)`, which diverges from locale-aware folding on Turkish
    /// dotless-i and ß/ss.
    ///
    /// ⚠️ Start AND end both come from the returned `Range`. Never compute `end = start +
    /// needle.count`: case-insensitive folding can match a span whose length differs from the
    /// needle's (ß matches "ss", precomposed matches decomposed).
    ///
    /// Only `contains` has a locatable span. `equals` would give the degenerate whole field;
    /// `notContains` / `notEquals` / `isEmpty` / `always` match by absence or unconditionally, and
    /// highlighting a near-miss for `notContains` would paint precisely the text that would have
    /// made the rule NOT match.
    private static func matchSpans(for rule: ConditionRule, in text: String) -> [RuleMatchSpan] {
        guard rule.op == .contains, !text.isEmpty else { return [] }

        let needles = rule.value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var spans: [RuleMatchSpan] = []
        for needle in needles {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let found = text.range(of: needle, options: .caseInsensitive, range: searchStart..<text.endIndex, locale: .current) {
                spans.append(RuleMatchSpan(
                    label: rule.label,
                    start: text.distance(from: text.startIndex, to: found.lowerBound),
                    end: text.distance(from: text.startIndex, to: found.upperBound)
                ))
                // A zero-width match would loop forever; step past it.
                searchStart = found.upperBound > found.lowerBound ? found.upperBound : text.index(after: found.lowerBound)
            }
        }

        // One rule's comma-separated needles can overlap ("urgent, urgently"). Merge, so the
        // banner's forward-cursor painter never receives overlapping or out-of-order spans.
        let sorted = spans.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var merged: [RuleMatchSpan] = []
        for span in sorted {
            if let last = merged.last, span.start <= last.end {
                merged[merged.count - 1] = RuleMatchSpan(label: last.label, start: last.start, end: max(last.end, span.end))
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    /// Sleeps until **compute** time exceeds `limit`, then throws `.executionTimeout`. Never returns
    /// normally — it is a sentinel to race real work against.
    ///
    /// ⚠️ THE POINT: the clock excludes time spent parked awaiting a human. A node that sat for ten
    /// minutes because nobody clicked a confirmation button has not misbehaved. Before 2026-08-13
    /// the profile path raced a plain `Task.sleep`, so a slow tool confirmation killed the node at
    /// 120s — a live defect — and extending that raw race to every node kind would have killed the
    /// Router's deliberately-indefinite ambiguity arbitration on its first use.
    ///
    /// Self-correcting rather than a precomputed deadline: sleep to the nominal deadline, ask how
    /// much of that was parked, and if compute has not reached the limit, extend by the shortfall
    /// and sleep again. That handles parks beginning AFTER the sentinel is already asleep, which a
    /// deadline computed up front cannot.
    ///
    /// ⚠️ Park time is accounted per CONVERSATION, so parallel siblings share the credit and a node
    /// can over-run its limit when a sibling parked. Deliberate: over-crediting wastes some time,
    /// under-crediting kills work that was only ever waiting.
    static func computeTimeoutSentinel(
        _ limit: TimeInterval,
        conversationID: UUID,
        nodeName: String
    ) async throws -> Never {
        let start = Date()
        let parkedAtStart = await ExecutionSuspensionService.shared.cumulativeParkedTime(for: conversationID)
        var remaining = limit

        while true {
            try await Task.sleep(for: .seconds(remaining))
            let parked = await ExecutionSuspensionService.shared
                .cumulativeParkedTime(for: conversationID) - parkedAtStart
            let wall = Date().timeIntervalSince(start)
            let compute = wall - parked

            if compute >= limit {
                logger.error("[WF_TIMEOUT] Node '\(nodeName)' exceeded its \(Int(limit))s compute budget (\(Int(compute))s compute, \(Int(parked))s parked awaiting a human, \(Int(wall))s wall-clock). CONSEQUENCE: the node fails and activates its `error` port; a branch wired there runs, otherwise this branch stops here.")
                throw AgentExecutionError(reason: .executionTimeout(elapsed: compute, limit: limit))
            }

            remaining = limit - compute
            logger.info("[WF_TIMEOUT] Node '\(nodeName)' timeout extended by \(Int(remaining))s — \(Int(parked))s of the elapsed \(Int(wall))s was spent awaiting a human, which does not count against the compute budget.")
        }
    }

    /// The RUNNING-skip racer child — Phase B increment 5 (D2.1). Parks on the skip store until
    /// the user skips this RUNNING node, then throws the typed signal. `-> Never` like
    /// `computeTimeoutSentinel`: it resolves only by throwing — `WorkflowNodeSkipRequested` on
    /// the signal, or `CancellationError` when the node finishes first and the group cancels it.
    static func runningSkipSentinel(nodeID: UUID, conversationID: UUID) async throws -> Never {
        try await WorkflowNodeSkipStore.shared.awaitRunningSkip(nodeID: nodeID, conversationID: conversationID)
        throw WorkflowNodeSkipRequested(nodeID: nodeID)
    }

    /// Applies a `UserSkipTeardownPolicy` verdict to an interrupted node run.
    ///
    /// For `.skippedByUser`: the node settles exactly like a Phase A pre-dispatch skip —
    /// `.skipped(reason: .byUser)`, its aggregated INPUT as output (partial generated output is
    /// discarded with the work child; it was never assigned out of the racer tuple), upstream
    /// artifacts forwarded by the shared envelope build. Downstream stays live; no port activates.
    ///
    /// Also drains any park this node still holds, as BELT-AND-BRACES with outcome "skipped":
    /// the group teardown already cancelled the inner producer task (its `onTermination` →
    /// `task.cancel()`), which resolves every park in that task's tree through the suspension
    /// service's own cancellation handlers — so this drain normally finds nothing. It exists for
    /// a park OUTSIDE that tree (an unstructured task a capability might one day spawn), where
    /// it is the only thing standing between the skip and a banner that never clears.
    private nonisolated static func settleUserSkipTeardown(
        verdict: UserSkipTeardownPolicy.Verdict,
        nodeID: UUID,
        displayName: String,
        conversationID: UUID,
        passThrough: String
    ) async -> (status: NodeExecutionStatus, output: String?) {
        switch verdict {
        case .cancelled:
            // Stop landed while the skip was in flight — Stop wins (see the policy's header).
            logger.notice("[NODE-SKIP] Node '\(displayName)' [node \(nodeID.uuidString.prefix(8))] had a RUNNING-skip in flight when the run was cancelled — settling as CANCELLED, not skipped. CONSEQUENCE: downstream dies with the run; no pass-through is forwarded (a skip continues a run, and there is no run left to continue).")
            return (.canceled, nil)
        case .skippedByUser:
            let drained = await ExecutionSuspensionService.shared.cancelNode(
                nodeID, in: conversationID, outcome: "skipped")
            if !drained.isEmpty {
                logger.notice("[NODE-SKIP] RUNNING-skip of '\(displayName)' drained \(drained.count) park(s) the task-tree cancellation did not reach. CONSEQUENCE: their banners clear with outcome \"skipped\"; without this drain they would have waited forever.")
            }
            logger.notice("[WF_ROUTE] Skipping RUNNING node '\(displayName)' [node \(nodeID.uuidString.prefix(8))] BY USER REQUEST — its in-flight work was torn down and PARTIAL OUTPUT DISCARDED; its input (\(passThrough.count) chars) is forwarded downstream unchanged and NO port is activated: default edges below it stay LIVE, error branches do not fire (a user skip is an instruction, not a failure). CONSEQUENCE: downstream receives this node's INPUT, not its output — and not the partial output it produced before the skip.")
            return (.skipped(reason: .byUser), passThrough)
        }
    }

    /// How many times a structural node will attempt its work.
    ///
    /// ⚠️ Only Action nodes retry. A Code, Router or Gate node never did, so giving them a
    /// multiplied budget would weaken a real bound in exchange for nothing.
    static func plannedAttempts(for node: WorkflowNode, workflowConfig: WorkflowConfig) -> Int {
        // Action nodes retry inside their own per-tool loop; sub-workflow nodes retry in the OUTER
        // loop in `executeStructuralNodeBounded`. Both need the budget sized to the whole retry
        // run, or attempt 1 eats it and the rest are unreachable (the WF-EX2 shape).
        //
        // ⚠️ Sub-workflow nodes are `.profile` KIND, which is why they were excluded and why the
        // Node-Level Retries stepper did nothing for them (§9 N4). Bot/agent nodes are also
        // `.profile`, but they never reach here — `outerTimeoutBudget` has exactly one caller and
        // it is the structural path — so widening this cannot double-count their retries.
        let isSubWorkflow = node.profileType == .workflow
        guard case .action = node.kind else {
            guard isSubWorkflow else { return 1 }
            return max((node.nodeConfig?.maxNodeRetries ?? workflowConfig.resolvedMaxRetries) + 1, 1)
        }
        return max((node.nodeConfig?.maxNodeRetries ?? workflowConfig.resolvedMaxRetries) + 1, 1)
    }

    /// The node's OUTER backstop — the per-attempt limit multiplied across every planned attempt,
    /// plus the delays between them.
    ///
    /// ⚠️ THE INVARIANT: this must always be ≥ the per-attempt limit × attempts, or retries become
    /// unreachable. It was previously the per-attempt limit itself, so attempt 1 consumed the whole
    /// budget and the sentinel fired the moment attempt 2 began — a node configured "60s, 3 retries"
    /// got exactly one attempt, and any tool that failed slower than `limit / attempts` had its
    /// configured retries silently disabled. Slow failure is precisely what retries are for.
    ///
    /// `nil` (timeout off) stays `nil` — unbounded is unbounded however many attempts there are.
    static func outerTimeoutBudget(for node: WorkflowNode, workflowConfig: WorkflowConfig) -> TimeInterval? {
        guard let perAttempt = node.nodeConfig?.hardTimeout ?? workflowConfig.effectiveNodeTimeout else { return nil }
        let attempts = plannedAttempts(for: node, workflowConfig: workflowConfig)
        let retryDelay = node.nodeConfig?.retryDelay ?? 0
        return Double(attempts) * perAttempt + Double(attempts - 1) * retryDelay
    }

    /// Runs `work`, failing it if compute time exceeds `limit`. `nil` limit ⇒ unbounded.
    /// See `computeTimeoutSentinel` for why the clock is not wall-clock.
    static func withComputeTimeout<T: Sendable>(
        _ limit: TimeInterval?,
        conversationID: UUID,
        nodeName: String,
        work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard let limit else { return try await work() }

        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await computeTimeoutSentinel(limit, conversationID: conversationID, nodeName: nodeName)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
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
    /// `streamProvider` and `profileMap` are threaded for the sub-workflow child executor and Action-node tool resolution.
    /// `executeStructuralNode` bounded by the node's compute timeout.
    ///
    /// ⚠️ Structural nodes had NO timeout at all before 2026-08-13 (WF22) — the race existed only on
    /// the profile-stream and Action-tool paths, so a Router's MLX classifier, a Code template, a
    /// sub-workflow could run unbounded while the settings sheet claimed a "maximum
    /// wall-clock time per node".
    ///
    /// ⚠️ On timeout the node FAILS with `activePorts == nil`, so the driver activates `error` —
    /// wireable on every failable kind since WF61. A timed-out node is therefore recoverable rather
    /// than a dead branch.
    ///
    /// ⚠️ Safe to apply to Gate and to Router arbitration ONLY because the clock excludes parked
    /// time (see `withComputeTimeout`). A raw wall-clock race here would kill an unanswered gate and
    /// the deliberately-indefinite ambiguity arbitration.
    private nonisolated static func executeStructuralNodeBounded(
        node: WorkflowNode,
        upstreamResults: [NodeResultEnvelope],
        state: WorkflowState,
        conversationID: UUID,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation,
        nodeIndex: Int,
        totalNodes: Int,
        traceContext: TraceContext = TraceContext(subAgentName: "structural", provider: .anthropic),
        onTraceUpdate: @escaping @Sendable (AgentTraceLog) -> Void = { _ in },
        streamProvider: (any WorkflowStreamProvider)? = nil,
        injectedProfileMap: [UUID: BackendProfileModel]? = nil,
        workflowConfig: WorkflowConfig = WorkflowConfig(agentProfileIDs: [])
    ) async -> StructuralNodeResult {
        // The timeout is PER ATTEMPT, so the outer backstop must be sized to the whole retry budget.
        //
        // ⚠️ THIS IS WHAT DEFEATED RETRIES ENTIRELY (WF-EX2). The outer bound and the per-attempt
        // bound inside the Action path were computed from the IDENTICAL expression, so attempt 1
        // consumed the whole budget and the outer sentinel fired the instant attempt 2 began:
        // a node configured "60s, 3 retries" got exactly one attempt. Any Action node whose tool
        // failed slower than `timeout / (retries + 1)` had its configured retries silently
        // disabled — and slow failure is precisely the case retries exist for.
        //
        // ⚠️ The outer clock is NOT redundant now that the inner one is per-attempt: it is the ONLY
        // bound on the other five structural kinds. A Router's LLM classifier, a Code template, a
        // A sub-workflow has no inner timeout of its own (that was WF22), so
        // removing it would put them back to running unbounded.
        //
        // Same multiplicative shape the profile path already documents and accepts: bounded, never
        // infinite, and `maxNodeRetries` defaults to 0 so nothing changes unless a user opts in.
        let perAttemptLimit = node.nodeConfig?.hardTimeout ?? workflowConfig.effectiveNodeTimeout
        let retryDelay = node.nodeConfig?.retryDelay ?? 0
        let attempts = Self.plannedAttempts(for: node, workflowConfig: workflowConfig)
        let limit = Self.outerTimeoutBudget(for: node, workflowConfig: workflowConfig)

        if attempts > 1, let perAttemptLimit, let limit {
            logger.info("[WF_TIMEOUT] Node '\(node.displayName)' is bounded at \(Int(perAttemptLimit))s PER ATTEMPT across \(attempts) attempt(s) (+\(Int(retryDelay))s between), so the node's outer backstop is \(Int(limit))s. CONSEQUENCE: a retry now gets its own full budget instead of whatever the first attempt left.")
        }

        // ⚠️ SUB-WORKFLOW NODES ONLY (§9 N4). The Node-Level Retries stepper was rendered for these
        // nodes and did nothing: they are dispatched structurally (so they never reach
        // `executeProfileNodeWithRetry`) and the structural path had no loop of its own.
        //
        // Deliberately NOT `attempts` — that is the TIMEOUT budget's count, and it is > 1 for Action
        // nodes too. Looping here on it would multiply with the Action path's own per-tool loop
        // (3 outer × 3 inner = 9 invocations for a setting that reads 3).
        let outerAttempts = WorkflowRetryPolicy.structuralAttempts(
            isSubWorkflow: node.profileType == .workflow,
            maxNodeRetries: node.nodeConfig?.maxNodeRetries,
            fallbackRetries: workflowConfig.resolvedMaxRetries
        )

        let startTime = Date()
        var lastFailure: StructuralNodeResult?

        for outerAttempt in 0..<outerAttempts {
        if outerAttempt > 0 {
            logger.notice("[WF_EXEC] Sub-workflow node '\(node.displayName)' [node \(node.id.uuidString.prefix(8))] RETRY \(outerAttempt)/\(outerAttempts - 1) after \(Int(retryDelay))s. CONSEQUENCE: the ENTIRE child workflow re-runs from its first node — any side effect it already committed (a sent message, a written file) happens again. Its previous attempt's output is discarded.")
            continuation.yield(.thought("[\(node.displayName)] Retrying nested workflow (attempt \(outerAttempt + 1)/\(outerAttempts))...", sourceNodeID: node.id))
            if retryDelay > 0 { try? await Task.sleep(for: .seconds(retryDelay)) }
        }

        do {
            let result = try await withComputeTimeout(limit, conversationID: conversationID, nodeName: node.displayName) {
                await executeStructuralNode(
                    node: node, upstreamResults: upstreamResults, state: state,
                    conversationID: conversationID, continuation: continuation,
                    nodeIndex: nodeIndex, totalNodes: totalNodes,
                    traceContext: traceContext, onTraceUpdate: onTraceUpdate,
                    streamProvider: streamProvider, injectedProfileMap: injectedProfileMap,
                    workflowConfig: workflowConfig
                )
            }
            // ⚠️ A STRUCTURAL FAILURE IS RETURNED, NOT THROWN. `executeStructuralNode` reports a
            // failed child by returning an envelope with `.failed` status — only timeouts and
            // cancellation come back as thrown errors. Retrying solely in the `catch` below
            // therefore missed the ENTIRE case this loop exists for: a sub-workflow whose child
            // failed ran exactly once, with the loop silently inert. (Caught by
            // `testSubWorkflowNode_RetriesOnFailure…`, not by the unit tests — the policy was
            // right and the wiring was not.)
            if outerAttempt < outerAttempts - 1,
               case .failed(let failReason) = result.envelope.status,
               WorkflowRetryPolicy.shouldRetrySubWorkflow(after: failReason) {
                if case .iterationBudgetExhausted(let iterations) = failReason {
                    logger.notice("[WF_EXEC] Sub-workflow node '\(node.displayName)' [node \(node.id.uuidString.prefix(8))] attempt \(outerAttempt + 1)/\(outerAttempts) exhausted all \(iterations) iterations WITHOUT producing an answer — retrying. CONSEQUENCE: the ENTIRE child re-runs and costs another full iteration budget; exhaustion is a capacity limit, so raising Max Iterations or simplifying the task is more likely to help than more retries.")
                } else {
                    logger.notice("[WF_EXEC] Sub-workflow node '\(node.displayName)' [node \(node.id.uuidString.prefix(8))] attempt \(outerAttempt + 1)/\(outerAttempts) FAILED (\(failReason.localizedDescription)) — retrying. CONSEQUENCE: no terminal event is emitted for this attempt, so the canvas shows one outcome at the end rather than a node that appears to fail repeatedly.")
                }
                lastFailure = result
                continue
            }

            emitStructuralTerminalEvent(
                node: node, envelope: result.envelope,
                variableUpdates: result.variableUpdates, continuation: continuation
            )
            return result
        } catch is CancellationError {
            // ⚠️ CANCELLATION IS NOT A FAILURE, and this arm is why it used to look like one.
            //
            // This was a bare `catch`. On Stop the timeout sentinel's `Task.sleep` throws
            // `CancellationError` and usually wins the race, so the generic arm below mapped the
            // user's own Stop to `.modelError(provider: "workflow", error: "The operation couldn't
            // be completed. (Swift.CancellationError error 1.)")` — raw Swift internals shown as a
            // workflow error — OVERWROTE the honest `.canceled` the work side had already
            // reported, and activated the node's `error` branch. It fired on the DEFAULT path
            // (`effectiveNodeTimeout` is `nodeTimeoutEnabled ?? true`), i.e. every Stop with a
            // structural node in flight, and it silently undid the cancelled-status work done
            // elsewhere in the model.
            //
            // ⚠️ `activePorts` stays nil AND the status is `.canceled`, not `.failed`, so the
            // driver does NOT activate `error`: `edgeIsLive` treats `.canceled` as dead in both
            // directions, which is correct — a cancelled node routes nowhere.
            let envelope = NodeResultEnvelope(
                taskID: UUID(), nodeID: node.id,
                sourceProfileID: node.profileID ?? UUID(),
                profileName: node.displayName,
                profileType: node.profileType ?? .bot,
                status: .canceled,
                output: "",
                artifacts: [],
                metadata: .simple(start: startTime, end: Date(), output: "")
            )
            logger.notice("[WF_EXEC] Structural node '\(node.displayName)' [node \(node.id.uuidString.prefix(8))] CANCELLED after \(Int(Date().timeIntervalSince(startTime)))s. CONSEQUENCE: recorded as cancelled (not failed); its `error` port is NOT activated, so no recovery branch runs — the run is being torn down.")
            continuation.yield(.workflowNodeCancelled(nodeID: node.id, profileName: node.displayName))
            // ⚠️ Never retried — a cancel is the user pressing Stop, not a failure. Retrying would
            // restart the run they just stopped. See WorkflowRetryPolicy's header.
            return StructuralNodeResult(envelope: envelope, activePorts: nil, variableUpdates: [:])
        } catch {
            let reason = (error as? AgentExecutionError)?.reason
                ?? .modelError(provider: "workflow", error: error.localizedDescription)
            let envelope = NodeResultEnvelope(
                taskID: UUID(), nodeID: node.id,
                sourceProfileID: node.profileID ?? UUID(),
                profileName: node.displayName,
                profileType: node.profileType ?? .bot,
                status: .failed(reason),
                output: "",
                artifacts: [],
                metadata: .simple(start: startTime, end: Date(), output: "")
            )
            // ⚠️ The node's real result — if the work finished before the group could unwind it —
            // is UNRECOVERABLE here: `group.next()` rethrew the sentinel's error and the work
            // child's value went with it. Say so, because a discarded answer with no log is
            // indistinguishable in a support bundle from a node that produced nothing.
            logger.error("[WF_EXEC] Structural node '\(node.displayName)' [node \(node.id.uuidString.prefix(8))] failed after \(Int(Date().timeIntervalSince(startTime)))s: \(reason.localizedDescription). CONSEQUENCE: the node reports empty output and activates its `error` port. If this was a compute-timeout, any result the node produced while unwinding was DISCARDED — the timeout race keeps the losing side's value out of reach — so downstream sees \"\" rather than a late answer.")
            // ⚠️ `activePorts: nil` so the driver activates `error`. Setting it here would suppress
            // the one recovery route a timed-out node has.
            let failed = StructuralNodeResult(envelope: envelope, activePorts: nil, variableUpdates: [:])

            // Hold the TERMINAL event back while attempts remain: emitting it per attempt would
            // show the node failing N times on the canvas and activate its `error` port before the
            // retries had run.
            if outerAttempt < outerAttempts - 1,
               WorkflowRetryPolicy.shouldRetrySubWorkflow(after: reason) {
                lastFailure = failed
                continue
            }

            continuation.yield(.workflowNodeFailed(
                nodeID: node.id, profileName: node.displayName,
                error: reason.localizedDescription))
            return failed
        }
        } // end retry loop

        // Unreachable: every arm above returns or continues, and the last iteration cannot continue.
        // Returning the last failure rather than force-unwrapping keeps a future edit from trapping.
        return lastFailure ?? StructuralNodeResult(
            envelope: NodeResultEnvelope(
                taskID: UUID(), nodeID: node.id,
                sourceProfileID: node.profileID ?? UUID(),
                profileName: node.displayName,
                profileType: node.profileType ?? .bot,
                status: .failed(.modelError(provider: "workflow", error: "retry loop exited without a result")),
                output: "", artifacts: [],
                metadata: .simple(start: startTime, end: Date(), output: "")
            ),
            activePorts: nil, variableUpdates: [:]
        )
    }

    /// Emits the ONE terminal event for a structural node (WF-EX4).
    ///
    /// ⚠️ The single emitter. `executeStructuralNode` deliberately emits none of its own — see the
    /// comment where its switch used to be.
    private nonisolated static func emitStructuralTerminalEvent(
        node: WorkflowNode,
        envelope: NodeResultEnvelope,
        variableUpdates: [String: String],
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) {
        switch envelope.status {
        case .completed:
            // Full output (see executeNode) — the display renders & persists it in
            // full; previews clip downstream.
            let summary = envelope.output
            continuation.yield(.workflowNodeCompleted(nodeID: node.id, profileName: node.displayName, summary: summary))
        case .failed(let reason):
            continuation.yield(.workflowNodeFailed(nodeID: node.id, profileName: node.displayName, error: reason.localizedDescription, suggestion: reason.remediation))
        case .canceled:
            continuation.yield(.workflowNodeCancelled(nodeID: node.id, profileName: node.displayName))
        case .skipped(let reason):
            continuation.yield(.workflowNodeSkipped(nodeID: node.id, profileName: node.displayName, reason: reason, ranBeforeSkip: true))
        }
    }

    private nonisolated static func executeStructuralNode(
        node: WorkflowNode,
        upstreamResults: [NodeResultEnvelope],
        state: WorkflowState,
        conversationID: UUID,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation,
        nodeIndex: Int,
        totalNodes: Int,
        // Trace context + callback are threaded through so a sub-workflow child
        // can produce child spans of the parent node rather than fresh root
        // traces, and so its onTraceUpdate events reach the same consumer as the
        // parent workflow's. Defaults preserve the single-shot behaviour of the
        // other structural kinds (condition, gate, code).
        traceContext: TraceContext = TraceContext(subAgentName: "structural", provider: .anthropic),
        onTraceUpdate: @escaping @Sendable (AgentTraceLog) -> Void = { _ in },
        streamProvider: (any WorkflowStreamProvider)? = nil,
        // ⚠️ The map the CALLER was injected with (nil in production), NOT the parent's own
        // resolved `profileMap`. Its only use is to be forwarded to a nested sub-workflow's executor.
        //
        // Forwarding the parent's resolved map is what broke nested execution outright: the parent
        // builds it from `Set(layout.nodes.map(\.profileID))` — its OWN nodes — so a body
        // profile the parent does not also use is absent by construction. The body executor's
        // `if let injected` short-circuit then skips its own fetch, pre-flight validation
        // reports every body profile node as "Profile not found — it may have been deleted",
        // and the run throws `validationFailed` for profiles that exist and are visible in
        // the sidebar. Passing the INJECTION through instead means production (nil) lets the
        // body resolve its own profiles, while tests keep the map they deliberately supply.
        injectedProfileMap: [UUID: BackendProfileModel]? = nil,
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

        // Per-structural-node span so condition/code/gate/action nodes appear in the
        // trace tree (mirrors the profile-node span) and Action-node tool results below
        // attach to a real parent row (Gap #11). Status reflects the node's outcome.
        let structSpan = traceContext.newSpan()
        await TraceRecorder.shared.beginSpan(context: structSpan, name: "node:\(displayName)", kind: .workflowNode)
        defer {
            let endedAt = Date() // real end, captured before the hop (earliest-wins)
            let spanStatus: SpanStatus = { if case .completed = status { return .completed } else { return .error } }()
            Task { await TraceRecorder.shared.endSpan(spanID: structSpan.spanID, status: spanStatus, at: endedAt) }
        }

        let upstreamNames = upstreamResults.map(\.profileName).joined(separator: ", ")
        let upstreamTotalChars = upstreamResults.reduce(0) { $0 + $1.output.count }
        let kindLabel: String = switch node.kind {
        case .profile: "profile"
        case .condition: "condition"
        case .code: "code"
        case .gate: "gate"
        case .trigger: "trigger"
        case .action: "action"
        }
        logger.info("Structural node '\(displayName)' (\(kindLabel)): \(upstreamResults.count) upstream results [\(upstreamNames)], total \(upstreamTotalChars) chars")

        switch node.kind {
        case .profile(let profileID, let profileType):
            // NESTED SUB-WORKFLOW. Only workflow-backed profile nodes are dispatched here; every
            // other profile type goes down the agent path in `executeNode`.
            guard profileType == .workflow else {
                // Previously `break // Should never reach here`, which meant a routing mistake
                // presented as a GREEN node with empty output — downstream consumed nothing,
                // joins were satisfied, the error port stayed inactive and the run reported
                // success. A broken invariant must not default to silent success, and there are
                // no `assert`s in this subsystem to catch it in debug either.
                logger.error("[WF_EXEC] node '\(displayName)' [node \(nodeID.uuidString.prefix(8))] reached executeStructuralNode as a \(profileType.rawValue) profile, which only the agent path can run. CONSEQUENCE: the node is failed rather than reported as an empty success; its error port activates and dependents skip.")
                status = .failed(.modelError(
                    provider: "workflow",
                    error: "Internal routing error: '\(displayName)' is a \(profileType.rawValue) profile and cannot run as a structural node."
                ))
                break
            }

            let upstreamText = upstreamResults.map(\.output).joined(separator: "\n")
            logger.info("[WF_EXEC] sub-workflow '\(displayName)' [node \(nodeID.uuidString.prefix(8))] starting: child profile \(profileID), \(upstreamText.count) chars of upstream input, depth \(WorkflowDepth.current).")

            // The child runs its OWN canvas. `layout: nil` makes it load that workflow's layout,
            // and `profileMap` is the INJECTION (nil in production) so the child resolves the
            // profiles ITS nodes reference — the parent's resolved map only ever holds the
            // parent's. The recursion guard needs nothing here: `executeWorkflow` increments the
            // `WorkflowDepth` TaskLocal itself and refuses past `maxDepth`, and TaskLocals
            // propagate into the child's task.
            let childExecutor = WorkflowExecutor(workflowProfileID: profileID)
            // Derive from the NODE's span, not the workflow-run context: `traceContext` here is
            // the run root, so the child workflow's whole tree used to hang off the GRANDPARENT
            // as a sibling of this node — the report showed the sub-workflow beside the node
            // that ran it instead of inside it. Same traceID either way (one run, one trace).
            let childTrace = structSpan.newSpan()
            let childStream = childExecutor.executeWorkflow(
                userInput: upstreamText,
                chatHistory: [],
                conversationID: conversationID,
                ragContext: nil,
                traceContext: childTrace,
                onTraceUpdate: onTraceUpdate,
                layout: nil,
                profileMap: injectedProfileMap,
                streamProvider: streamProvider
            )

            var childOutput = ""
            var childOutcome: ExecutionOutcome? = nil
            var childFailureReason: String? = nil
            var suppressedOrchestrationEvents = 0

            // Inner node id → display name, harvested from the child's own (suppressed)
            // `workflowNodeStarted` events. Used only to title a forwarded HITL banner.
            var childNodeNames: [UUID: String] = [:]

            /// Banner title for a request forwarded out of this sub-workflow.
            ///
            /// Prefers "SubWorkflowNode › InnerNode" so a user looking at the PARENT canvas can tell
            /// which of two parallel sub-workflows is asking AND what inside it asked. Falls back to
            /// the sub-workflow node's own name when the inner node has not announced itself yet
            /// (a HITL raised before its `workflowNodeStarted` was observed).
            func hitlDisplayName(_ innerNode: UUID?) -> String {
                guard let innerNode, let inner = childNodeNames[innerNode] else { return displayName }
                return "\(displayName) › \(inner)"
            }

            do {
                for try await event in childStream {
                    switch event {
                    case .content(let text):
                        childOutput += text

                    case .thought(let msg, let id, _):
                        continuation.yield(.thought("[\(displayName)] \(msg)", id: id, sourceNodeID: nodeID))

                    case .reasoning(let msg, let id, _):
                        continuation.yield(.reasoning("[\(displayName)] \(msg)", id: id, sourceNodeID: nodeID))

                    // Tool and artifact evidence is FORWARDED, not suppressed. A sub-workflow that
                    // writes a file or generates an image must show its tool cards in the timeline,
                    // land in the persisted run record, and hand its media downstream — otherwise a
                    // consumer node answers about an artifact it never received.
                    case .toolCall(let name, let params, _, let stepId):
                        continuation.yield(.toolCall(name: name, params: params, sourceNodeID: nodeID, stepId: stepId))

                    case .toolSucceeded(let toolOutput, let durationMs, _):
                        continuation.yield(.toolSucceeded(toolOutput, durationMs: durationMs, sourceNodeID: nodeID))

                    case .toolFailed(let toolOutput, let category, let suggestion, _):
                        continuation.yield(.toolFailed(toolOutput, category: category, suggestion: suggestion, sourceNodeID: nodeID))

                    case .artifactProduced(let artifact):
                        producedArtifacts.append(artifact)
                        continuation.yield(.artifactProduced(artifact))

                    case .warning(let category, let message, let relatedPath, _):
                        continuation.yield(.warning(category: category, message: "[\(displayName)] \(message)", relatedPath: relatedPath, sourceNodeID: nodeID))

                    case .error(let errMsg):
                        // Surface in the node's timeline, but let `.executionFinished` decide the
                        // outcome — an `.error` fires only when every terminal failed, so keying
                        // off it would miss a partial failure.
                        continuation.yield(.thought("[\(displayName)] Error: \(errMsg.message)", sourceNodeID: nodeID))
                        childFailureReason = errMsg.message

                    case .executionFinished(let outcome, let reason):
                        childOutcome = outcome
                        if let reason { childFailureReason = reason }

                    // ⚠️ HITL requests MUST be forwarded — each carries an `operationID` the child
                    // is already suspended on. Swallowing one means no banner, nobody to answer,
                    // and a workflow hung forever with no error and no timeout. `sourceNodeID`
                    // keeps the INNER node's id: it is what the approval scope is keyed on, so
                    // collapsing it here would pool approvals across every node in the child.
                    case .requestConfirmation(let toolName, let params, let operationID, let innerNode, _):
                        logger.notice("[WF_HITL] sub-workflow '\(displayName)' forwarding confirmation for '\(toolName)' [op \(operationID) node \(innerNode?.uuidString ?? nodeID.uuidString)] — run is now WAITING on the user")
                        continuation.yield(.requestConfirmation(
                            toolName: toolName, params: params,
                            operationID: operationID, sourceNodeID: innerNode ?? nodeID,
                            sourceNodeName: hitlDisplayName(innerNode)))

                    case .requestGate(let prompt, let options, let operationID, let deadline, let innerNode, let inputText, let highlights, _):
                        logger.notice("[WF_HITL] sub-workflow '\(displayName)' forwarding GATE [op \(operationID)] — run is now WAITING on the user")
                        continuation.yield(.requestGate(
                            prompt: prompt, options: options, operationID: operationID,
                            deadline: deadline, sourceNodeID: innerNode ?? nodeID,
                            inputText: inputText, highlights: highlights,
                            sourceNodeName: hitlDisplayName(innerNode)))

                    case .requestClarification(let question, let operationID, let innerNode, let options, let multiline, _):
                        logger.notice("[WF_HITL] sub-workflow '\(displayName)' forwarding clarification [op \(operationID)] — run is now WAITING on the user")
                        continuation.yield(.requestClarification(
                            question: "[\(displayName)] \(question)",
                            operationID: operationID, sourceNodeID: innerNode ?? nodeID,
                            options: options, multiline: multiline,
                            sourceNodeName: hitlDisplayName(innerNode)))

                    // ⚠️ THE FOURTH HITL KIND. Its absence here was a PERMANENT HANG: a plan
                    // review raised inside a sub-workflow fell into `default:` below, so no banner
                    // ever appeared, while the child sat in `suspendForPlanReview` — which has NO
                    // timeout by design ("awaiting user action"). The node compute timeout cannot
                    // rescue it either: the sentinel subtracts `cumulativeParkedTime` and EXTENDS
                    // itself by the shortfall, and a run doing nothing but waiting on a human is
                    // 100% parked time, so it re-arms forever. Only Stop ended the run.
                    //
                    // The profile-node path forwarded this correctly all along (:1256) — the two
                    // paths simply disagreed. Design doc §9 N2.
                    case .requestPlanReview(let subtasks, let operationID, let innerNode, _):
                        logger.notice("[WF_HITL] sub-workflow '\(displayName)' forwarding PLAN REVIEW [op \(operationID) node \(innerNode?.uuidString ?? nodeID.uuidString)] — run is now WAITING on the user")
                        continuation.yield(.requestPlanReview(
                            subtasks: subtasks, operationID: operationID,
                            sourceNodeID: innerNode ?? nodeID,
                            sourceNodeName: hitlDisplayName(innerNode)))

                    case .workflowNodeStarted(let innerID, let innerName, _, _):
                        // SUPPRESSED from the parent's timeline exactly as before — but the NAME is
                        // kept, because it is the only place the child's node names ever cross this
                        // boundary. Without this, a HITL forwarded below can only be attributed to
                        // the sub-workflow node, and the banner cannot say WHICH inner node asked.
                        childNodeNames[innerID] = innerName
                        suppressedOrchestrationEvents += 1

                    default:
                        // The child's OWN orchestration events (its per-node completed/failed, its
                        // progress counter, its token usage). Re-emitting them would make the
                        // parent's timeline show the child's nodes as siblings of its own and
                        // double-count progress against the parent's total. Counted, not silent —
                        // see the log line below.
                        suppressedOrchestrationEvents += 1
                    }
                }
            } catch is CancellationError {
                logger.notice("[WF_EXEC] sub-workflow '\(displayName)' [node \(nodeID.uuidString.prefix(8))] cancelled after \(childOutput.count) chars. CONSEQUENCE: node recorded as cancelled; no error port activates and the parent settles this node as stopped, not failed.")
                output = childOutput
                status = .canceled
                break
            } catch {
                logger.error("[WF_EXEC] sub-workflow '\(displayName)' [node \(nodeID.uuidString.prefix(8))] threw: \(error.localizedDescription). CONSEQUENCE: node failed, error port activates, dependents skip per the node's failure policy.")
                output = childOutput
                status = .failed(.modelError(provider: "workflow", error: "Sub-workflow '\(displayName)' failed: \(error.localizedDescription)"))
                break
            }

            output = childOutput

            switch childOutcome {
            case .failed:
                let reasonText = childFailureReason ?? "Sub-workflow reported failure"
                logger.error("[WF_EXEC] sub-workflow '\(displayName)' [node \(nodeID.uuidString.prefix(8))] outcome=.failed (\(reasonText)). CONSEQUENCE: node failed with \(childOutput.count) chars of partial output preserved; error port activates.")
                status = .failed(.modelError(provider: "workflow", error: "Sub-workflow '\(displayName)' failed: \(reasonText)"))
            case .cancelled:
                logger.notice("[WF_EXEC] sub-workflow '\(displayName)' [node \(nodeID.uuidString.prefix(8))] outcome=.cancelled.")
                status = .canceled
            case .completedWithWarnings:
                logger.notice("[WF_EXEC] sub-workflow '\(displayName)' [node \(nodeID.uuidString.prefix(8))] completed with warnings (\(childFailureReason ?? "degraded run")) — continuing with its output.")
            case .completed:
                break
            case nil:
                // No terminal event at all. Treated as a FAILURE, never as success: an empty
                // green node is the one outcome that corrupts everything downstream silently.
                logger.error("[WF_EXEC] sub-workflow '\(displayName)' [node \(nodeID.uuidString.prefix(8))] ended without an executionFinished event (\(childOutput.count) chars produced). CONSEQUENCE: node failed rather than reported as an empty success, so the error port activates instead of downstream nodes running on nothing.")
                status = .failed(.modelError(
                    provider: "workflow",
                    error: "Sub-workflow '\(displayName)' ended without reporting an outcome."
                ))
            }

            logger.info("[WF_EXEC] sub-workflow '\(displayName)' [node \(nodeID.uuidString.prefix(8))] finished: \(childOutput.count) chars, \(producedArtifacts.count) artifact(s) forwarded, \(suppressedOrchestrationEvents) child orchestration event(s) not re-emitted (deliberate — they belong to the child's own progress tally).")

        case .condition(let config):
            let upstreamText = upstreamResults.map(\.output).joined(separator: "\n")
            logger.debug("Router '\(displayName)' input preview: \(String(upstreamText.prefix(300)))")

            // Step 1: Pattern matching — always runs first.
            //
            // ⚠️ ALL matching rules are collected; the loop no longer stops at the first hit.
            // Routing is UNCHANGED — `matchedLabels.first` is exactly the rule the old `break`
            // would have stopped on, because rule order is unchanged and each rule's verdict is
            // computed from `fieldValue` and `values` alone, with no cross-rule state. What the
            // extra work buys is knowing that an input was AMBIGUOUS, which is invisible today:
            // a rule ordered second can match every input and nothing ever says so.
            var matchedLabels: [String] = []
            for rule in config.rules {
                let fieldValue: String
                switch rule.field {
                case .upstreamOutput: fieldValue = upstreamText
                case .variable:       fieldValue = state.variables[rule.variableName ?? ""] ?? ""
                case .other(let raw):
                    // A field this build cannot evaluate (newer-version blob, WF-PE3). The rule is
                    // INERT — never a match — and says so; guessing a field would route traffic on
                    // semantics this build does not have. The validator flags the node.
                    logger.error("[WF_ROUTE] Router rule '\(rule.label)' uses field '\(raw)', which this build does not recognise (saved by a newer version). CONSEQUENCE: the rule never matches on this build; routing falls to the remaining rules or the no-match failure path.")
                    continue
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
                case .other(let raw):
                    // Same contract as an unknown field: inert, loud, never a guess (WF-PE3).
                    logger.error("[WF_ROUTE] Router rule '\(rule.label)' uses operator '\(raw)', which this build does not recognise (saved by a newer version). CONSEQUENCE: the rule never matches on this build.")
                    matches = false
                case .isEmpty:     matches = fieldValue.isEmpty
                case .isNotEmpty:  matches = !fieldValue.isEmpty
                // ⚠️ `case .always` was HARD-DELETED 2026-08-16 — a stored "always" now decodes to
                // `.other("always")` and lands in the never-matches arm above. The catch-all's job
                // moved to `config.noMatchBehavior`; unmatched input follows that setting.
                }

                logger.debug("Router '\(displayName)' rule: field=\(String(describing: rule.field)) op=\(String(describing: rule.op)) value='\(rule.value)' → \(matches ? "MATCH" : "no match") (label: '\(rule.label)')")
                if matches {
                    matchedLabels.append(rule.label)
                    logger.info("Router '\(displayName)': pattern rule matched → '\(rule.label)' (field=\(String(describing: rule.field)), op=\(String(describing: rule.op)), value='\(rule.value)')")
                }
            }

            // ⚠️ Deduped BY LABEL before anything counts them. Two rules may legitimately share a
            // label — they share one output port — and counting them separately would manufacture
            // an ambiguity against a single branch.
            var seenLabels = Set<String>()
            let distinctMatched = matchedLabels.filter { seenLabels.insert($0).inserted }

            // Step 1b: ambiguity — more than one rule described the same input.
            //
            // ⚠️ LEGACY PATH ONLY (2026-08-17). A node carrying a `decisionPolicy` resolves BOTH
            // ambiguity and no-match through the unified consultation further down; this inline
            // block is what governs a node saved before the redesign, and it must stay
            // byte-identical for those. `nil` policy is not "unset", it is "the legacy trio governs".
            var arbitratedLabel: String?
            if config.decisionPolicy == nil, distinctMatched.count > 1 {
                logger.notice("[WF_ROUTE] Router '\(displayName)': \(matchedLabels.count) rules matched the same input — [\(matchedLabels.joined(separator: ", "))]. CONSEQUENCE: routing to '\(matchedLabels[0])' because it is FIRST in rule order\(config.askOnAmbiguity ? " unless a human picks otherwise" : ""); the other \(matchedLabels.count - 1) matching branch(es) will not run. If that tiebreak is not what you meant, reorder the rules or make them mutually exclusive.")

                if config.askOnAmbiguity, !WorkflowRunAttendance.isAttended {
                    // ⚠️ Unattended (scheduled / ChatOps): never park. Nobody can see the banner,
                    // and the container either cancels the whole run at its deadline (scheduler) or
                    // has no bound at all (ChatOps). First match is exactly what an unanswered
                    // arbitration resolves to, so behaviour is identical minus the doomed wait.
                    logger.notice("[WF_ROUTE] Router '\(displayName)': arbitration SKIPPED — this run is unattended (scheduled or bridge-initiated), so nobody could answer. CONSEQUENCE: routing to '\(matchedLabels[0])' (first match), the same branch an unanswered arbitration resolves to; the run keeps moving instead of parking until the container kills it.")
                } else if config.askOnAmbiguity {
                    // ⚠️ Reuses the GATE interaction verbatim — same event, same suspension, same
                    // banner, same remote mirroring. Rule arbitration IS a gate: the user picks one
                    // of N labels and that choice routes to the matching port. Critically, every
                    // option here is a MATCHED RULE LABEL, and rule labels are already declared
                    // output ports (`ConditionNodeConfig.outputPortLabels`), so `activePorts =
                    // [chosen]` routes with no engine change. A free-form dynamic option set would
                    // NOT work — the display travels in the payload but the routing target is bound
                    // to config-derived edges.
                    let operationID = UUID()

                    // ⚠️ Spans are computed against the TRUNCATED preview, not the full text, so
                    // an offset can never point past the string the banner actually renders.
                    let preview = upstreamText.count > 500
                        ? String(upstreamText.prefix(500)) + "…"
                        : upstreamText
                    let highlights = config.rules
                        .filter { matchedLabels.contains($0.label) }
                        .flatMap { Self.matchSpans(for: $0, in: preview) }

                    // ⚠️ `deadline: nil` — the arbitration waits INDEFINITELY (user decision
                    // 2026-08-13; the previous 120s auto-resolve took the decision away from someone
                    // who had simply stepped away). nil also suppresses the banner's countdown, so
                    // the UI matches the behaviour instead of showing a timer that never fires.
                    //
                    // ⚠️ The container owns the deadline now, exactly as it does for a Gate with no
                    // configured timeout: Stop for an attended run, the 600s deadline for a
                    // scheduled one. Structural nodes get no per-node timeout race (WF22), so there
                    // is no other bound — and for a scheduled run the container deadline cancels the
                    // WHOLE run, not just this node.
                    continuation.yield(.requestGate(
                        prompt: "\(matchedLabels.count) rules match this input — which branch should it take?",
                        options: matchedLabels,
                        operationID: operationID,
                        deadline: nil,
                        sourceNodeID: nodeID,
                        inputText: preview,
                        highlights: highlights
                    ))

                    logger.notice("[WF_ROUTE] Router '\(displayName)' PARKED INDEFINITELY for ambiguity arbitration (operationID: \(operationID), options: [\(matchedLabels.joined(separator: " | "))]). CONSEQUENCE: this run makes no further progress on this branch until a human answers. There is no per-node timeout — only the container bounds it (Stop, or a scheduled run's 600s deadline, which cancels the ENTIRE run). ⚠️ A scheduled run renders NO banner for this: switch 'Ask Me Which Branch' off on Routers used in unattended workflows.")

                    let chosen = await ExecutionSuspensionService.shared.suspendForGate(
                        for: operationID, conversationID: conversationID, nodeID: nodeID
                    )

                    // ⚠️ Only a label that actually matched may be honoured. The suspension resolves
                    // from several surfaces (banner, QuickAccess, Slack/Discord/Telegram index
                    // lookup); a stale or mis-indexed answer must not activate a port that this run
                    // never matched, which would route on a rule the input does not satisfy.
                    if let chosen, matchedLabels.contains(chosen) {
                        arbitratedLabel = chosen
                        logger.notice("[WF_ROUTE] Router '\(displayName)': human chose '\(chosen)' from [\(matchedLabels.joined(separator: ", "))].")
                    } else {
                        // ⚠️ FIRST MATCH, never `fallbackLabel`. There is no per-node timeout any
                        // more, so "unanswered" now means Stop, a closed conversation, or the
                        // container deadline force-resolving the suspension — all of which must
                        // leave the run behaving exactly as it would with arbitration switched off.
                        // Routing to the catch-all instead would silently change where every
                        // unattended ambiguous input goes.
                        let reason = chosen == nil ? "unanswered (Stop, conversation closed, or container deadline)" : "answered with '\(chosen!)', which is not among the matched rules"
                        logger.notice("[WF_ROUTE] Router '\(displayName)': arbitration \(reason) — falling back to the first match '\(matchedLabels[0])'. CONSEQUENCE: routing is identical to this node having arbitration switched off; no branch is lost.")
                    }
                }
            }

            // Step 2: LLM fallback — only fires when no pattern rule matched
            // Step 2: AI Classifier — kept in its own variable so the routing METHOD is a fact
            // rather than something re-derived from the label afterwards (see step 3).
            var classifierOutcome: ClassifierOutcome?     // nil = never consulted
            // ⚠️ `isEmpty`, NOT `count != 1`. The classifier is a NO-MATCH fallback; triggering it
            // on an ambiguous input would start calling a model for inputs that route fine today.
            if matchedLabels.isEmpty && config.llmFallbackEnabled {
                logger.info("Router '\(displayName)': no pattern match, delegating to AI Classifier")
                do {
                    classifierOutcome = try await Self.evaluateConditionWithLLM(
                        config: config,
                        upstreamText: upstreamText,
                        displayName: displayName,
                        nodeID: nodeID,
                        continuation: continuation,
                        // The node's span, not the run root: the classifier's llmCall span
                        // (`classifier:<name>`) parents under the Router node that invoked it
                        // instead of floating beside it at trace root level.
                        traceContext: structSpan
                    )
                } catch is CancellationError {
                    // ⚠️ WF-CC13, fixed alongside WF-CC10 because it cannot wait. This was a BARE
                    // catch, so a Stop landing in the classifier's `model.generate` was recorded
                    // as a classifier FAILURE, counted as one in TrendsView, and then routed
                    // through `noMatchBehavior` — under `.endWorkflow` the node reported
                    // `.completed` and its passthrough became the run's final answer. Every other
                    // structural failure path in this file already has this arm; this one did not.
                    // It MUST ship with WF-CC10: without it, failing on a classifier fault would
                    // make every Stop taken during classification fire the recovery branch.
                    classifierOutcome = .cancelled
                } catch {
                    // ⚠️ `Task.isCancelled` as well as the typed catch: the MLX provider may wrap a
                    // cancellation rather than rethrow it, and misclassifying a Stop as a fault
                    // fires the error branch on every Stop taken during classification.
                    if Task.isCancelled {
                        classifierOutcome = .cancelled
                    } else {
                        classifierOutcome = .failed(reason: error.localizedDescription)
                        logger.error("[WF_ROUTE] Router '\(displayName)' [node \(nodeID.uuidString.prefix(8))]: AI Classifier FAILED — \(error.localizedDescription) (model: \(config.llmModelName ?? "none")). CONSEQUENCE: no routing verdict exists for this input, so the node fails onto its `error` port and 'When Nothing Matches' is deliberately NOT applied — that setting answers 'no rule described this input', and nothing here read the input at all. To recover automatically, wire this Router's `error` port to the branch you would have defaulted to.")
                        // ⚠️ Prefix "AI Classifier failed:" is VERBATIM — several tests key on it,
                        // including one that asserts its ABSENCE. Do not reword.
                        continuation.yield(.thought("[\(displayName)] AI Classifier failed: \(error.localizedDescription)", sourceNodeID: nodeID))
                        // P1-18: classify the failure into the workflow phase so it
                        // surfaces in TrendsView instead of being a silent thought event.
                        // ⚠️ NOT emitted for `.cancelled` — a Stop is a user action, not a
                        // classifier fault, and counting it as one poisons the reliability stats.
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
            }

            // A cancelled classifier settles the node HERE, before any routing is considered.
            // ⚠️ `.canceled`, not `.failed`, and `activePorts` stays nil — `edgeIsLive` treats a
            // cancelled node as dead in both directions, so it routes NOWHERE. Marking it failed
            // would activate `error` on every Stop.
            if case .cancelled = classifierOutcome {
                output = ""
                status = .canceled
                logger.notice("[WF_ROUTE] Router '\(displayName)' [node \(nodeID.uuidString.prefix(8))]: AI Classifier CANCELLED (Stop, or the container deadline). CONSEQUENCE: recorded as cancelled, not failed; the `error` port is NOT activated and no recovery branch runs — the run is being torn down, not misrouted. No classifier-failure telemetry is emitted.")
                break
            }

            // ═══════════════════════════════════════════════════════════════════════════════
            // Step 2b: THE UNIFIED DECISION (2026-08-17 redesign) — policy nodes only.
            //
            // One setting answers both "several rules matched" and "nothing matched", and the AI
            // Classifier inherits it: one token routes, zero is EMPTY, two or more is AMBIGUOUS
            // (which is what retires WF-OB2's per-launch-random pick).
            //
            // ⚠️ Everything below this block — `resolveRouterPort`, the `method` chain, the
            // `noMatchBehavior` switch — is the LEGACY path and runs only when `decisionPolicy` is
            // nil. Both are kept because the legacy 2×3 matrix does not collapse onto the new axis
            // losslessly; a stored workflow keeps its exact behaviour until its author re-saves it.
            // ═══════════════════════════════════════════════════════════════════════════════
            if let policy = config.decisionPolicy {
                // Exactly one branch named → route, policy never consulted (spec point 1).
                var decided: String? = distinctMatched.count == 1 ? distinctMatched[0] : nil
                var situation: RouterUndecided?
                var boundaryFailReason: String?

                if decided == nil {
                    if distinctMatched.count > 1 {
                        situation = .ambiguous(candidates: distinctMatched, origin: .pattern)
                    } else if let outcome = classifierOutcome {
                        // ⚠️ `classify` sorts crash/Stop OUT before any situation value exists, so
                        // no policy branch can route them (WF-CC10 / WF-CC13, now type-enforced).
                        switch Self.classify(outcome: outcome) {
                        case .decided(let label):        decided = label
                        case .situation(let s):          situation = s
                        case .boundaryFail(let reason):  boundaryFailReason = reason
                        case .boundaryCancel:
                            // Unreachable: the `.cancelled` settle above already broke out.
                            boundaryFailReason = nil
                        }
                    } else {
                        situation = .empty(.noRuleMatched)
                    }
                }

                if let reason = boundaryFailReason {
                    // ⚠️ The policy is deliberately NOT applied: it answers "no rule described this
                    // input", and a classifier that threw never read the input at all.
                    output = ""
                    status = .failed(.modelError(provider: "workflow", error: "Router '\(displayName)': \(reason)"))
                    logger.error("[WF_ROUTE] Router '\(displayName)' [node \(nodeID.uuidString.prefix(8))] FAILED — \(reason). CONSEQUENCE: the node activates its `error` port; 'When Routing Can't Decide' is deliberately NOT applied to a classifier FAULT. To recover automatically, wire this Router's `error` port.")
                    break
                }

                if let label = decided {
                    activePorts = [label]
                    output = upstreamText
                    let via = distinctMatched.count == 1 ? "pattern" : "classifier"
                    logger.info("[WF_ROUTE] Router '\(displayName)' activated port: '\(label)' via \(via) (policy not consulted — exactly one branch named), output \(output.count) chars")
                    break
                }

                guard let undecided = situation else { break }   // unreachable by construction

                // Resolve, honouring an Ask by parking; whatever the human answers (or does not)
                // funnels back through the SAME table via the fallback.
                var disposition = Self.resolveUndecided(policy: policy, situation: undecided, rules: config.rules)

                if case .ask(let options, let prompt, let fallback) = disposition {
                    if !WorkflowRunAttendance.isAttended {
                        // ⚠️ Unattended (scheduled / chat bridge): never park. Nobody can see the
                        // banner, and the container either cancels the whole run at its deadline or
                        // has no bound at all.
                        logger.notice("[WF_ROUTE] Router '\(displayName)': Ask SKIPPED — this run is unattended (scheduled or bridge-initiated), so nobody could answer. CONSEQUENCE: falling back to the configured 'If nobody can answer' action instead of parking until the container kills the run.")
                        disposition = Self.resolveUndecided(
                            policy: Self.policy(for: fallback), situation: undecided, rules: config.rules)
                    } else {
                        let operationID = UUID()
                        let preview = upstreamText.count > 500
                            ? String(upstreamText.prefix(500)) + "…"
                            : upstreamText
                        // Highlights only make sense when specific rules matched; an EMPTY situation
                        // has nothing to point at, and the banner renders fine with none.
                        let highlights: [RuleMatchSpan]
                        if case .ambiguous(let candidates, .pattern) = undecided {
                            highlights = config.rules
                                .filter { candidates.contains($0.label) }
                                .flatMap { Self.matchSpans(for: $0, in: preview) }
                        } else {
                            highlights = []
                        }

                        continuation.yield(.requestGate(
                            prompt: prompt,
                            options: options,
                            operationID: operationID,
                            deadline: nil,
                            sourceNodeID: nodeID,
                            inputText: preview,
                            highlights: highlights
                        ))
                        logger.notice("[WF_ROUTE] Router '\(displayName)' PARKED INDEFINITELY for a routing decision (operationID: \(operationID), options: [\(options.joined(separator: " | "))]). CONSEQUENCE: this branch makes no further progress until a human answers. There is no per-node timeout — only the container bounds it (Stop, or a scheduled run's 600s deadline, which cancels the ENTIRE run).")

                        let chosen = await ExecutionSuspensionService.shared.suspendForGate(
                            for: operationID, conversationID: conversationID, nodeID: nodeID
                        )

                        // ⚠️ Only an OFFERED option may be honoured. The suspension resolves from
                        // several surfaces (banner, QuickAccess, chat bridges); a stale or
                        // mis-indexed answer must not activate a port this situation never offered.
                        if let chosen, options.contains(chosen) {
                            logger.notice("[WF_ROUTE] Router '\(displayName)': human chose '\(chosen)' from [\(options.joined(separator: ", "))].")
                            disposition = .route(port: chosen)
                        } else {
                            let why = chosen == nil
                                ? "unanswered (Stop, conversation closed, or container deadline)"
                                : "answered with '\(chosen!)', which was not offered"
                            logger.notice("[WF_ROUTE] Router '\(displayName)': routing decision \(why) — applying the configured 'If nobody can answer' action. CONSEQUENCE: identical to an unattended run, so an unanswered Ask and an unattendable one never diverge.")
                            disposition = Self.resolveUndecided(
                                policy: Self.policy(for: fallback), situation: undecided, rules: config.rules)
                        }
                    }
                }
                switch disposition {
                case .route(let port):
                    activePorts = [port]
                    output = upstreamText
                    logger.notice("[WF_ROUTE] Router '\(displayName)' [node \(nodeID.uuidString.prefix(8))]: no single branch was named — routing to '\(port)' per 'When Routing Can't Decide'. CONSEQUENCE: the run continues down that branch exactly as if that rule had matched; any branches that DID match do not run.")

                case .endBranch:
                    output = upstreamText
                    status = .completed
                    activePorts = []
                    logger.notice("[WF_ROUTE] Router '\(displayName)' [node \(nodeID.uuidString.prefix(8))]: no single branch was named — ENDING this branch per 'When Routing Can't Decide'. CONSEQUENCE: everything downstream skips as 'not chosen', nothing is reported as failed, and this Router's passthrough content becomes (part of) the final answer. Parallel branches are unaffected.")

                case .fail(let reason):
                    // ⚠️ `activePorts` left NIL so the driver's structural-failure path activates
                    // `error`. Setting it here would suppress that.
                    output = ""
                    status = .failed(.modelError(provider: "workflow", error: "Router '\(displayName)': \(reason)"))
                    logger.error("[WF_ROUTE] Router '\(displayName)' [node \(nodeID.uuidString.prefix(8))] FAILED — \(reason) (\(config.rules.count) rule(s) evaluated against \(upstreamText.count) chars). CONSEQUENCE: this node activates its `error` port; a branch wired there runs, otherwise this branch stops and the reason appears in the run's final output.")

                case .ask:
                    // Unreachable: every Ask above resolves to route/fail/endBranch before here.
                    output = ""
                    status = .failed(.modelError(provider: "workflow", error: "Router '\(displayName)': routing decision could not be resolved"))
                    logger.error("[WF_ROUTE] Router '\(displayName)': an Ask disposition survived resolution — this is a bug in the unified decision path, not a configuration error.")
                }
                break
            }

            // ⚠️ LEGACY-ONLY WF-OB2 REPAIR. A nil-policy node has no setting to consult about an
            // ambiguous classifier reply, so it collapses to the FIRST-STATED candidate. That is
            // still a behaviour change for untouched blobs — and it is strictly the bugfix: what it
            // replaces was whichever label an unordered Dictionary happened to yield, which could
            // differ between app launches for the same input. First-stated is deterministic and is
            // the model's own answer (the rest of a "not X, it's Y" reply is hedging).
            if config.decisionPolicy == nil, case .ambiguous(let candidates)? = classifierOutcome,
               let firstStated = candidates.first {
                logger.notice("[WF_ROUTE] Router '\(displayName)' [node \(nodeID.uuidString.prefix(8))]: the AI Classifier named \(candidates.count) categories — [\(candidates.joined(separator: ", "))] — and this Router predates the unified routing setting, so it takes the FIRST-STATED one, '\(firstStated)'. CONSEQUENCE: deterministic, unlike the previous behaviour which picked by hash order and could differ between launches. Open this node and save it to choose what should happen instead.")
                classifierOutcome = .label(firstStated)
            }

            // Step 3: resolve the port.
            //
            // ⚠️ `matchedLabels.first` reproduces the pre-2026-08-13 first-match-wins exactly.
            // `fallbackLabel` is a LEGACY compatibility path — the Static Fallback picker is gone and
            // a default branch is now an ordinary last rule with the `always` operator. Configs
            // saved before that still carry a fallback and are still honoured, because silently
            // converting them on load would change where unmatched input goes in every existing
            // workflow.
            // ⚠️ Extracted to `resolveRouterPort` so this decision is unit-testable (WF-EX1). The
            // classifier itself needs a real MLX model and cannot be reached from a test, but the
            // rule that turns its answer into a port is pure — and that rule is where the defect was.
            let resolution = Self.resolveRouterPort(
                arbitrated: arbitratedLabel,
                matched: matchedLabels,
                classifier: classifierOutcome?.label,
                legacyFallback: config.fallbackLabel
            )
            if case .none(let discardedEmptyLabel) = resolution, discardedEmptyLabel {
                logger.error("[WF_ROUTE] Router '\(displayName)' [node \(nodeID.uuidString.prefix(8))] resolved an EMPTY port label and DISCARDED it. CONSEQUENCE: the node fails onto its `error` port instead of activating a port no edge can legitimately carry — activating \"\" would have made every UNLABELLED edge out of this node fire, sending the run down the default branch as though a rule had matched. Give every rule a non-empty label.")
            }
            let resolvedPort = resolution.port

            // ⚠️ The routing METHOD is TRACKED, not inferred. The old expression asked whether the
            // matched label was ABSENT from `config.rules` — but the classifier only ever returns a
            // rule label, so that test was always false and every classifier decision was reported
            // as "pattern" (WF65). Inference was the bug.
            // ⚠️ `var`, not `let`: the no-match arm below corrects it to "no-match-default".
            // Without that, a `.route(...)` no-match logged "activated port 'General' via
            // legacy-fallback" for a route no legacy fallback was involved in — this chain falls
            // to its `else` when all three signals are nil (WF-CC10).
            var method: String
            if arbitratedLabel != nil {
                method = "arbitrated"
            } else if !matchedLabels.isEmpty {
                method = "pattern"
            } else if classifierOutcome?.label != nil {
                method = "classifier"
            } else {
                method = "legacy-fallback"
            }

            // NO RULE MATCHED — a real outcome, not something to swallow. What happens next is the
            // author's explicit choice (`noMatchBehavior`, 2026-08-16), replacing the deleted
            // `always` catch-all idiom. Never a run-level stop (that would be `stopWorkflow`
            // renamed, retired 2026-08-12): parallel branches keep their results in every case.
            var noMatchPort: String?
            var noMatchSettled = false
            if resolvedPort == nil {
                // ⚠️ Placed AFTER `resolveRouterPort`, deliberately: a non-empty legacy
                // `fallbackLabel` resolves a port at step 3 and never reaches here, so this change
                // leaves pre-2026-08-13 configs routing exactly where they route today. Declining
                // the legacy catch-all on a classifier fault too would be a separate, currently
                // unpinned behaviour change.
                switch Self.resolveNoMatch(
                    behavior: config.noMatchBehavior,
                    outcome: classifierOutcome,
                    rules: config.rules
                ) {
                case .fail(let reason):
                    // ⚠️ `activePorts` is left NIL so the driver's structural-failure path activates
                    // `error`. Setting it here would suppress that.
                    output = ""
                    status = .failed(.modelError(provider: "workflow", error: "Router '\(displayName)': \(reason)"))
                    noMatchSettled = true
                    logger.error("[WF_ROUTE] Router '\(displayName)' [node \(nodeID.uuidString.prefix(8))] FAILED — \(reason) (\(config.rules.count) rule(s) evaluated against \(upstreamText.count) chars). CONSEQUENCE: this node activates its `error` port; a branch wired there runs, otherwise this branch stops and the reason appears in the run's final output. To send unmatched input somewhere instead, set the Router's 'When Nothing Matches' option — ⚠️ except after a classifier FAULT, which that setting deliberately does not cover.")

                case .route(let port):
                    noMatchPort = port
                    method = "no-match-default"
                    logger.notice("[WF_ROUTE] Router '\(displayName)' [node \(nodeID.uuidString.prefix(8))]: no port resolved — routing to DEFAULT '\(port)' per 'When Nothing Matches'. CONSEQUENCE: the run continues down that branch exactly as if the rule had matched. The classifier produced a verdict, or was never consulted; a classifier FAULT would have failed the node instead.")

                case .endBranch:
                    // Graceful end of THIS BRANCH: complete with an explicitly EMPTY port set, so
                    // every outgoing edge is dead, downstream skips as `.notChosen` (quiet, not
                    // red), and — terminality being computed over LIVE edges — this Router becomes
                    // a terminal whose passthrough content is the run's final output.
                    // ⚠️ Parallel siblings are untouched (invariant W28).
                    output = upstreamText
                    status = .completed
                    activePorts = []
                    noMatchSettled = true
                    logger.notice("[WF_ROUTE] Router '\(displayName)' [node \(nodeID.uuidString.prefix(8))]: no port resolved — ENDING this branch per 'When Nothing Matches'. CONSEQUENCE: every node downstream of this Router skips as 'not chosen', nothing is reported as failed, and the Router's passthrough content becomes (part of) the run's final answer. Parallel branches are unaffected. A classifier FAULT would have failed the node instead.")
                }
            }
            if noMatchSettled { break }

            guard let activatedPort = resolvedPort ?? noMatchPort else {
                // Unreachable: every no-match arm either settled above or set `noMatchPort`.
                break
            }

            activePorts = [activatedPort]
            if !config.fallbackLabel.isEmpty, method == "legacy-fallback" {
                logger.notice("[WF_ROUTE] Router '\(displayName)' used its LEGACY catch-all '\(config.fallbackLabel)'. The Static Fallback picker was retired 2026-08-13 and stored values are still honoured so existing workflows keep behaving identically. CONSEQUENCE: none today — but to express this on the canvas instead, set the Router's 'When Nothing Matches' option to route to '\(config.fallbackLabel)'.")
            }
            // ⚠️ A Router ALWAYS passes the upstream content through. The "Pass Through Content"
            // toggle was retired 2026-08-13: switched off it emitted a debug string in place of the
            // payload, which nothing downstream could consume, and it suppressed text only —
            // artifacts flowed either way.
            output = upstreamText
            if !config.passthroughContent {
                logger.notice("[WF_ROUTE] Router '\(displayName)' carries a RETIRED 'Pass Through Content = off' setting, which is ignored. CONSEQUENCE: downstream nodes now receive the full upstream content instead of the routing-label string they used to get. If a downstream rule or prompt was written against text like \"route \u{2192} \(activatedPort)\", it will no longer match — key off the content itself.")
            }
            logger.info("[WF_ROUTE] Router '\(displayName)' activated port: '\(activatedPort)' via \(method), output \(output.count) chars")

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
                                for: operationID, conversationID: conversationID, nodeID: nodeID
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
                    for: operationID, conversationID: conversationID, nodeID: nodeID
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
            // flag.
            //
            // ⚠️ Gate on the RESOLVED tool, not on `toolRef` (the node's stored snapshot).
            // `toolRef.requiresConfirmation` is frozen at the moment the tool was picked, and
            // that seed was hardcoded `false` before 2026-07-31 — so every Action node saved
            // before then ran destructive tools unattended forever, and no later change to the
            // tool's policy could reach it. `resolveWorkflowTool` re-derives the value from the
            // live definition (failing closed when it cannot), which makes THIS the authority.
            //
            // Resolved arguments (not the argument NAMES the timeline shows) are what the user
            // is asked to approve — approving "args: [command]" without seeing the command is
            // not consent. This matches the agent path, which has always surfaced real arguments
            // in the banner; the trace event above stays names-only because it is exportable.
            if agentTool.requiresConfirmation {
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
                        for: operationID, conversationID: conversationID, nodeID: nodeID
                    )

                    // Honour argument edits made in the banner. Offering an editor and then
                    // running the ORIGINAL arguments would be worse than offering none.
                    if approved,
                       let edited = await ExecutionSuspensionService.shared.consumeEditedArguments(for: operationID),
                       let reEncoded = try? JSONEncoder().encode(edited) {
                        argsData = reEncoded
                        logger.info("Action node '\(displayName)': running '\(toolRef.name)' with user-edited arguments.")
                    }

                    // ⚠️ A CANCELLED PARK IS NOT A DENIAL — the Action-node twin of the guard in
                    // `ToolExecutionLoop`. Stop resolves a waiting confirmation with `false`, and
                    // without this the node is recorded as `.failed("User denied tool …")`, which
                    // ACTIVATES ITS ERROR PORT: a recovery branch runs, and any webhook or message
                    // wired there fires — on a run the user simply stopped. `.canceled` is the
                    // established shape here (the sub-workflow and Router arms both use it) and it
                    // routes NOWHERE, which is correct for a teardown.
                    if Task.isCancelled {
                        output = ""
                        status = .canceled
                        logger.notice("Action node '\(displayName)': confirmation for '\(toolRef.name)' was torn down by cancellation, NOT denied by the user. CONSEQUENCE: recorded as cancelled, so no error port activates and no recovery branch runs.")
                        break
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

            // (#1) Per-ATTEMPT timeout — a hung tool can't block the workflow forever.
            // (#2) Retry — transient failures (network/MCP/timeout) retry up to
            // `maxNodeRetries`. Defaults: hardTimeout → workflow default (120s),
            // retries → workflow default (0). Both honor per-node overrides.
            //
            // ⚠️ These two were documented as independent and were NOT (WF-EX2): the caller's outer
            // backstop was computed from this SAME expression, so the first attempt consumed the
            // entire node budget and every retry was silently unreachable. The outer bound is now
            // sized to `attempts × limit` in `executeStructuralNodeBounded` — read that before
            // changing either number, because they only work as a pair.
            let nodeTimeout: TimeInterval? = node.nodeConfig?.hardTimeout ?? workflowConfig.effectiveNodeTimeout
            let maxRetries = node.nodeConfig?.maxNodeRetries ?? workflowConfig.resolvedMaxRetries
            let retryDelay = node.nodeConfig?.retryDelay ?? 0
            logger.info("Action node '\(displayName)': invoking tool '\(toolRef.name)' (\(config.argumentBindings.count) binding(s), timeout \(nodeTimeout.map { "\(Int($0))s" } ?? "off"), retries \(maxRetries))")

            var attempt = 0
            while true {
                // ⚠️ Per ATTEMPT, not since the node began. `toolStart` is set once before the loop,
                // so with retries every duration after the first was cumulative — attempt 3 of a
                // 60s-timeout tool was reported as a 180s call in the timeline and in per-tool
                // latency stats.
                let attemptStart = Date()
                do {
                    let (toolOutput, toolArtifacts) = try await Self.runToolWithTimeout(agentTool, args: argsData, timeout: nodeTimeout)
                    output = toolOutput
                    producedArtifacts = toolArtifacts
                    let durationMs = Int(Date().timeIntervalSince(attemptStart) * 1000)

                    // A tool that reports failure by RETURNING an error string is a failure.
                    //
                    // ⚠️ Not throwing is not the same as succeeding. `http_request` answers a dead
                    // endpoint with "Error: HTTP request failed …" and returns normally; so do many
                    // MCP tools. This branch used to mark every non-throwing return a success, so
                    // the node went green, the tool card said success, no `error` port activated —
                    // and the node's error-handler branch was unreachable for that whole class of
                    // tool, which is most of the integration tools people wire Action nodes to.
                    //
                    // Same predicate and same opt-out as the agent path, deliberately reused rather
                    // than re-implemented: tools whose legitimate output surfaces error text (shell
                    // stderr, build-log readers) set `contentMayLookLikeError` and are exempt —
                    // their real failures still throw.
                    let semanticFailure = agentTool.contentMayLookLikeError
                        ? false
                        : ToolExecutionMediator.isSemanticFailure(toolOutput)

                    if semanticFailure {
                        // Deliberately NOT retried, unlike a thrown error. The tool returned
                        // normally, so it may already have performed its side effect and merely
                        // reported badly — re-running a POST that answered "Error: HTTP 500" can
                        // double-submit. The thrown path retries because the call is known not to
                        // have completed. Revisit only with a per-tool idempotency signal.
                        status = .failed(.modelError(provider: "tool", error: "Tool '\(toolRef.name)' reported a failure: \(toolOutput)"))
                        await TraceRecorder.shared.emitToolResult(span: structSpan, name: toolRef.name, success: false, output: toolOutput, durationMs: durationMs)
                        continuation.yield(.toolFailed(
                            ToolOutput(toolName: toolRef.name, params: toolParams, output: toolOutput, isSuccess: false),
                            category: .executionThrew, sourceNodeID: nodeID
                        ))
                        logger.error("[WF_EXEC] Action node '\(displayName)' [node \(nodeID.uuidString.prefix(8))]: tool '\(toolRef.name)' returned normally but its output reports a failure: \(toolOutput.prefix(200)). CONSEQUENCE: the node is failed and its error port activates, so an error-handler branch runs — previously this reported success and downstream nodes consumed the error text as data.")
                        break
                    }

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
                    // ⚠️ REPORT EVERY FAILED ATTEMPT, not just the last one.
                    //
                    // This branch used to log and yield a `.thought`, then `continue` — so an
                    // attempt that failed and was retried reached neither the trace nor per-tool
                    // reliability stats. A tool that failed twice and succeeded on the third try was
                    // recorded as one clean success, which is exactly backwards for a stat whose
                    // whole job is to show which tools are flaky.
                    let attemptDurationMs = Int(Date().timeIntervalSince(attemptStart) * 1000)
                    let attemptCategory: ToolFailureCategory
                    if let agentErr = error as? AgentExecutionError, case .executionTimeout = agentErr.reason {
                        attemptCategory = .timeout
                    } else {
                        attemptCategory = .executionThrew
                    }

                    // Retry transient failures (timeout, network) up to the cap.
                    //
                    // ⚠️ THIS COMMENT USED TO BE FALSE. The condition was a bare `attempt < maxRetries`
                    // inside a bare `catch`, so EVERY error retried — a bad argument, a missing file,
                    // a permission denial. `attemptCategory` was computed just above but only ever
                    // used for reporting. A tool call is deterministic, so those attempts burned the
                    // node's budget to arrive at the identical error.
                    if attempt < maxRetries, WorkflowRetryPolicy.isTransientToolError(error) {
                        attempt += 1
                        await TraceRecorder.shared.emitToolResult(span: structSpan, name: toolRef.name, success: false, output: error.localizedDescription, durationMs: attemptDurationMs)
                        continuation.yield(.toolFailed(
                            ToolOutput(
                                toolName: toolRef.name, params: toolParams,
                                output: "Attempt \(attempt) of \(maxRetries + 1) failed: \(error.localizedDescription)",
                                isSuccess: false
                            ),
                            category: attemptCategory, sourceNodeID: nodeID
                        ))
                        logger.notice("[WF_EXEC] Action node '\(displayName)': tool '\(toolRef.name)' failed on attempt \(attempt)/\(maxRetries + 1) after \(attemptDurationMs)ms (\(error.localizedDescription)); retrying\(retryDelay > 0 ? " after \(Int(retryDelay))s" : ""). CONSEQUENCE: this attempt IS counted in the tool's reliability stats and shown in the node's timeline — a retried failure is not a silent one.")
                        continuation.yield(.thought("[\(displayName)] Tool failed — retrying (\(attempt)/\(maxRetries))...", sourceNodeID: nodeID))
                        if retryDelay > 0 { try? await Task.sleep(for: .seconds(retryDelay)) }
                        continue
                    }
                    if attempt < maxRetries {
                        logger.notice("[WF_EXEC] Action node '\(displayName)': tool '\(toolRef.name)' failed on attempt \(attempt + 1)/\(maxRetries + 1) and \(maxRetries - attempt) retry/retries remain, but they were NOT used — \(WorkflowRetryPolicy.declineReason(for: error)). CONSEQUENCE: the node fails now rather than repeating a deterministic error until the budget runs out; the configured retry count is unchanged and still applies to transient failures.")
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
                    let durationMs = attemptDurationMs
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

        // ⚠️ NO terminal event is emitted here. `executeStructuralNodeBounded` — the ONLY caller —
        // emits exactly one, from the envelope this function returns (WF-EX4).
        //
        // This function used to yield its own `workflowNodeCompleted`/`Failed`/etc., and the
        // wrapper yielded ANOTHER on the timeout path, so one node produced TWO contradictory
        // terminal events: a green "✅ node: <full answer>" immediately followed by a red
        // "❌ Execution timeout". Structured concurrency makes that ordering deterministic (the
        // wrapper's task group must await this child before rethrowing), so the node settled on
        // the right verdict — but the activity log recorded a success and a failure for the same
        // node, seconds apart, with nothing explaining it. One emitter, one event.

        // True structural kinds (condition/code/gate/action/trigger) have no backing
        // profile, so the envelope carries a placeholder. A sub-workflow node DOES have one,
        // and reporting it as a random `.bot` would mislabel it everywhere the run record is
        // read — the timeline icon, the node card and the history row all key off these.
        let envelopeProfileID: UUID
        let envelopeProfileType: ProfileType
        if case .profile(let pid, let ptype) = node.kind {
            envelopeProfileID = pid
            envelopeProfileType = ptype
        } else {
            envelopeProfileID = UUID()
            envelopeProfileType = .bot
        }

        let envelope = NodeResultEnvelope(
            taskID: UUID(),
            nodeID: nodeID,
            sourceProfileID: envelopeProfileID,
            profileName: displayName,
            profileType: envelopeProfileType,
            status: status,
            output: output,
            // Structural nodes (Code/Gate/Condition) are pipeline plumbing —
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
            // node emitting JSON, or a Gate passing JSON through, exposes it as
            // `structuredOutput` for downstream `{{ input.json.path }}` access.
            structuredOutput: JSONValue.parseStructured(output)
        )

        return StructuralNodeResult(envelope: envelope, activePorts: activePorts, variableUpdates: variableUpdates)
    }

    // MARK: - Classifier Outcome (WF-CC10)

    /// What the AI Classifier produced for THIS node — a FACT, not an absence.
    ///
    /// ⚠️ `classifierLabel: String?` collapsed FOUR different sentences into `nil`: the classifier
    /// was never consulted, it answered "none of these", it answered unreadably, and it never
    /// answered at all (it threw). `noMatchBehavior` answers "no rule described this input" — a
    /// verdict about CONTENT. A classifier that threw produced no verdict, so applying that
    /// setting turns an infrastructure fault into a routing decision, and under `.route` the run
    /// then reports SUCCESS with an arbitrary branch taken.
    ///
    /// ⚠️ "Did it run at all?" is modelled as OPTIONALITY, not a case. That removes the
    /// `config.llmFallbackEnabled && classifierLabel == nil` inference, which was wrong whenever a
    /// rule matched with a BLANK label: the classifier is skipped (its trigger is
    /// `matchedLabels.isEmpty`) yet the reason claimed it had weighed the input and returned nothing.
    enum ClassifierOutcome: Equatable, Sendable {
        /// It named a rule label. NOT guaranteed non-empty — `resolveRouterPort` still owns
        /// empty-label rejection (WF-EX1) and this type must not grow a second opinion about it.
        case label(String)
        /// It answered, and the answer was the no-match sentinel. A verdict about the RULES;
        /// remedy: add or widen one. FOLLOWS `noMatchBehavior` — this is the case that setting
        /// was written for.
        case noMatch
        /// It answered, and the reply carried no recognisable token. A verdict about the MODEL;
        /// remedy: pick a stronger one. ⚠️ Deliberately ALSO follows `noMatchBehavior`: the model
        /// ran and could not decide, and "if it can't decide, When Nothing Matches applies" is
        /// what the Router inspector promises.
        case unreadable(preview: String)
        /// It never answered — threw before or during the model call. NOT a verdict about
        /// anything. The ONLY case that bypasses `noMatchBehavior`.
        case failed(reason: String)
        /// Torn down by Stop or the container deadline. ⚠️ Kept APART from `.failed` because this
        /// file's own rule is "cancellation is not a failure": a cancelled node records
        /// `.canceled` and must NOT activate `error`, or every Stop taken during classification
        /// would run the recovery branch.
        case cancelled

        /// The reply named TWO OR MORE distinct labels, in first-appearance order (WF-OB2).
        /// ⚠️ A verdict the model DID produce, so it feeds the Router's decision policy exactly
        /// like several pattern rules matching — it is ambiguity, not a fault.
        case ambiguous(candidates: [String])

        /// Adapter for `resolveRouterPort`, whose contract is "signals that are PRESENT".
        var label: String? {
            if case .label(let l) = self { return l }
            return nil
        }
    }

    // MARK: - Unified Router decision (2026-08-17 redesign)

    /// Where an undecided Router's situation came from — pattern rules, or the AI Classifier.
    /// Carried so a log or a failure reason can say WHICH, since the remedies differ.
    enum RouterUndecidedOrigin: Equatable, Sendable { case pattern, classifier }

    /// Why a Router could not decide.
    ///
    /// ⚠️ THIS TYPE STRUCTURALLY CANNOT EXPRESS A FAULT OR A STOP, and that is the point. A
    /// classifier CRASH bypasses the decision policy and fails the node (WF-CC10); a Stop settles
    /// `.canceled` and routes nowhere (WF-CC13). Both are separated out by `classify(outcome:)`
    /// BEFORE a value of this type exists, so no policy branch can accidentally route them.
    enum RouterUndecided: Equatable, Sendable {
        /// Nothing named a branch.
        case empty(EmptyEvidence)
        /// Several branches were named — pattern rules or classifier tokens. Candidates are
        /// deduped and ordered (rule order for patterns, reply order for the classifier).
        case ambiguous(candidates: [String], origin: RouterUndecidedOrigin)

        /// Why nothing was named. The distinction is the user's remedy: widen a rule, versus pick
        /// a stronger model.
        enum EmptyEvidence: Equatable, Sendable {
            /// No rule matched and the classifier was never consulted (off, or a rule matched).
            case noRuleMatched
            /// The model explicitly answered "none of these fit" — a verdict about the RULES.
            case classifierNoMatch
            /// The reply carried nothing recognisable — a verdict about the MODEL.
            case classifierUnreadable(preview: String)
        }
    }

    /// A classifier outcome sorted into the two things it can be: a boundary the policy must never
    /// see, or a routable situation.
    enum RouterBoundaryOrSituation: Equatable {
        case decided(String)
        case situation(RouterUndecided)
        case boundaryFail(reason: String)
        case boundaryCancel
    }

    /// ⚠️ THE crashed-vs-inconclusive differential lives here — moved out of `resolveNoMatch`'s
    /// first guard so it stays unit-provable while becoming type-enforced downstream.
    ///
    /// ⚠️ Exhaustive with NO `default`: a new `ClassifierOutcome` case must break this build rather
    /// than silently inherit a routing verdict.
    static func classify(outcome: ClassifierOutcome) -> RouterBoundaryOrSituation {
        switch outcome {
        case .failed(let reason):
            // WF-CC10, wording preserved verbatim — tests pin it.
            return .boundaryFail(reason: "the AI Classifier could not be consulted (\(reason)), so nothing classified this input and no branch was chosen")
        case .cancelled:
            return .boundaryCancel
        case .label(let l):
            return .decided(l)
        case .ambiguous(let candidates):
            return .situation(.ambiguous(candidates: candidates, origin: .classifier))
        case .noMatch:
            return .situation(.empty(.classifierNoMatch))
        case .unreadable(let preview):
            return .situation(.empty(.classifierUnreadable(preview: preview)))
        }
    }

    /// What the executor should do about an undecided Router.
    enum UndecidedDisposition: Equatable {
        case fail(reason: String)
        case route(port: String)
        case endBranch
        /// Park and ask. The executor owns the actual suspension; this carries what to offer and
        /// what to do when nobody answers.
        case ask(options: [String], prompt: String, fallback: RouterDecisionPolicy.AskFallback)
    }

    /// The unified decision: one policy, both triggers (user decision 2026-08-17).
    ///
    /// ⚠️ Pure and total, so the whole decision table is unit-testable without an executor — the
    /// classifier cannot be driven from a test (it reaches `MLXService.shared` directly), so this
    /// function is the only place the situations can be compared against each other.
    static func resolveUndecided(
        policy: RouterDecisionPolicy,
        situation: RouterUndecided,
        rules: [ConditionRule]
    ) -> UndecidedDisposition {
        // The human-readable evidence, shared by every disposition that reports one.
        let detail: String
        switch situation {
        case .empty(.noRuleMatched):
            detail = "no rule matched"
        case .empty(.classifierNoMatch):
            detail = "no rule matched, and the AI Classifier reported that none of the \(rules.count) categories fit"
        case .empty(.classifierUnreadable(let preview)):
            detail = "no rule matched, and the AI Classifier's reply (\"\(preview)\") carried no recognisable label"
        case .ambiguous(let candidates, let origin):
            let source = origin == .pattern ? "\(candidates.count) rules matched the same input" : "the AI Classifier named \(candidates.count) categories"
            detail = "\(source) — [\(candidates.joined(separator: ", "))] — so no single branch was chosen"
        }

        switch policy {
        case .failNode:
            return .fail(reason: detail)

        case .endBranch:
            return .endBranch

        case .route(let ruleID):
            // ⚠️ Resolved by the rule's STABLE ID so renames cannot strand it. A deleted target is
            // a design-time validation ERROR; reaching this at run time means validation was
            // bypassed, so fail honestly rather than guess.
            guard let target = rules.first(where: { $0.id == ruleID }) else {
                return .fail(reason: "\(detail), and the chosen default route points at a rule that no longer exists")
            }
            return .route(port: target.label)

        case .ask(let fallback):
            // ⚠️ The offered options differ by situation, and every one of them is a RULE LABEL —
            // which is what makes the gate reuse work, since rule labels are already declared
            // output ports. Ambiguity offers only the branches actually named; EMPTY has no
            // candidates, so it offers every rule (the question becomes "none of these fit — which
            // should it take anyway?").
            let options: [String]
            let prompt: String
            switch situation {
            case .ambiguous(let candidates, let origin):
                options = candidates
                prompt = origin == .pattern
                    ? "\(candidates.count) rules match this input — which branch should it take?"
                    : "The AI Classifier named \(candidates.count) categories — which branch should it take?"
            case .empty:
                // Deduped, order preserved: two rules may share a label (one port), and the
                // banner must not offer the same branch twice.
                var seen = Set<String>()
                options = rules.map(\.label).filter { !$0.isEmpty && seen.insert($0).inserted }
                prompt = "Nothing matched this input — which branch should it take?"
            }
            // A Router with no rules cannot offer a choice; fall straight to the fallback rather
            // than parking on an empty banner.
            guard !options.isEmpty else {
                return Self.resolveUndecided(
                    policy: Self.policy(for: fallback), situation: situation, rules: rules)
            }
            return .ask(options: options, prompt: prompt, fallback: fallback)
        }
    }

    /// An `AskFallback` is a policy minus `ask` — this lifts it back so the fallback resolves
    /// through the SAME table rather than a parallel one that could drift.
    static func policy(for fallback: RouterDecisionPolicy.AskFallback) -> RouterDecisionPolicy {
        switch fallback {
        case .failNode:          return .failNode
        case .route(let ruleID): return .route(ruleID: ruleID)
        case .endBranch:         return .endBranch
        }
    }

    /// What the Router does when no port resolved.
    enum NoMatchDisposition: Equatable {
        case fail(reason: String)
        case route(port: String)
        case endBranch
    }

    /// ⚠️ Extracted PURE so the crashed-vs-inconclusive distinction is PROVABLE. The classifier
    /// cannot be driven from a test — it reaches `MLXModelService.shared` / `MLXService.shared` as
    /// concrete singletons with no injection seam — so an INCONCLUSIVE classifier is unreachable
    /// end-to-end, and this function is the only place the two can be compared. Same concession,
    /// and the same reason, as `resolveRouterPort`.
    static func resolveNoMatch(
        behavior: RouterNoMatchBehavior,
        outcome: ClassifierOutcome?,
        rules: [ConditionRule]
    ) -> NoMatchDisposition {
        // ⚠️ WF-CC10 LIVES IN THIS BLOCK AND NOWHERE ELSE.
        // A classifier that never executed did not find the input unmatched — it never read it.
        // `noMatchBehavior` is the answer to a question that was never asked, so it is not applied.
        // Same reasoning as the deleted-route arm below: fail honestly rather than guess.
        // ⚠️ `.cancelled` never reaches here — its caller settles the node as `.canceled` first.
        if case .failed(let reason) = outcome {
            return .fail(reason: "the AI Classifier could not be consulted (\(reason)), so nothing classified this input and no branch was chosen")
        }

        let detail: String
        switch outcome {
        // ⚠️ `.failed` is listed only because Swift does not narrow the enum after the `if case`
        // early-return above — it is unreachable here. Kept in the exhaustive switch rather than
        // hidden behind a `default:` so that adding a ClassifierOutcome case still breaks the build.
        case nil, .label, .cancelled, .failed, .ambiguous:
            // nil = the classifier was off, or a rule matched (possibly with a BLANK label, which
            // `resolveRouterPort` then discarded). `.label` reaching here means the label was
            // blank. `.ambiguous` is unreachable on this LEGACY path: the call site collapses it to
            // its first-stated candidate before this runs, because a nil-policy node has no setting
            // to consult (that collapse is the WF-OB2 bugfix — deterministic first-stated replacing
            // a per-launch random pick). None of these may mention a classifier verdict.
            detail = "no rule matched"
        case .noMatch:
            detail = "no rule matched, and the AI Classifier reported that none of the \(rules.count) categories fit"
        case .unreadable(let preview):
            detail = "no rule matched, and the AI Classifier's reply (\"\(preview)\") carried no recognisable label"
        }

        switch behavior {
        case .failNode:
            return .fail(reason: detail)
        case .endWorkflow:
            return .endBranch
        case .route(let ruleID):
            // ⚠️ Resolved by the rule's STABLE ID, so renames cannot strand it. A deleted target is
            // a design-time validation ERROR; reaching this at run time means validation was
            // bypassed, so fail honestly rather than guess.
            guard let target = rules.first(where: { $0.id == ruleID }) else {
                return .fail(reason: "\(detail), and its 'When Nothing Matches' route points at a rule that no longer exists")
            }
            return .route(port: target.label)
        }
    }

    // MARK: - Router Port Resolution

    /// Which output port a Router activates, or nothing at all.
    enum RouterPortResolution: Equatable {
        case port(String)
        /// No port resolved — the node must FAIL onto its `error` port.
        /// `discardedEmptyLabel` is true when a candidate existed but was an empty string, which is
        /// worth logging separately because it means a rule was saved with a blank label.
        case none(discardedEmptyLabel: Bool)

        var port: String? {
            if case .port(let p) = self { return p }
            return nil
        }
    }

    /// Turns the three routing signals into the port to activate.
    ///
    /// ⚠️ `internal`, not `private`, SOLELY so it can be unit-tested — the same concession
    /// `AgentConnect.resolveExecutableTools` makes. The classifier that feeds it reaches for
    /// `MLXModelService.shared`/`MLXService.shared` directly and cannot be driven from a test, so
    /// extracting the pure half is what makes WF-EX1 verifiable at all.
    ///
    /// ⚠️ AN EMPTY LABEL IS ABSENT, NOT A PORT — the whole point of this function (WF-EX1).
    /// `evaluateConditionWithLLM` used to return `matched ?? config.fallbackLabel`, and since the
    /// Static Fallback picker was retired 2026-08-13 `fallbackLabel` is empty on every Router made
    /// since — so an unreadable model reply produced `""`. A `??` chain treats `""` as PRESENT, so it
    /// sailed past the `guard let` written to fail the node and activated a port named `""`.
    /// `WorkflowState.edgeIsLive` resolves an edge's port as `edge.sourcePortLabel ?? ""`, so that
    /// empty port matched every UNLABELLED edge out of the Router: the run took the default branch as
    /// though a rule had matched, and still reported success.
    ///
    /// Normalising HERE, once, rather than at each producer, means every future signal added to this
    /// chain inherits the guarantee instead of re-learning it the same way.
    ///
    /// Priority is unchanged: HITL arbitration → first pattern match → classifier → legacy catch-all.
    static func resolveRouterPort(
        arbitrated: String?,
        matched: [String],
        classifier: String?,
        legacyFallback: String
    ) -> RouterPortResolution {
        // ⚠️ The legacy fallback is handled AFTER the loop, deliberately. An empty `legacyFallback`
        // is the ORDINARY state of every Router created since the Static Fallback picker was retired
        // — it means "no catch-all configured", not "someone saved a blank label". Feeding it through
        // the same empty-detection as the real signals would raise `discardedEmptyLabel` on every
        // no-match run and turn a genuine diagnostic into noise.
        var sawEmptyCandidate = false
        for candidate in [arbitrated, matched.first, classifier] {
            guard let candidate else { continue }
            if candidate.isEmpty {
                // Not an answer, but a signal worth reporting — keep looking.
                sawEmptyCandidate = true
                continue
            }
            return .port(candidate)
        }
        if !legacyFallback.isEmpty { return .port(legacyFallback) }
        return .none(discardedEmptyLabel: sawEmptyCandidate)
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
    ) async throws -> ClassifierOutcome {

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
        // ⚠️ The no-match token is logged alongside the label map because without it a support bundle
        // cannot decode the reply: a lone unfamiliar 4-char code in the trace is indistinguishable
        // from a hallucinated one, and the two have opposite remedies.
        logger.debug("AI Classifier '\(displayName)' token map: [\(tokenMapDebug)]\(tokenMapper.fallbackIsNoMatchSentinel ? ", no-match token → \(tokenMapper.fallbackToken) (routes nowhere)" : ", catch-all → \(tokenMapper.fallbackToken)")")

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
        <instruction>\(config.resolvedRoutingPrompt())</instruction>
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
        // Declared so the Run Report's Model lane counts the classifier as the real model time
        // it is (see RunReportProjection.declaredModelMs) — it was silently unattributed before.
        await TraceRecorder.shared.endSpan(
            spanID: classifierSpan.spanID, status: .completed,
            metadata: ["model": model.modelName, "duration_ms": "\(durationMs)"])

        logger.debug("AI Classifier '\(displayName)' raw response: \"\(response)\"")

        // Immediately reclaim GPU RAM — classifier is a one-shot task,
        // no need to keep the model loaded until the idle timer fires.
        // The next workflow node will load whatever model it needs.
        await MLXService.shared.unloadModel()
        logger.debug("AI Classifier '\(displayName)': unloaded MLX model after classification")

        // Parse response using token mapper — handles clean, wrapped, and lowercased responses
        let matched = tokenMapper.parseResponse(response)

        // ⚠️ nil, NEVER "" (WF-EX1). This used to be `matched ?? config.fallbackLabel`, and since the
        // Static Fallback picker was retired 2026-08-13 `fallbackLabel` is EMPTY on every Router
        // created since — so a model reply carrying no recognisable token produced the empty string
        // and handed it back as though it were a routing decision.
        //
        // The caller's `??` chain then treated "" as PRESENT, sailed past the `guard let` written to
        // fail the node on no-match, and activated a port named "". Two ways that hurt, both silent
        // and both leaving the run reporting SUCCESS:
        //   • no edge is labelled "", so the branch just stops; or worse
        //   • `WorkflowState.edgeIsLive` compares `edge.sourcePortLabel ?? ""`, so an UNLABELLED
        //     edge out of this Router matches "" and FIRES — the run routes down the default branch
        //     as if a rule had matched, on a reply the classifier could not read at all.
        //
        // Returning nil lets the caller's existing no-match arm do its job: fail the node, activate
        // `error`, and put the reason in the run's final output.
        // ⚠️ NEVER "" (WF-EX1) and, since WF-CC10, never a bare `nil` either. The three non-label
        // endings are DIFFERENT SENTENCES and the caller needs all three: `noMatch` and
        // `unreadable` are verdicts the model produced, so they follow `noMatchBehavior`; a THROW
        // (which never reaches this line) is not a verdict at all. Collapsing them to `String?`
        // meant an MLX slot race and a clean "none of these" arrived identically, and under
        // `.route` an infrastructure fault silently became a routing decision.
        let result: String? = matched ?? (config.fallbackLabel.isEmpty ? nil : config.fallbackLabel)
        let responsePreview = String(response.trimmingCharacters(in: .whitespacesAndNewlines).prefix(50))

        if let result {
            continuation.yield(.thought("[\(displayName)] AI Classifier: \"\(responsePreview)\" → route: \(result)", sourceNodeID: nodeID))
            logger.info("Router AI Classifier '\(displayName)': response=\"\(responsePreview)\", resolved=\(result)")
            return .label(result)
        }

        if tokenMapper.isExplicitNoMatch(response) {
            // ⚠️ Reported separately from an unparseable reply (WF-OB1). The model DID answer, and
            // its answer was "none of these" — that is a statement about the RULES, not a
            // misbehaving model, and the remedy is different: add or widen a rule.
            continuation.yield(.thought("[\(displayName)] AI Classifier: none of the categories matched", sourceNodeID: nodeID))
            logger.notice("[WF_ROUTE] Router AI Classifier '\(displayName)' [node \(nodeID.uuidString.prefix(8))]: the model explicitly reported that NONE of the \(classificationLabels.count) categor(ies) fit. CONSEQUENCE: no port is resolved, so the node follows its 'When Nothing Matches' setting — this is the classifier working correctly on input the rules do not cover, not a model failure. Add a rule that covers this input.")
            return .noMatch
        }

        // ⚠️ The two log lines above and below used to say "the node fails onto its `error` port".
        // That has been false since `noMatchBehavior` shipped 2026-08-16 — true only under
        // `.failNode`. A log line must state its TRUE consequence (WF-CC10).
        logger.error("[WF_ROUTE] Router AI Classifier '\(displayName)' [node \(nodeID.uuidString.prefix(8))]: the model reply \"\(responsePreview)\" contained NONE of the \(classificationLabels.count) label token(s) and not the no-match token either — an unusable answer. CONSEQUENCE: no port is resolved, so the node follows its 'When Nothing Matches' setting; the model RAN, so this is treated as an undecided verdict rather than a classifier fault. If this recurs, the model is too small to follow the token protocol; pick a stronger one for this Router.")
        continuation.yield(.thought("[\(displayName)] AI Classifier: \"\(responsePreview)\" → no recognisable label", sourceNodeID: nodeID))
        return .unreadable(preview: responsePreview)
    }

}
