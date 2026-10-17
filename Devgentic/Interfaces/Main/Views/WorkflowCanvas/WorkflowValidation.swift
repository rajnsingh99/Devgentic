// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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

    /// The one sentence shown when a node's backing configuration cannot be resolved.
    ///
    /// ⚠️ SHARED because it appears in TWO places — this validator's issue (the panel and the
    /// toolbar pill) and `ProfileNodeInspectorView`'s card — and they must not drift into
    /// describing what looks like two different problems. It was reworded once already, on
    /// 2026-08-29, when node-owned configuration turned a dead end ("Profile not found — it may
    /// have been deleted") into something the user can actually fix; two literals would have made
    /// that a two-file change with nothing to catch a miss.
    ///
    /// ⚠️ Names a REMEDY, not just a fault. Re-adding the node genuinely repairs a bot/agent node,
    /// because such a node owns its configuration. A SUB-WORKFLOW node is not covered by this —
    /// it references another workflow's canvas, so the inspector says something else for that case.
    static let missingConfigurationMessage =
        "This node's configuration is missing. Delete it and add the node again."

    /// The sub-workflow counterpart, for a node whose referenced WORKFLOW is gone.
    ///
    /// ⚠️ Deliberately does NOT say "delete and re-add". A sub-workflow node's `profileID` is the
    /// only surviving record of which child workflow that step ran; telling the user to delete the
    /// node destroys it, and re-adding is impossible once the child is gone. Shared with
    /// `ProfileNodeInspectorView` for the same anti-drift reason as its sibling.
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

        // [EXA-8] A canvas on which NOTHING produces new content. Router, Gate and Trigger all
        // assign `output = upstreamText`, so such a workflow can only answer with the user's own
        // message — the run "succeeds" and hands back the question that started it.
        //
        // ⚠️ WIDER THAN THE FILED ROW, which named only the Trigger. Trigger nodes cannot be created
        // by any palette entry in this build, so a Trigger-only canvas is reachable only from a
        // legacy layout — but a Router-only or Gate-only canvas is buildable TODAY from the palette,
        // and has exactly the same outcome.
        //
        // ⚠️ WARNING, never `.error`: the executor throws `.validationFailed` on any error-severity
        // issue, and refusing to run a graph the user may have built deliberately is the enforcement
        // this project has repeatedly decided against. The exhaustive switch is the point — a new
        // node kind must DECIDE whether it produces content rather than inherit a silent skip.
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
        // [EXA-5] Execution level of every writer, per variable — the input to
        // `WorkflowVariableVisibility.resolve`. Derived from the SAME `outputVariableOwners` the
        // parallel-write rule uses, so the two cannot disagree about who writes what.
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

        // --- WF-CC2: same-level MLX model contention ---
        //
        // `MLXService` keeps exactly ONE model container resident and, since decision D6
        // (2026-10-07), the engine runs every same-level MLX node in its own lane — different
        // models would evict each other on every generation call, and one model would decode the
        // nodes concurrently with no throughput gain. So ANY two same-level MLX nodes are flagged,
        // same model or not; the rule describes what the runtime partition will do.
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
        for node in layout.nodes {
            guard let level = nodeLevel[node.id] else { continue }
            switch node.kind {
            case .profile(let profileID, let profileType):
                // `.workflow` runs a CHILD executor — see the WF-CC5 pool below, which covers it
                // (and Router fallbacks) via the runtime's own partition function instead.
                guard profileType != .workflow,
                      let profile = profileMap[profileID],
                      let config = profile.resolvedLLMConfig,
                      // ⚠️ Shared with the runtime partition ON PURPOSE — this rule and
                      // `WorkflowExecutor.profileDispatchLanes` must never disagree about which
                      // nodes contend.
                      let slot = WorkflowExecutor.mlxSlotKey(for: profile) else { continue }
                mlxProfileDemands.append((node.id, node.displayName, level,
                                          config.modelName.trimmingCharacters(in: .whitespacesAndNewlines), slot))

            case .unsupported, .condition, .code, .gate, .trigger, .action:
                // Handled by the WF-CC5 pool below (`.condition`) or provably MLX-inert
                // (everything else). Exhaustive on purpose — a new `WorkflowNodeKind` must fail to
                // compile here rather than inherit a silent skip.
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

        // --- WF-CC5: same-level STRUCTURAL MLX contention (Router fallback + nested sub-workflow) ---
        //
        // Router `.condition` fallback calls and nested sub-workflow nodes physically share the
        // runtime's STRUCTURAL task group (unlike profile nodes, which run in a separate,
        // non-overlapping phase — that's why they keep their own pool above). Until WF-CC5 that
        // group was entirely unpartitioned; it is now split by `WorkflowExecutor.structuralDispatchLanes`.
        //
        // ⚠️ Reuses that function DIRECTLY rather than re-deriving an approximation of it, so this
        // warning and the runtime partition CANNOT disagree about which nodes contend — the same
        // invariant `mlxSlotKey` already enforces for the profile pool above. A nested sub-workflow
        // gets a unique-per-node lane there (its real MLX demand lives in a child layout this rule
        // cannot see either — see that function's doc comment for why precise resolution isn't
        // attempted), so any level with 2+ same-level sub-workflows, or a sub-workflow beside an
        // MLX-fallback Router, always collides — deliberately conservative, matching the runtime.
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
                // ⚠️ Mirrors `WorkflowExecutor.mlxSlotKey(modelName:)`'s own emptiness check ON
                // PURPOSE — a fallback-enabled Router with a blank/whitespace model name resolves
                // to `slot == nil` there too (`structuralDispatchLanes` treats it as unconstrained,
                // riding along in lane 0), so it must get NO descriptor here. Gating on
                // `llmFallbackEnabled` alone (the original shape of this check) let such a node
                // acquire a descriptor anyway, so a THIRD, genuinely-slotted sibling forcing
                // `lanes.count > 1` swept it into `contenders` below and warned it was contending
                // for a local MLX model named `''` — a fabricated warning about a node the runtime
                // never separates into its own lane and that never touches MLX at all.
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
            // ⚠️ Filtered by DESCRIPTOR presence, not by `lane.slot != nil` — every lane returned
            // once `lanes.count > 1` necessarily has a non-nil slot (drawn from `slotOrder`, which
            // by construction contains only non-nil entries), so a lane-level filter here is a
            // no-op that cannot exclude a node that merely "rode along" into lane 0 via
            // `structuralDispatchLanes`'s `unconstrained + bySlot[slot]!` merge. A node's OWN
            // descriptor (built above with the same emptiness gate as `mlxSlotKey`) is what
            // actually says whether it demands a real slot.
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
                validateConditionNode(node: node, config: config, writtenVariables: writtenVariables, readerLevel: nodeLevel[node.id], variableWriterLevels: variableWriterLevels, edges: layout.edges, issues: &issues)

            case .gate(let config):
                validateGateNode(node: node, config: config, issues: &issues)

            case .code(let config):
                // ⚠️ `nodeLevel[node.id]`, NOT `?? -1`: on a cyclic layout `computeExecutionLevels`
                // returns nil and the map is empty, and the -1 sentinel made every variable on the
                // canvas report "runs at the same time as this node" while the panel never
                // mentioned the cycle. nil means "ordering unknown", and the verdict says nothing.
                validateCodeNode(node: node, config: config, writtenVariables: writtenVariables, readerLevel: nodeLevel[node.id], variableWriterLevels: variableWriterLevels, issues: &issues)

            case .action(let config):
                validateActionNode(node: node, config: config, availableToolSources: availableToolSources, writtenVariables: writtenVariables, readerLevel: nodeLevel[node.id], variableWriterLevels: variableWriterLevels, issues: &issues)

            case .trigger:
                break // Trigger nodes have no user-configurable fields to validate

            case .unsupported:
                // [WF-PE4] BLOCKING. The graph is intact and saveable, but this build cannot
                // execute a node it does not understand — the executor refuses the run at its
                // choke point with the same message, and this issue is the design-time surface
                // that tells the user BEFORE they press Run.
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
            // ⚠️ WHY THIS RULE STILL EXISTS, now that nodes own their configuration. Its original
            // case — a node referencing a SHARED profile the user had deleted — is gone: such
            // workflows were deleted by the owner on 2026-08-29 (pre-release), and the convert-on-
            // open migration that would have repaired them was deleted with them.
            //
            // What survives is the store failing: `WorkflowExecutor` resolves profiles with
            // `(try? BackendProfileStore.shared.fetchProfiles()) ?? []`, so a fetch that throws
            // yields an EMPTY map and every profile node becomes unresolvable at once. That is the
            // live case this guards, and it is why the rule must not be deleted as dead code — a
            // conclusion an earlier plan reached and adversarial verification refuted.
            //
            // ⚠️ Reworded 2026-08-29 because the remedy CHANGED. It used to describe a dead end
            // ("Profile not found — it may have been deleted"); a node's configuration is now its
            // own, so deleting and re-adding the node genuinely repairs it.
            // ⚠️ KIND-SPECIFIC, because the remedy is — and because the advice below is actively
            // destructive for the wrong kind. A sub-workflow node REFERENCES another workflow's
            // canvas; "delete it and add the node again" would discard the node's `profileID`, the
            // only surviving record of which child that step ran, and re-adding is impossible
            // because the child is gone. `missingConfigurationMessage`'s own doc says this case is
            // not covered by it, and `ProfileNodeInspectorView` has always branched — the validator
            // did not, so the panel and the pill gave advice the inspector contradicted.
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

        // ⚠️ NO TASK-DESCRIPTION RULE ANY MORE (2026-08-29). A blocking "Task description is
        // required" error used to live here, so every profile node had to be configured before any
        // run could start. The field it guarded is gone: a node's behaviour is its profile's
        // system instructions, and its input is the run's query (entry node) or its upstream's
        // output. There is nothing left on a profile node that must be filled in beyond choosing
        // the profile, which adding the node already did.
        //
        // The sub-workflow exemption that used to sit here is gone with it — and it is worth
        // recording WHY it existed, because it was the first place this design was conceded: a
        // sub-workflow node had no task because "its directive is the upstream output". That is
        // now true of every node.
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
                } else {
                    // [EXA-5, routed through the shared verdict for EXA-10] A rule reads a stored
                    // NAME rather than a template, so its candidate list is the one name — but the
                    // DECISION and the WORDING now come from the same two functions the Code and
                    // Action surfaces use, which is what stops the three drifting apart on the same
                    // canvas. The variable may be unwritten, or written on this node's own level:
                    // not a race, a same-level write lands only after the level finishes, so the
                    // rule compares against an empty string on EVERY run, deterministically.
                    //
                    // ⚠️ WARNING, never `.error`. The executor throws `.validationFailed` on any
                    // error-severity issue, so an error here would refuse to run canvases that run
                    // today — and a rule that hard-blocks a shape the user may have meant teaches
                    // people to run past the panel.
                    // ⚠️ `[name]`, NOT run through `variableCandidates`: a Router rule reads
                    // `state.variables[key]` with an exact trimmed key and has no dot-path
                    // fallback, so its candidate list really is the one name. Its CONSEQUENCE is
                    // its own too — an always-empty comparison, not a leftover placeholder.
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

            // A rule this build cannot evaluate — an op or field written by a NEWER version and
            // preserved verbatim by the raw-preserving catch-alls (WF-PE3). The engine treats such
            // a rule as inert (never matches), so say so HERE, at design time, with the remedy.
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

        // The routing policy's route target must point at a rule that still exists. Stored by
        // STABLE ID, so renames are safe and only deletion can break it; at run time the executor
        // fails the node rather than guess, so this must surface at design time.
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

    /// Where a `{{ var.… }}` reference was read, which decides how the CONSEQUENCE reads.
    ///
    /// ⚠️ The three surfaces share the DECISION but not the sentence, and conflating those was a
    /// real regression: the first version of this gave a Router rule the template consequence
    /// ("the placeholder text is left in place"). A Router rule has no placeholder — the engine
    /// does `state.variables[key] ?? ""` — so the sentence described a mechanism that does not
    /// exist there, and it dropped the one fact the old Router wording carried, which is that an
    /// always-empty comparison makes `isEmpty`/`notContains`/`notEquals` match unconditionally.
    /// Each tail here mirrors that surface's own runtime warning.
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

    /// THE verdict for a variable reference — Router rules, Code templates and Action bindings all
    /// go through here, so the three cannot start disagreeing about the same canvas.
    ///
    /// ⚠️⚠️ IT MIRRORS THE RESOLVER'S *RUNTIME* SELECTION, and the first version of this did not —
    /// it took the first candidate written ANYWHERE on the canvas and judged only that candidate's
    /// levels. `WorkflowTemplate.resolve` takes the first candidate PRESENT IN THE SNAPSHOT, which
    /// is not the same thing: with `result` written on level 0 and `result.status` written on the
    /// reader's own level, `{{ var.result.status }}` resolves fine at run time (the same-level
    /// write is simply absent, so the first-segment JSON-path fallback fires) while the old rule
    /// warned. **A warning on a canvas that runs is the failure this whole row's doctrine says is
    /// worse than the bug, and the first attempt shipped one.** So: ANY candidate visible from an
    /// earlier level makes the reference fine.
    ///
    /// ⚠️ `readerLevel` is OPTIONAL, and nil means the layout is cyclic (`computeExecutionLevels`
    /// returns nil, so every node falls to no level). Ordering is then unknowable and this says
    /// NOTHING about it — the same opt-out the WF-CC2 contention rule takes, and for the same
    /// reason: asserting an ordering fault about a run that can never start is noise, and the
    /// sentinel would have rendered "runs at the same time as this node" for every variable on the
    /// canvas while the panel never mentioned the actual cycle.
    ///
    /// ⚠️ Conservative BY DESIGN. A MISSED warning costs nothing new — the runtime
    /// unresolved-placeholder logs still fire exactly as they do today; a FALSE warning spends the
    /// panel's credibility, which is the only asset the whole validator has.
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

    /// The sentence a verdict produces. Shared so the three surfaces cannot drift in wording, with
    /// the CONSEQUENCE supplied per surface (see `VariableReferenceSite`).
    ///
    /// ⚠️ `.writtenTooLate` names the candidate the VERDICT matched, not the text the user typed:
    /// for `{{ var.result.status }}` decided by a writer of `result`, naming `result.status` sent
    /// the user hunting for a Code node that does not exist.
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

    /// Every DISTINCT variable reference in one template or binding, in first-appearance order.
    ///
    /// ⚠️ De-duplicated per site: `referencedVariableNames` yields one list per PLACEHOLDER, so a
    /// report template that interpolates `{{ var.summary }}` in a heading and again in the body
    /// produced two byte-identical rows and a "2 issues" header for one mistake. Ten references
    /// produced ten. That is the credibility spend this rule exists to avoid, arriving through the
    /// rule itself.
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

        // [EXA-10] Until now a `{{ var.… }}` reference in a TEMPLATE got no design-time signal at
        // all — not for a same-level write, and not even for a plain typo — while the identical
        // mistake in a Router rule was warned. The user's only evidence was a runtime log, after
        // the tokens and side effects were spent.
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
        writtenVariables: Set<String>,
        readerLevel: Int?,
        variableWriterLevels: [String: [Int]],
        issues: inout [WorkflowValidationIssue]
    ) {
        // [EXA-10] Same rule as the Code template, per BINDING — an Action node renders N strings,
        // not one, and naming the argument matches `WorkflowActionArgs`' runtime line so the two
        // read as one system. Deliberately BEFORE the `guard let tool` below: a binding that reads
        // a variable nothing writes is worth saying even on a node whose tool is not chosen yet.
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

        // A built-in that cannot work until the user configures it (e.g. `web_search` with no
        // provider/key). An Action node embeds its own tool and never passes through a profile's
        // tool list, so the Tool Library's block on enabling does not reach it. Warning, not
        // error, like the offline-server case below: the user may finish setup before running.
        if tool.sourceId == nativeToolSourceID, let blocker = NativeToolCatalog.setupBlocker(for: tool.name) {
            issues.append(WorkflowValidationIssue(
                nodeID: node.id,
                nodeName: node.displayName,
                severity: .warning,
                message: "Tool '\(tool.name)' needs setup — the action will fail at run time until it is configured. \(blocker)"
            ))
        }

        // Availability check for MCP tools — warn (not error) when the tool's
        // server isn't currently in the catalog, so the user learns at design
        // time rather than at run time. Native tools are always resolvable, and
        // we skip the check entirely when no catalog was supplied.
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
                // INS-1's gap-inside-the-gap: a DISABLED server stays in the catalog WITH its
                // tools (the Tool Library needs it visible to re-enable), so the membership test
                // above passes and no warning ever fired — while the executor's resolver refuses
                // a disabled source by design and the node fails at run time. Warning, not error,
                // matching the offline-server precedent: the user may re-enable before running.
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
