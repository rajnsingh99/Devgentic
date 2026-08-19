//
//  WorkflowValidation.swift
//  Devgentic
//
//  Created by Raj Singh on 13/04/26.
//
//  Pure validation system for workflow configurations.
//  Scans all nodes for configuration issues and returns actionable results.
//  The validator is a stateless pure function — O(n+e) on layout size, safe to
//  call on every canvas change without debouncing.
//

import Foundation

// MARK: - Validation Issue

/// A single configuration issue found during workflow validation.
struct WorkflowValidationIssue: Identifiable, Hashable, Sendable {
    let id: UUID
    /// The node that has the issue. Nil for workflow-level issues.
    let nodeID: UUID?
    /// Display name of the node (or "Workflow" for workflow-level).
    let nodeName: String
    /// Error = blocks execution. Warning = informational, execution allowed.
    let severity: Severity
    /// Human-readable description of the issue.
    let message: String

    enum Severity: String, Sendable, Comparable, Hashable {
        case error
        case warning

        // Errors sort before warnings
        static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs == .error && rhs == .warning
        }
    }

    init(nodeID: UUID? = nil, nodeName: String, severity: Severity, message: String) {
        self.id = UUID()
        self.nodeID = nodeID
        self.nodeName = nodeName
        self.severity = severity
        self.message = message
    }
}

// MARK: - Validator

/// Pure validation function for workflow layouts.
/// No side effects, no singletons, no async — fully testable in isolation.
enum WorkflowValidator {

