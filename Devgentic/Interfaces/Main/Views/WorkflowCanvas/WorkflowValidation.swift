// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowValidation.swift
//  Devgentic
//
//  Created by Raj Singh.
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

    // Why: shared with ProfileNodeInspectorView so the panel, pill and inspector card cannot drift apart
    /// The message shown when a node's backing configuration cannot be resolved.
    /// Names a remedy: re-adding the node repairs a bot or agent node, which owns its configuration.
    static let missingConfigurationMessage =
        "This node's configuration is missing. Delete it and add the node again."

    // Why: shared with ProfileNodeInspectorView so the validator and the inspector give the same advice
    /// The message for a sub-workflow node whose referenced workflow is gone.
    /// Does not advise delete-and-re-add: the node's profileID is the only record of which child workflow it ran.
    static let missingWorkflowMessage =
        "The workflow this node runs no longer exists. Point this step at another workflow, or delete the node."


    /// Validates a workflow layout and returns all configuration issues.
    /// - Parameters:
    ///   - layout: The workflow's node/edge graph.
    ///   - profileMap: Available profiles keyed by UUID (for checking profile existence).
    /// - Returns: Issues sorted by severity (errors first), then by layout order.
    static func validate(
        layout: WorkflowLayout,
        profileMap: [UUID: BackendProfileModel],
        // Current tool catalog (native + connected MCP), for warning when an Action node references an offline or removed
        // MCP server's tool. Empty skips the availability checks.
        availableToolSources: [ToolSource] = [],
        // Why: the caller resolves these so validation stays pure and synchronous; it re-runs on every canvas edit
        // Every layout reachable through sub-workflow nodes, keyed by workflow profile ID. Empty skips the nesting/cycle checks.
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

        // Why: a warning, never an error: the executor refuses to run any error-severity issue; keep the switch exhaustive
        // Flags a canvas on which nothing produces new content: Router, Gate and Trigger only forward the upstream text,
        // so the run would hand back the user's own message.
        let producesNewContent = layout.nodes.contains { node in
            switch node.kind {
            case .profile, .code, .action:                  return true
            case .condition, .gate, .trigger, .unsupported: return false
            }
        }
        if !producesNewContent {
            issues.append(WorkflowValidationIssue(
                nodeName: "Workflow",
                severity: .warning,
                message: "No node on this canvas produces new content — Router, Gate and Trigger nodes only pass their input along, so this workflow will answer with your own message. Add a Profile, Code or Action node."
            ))
        }

        // Flags Code nodes writing the same variable on the same execution level, which run in parallel and race.
        // Different levels run sequentially; if levels cannot be computed (cycle), any duplicate is flagged.
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
        // The set of variable names any node can write: only Code-node `outputVariable` feeds the engine's variable store.
        let writtenVariables = Set(outputVariableOwners.keys)
        // Execution level of every writer, per variable; input to `WorkflowVariableVisibility.resolve`.
        let variableWriterLevels: [String: [Int]] = outputVariableOwners.mapValues { $0.map(\.level) }

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

        // Why: a warning, never an error: the executor throws only on error severity, and a backend label must not gate a run
        // Same-level MLX contention: MLXService keeps one model container resident, and the engine runs same-level MLX nodes
        // in separate lanes, so any two same-level MLX nodes are flagged. Silent on a cyclic layout (no levels).
        typealias MLXDemand = (nodeID: UUID, displayName: String, level: Int, model: String, slot: String)
        var mlxProfileDemands: [MLXDemand] = []
        for node in layout.nodes {
            guard let level = nodeLevel[node.id] else { continue }
            switch node.kind {
            case .profile(let profileID, let profileType):
                // `.workflow` nodes run a child executor and are covered by the structural pool below.
                guard profileType != .workflow,
                      let profile = profileMap[profileID],
                      let config = profile.resolvedLLMConfig,
                      // Uses the runtime's own slot function so this rule and `WorkflowExecutor.profileDispatchLanes` agree on contention.
                      let slot = WorkflowExecutor.mlxSlotKey(for: profile) else { continue }
                mlxProfileDemands.append((node.id, node.displayName, level,
                                          config.modelName.trimmingCharacters(in: .whitespacesAndNewlines), slot))

            case .unsupported, .condition, .code, .gate, .trigger, .action:
                // Handled by the structural pool below (`.condition`) or MLX-inert. Exhaustive so a new node kind must be decided here.
                continue
            }
        }

        let mlxPools: [(demands: [MLXDemand], body: (String, String) -> String)] = [
            (mlxProfileDemands, { model, others in
                "Runs the local MLX model '\(model)' on the same step as \(others). Only one MLX model stays in memory and it generates one request at a time, so the engine runs these one after another instead of in parallel — this step takes as long as the nodes combined."
            })
        ]
        for pool in mlxPools {
            for (_, sameLevel) in Dictionary(grouping: pool.demands, by: { $0.level })
            where sameLevel.count > 1 {
                for demand in sameLevel {
                    let others = sameLevel
                        .filter { $0.nodeID != demand.nodeID }
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

        // Same-level structural MLX contention: Router fallback calls and nested sub-workflows share the structural task group,
        // partitioned by `WorkflowExecutor.structuralDispatchLanes`, which this rule reuses so the two cannot disagree.
        struct StructuralMLXDescriptor { let displayName: String; let model: String?; let isSubWorkflow: Bool }
        var structuralDescriptorByNodeID: [UUID: StructuralMLXDescriptor] = [:]
        var structuralNodesByLevel: [Int: [WorkflowNode]] = [:]
        for node in layout.nodes {
            guard let level = nodeLevel[node.id] else { continue }
            switch node.kind {
            case .profile(_, let profileType) where profileType == .workflow:
                structuralNodesByLevel[level, default: []].append(node)
                structuralDescriptorByNodeID[node.id] = StructuralMLXDescriptor(
                    displayName: node.displayName, model: nil, isSubWorkflow: true
                )
            case .condition(let config):
                structuralNodesByLevel[level, default: []].append(node)
                // Mirrors `WorkflowExecutor.mlxSlotKey(modelName:)`'s emptiness check: a fallback Router with a blank model name
                // has no slot at runtime, so it gets no descriptor here.
                let trimmedModel = (config.llmModelName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if config.llmFallbackEnabled, !trimmedModel.isEmpty {
                    structuralDescriptorByNodeID[node.id] = StructuralMLXDescriptor(
                        displayName: node.displayName,
                        model: trimmedModel,
                        isSubWorkflow: false
                    )
                }
            case .code, .gate, .trigger, .action, .unsupported:
                structuralNodesByLevel[level, default: []].append(node)
            case .profile:
                continue
            }
        }
        for (_, nodesAtLevel) in structuralNodesByLevel {
            let lanes = WorkflowExecutor.structuralDispatchLanes(nodesAtLevel)
            guard lanes.count > 1 else { continue }
            // Filters by descriptor presence, not lane slot: every lane past the first has a slot, so a lane filter would not
            // exclude a node that rode along into lane 0.
            let contenders = lanes.flatMap(\.members).filter { structuralDescriptorByNodeID[$0.id] != nil }
            guard contenders.count > 1 else { continue }
            for node in contenders {
                guard let descriptor = structuralDescriptorByNodeID[node.id] else { continue }
                let others = contenders
                    .filter { $0.id != node.id }
                    .compactMap { structuralDescriptorByNodeID[$0.id] }
                    .sorted { $0.displayName < $1.displayName }
                    .map { other in
                        other.isSubWorkflow
                            ? "'\(other.displayName)' (nested sub-workflow)"
                            : "'\(other.displayName)' (\(other.model ?? "?"))"
                    }
                    .joined(separator: ", ")
                guard !others.isEmpty else { continue }
                let message = descriptor.isSubWorkflow
                    ? "Only one MLX model stays in memory, and this nested sub-workflow can independently reach it on the same step as \(others). Devgentic can't see which model(s) a sub-workflow uses at design time, so it always runs same-step sub-workflows — and same-step AI Classifiers — one after another instead of in parallel, to stay safe. This step now takes as long as all of them combined."
                    : "Its AI Classifier runs the local MLX model '\(descriptor.model ?? "")' on the same step as \(others). Only one MLX model stays in memory and it generates one request at a time, so the engine now runs these one after another instead of in parallel — this step takes as long as all of them combined."
                issues.append(WorkflowValidationIssue(
                    nodeID: node.id,
                    nodeName: node.displayName,
                    severity: .warning,
                    message: message
                ))
            }
        }

        // Disconnected pipelines: two clusters with edges but no path between them run in parallel and share one answer.
        // Multiple entry nodes are legitimate and not flagged. A warning, not an error.
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

        // Dangling output ports: an edge whose source port label is not among the node's ports never fires, so its
        // downstream branch is skipped while the canvas still draws the edge. A warning, not an error.
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
                validateConditionNode(node: node, config: config, writtenVariables: writtenVariables, readerLevel: nodeLevel[node.id], variableWriterLevels: variableWriterLevels, edges: layout.edges, issues: &issues)

            case .gate(let config):
                validateGateNode(node: node, config: config, issues: &issues)

            case .code(let config):
                // Passes `nodeLevel[node.id]` as nil on a cyclic layout (no levels): ordering is unknown and no verdict is given.
                validateCodeNode(node: node, config: config, writtenVariables: writtenVariables, readerLevel: nodeLevel[node.id], variableWriterLevels: variableWriterLevels, issues: &issues)

            case .action(let config):
                validateActionNode(node: node, config: config, availableToolSources: availableToolSources, writtenVariables: writtenVariables, readerLevel: nodeLevel[node.id], variableWriterLevels: variableWriterLevels, issues: &issues)

            case .trigger:
                break // Trigger nodes have no user-configurable fields to validate

            case .unsupported:
                // Blocking: the executor refuses a node this build does not understand; this reports it before the user presses Run.
                issues.append(WorkflowValidationIssue(
                    nodeID: node.id,
                    nodeName: node.displayName,
                    severity: .error,
                    message: "'\(node.displayName)' was saved by a different version of Devgentic and cannot run on this one. The node and its connections are preserved — update Devgentic to use it, or delete it to run this workflow."
                ))
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
            // Ignores edges pointing at nodes that do not exist, as `computeExecutionLevels` does.
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
            // Guards the case where profile resolution fails wholesale (a failed fetch yields an empty map, so every profile
            // node is unresolvable). The message depends on the kind: sub-workflow nodes must not be told to delete the node.
            let isSubWorkflow: Bool = {
                if case .profile(_, .workflow) = node.kind { return true }
                return false
            }()
            issues.append(WorkflowValidationIssue(
                nodeID: node.id,
                nodeName: node.displayName,
                severity: .error,
                message: isSubWorkflow ? Self.missingWorkflowMessage : Self.missingConfigurationMessage
            ))
        }

        // An ImageGen profile cannot run as a workflow node: the dispatcher's workflow arm yields an error for it.
        // Reported at design time; deleting the node clears it.
        if case .profile(_, .imageGen) = node.kind {
            issues.append(WorkflowValidationIssue(
                nodeID: node.id,
                nodeName: node.displayName,
                severity: .error,
                message: "Image generation profiles can't be used as a workflow step — they run through a separate pipeline. Remove this node."
            ))
            return
        }

    }

    // MARK: - Condition Node

    private static func validateConditionNode(
        node: WorkflowNode,
        config: ConditionNodeConfig,
        writtenVariables: Set<String>,
        readerLevel: Int?,
        variableWriterLevels: [String: [Int]],
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

            // A rule labelled like the reserved failure port makes rule matches and failures indistinguishable.
            // A warning, not an error, so older workflows still run.
            if rule.label.caseInsensitiveCompare(WorkflowEdge.errorPortLabel) == .orderedSame {
                issues.append(WorkflowValidationIssue(
                    nodeID: node.id,
                    nodeName: node.displayName,
                    severity: .warning,
                    message: "Rule label '\(rule.label)' collides with the reserved failure port — a match and a failure will both route to it. Rename the rule."
                ))
            }

            // Rules on `.variable`: the engine reads a missing variable as an empty string without logging, so a rule on a
            // blank or never-written name matches everything or fails every run.
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
                } else {
                    // Uses the shared variable verdict with the rule's single stored name as the only candidate (no dot-path fallback).
                    // A same-level write lands after the level finishes, so the rule compares against an empty string. A warning only.
                    let verdict = variableReferenceVerdict(
                        candidates: [name], writtenVariables: writtenVariables,
                        readerLevel: readerLevel, variableWriterLevels: variableWriterLevels
                    )
                    if let message = variableReferenceMessage(
                        verdict: verdict, site: .routerRule(label: rule.label),
                        typedName: name, readerLevel: readerLevel
                    ) {
                        issues.append(WorkflowValidationIssue(
                            nodeID: node.id,
                            nodeName: node.displayName,
                            severity: .warning,
                            message: message
                        ))
                    }
                }
            }

            // A rule with an op or field this build cannot evaluate is inert (never matches); this says so at design time.
            if case .other(let raw) = rule.op {
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

        // The routing policy's route target must point at an existing rule; it is stored by stable ID so only deletion
        // breaks it, and the executor fails the node at run time rather than guess.
        do {
            let policy = config.decisionPolicy
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

            // Warns, never errors: an "Ask me" Router with no error port wired and a Fail fallback stops the branch on
            // any undecided input in a scheduled run.
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

    /// Where a `{{ var.… }}` reference was read, which decides how the consequence reads.
    /// Surfaces share the verdict but not the sentence: a Router rule has no placeholder text.
    enum VariableReferenceSite: Equatable {
        case routerRule(label: String)
        case codeTemplate
        case actionArgument(name: String)

        var subject: String {
            switch self {
            case .routerRule(let label): return "Rule '\(label)'"
            case .codeTemplate: return "The template"
            case .actionArgument(let name): return "Argument '\(name)'"
            }
        }

        /// What the user actually gets when the read resolves to nothing, per surface.
        var emptyReadConsequence: String {
            switch self {
            case .routerRule:
                return "it is compared as an empty string every run, so 'is empty'/'does not contain'/'does not equal' match unconditionally and 'equals'/'contains' never match"
            case .codeTemplate:
                return "it resolves to nothing and the literal placeholder text is left in this node's output"
            case .actionArgument:
                return "it resolves to nothing and the tool receives the literal placeholder text"
            }
        }
    }

    /// What is wrong with ONE `{{ var.… }}` reference, or nothing (register EXA-10).
    enum VariableReferenceVerdict: Equatable {
        case ok
        /// No Code node on this canvas writes any of the candidate names.
        case neverWritten
        /// A writer exists but never runs early enough to be seen — `EXA-5`'s shape. Carries the
        /// candidate the verdict is ABOUT, so the message cannot name a different one.
        case writtenTooLate(name: String, earliestWriterLevel: Int)
    }

    /// The verdict for a variable reference, shared by Router rules, Code templates and Action bindings.
    /// Mirrors the resolver's runtime selection: any candidate visible from an earlier level makes the reference fine.
    /// A nil `readerLevel` (cyclic layout) yields no verdict; the check is deliberately conservative.
    nonisolated static func variableReferenceVerdict(
        candidates: [String],
        writtenVariables: Set<String>,
        readerLevel: Int?,
        variableWriterLevels: [String: [Int]]
    ) -> VariableReferenceVerdict {
        guard !candidates.isEmpty else { return .ok }
        let written = candidates.filter(writtenVariables.contains)
        guard !written.isEmpty else { return .neverWritten }
        guard let readerLevel else { return .ok }

        // The resolver reads whichever candidate is actually THERE, so one visible candidate is
        // enough for the reference to work.
        var earliest: (name: String, level: Int)?
        for name in written {
            switch WorkflowVariableVisibility.resolve(
                readerLevel: readerLevel, writerLevels: variableWriterLevels[name] ?? []
            ) {
            case .visible:
                return .ok
            case .writtenTooLate(let level):
                if earliest == nil || level < earliest!.level { earliest = (name, level) }
            case .neverWritten:
                continue
            }
        }
        // Report the candidate CLOSEST to working — its name and its own level, never one name's
        // level under another name's label.
        guard let earliest else { return .neverWritten }
        return .writtenTooLate(name: earliest.name, earliestWriterLevel: earliest.level)
    }

    /// The sentence a verdict produces, with the consequence supplied per surface (see `VariableReferenceSite`).
    /// `.writtenTooLate` names the candidate the verdict matched, not the text the user typed.
    nonisolated static func variableReferenceMessage(
        verdict: VariableReferenceVerdict, site: VariableReferenceSite,
        typedName: String, readerLevel: Int?
    ) -> String? {
        switch verdict {
        case .ok:
            return nil
        case .neverWritten:
            return "\(site.subject) reads variable '\(typedName)', but no Code node on this canvas writes it — \(site.emptyReadConsequence)."
        case .writtenTooLate(let name, let writerLevel):
            let timing = writerLevel == readerLevel ? "at the same time as this node" : "after this node"
            return "\(site.subject) reads variable '\(name)', but the Code node that writes it runs \(timing) — so \(site.emptyReadConsequence) on every run. Wire the writing Code node upstream of this one."
        }
    }

    /// Every distinct variable reference in one template or binding, in first-appearance order.
    /// De-duplicated per site so a repeated reference yields one row.
    nonisolated static func distinctVariableReferences(in text: String) -> [[String]] {
        var seen = Set<[String]>()
        return WorkflowTemplate.referencedVariableNames(in: text).filter { seen.insert($0).inserted }
    }

    private static func validateCodeNode(
        node: WorkflowNode,
        config: CodeNodeConfig,
        writtenVariables: Set<String>,
        readerLevel: Int?,
        variableWriterLevels: [String: [Int]],
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

        // Checks `{{ var.… }}` references in the template, as Router rules are checked.
        for candidates in distinctVariableReferences(in: config.template) {
            let verdict = variableReferenceVerdict(
                candidates: candidates, writtenVariables: writtenVariables,
                readerLevel: readerLevel, variableWriterLevels: variableWriterLevels
            )
            if let message = variableReferenceMessage(
                verdict: verdict, site: .codeTemplate,
                typedName: candidates[0], readerLevel: readerLevel
            ) {
                issues.append(WorkflowValidationIssue(
                    nodeID: node.id, nodeName: node.displayName,
                    severity: .warning, message: message
                ))
            }
        }
    }

    // MARK: - Action Node

    // Why: a re-spelled literal would drift silently and warn that the MCP server may be offline for native tools
    /// Source id for built-in (native) tools, which are always resolvable. Uses the canonical `ToolSource.builtInSourceID`.
    private static let nativeToolSourceID = ToolSource.builtInSourceID

    private static func validateActionNode(
        node: WorkflowNode,
        config: ActionNodeConfig,
        availableToolSources: [ToolSource],
        writtenVariables: Set<String>,
        readerLevel: Int?,
        variableWriterLevels: [String: [Int]],
        issues: inout [WorkflowValidationIssue]
    ) {
        // Applies the Code-template variable rule per argument binding, before the `guard let tool` below so it fires
        // even when no tool is chosen yet.
        for (argName, binding) in config.argumentBindings.sorted(by: { $0.key < $1.key }) {
            // Deduped PER BINDING, not per node: the same variable in two different arguments is
            // two facts the user needs, each naming its own argument.
            for candidates in distinctVariableReferences(in: binding) {
                let verdict = variableReferenceVerdict(
                    candidates: candidates, writtenVariables: writtenVariables,
                    readerLevel: readerLevel, variableWriterLevels: variableWriterLevels
                )
                if let message = variableReferenceMessage(
                    verdict: verdict, site: .actionArgument(name: argName),
                    typedName: candidates[0], readerLevel: readerLevel
                ) {
                    issues.append(WorkflowValidationIssue(
                        nodeID: node.id, nodeName: node.displayName,
                        severity: .warning, message: message
                    ))
                }
            }
        }

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

        // A built-in that needs configuration first (e.g. `web_search` with no provider). An Action node bypasses the Tool
        // Library's enable block, so this warns instead; the user may finish setup before running.
        if tool.sourceId == nativeToolSourceID, let blocker = NativeToolCatalog.setupBlocker(for: tool.name) {
            issues.append(WorkflowValidationIssue(
                nodeID: node.id,
                nodeName: node.displayName,
                severity: .warning,
                message: "Tool '\(tool.name)' needs setup — the action will fail at run time until it is configured. \(blocker)"
            ))
        }

        // Warns (not errors) when an MCP tool's server is not in the catalog; skipped when no catalog was supplied.
        if tool.sourceId != nativeToolSourceID, !availableToolSources.isEmpty {
            let source = availableToolSources.first { $0.id == tool.sourceId }
            let present = source.map { $0.tools.contains { $0.name == tool.name } } ?? false
            if !present {
                issues.append(WorkflowValidationIssue(
                    nodeID: node.id,
                    nodeName: node.displayName,
                    severity: .warning,
                    message: "Tool '\(tool.name)' isn't currently available — its MCP server may be offline or the tool was removed. The action will fail at run time unless it reconnects."
                ))
            } else if let source, !source.isEnabled {
                // A disabled server stays in the catalog with its tools, but the executor refuses a disabled source, so warn.
                issues.append(WorkflowValidationIssue(
                    nodeID: node.id,
                    nodeName: node.displayName,
                    severity: .warning,
                    message: "Tool '\(tool.name)' is on a disabled MCP server ('\(source.serverName)') — the action will fail at run time. Re-enable the server in the Tool Library to run this node."
                ))
            }
        }
    }

    // MARK: - Sub-workflow nesting

    // Why: the runtime depth counter stays as a backstop because editing a child can invalidate an already-validated parent
    /// Checks sub-workflow nesting: cycles, chains longer than the engine allows, and references to empty canvases.
    /// Reports nothing when `subWorkflowLayouts` is empty: silence means not checked.
    private static func validateNesting(
        layout: WorkflowLayout,
        subWorkflowLayouts: [UUID: WorkflowLayout],
        rootProfileID: UUID?,
        issues: inout [WorkflowValidationIssue]
    ) {
        guard !subWorkflowLayouts.isEmpty else { return }

        /// Edges out of one workflow, delegated to the shared `WorkflowLayoutStore.workflowReferences` extractor.
        func references(of layout: WorkflowLayout) -> [(profileID: UUID, nodeName: String)] {
            WorkflowLayoutStore.workflowReferences(in: layout)
        }

        let rootKey = rootProfileID ?? UUID()
        var graph: [UUID: [(profileID: UUID, nodeName: String)]] = [rootKey: references(of: layout)]
        for (id, sub) in subWorkflowLayouts { graph[id] = references(of: sub) }

        // A referenced canvas that is empty fails the child run at start (`WorkflowError.emptyWorkflow`); `load(for:)`
        // returns `.empty` for a missing row, unreadable blob or empty canvas, so one check covers all three.
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

        // Why: `path.count` is a hard recursion bound so a faulty cycle check degrades instead of overflowing the stack
        /// DFS carrying the path: a repeat on the current path is a cycle; a repeat elsewhere is just a reused workflow.
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

        // `deepestChain` counts this workflow as level 1, matching the runtime counter; a limit of N is this plus N-1 nested.
        if deepestChain.count > WorkflowDepth.maxDepth {
            issues.append(WorkflowValidationIssue(
                nodeName: "Workflow",
                severity: .error,
                message: "Sub-workflows nest \(deepestChain.count) levels deep, and the limit is \(WorkflowDepth.maxDepth): \(deepestChain.joined(separator: " → ")). Flatten one of these into its parent."
            ))
        }
    }
}