    /// Validates a workflow layout and returns all configuration issues.
    /// - Parameters:
    ///   - layout: The workflow's node/edge graph.
    ///   - profileMap: Available profiles keyed by UUID (for checking profile existence).
    /// - Returns: Issues sorted by severity (errors first), then by layout order.
    static func validate(
        layout: WorkflowLayout,
        profileMap: [UUID: BackendProfileModel],
        // Current tool catalog (native + connected MCP). Used to warn when an
        // Action node references an MCP tool whose server is offline/removed.
        // Empty = skip availability checks (caller didn't provide a catalog).
        availableToolSources: [ToolSource] = [],
        // Every workflow layout reachable through sub-workflow nodes, keyed by workflow profile ID
        // (`WorkflowLayoutStore.resolveNestedLayouts`). Empty = skip the nesting/cycle checks.
        //
        // ⚠️ Resolved by the caller so this function stays PURE and SYNCHRONOUS — it re-runs on
        // every canvas edit, and loading layouts here would mean a SwiftData fetch per keystroke.
        subWorkflowLayouts: [UUID: WorkflowLayout] = [:],
        // This workflow's own profile ID, so a workflow that contains ITSELF is detectable.
        // Without it only cycles among the sub-workflows are visible.
        rootProfileID: UUID? = nil
    ) -> [WorkflowValidationIssue] {
        var issues: [WorkflowValidationIssue] = []

        // --- Workflow-Level Checks ---

        if layout.nodes.isEmpty {
            issues.append(WorkflowValidationIssue(
                nodeName: "Workflow",
                severity: .error,
                message: "Workflow has no nodes. Add profiles to the canvas."
            ))
            return issues // No point checking nodes if there are none
        }

        // Disconnected nodes (no incoming or outgoing edges)
        let connectedNodeIDs = Set(layout.edges.map(\.sourceNodeID)).union(Set(layout.edges.map(\.targetNodeID)))
        for node in layout.nodes {
            if !connectedNodeIDs.contains(node.id) && layout.nodes.count > 1 {
                issues.append(WorkflowValidationIssue(
                    nodeID: node.id,
                    nodeName: node.displayName,
                    severity: .warning,
                    message: "Node is disconnected — no edges to or from other nodes."
                ))
            }
        }

        // P0-8: Code-node `outputVariable` collisions that can RACE. Two Code nodes
        // writing the same variable on the SAME execution level run in parallel
        // (`WorkflowState.variables` is a plain dict — last write wins, order
        // nondeterministic). Writes on DIFFERENT levels are sequential and therefore
        // deterministic (last write wins predictably), so only same-level collisions
        // are flagged. If levels can't be computed (cycle), fall back to flagging any
        // duplicate conservatively.
        let nodeLevel: [UUID: Int] = {
            guard let levels = layout.computeExecutionLevels() else { return [:] }
            var map: [UUID: Int] = [:]
            for (levelIndex, level) in levels.enumerated() {
                for nodeID in level { map[nodeID] = levelIndex }
            }
            return map
        }()
        var outputVariableOwners: [String: [(nodeID: UUID, displayName: String, level: Int)]] = [:]
        for node in layout.nodes {
            if case .code(let config) = node.kind,
               let varName = config.outputVariable?.trimmingCharacters(in: .whitespacesAndNewlines),
               !varName.isEmpty {
                // level -1 = unknown (cyclic): groups together so they still collide.
                outputVariableOwners[varName, default: []].append((node.id, node.displayName, nodeLevel[node.id] ?? -1))
            }
        }
        // The complete set of variable names ANY node can ever write. Statically enumerable
        // because the engine's `setVariable` is fed exclusively by Code-node `outputVariable` —
        // profile nodes never write, and the run starts with an empty variable store. This is what
        // makes the "rule reads a variable nothing writes" lint below possible WITHOUT duplicating
        // any engine evaluation logic: the P0-8 pass above already collected the Code-node half for
        // its collision check.
        let writtenVariables = Set(outputVariableOwners.keys)

        for (varName, owners) in outputVariableOwners {
            for (_, sameLevelOwners) in Dictionary(grouping: owners, by: { $0.level }) where sameLevelOwners.count > 1 {
                for owner in sameLevelOwners {
                    let otherNames = sameLevelOwners
                        .filter { $0.nodeID != owner.nodeID }
                        .map(\.displayName)
                        .joined(separator: ", ")
                    issues.append(WorkflowValidationIssue(
                        nodeID: owner.nodeID,
                        nodeName: owner.displayName,
                        severity: .error,
                        message: "Output variable '\(varName)' also written by: \(otherNames). Parallel writes race — rename for stable behavior."
                    ))
                }
            }
        }

        // --- WF-CC2: same-level MLX model contention ---
        //
        // `MLXService` keeps exactly ONE model container resident. `loadModel` calls
        // `performUnload()` before loading a different directory (MLXService.swift:246) and
        // EARLY-RETURNS for the one already resident (:215-219), so two same-level nodes on
        // DIFFERENT MLX models evict each other on every generation call while two on the SAME
        // model share one container for free. Only DISTINCT models are flagged.
        //
        // ⚠️ WARNING, never an error, and this is not a judgement call. The graph is legal and it
        // runs. Per the standing directive a backend label may describe but must never gate.
        // `WorkflowExecutor` filters `severity == .error` before throwing `.validationFailed` —
        // that is the only place a validation issue can stop a run — so `.warning` is safe here
        // by construction.
        //
        // ⚠️ TWO POOLS, not one. The executor fully awaits the STRUCTURAL task group before it
        // opens the PROFILE group, so an AI-Classifier Router and a profile node on one level
        // never overlap in time. Merging the pools would flag a provably safe shape, and a rule
        // that flags safe shapes teaches people to run past the panel.
        //
        // ⚠️ Silent on a cycle: `nodeLevel` is empty when `computeExecutionLevels()` returns nil,
        // and a cyclic layout is refused at pre-flight anyway. Asserting contention about a run
        // that can never start is noise.
        typealias MLXDemand = (nodeID: UUID, displayName: String, level: Int, model: String, slot: String)
        var mlxProfileDemands: [MLXDemand] = []
        var mlxRouterDemands: [MLXDemand] = []
        for node in layout.nodes {
            guard let level = nodeLevel[node.id] else { continue }
            switch node.kind {
            case .profile(let profileID, let profileType):
                // `.workflow` runs a CHILD executor and its demand lives in the child layout,
                // which this rule cannot see. `resolvedLLMConfig` is already nil for both
                // `.workflow` and `.imageGen`; the explicit guard says so at the call site.
                guard profileType != .workflow,
                      let profile = profileMap[profileID],
                      let config = profile.resolvedLLMConfig,
                      // ⚠️ Shared with the runtime partition ON PURPOSE — this rule and
                      // `WorkflowExecutor.profileDispatchLanes` must never disagree about which
                      // nodes contend.
                      let slot = WorkflowExecutor.mlxSlotKey(for: profile) else { continue }
                mlxProfileDemands.append((node.id, node.displayName, level,
                                          config.modelName.trimmingCharacters(in: .whitespacesAndNewlines), slot))

            case .condition(let config):
                // The AI Classifier is MLX-only by construction — `evaluateConditionWithLLM`
                // resolves `llmModelName` through `MLXModelService.installedModel(named:)` and
                // calls `MLXService.shared.loadModel`. There is no provider field, so presence is
                // the whole check.
                guard config.llmFallbackEnabled,
                      let slot = WorkflowExecutor.mlxSlotKey(modelName: config.llmModelName ?? "") else { continue }
                mlxRouterDemands.append((node.id, node.displayName, level,
                                         (config.llmModelName ?? "").trimmingCharacters(in: .whitespacesAndNewlines), slot))

            case .code, .gate, .trigger, .action:
                // `.code` is deterministic non-LLM processing and `.action` invokes a tool
                // directly; neither can reach MLXService. Exhaustive on purpose — a new
                // `WorkflowNodeKind` must fail to compile here rather than inherit a silent skip.
                continue
            }
        }

        let mlxPools: [(demands: [MLXDemand], body: (String, String) -> String)] = [
            (mlxProfileDemands, { model, others in
                "Runs the local MLX model '\(model)' on the same step as \(others). Only one MLX model stays in memory, so the engine runs these one after another instead of in parallel — this step takes as long as both nodes combined. Point them at the same model, or wire one into the other so they run on different steps, to get the parallelism back."
            }),
            (mlxRouterDemands, { model, others in
                "Its AI Classifier runs the local MLX model '\(model)' on the same step as \(others). Only one MLX model stays in memory, and same-step Routers are NOT run one at a time — they evict each other's weights, so every hand-off re-reads multi-GB of model from disk and a classification can fail outright. Point them at the same model, or wire them onto different steps."
            })
        ]
        for pool in mlxPools {
            for (_, sameLevel) in Dictionary(grouping: pool.demands, by: { $0.level })
            where Set(sameLevel.map(\.slot)).count > 1 {
                for demand in sameLevel {
                    let others = sameLevel
                        .filter { $0.nodeID != demand.nodeID && $0.slot != demand.slot }
                        // Sorted so the message text is deterministic — `Dictionary(grouping:)` is
                        // not, and a test that greps the message would otherwise flake.
                        .sorted { ($0.displayName, $0.model) < ($1.displayName, $1.model) }
                        .map { "'\($0.displayName)' (\($0.model))" }
                        .joined(separator: ", ")
                    guard !others.isEmpty else { continue }
                    issues.append(WorkflowValidationIssue(
                        nodeID: demand.nodeID,
                        nodeName: demand.displayName,
                        severity: .warning,
                        message: pool.body(demand.model, others)
                    ))
                }
            }
        }

        // --- Disconnected pipelines ("islands") ---
        //
        // The rule above only catches a node with NO edges at all. Two clusters that each have
        // edges but no path between them pass it — and that shape is two workflows sharing one
        // canvas: BOTH clusters' entry nodes receive the user's prompt (every zero-in-degree node
        // is an entry node), both run in parallel, and both terminals land in one combined answer.
        //
        // ⚠️ Multiple ENTRY nodes are legitimate and NOT flagged — two research nodes feeding one
        // synthesizer is a single connected pipeline with two starts. What is flagged is the
        // absence of any path between clusters.
        //
        // WARNING, not error: the graph runs correctly, and a hard block would stop workflows that
        // are already working (the WF10 lesson). It names the split so an accidental missing edge
        // is visible.
        if layout.nodes.count > 1 {
            let components = connectedComponents(layout: layout)
            if components.count > 1 {
                let named = components.map { component -> String in
                    let names = component.compactMap { id in layout.nodes.first(where: { $0.id == id })?.displayName }
                    return "\"" + names.sorted().joined(separator: " + ") + "\""
                }.sorted()
                issues.append(WorkflowValidationIssue(
                    nodeName: "Workflow",
                    severity: .warning,
                    message: "This canvas holds \(components.count) separate pipelines with no connection between them: \(named.joined(separator: ", ")). They will all run on the same input and their results will be combined into one answer. Connect them, or move one into its own workflow."
                ))
            }
        }

        // --- Sub-workflow nesting: cycles and depth ---
        validateNesting(
            layout: layout,
            subWorkflowLayouts: subWorkflowLayouts,
            rootProfileID: rootProfileID,
            issues: &issues
        )

        // --- Dangling output ports ---
        //
        // An edge addresses its source port by LABEL. If that label is not among the node's
        // current ports, the edge can never fire: `WorkflowState.shouldExecuteNode` sees a port
        // that never activates, so the whole downstream branch is skipped at run time — while the
        // canvas keeps DRAWING the edge, because the port-position lookup falls back to index 0
        // for an unknown label. Nothing else in the app reports this, so a rename or a deleted
        // rule produced a valid-looking graph that quietly stopped routing.
        //
        // `replaceNode` now re-points edges through a rename, so this fires mainly for a DELETED
        // port and for layouts broken before that fix — which is exactly why it is needed: the
        // remap cannot repair what is already on disk.
        //
        // ⚠️ WARNING, not error, and the distinction is deliberate. A dangling port is a real
        // defect — that branch cannot run — but it is a defect the workflow has been living with,
        // possibly for a long time, while the REST of it worked. Promoting it to an error would
        // block those runs outright the moment this shipped: trading a silent dead branch for a
        // workflow that will not start, which is a worse regression than the bug. The complaint in
        // WF10 is that the failure was INVISIBLE; a warning in the validation panel fixes exactly
        // that, and `replaceNode` stops new ones being created.
        let nodesByID = Dictionary(layout.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for edge in layout.edges {
            guard let sourceNode = nodesByID[edge.sourceNodeID] else { continue }
            let ports = WorkflowCanvasState.outputPortLabels(for: sourceNode)
            // A node with no declared ports uses the single implicit default; only multi-port
            // kinds can strand an edge.
            guard !ports.isEmpty else { continue }
            let label = edge.sourcePortLabel ?? ""
            guard !ports.contains(label) else { continue }

            let targetName = nodesByID[edge.targetNodeID]?.displayName ?? "another node"
            issues.append(WorkflowValidationIssue(
                nodeID: sourceNode.id,
                nodeName: sourceNode.displayName,
                severity: .warning,
                message: "Output '\(label.isEmpty ? "(default)" : label)' no longer exists, but an edge to '\(targetName)' still uses it — that branch will never run. Reconnect it to one of: \(ports.map { $0.isEmpty ? "(default)" : $0 }.joined(separator: ", "))."
            ))
        }

        // --- Per-Node Checks ---

        for node in layout.nodes {
            switch node.kind {
            case .profile(let profileID, _):
                validateProfileNode(node: node, profileID: profileID, profileMap: profileMap, issues: &issues)

            case .condition(let config):
                validateConditionNode(node: node, config: config, writtenVariables: writtenVariables, edges: layout.edges, issues: &issues)

            case .gate(let config):
                validateGateNode(node: node, config: config, issues: &issues)

            case .code(let config):
                validateCodeNode(node: node, config: config, issues: &issues)

            case .action(let config):
                validateActionNode(node: node, config: config, availableToolSources: availableToolSources, issues: &issues)

            case .trigger:
                break // Trigger nodes have no user-configurable fields to validate
            }
        }

        // Sort: errors first, then warnings, preserving layout order within each group
        return issues.sorted { $0.severity < $1.severity }
    }

    // MARK: - Connectivity

    /// Weakly-connected components (edge direction ignored — a pipeline is one group whether its
    /// nodes fan in or out). Union-find over the node set; every node lands in exactly one group.
    private static func connectedComponents(layout: WorkflowLayout) -> [[UUID]] {
        var parent: [UUID: UUID] = [:]
        for node in layout.nodes { parent[node.id] = node.id }

        func find(_ id: UUID) -> UUID {
            var root = id
            while let p = parent[root], p != root { root = p }
            // Path compression keeps this near-linear on big canvases.
            var cursor = id
            while let p = parent[cursor], p != root {
                parent[cursor] = root
                cursor = p
            }
            return root
        }

        for edge in layout.edges {
            // Ignore edges pointing at nodes that no longer exist — the same tolerance
            // `computeExecutionLevels` applies, so a dangling edge can't invent a phantom group.
            guard parent[edge.sourceNodeID] != nil, parent[edge.targetNodeID] != nil else { continue }
            let a = find(edge.sourceNodeID), b = find(edge.targetNodeID)
            if a != b { parent[a] = b }
        }

        return Dictionary(grouping: layout.nodes.map(\.id), by: { find($0) })
            .values.map { $0 }
    }

    // MARK: - Profile Node

    private static func validateProfileNode(
        node: WorkflowNode,
        profileID: UUID,
        profileMap: [UUID: BackendProfileModel],
        issues: inout [WorkflowValidationIssue]
    ) {
        // Profile existence check
        if profileMap[profileID] == nil {
            issues.append(WorkflowValidationIssue(
                nodeID: node.id,
                nodeName: node.displayName,
                severity: .error,
                message: "Profile not found — it may have been deleted."
            ))
        }

        // An ImageGen profile cannot run as a workflow node at all.
        //
        // `BackendOrchestrationService` dispatches imageGen through its own path — "imageGen never
        // dispatches through AgentConnect" — and `streamWorkflowNodeResponse`'s
        // `case .workflow, .imageGen` arm yields an error and finishes. Until the executor was
        // taught to treat that shape as a failure, such a node reported success with empty output.
        // Now it fails honestly at run time; saying so HERE means the user finds out when they add
        // the node, not after a run that silently produced nothing. Deleting the node clears it.
        if case .profile(_, .imageGen) = node.kind {
            issues.append(WorkflowValidationIssue(
                nodeID: node.id,
                nodeName: node.displayName,
                severity: .error,
                message: "Image generation profiles can't be used as a workflow step — they run through a separate pipeline. Remove this node."
            ))
            return
        }

        // Task description is mandatory for workflow execution — EXCEPT for a node backed by a
        // workflow profile, which runs as a nested sub-workflow: its steps come from that
        // workflow's own canvas and its directive is the upstream output, so there is no
        // per-node task to write.
        //
        // ⚠️ Requiring it here is what made adding a sub-workflow node brick the whole workflow.
        // The error told the user to "Double-click to configure", the double-click handler
        // excluded exactly this node type, and `targetConfigNode` has no other writer — so the
        // blocking error was unfixable from the app and every later Run threw `validationFailed`
        // before a single node executed.
        if case .profile(_, .workflow) = node.kind { return }

        let taskDescription = node.nodeConfig?.taskDescription ?? ""
        if taskDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(WorkflowValidationIssue(
                nodeID: node.id,
                nodeName: node.displayName,
                severity: .error,
                message: "Task description is required. Double-click to configure."
            ))
        }
    }

    // MARK: - Condition Node

    private static func validateConditionNode(
        node: WorkflowNode,
        config: ConditionNodeConfig,
        writtenVariables: Set<String>,
        /// Needed only to tell whether this Router's `error` port is wired — see the Ask-fallback
        /// warning at the bottom.
        edges: [WorkflowEdge],
        issues: inout [WorkflowValidationIssue]
    ) {
        // Rule count
        if config.rules.count < ConditionNodeConfig.minRules {
            issues.append(WorkflowValidationIssue(
                nodeID: node.id,
                nodeName: node.displayName,
                severity: .error,
                message: "Requires at least \(ConditionNodeConfig.minRules) pattern rules."
            ))
        }

        // Per-rule validation
        var seenLabels = Set<String>()
        for rule in config.rules {
            // Label validity
            if !ConditionNodeConfig.isValidLabel(rule.label) {
                issues.append(WorkflowValidationIssue(
                    nodeID: node.id,
                    nodeName: node.displayName,
                    severity: .error,
                    message: "Rule label '\(rule.label)' is invalid (alphanumeric, max 10 chars)."
                ))
            }

            // Duplicate labels
            if seenLabels.contains(rule.label) {
                issues.append(WorkflowValidationIssue(
                    nodeID: node.id,
                    nodeName: node.displayName,
                    severity: .error,
                    message: "Duplicate rule label '\(rule.label)'."
                ))
            }
            seenLabels.insert(rule.label)

            // Collision with the reserved failure port (WF61 added `error` to every kind's port
            // list). ⚠️ WARNING, not error: a workflow authored before the reserved port existed may
            // already carry a rule named "error", and hard-blocking it would trade a confusing port
            // for a workflow that will not start — the same call as the dangling-port rule.
            // `outputPortLabels` de-duplicates, so the canvas draws one port; what the user loses is
            // the ability to tell a rule match from a failure, since both activate the same label.
            if rule.label.caseInsensitiveCompare(WorkflowEdge.errorPortLabel) == .orderedSame {
                issues.append(WorkflowValidationIssue(
                    nodeID: node.id,
                    nodeName: node.displayName,
                    severity: .warning,
                    message: "Rule label '\(rule.label)' collides with the reserved failure port — a match and a failure will both route to it. Rename the rule."
                ))
            }

            // Rules on field `.variable` — the two silent-empty-string traps (WF-VA5).
            //
            // The ENGINE reads a missing variable as "" with no log, so a rule on a blank or
            // never-written name either matches every input forever (isEmpty / notContains /
            // notEquals) or fails every run (contains / equals) — and the user debugs the rule's
            // VALUE, because nothing says the variable did not exist.
            if rule.field == .variable {
                let name = (rule.variableName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if name.isEmpty {
                    // ERROR: there is no reading of "compare against the variable named nothing"
                    // that the user meant.
                    issues.append(WorkflowValidationIssue(
                        nodeID: node.id,
                        nodeName: node.displayName,
                        severity: .error,
                        message: "Rule '\(rule.label)' reads a workflow variable but no variable name is set. Pick the variable in the rule editor."
                    ))
                } else if !writtenVariables.contains(name) {
                    // WARNING, not error: the graph still runs, and the set of writers is derived
                    // from THIS canvas — a deliberately exotic setup should not be hard-blocked.
                    issues.append(WorkflowValidationIssue(
                        nodeID: node.id,
                        nodeName: node.displayName,
                        severity: .warning,
                        message: "Rule '\(rule.label)' reads variable '\(name)', but no Code node on this canvas writes it — the rule will compare against an empty string every run."
                    ))
                }
            }

            // A rule this build cannot evaluate — an op or field written by a NEWER version and
            // preserved verbatim by the raw-preserving catch-alls (WF-PE3). The engine treats such
            // a rule as inert (never matches), so say so HERE, at design time, with the remedy.
            // ⚠️ "always" is EXCLUDED here: it is not a newer build's operator but a RETIRED one
            // (hard-deleted 2026-08-16), and it gets its own non-blocking WARNING below. Treating
            // it as this generic case did two wrong things at once — BLOCKED every old catch-all
            // workflow from running at all, and told the user to "Update Devgentic", pointing in
            // exactly the wrong direction for an operator no future build will ever bring back.
            if case .other(let raw) = rule.op, raw != "always" {
                issues.append(WorkflowValidationIssue(
                    nodeID: node.id,
                    nodeName: node.displayName,
                    severity: .error,
                    message: "Rule '\(rule.label)' uses the operator '\(raw)', which this version of Devgentic doesn't recognise — it was saved by a newer version. The rule will never match here. Update Devgentic, or edit the rule."
                ))
            }
            if case .other(let raw) = rule.field {
                issues.append(WorkflowValidationIssue(
                    nodeID: node.id,
                    nodeName: node.displayName,
                    severity: .error,
                    message: "Rule '\(rule.label)' reads the field '\(raw)', which this version of Devgentic doesn't recognise — it was saved by a newer version. The rule will never match here. Update Devgentic, or edit the rule."
                ))
            }

            // Empty match value for value-requiring operators
            let requiresValue: Bool = {
                switch rule.op {
                case .contains, .notContains, .equals, .notEquals: return true
                case .isEmpty, .isNotEmpty: return false
                // Flagged as an error above; it needs no match value on top of that.
                case .other: return false
                }
            }()
            if requiresValue && rule.value.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(WorkflowValidationIssue(
                    nodeID: node.id,
                    nodeName: node.displayName,
                    severity: .error,
                    message: "Rule '\(rule.label)' requires a match value for '\(rule.op.displayName)'."
                ))
            }
        }

        // AI Classifier checks
        if config.llmFallbackEnabled {
            if config.llmModelName == nil || config.llmModelName?.isEmpty == true {
                issues.append(WorkflowValidationIssue(
                    nodeID: node.id,
                    nodeName: node.displayName,
                    severity: .error,
                    message: "AI Classifier enabled but no MLX model selected."
                ))
            }
            if config.llmPrompt.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(WorkflowValidationIssue(
                    nodeID: node.id,
                    nodeName: node.displayName,
                    severity: .warning,
                    message: "AI Classifier enabled but routing prompt is empty."
                ))
            }
        }

        // P0-7: `fallbackLabel` must point to an actual rule label.
        // If the user renames a rule after creation without updating
        // `fallbackLabel`, the executor activates a port no downstream
        // edge subscribes to — silent dead-end at run time.
        let ruleLabels = Set(config.rules.map(\.label))
        // ⚠️ The `always` operator was HARD-DELETED 2026-08-16; a stored "always" decodes to
        // `.other("always")` and NEVER MATCHES on this build. That is a behaviour change for old
        // catch-all workflows, so it is called out specifically — the generic newer-version-operator
        // wording ("update Devgentic") would send the user in exactly the wrong direction.
        for rule in config.rules where rule.op == ConditionOp.other("always") {
            issues.append(WorkflowValidationIssue(
                nodeID: node.id,
                nodeName: node.displayName,
                severity: .warning,
                message: "Rule '\(rule.label)' uses the retired 'always matches' operator and now never matches. Delete the rule and use the Router's 'When Nothing Matches' option instead — it replaces the catch-all rule."
            ))
        }

        // The no-match default must point at a rule that still exists. The target is stored by the
        // rule's STABLE ID (renames are safe); only deletion can break it, and that must surface at
        // design time — at run time the executor fails the node rather than guess.
        // ⚠️ The LEGACY setting — checked only when no policy governs, or a migrated node would be
        // flagged for a stale value the engine no longer reads.
        if config.decisionPolicy == nil,
           case .route(let ruleID) = config.noMatchBehavior,
           !config.rules.contains(where: { $0.id == ruleID }) {
            issues.append(WorkflowValidationIssue(
                nodeID: node.id,
                nodeName: node.displayName,
                severity: .error,
                message: "The 'When Nothing Matches' route points at a rule that was deleted. Re-pick a default route in the Router inspector."
            ))
        }

        // The unified routing policy's route target must point at a rule that still exists — the
        // same contract, on the setting that replaced it (2026-08-17). Stored by STABLE ID, so
        // renames are safe and only deletion can break it; at run time the executor fails the node
        // rather than guess, so this must surface at design time.
        if let policy = config.decisionPolicy {
            let danglingTarget: UUID?
            switch policy {
            case .route(let ruleID):
                danglingTarget = config.rules.contains { $0.id == ruleID } ? nil : ruleID
            case .ask(.route(let ruleID)):
                danglingTarget = config.rules.contains { $0.id == ruleID } ? nil : ruleID
            case .ask, .endBranch, .failNode:
                danglingTarget = nil
            }
            if danglingTarget != nil {
                issues.append(WorkflowValidationIssue(
                    nodeID: node.id,
                    nodeName: node.displayName,
                    severity: .error,
                    message: "The Router's 'When Routing Can't Decide' route points at a rule that was deleted. Re-pick it in the Router inspector."
                ))
            }

            // ⚠️ WARNING, never an error — the graph is legal and it runs. An author who picks
            // "Ask me which branch" on a Router with no `error` port wired, and leaves the fallback
            // at Fail, gets a branch that simply stops on any undecided input in a scheduled run.
            // Worth saying once; not worth blocking.
            if case .ask(.failNode) = policy,
               !edges.contains(where: { $0.sourceNodeID == node.id && $0.sourcePortLabel == WorkflowEdge.errorPortLabel }) {
                issues.append(WorkflowValidationIssue(
                    nodeID: node.id,
                    nodeName: node.displayName,
                    severity: .warning,
                    message: "This Router asks you to choose, and falls back to failing when nobody can answer — but its error port is not wired. On a scheduled or chat-bridge run, undecided input will stop this branch with no handler. Wire the error port, or pick a different fallback."
                ))
            }
        }

        if !config.fallbackLabel.isEmpty, !ruleLabels.contains(config.fallbackLabel) {
            issues.append(WorkflowValidationIssue(
                nodeID: node.id,
                nodeName: node.displayName,
                severity: .error,
                message: "Fallback label '\(config.fallbackLabel)' doesn't match any rule label — downstream routing will dead-end."
            ))
        }
    }

    // MARK: - Gate Node

    private static func validateGateNode(
        node: WorkflowNode,
        config: GateNodeConfig,
        issues: inout [WorkflowValidationIssue]
    ) {
        // [E1] Each option is an output port matched by exact string. Trim + de-dup so blanks/duplicates
        // don't silently collapse into one routing port (where a single choice would fire two branches).
        let trimmedOptions = config.options.map { $0.trimmingCharacters(in: .whitespaces) }
        let nonBlank = trimmedOptions.filter { !$0.isEmpty }
        if nonBlank.count < 2 {
            issues.append(WorkflowValidationIssue(
                nodeID: node.id,
                nodeName: node.displayName,
                severity: .error,
                message: "Gate requires at least 2 non-empty options."
            ))
        }
        if Set(nonBlank).count != nonBlank.count {
            issues.append(WorkflowValidationIssue(
                nodeID: node.id,
                nodeName: node.displayName,
                severity: .warning,
                message: "Gate has duplicate option labels — duplicates share one output port, so a choice routes both branches."
            ))
        }
        if config.prompt.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(WorkflowValidationIssue(
                nodeID: node.id,
                nodeName: node.displayName,
                severity: .warning,
                message: "Gate prompt is empty — users won't know what to approve."
            ))
        }
    }

    // MARK: - Code Node

    private static func validateCodeNode(
        node: WorkflowNode,
        config: CodeNodeConfig,
        issues: inout [WorkflowValidationIssue]
    ) {
        if config.template.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(WorkflowValidationIssue(
                nodeID: node.id,
                nodeName: node.displayName,
                severity: .warning,
                message: "Code template is empty — node will produce no output."
            ))
        }
    }

    // MARK: - Action Node

    /// Fixed source id for built-in (native) tools — always resolvable, never
    /// "offline". Mirrors `UnifiedToolStore`'s native source id.
    /// The canonical constant, NOT a re-spelled literal. Three copies of this UUID existed
    /// (here, `CodeToolPreset`, and the canonical `ToolSource.builtInSourceID`); if the canonical
    /// id ever changed, every Action node bound to a native tool would gain a spurious
    /// "MCP server may be offline" warning while running fine — and nothing at build or test time
    /// would notice the drift.
    private static let nativeToolSourceID = ToolSource.builtInSourceID

    private static func validateActionNode(
        node: WorkflowNode,
        config: ActionNodeConfig,
        availableToolSources: [ToolSource],
        issues: inout [WorkflowValidationIssue]
    ) {
        guard let tool = config.tool else {
            issues.append(WorkflowValidationIssue(
                nodeID: node.id,
                nodeName: node.displayName,
                severity: .error,
                message: "Action node has no tool selected."
            ))
            return
        }

        // Every required argument must have a non-empty binding, otherwise the
        // tool call will fail to decode at run time.
        let boundKeys = Set(config.argumentBindings.filter {
            !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.keys)
        let missing = tool.parameters.required.filter { !boundKeys.contains($0) }
        if !missing.isEmpty {
            issues.append(WorkflowValidationIssue(
                nodeID: node.id,
                nodeName: node.displayName,
                severity: .error,
                message: "Tool '\(tool.name)' is missing required argument(s): \(missing.sorted().joined(separator: ", "))."
            ))
        }

        // Availability check for MCP tools — warn (not error) when the tool's
        // server isn't currently in the catalog, so the user learns at design
        // time rather than at run time. Native tools are always resolvable, and
        // we skip the check entirely when no catalog was supplied.
        if tool.sourceId != nativeToolSourceID, !availableToolSources.isEmpty {
            let present = availableToolSources.contains { source in
                source.id == tool.sourceId && source.tools.contains { $0.name == tool.name }
            }
            if !present {
                issues.append(WorkflowValidationIssue(
                    nodeID: node.id,
                    nodeName: node.displayName,
                    severity: .warning,
                    message: "Tool '\(tool.name)' isn't currently available — its MCP server may be offline or the tool was removed. The action will fail at run time unless it reconnects."
                ))
            }
        }
    }

    // MARK: - Sub-workflow nesting

    /// A Profile node can point at a WORKFLOW — so running it
    /// runs a whole nested workflow, which can contain another. Three things go wrong with that,
    /// and all are pure graph properties that belong at design time rather than as a runtime
    /// failure five levels in:
    ///
    /// 1. **A cycle** (A contains B, B contains A) is infinite by construction.
    /// 2. **A chain longer than the engine allows** fails partway through, after the outer levels
    ///    have already run and spent tokens.
    /// 3. **A reference to an EMPTY (or unreadable, or deleted) canvas** fails the child run the
    ///    moment it starts — same partway-through waste.
    ///
    /// ⚠️ Reports nothing when `subWorkflowLayouts` is empty — the caller did not resolve them, so
    /// there is nothing to walk. Silence here means "not checked", never "checked and clean".
    ///
    /// ⚠️ The runtime counter in `WorkflowDepth` is deliberately KEPT as a backstop. Validating A
    /// can be invalidated by editing B: A → B is fine today, and tomorrow B grows a chain of its own
    /// while A's canvas is not even open. Pre-flight re-validation catches that on the next run, but
    /// the counter costs one integer and is the last defence against unbounded recursion.
    private static func validateNesting(
        layout: WorkflowLayout,
        subWorkflowLayouts: [UUID: WorkflowLayout],
        rootProfileID: UUID?,
        issues: inout [WorkflowValidationIssue]
    ) {
        guard !subWorkflowLayouts.isEmpty else { return }

        /// Edges out of one workflow — DELEGATED to the one shared extractor. This used to be a
        /// private twin of `WorkflowLayoutStore.subWorkflowProfileIDs` and the two drifted the same
        /// way at the same time (both missed the since-retired Loop node's body reference). Same
        /// lesson as `edgeIsLive`: two implementations of one question WILL disagree eventually —
        /// delegate, don't copy.
        func references(of layout: WorkflowLayout) -> [(profileID: UUID, nodeName: String)] {
            WorkflowLayoutStore.workflowReferences(in: layout)
        }

        let rootKey = rootProfileID ?? UUID()
        var graph: [UUID: [(profileID: UUID, nodeName: String)]] = [rootKey: references(of: layout)]
        for (id, sub) in subWorkflowLayouts { graph[id] = references(of: sub) }

        // A referenced workflow whose canvas is EMPTY fails the child run the moment it starts
        // (`WorkflowError.emptyWorkflow`) — after the outer levels have already run and spent
        // tokens. `load(for:)` deliberately returns `.empty` for a missing row, an unreadable blob
        // AND a genuinely empty canvas, so this one check covers all three; the precise diagnosis
        // (e.g. the unreadable-layout overlay) lives on that workflow's own canvas.
        var reportedEmptyTargets = Set<UUID>()
        for (_, refs) in graph {
            for ref in refs where subWorkflowLayouts[ref.profileID]?.nodes.isEmpty == true {
                guard reportedEmptyTargets.insert(ref.profileID).inserted else { continue }
                issues.append(WorkflowValidationIssue(
                    nodeName: ref.nodeName,
                    severity: .error,
                    message: "'\(ref.nodeName)' runs a workflow whose canvas is empty (or could not be read) — it would fail the moment it starts, after everything before it has already run. Open that workflow and add nodes, or remove this node."
                ))
            }
        }

        var deepestChain: [String] = []
        var reportedCycles = Set<String>()

        /// DFS carrying the path, so a repeat ON THE CURRENT PATH is a cycle (a repeat elsewhere is
        /// just a workflow used twice, which is fine).
        ///
        /// ⚠️ `path.count` is a HARD RECURSION BOUND, independent of the cycle check above it. If the
        /// `onPath` logic is ever wrong, a cyclic graph would recurse until the stack overflows and
        /// takes the app down — and validation runs on every canvas edit, so that would be a crash
        /// while typing. Found by mutation-testing: disabling the cycle check did not fail the
        /// tests, it CRASHED the test runner, and the summary line still read "0 failures".
        ///
        /// The bound is generous (well past any limit worth reporting) so it never masks a real
        /// finding — it exists only to make a bug degrade instead of crash.
        let recursionBound = max(WorkflowDepth.maxDepth, 8) * 4

        func walk(_ id: UUID, path: [String], onPath: Set<UUID>) {
            if path.count > deepestChain.count { deepestChain = path }
            guard path.count < recursionBound else { return }

            for ref in graph[id] ?? [] {
                if onPath.contains(ref.profileID) {
                    let cycle = (path + [ref.nodeName]).joined(separator: " → ")
                    guard reportedCycles.insert(cycle).inserted else { continue }
                    issues.append(WorkflowValidationIssue(
                        nodeName: "Workflow",
                        severity: .error,
                        message: "Sub-workflow loop: \(cycle) — this workflow ends up running itself, which would never finish. Remove one of those workflow nodes."
                    ))
                    continue
                }
                walk(ref.profileID, path: path + [ref.nodeName], onPath: onPath.union([ref.profileID]))
            }
        }

        walk(rootKey, path: ["This workflow"], onPath: [rootKey])

        // ⚠️ `deepestChain` counts THIS workflow as level 1, matching the runtime counter, which is
        // incremented before its guard. A limit of N means this workflow plus N-1 nested levels.
        if deepestChain.count > WorkflowDepth.maxDepth {
            issues.append(WorkflowValidationIssue(
                nodeName: "Workflow",
                severity: .error,
                message: "Sub-workflows nest \(deepestChain.count) levels deep, and the limit is \(WorkflowDepth.maxDepth): \(deepestChain.joined(separator: " → ")). Flatten one of these into its parent."
            ))
        }
    }
}
