// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowState.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let wfStateLogger = DGLogger(category: "WorkflowState")

// MARK: - Node Output

/// Whether a node runs, and when it does not, why. See `WorkflowState.runDecision(for:edges:nodes:)`.
enum NodeRunDecision: Sendable, Equatable {
    case run
    case skip(NodeSkipReason)
}

/// Full output from a single node's execution: the data a downstream node needs (text, artifacts, status).
/// Unlike `NodeResultEnvelope`, it carries no profile metadata for UI or tracing.
struct NodeOutput: Sendable {
    let text: String
    /// Structured form of `text` when the node produced JSON (object/array).
    /// Carried so downstream nodes can do `{{ input.json.path }}` access without
    /// re-parsing. `nil` for plain-text outputs.
    let structuredOutput: JSONValue?
    let artifacts: [MediaArtifact]
    let metadata: NodeExecutionMetadata
    let status: NodeExecutionStatus
    let profileName: String
    let profileType: ProfileType
    let sourceProfileID: UUID
    /// Document ids the node read; see `NodeResultEnvelope.readDocumentIDs`.
    var readDocumentIDs: Set<UUID> = []
}

// MARK: - Workflow State

/// Typed workflow execution state: per-node `NodeOutput`s (text + artifacts + metadata) and shared `variables`
/// that Code nodes can write. Context compression happens at injection time (per LLM node), not at storage time.
struct WorkflowState: Sendable {

    /// Full per-node outputs keyed by nodeID.
    private(set) var nodeOutputs: [UUID: NodeOutput] = [:]

    /// Shared mutable variables across nodes.
    /// Code nodes can write to these; any node can read.
    private(set) var variables: [String: String] = [:]

    /// Active output ports per node. When set, only edges from these port labels are followed.
    /// Used by condition nodes to selectively activate downstream branches.
    /// Key = nodeID, Value = set of active port labels. Nil/missing = all ports active.
    private(set) var activeOutputPorts: [UUID: Set<String>] = [:]

    /// Chronological execution log for traceability.
    private(set) var executionLog: [WorkflowLogEntry] = []

    /// Failures that a sub-workflow node's own run absorbed, keyed by that node.
    /// The node itself is `.completed`, so `failedNodeSummaries()` never sees these.
    private(set) var nestedFailures: [UUID: [String]] = [:]

    // MARK: - Record

    /// Human-readable status for logs. Shared so a routing log and a record log describe the same
    /// status the same way when correlating a run.
    static func statusLabel(_ status: NodeExecutionStatus) -> String {
        switch status {
        case .completed: return "completed"
        case .failed(let reason): return "failed(\(reason.localizedDescription))"
        case .canceled: return "canceled"
        case .skipped(let reason): return "skipped(\(reason.rawValue))"
        }
    }

    /// Records a node's execution result from a NodeResultEnvelope.
    mutating func recordResult(from envelope: NodeResultEnvelope) {
        let statusLabel = Self.statusLabel(envelope.status)
        wfStateLogger.info("Recording result: node=\(envelope.profileName) [\(envelope.nodeID)] status=\(statusLabel) duration=\(String(format: "%.1f", envelope.metadata.duration))s output=\(envelope.output.count) chars")
        wfStateLogger.debug("Node '\(envelope.profileName)' output preview: \(String(envelope.output.prefix(300)))")

        nodeOutputs[envelope.nodeID] = NodeOutput(
            text: envelope.output,
            structuredOutput: envelope.structuredOutput,
            artifacts: envelope.artifacts,
            metadata: envelope.metadata,
            status: envelope.status,
            profileName: envelope.profileName,
            profileType: envelope.profileType,
            sourceProfileID: envelope.sourceProfileID,
            readDocumentIDs: envelope.readDocumentIDs
        )
        executionLog.append(WorkflowLogEntry(
            timestamp: Date(),
            nodeID: envelope.nodeID,
            profileName: envelope.profileName,
            profileType: envelope.profileType,
            status: envelope.status,
            outputPreview: String(envelope.output.prefix(200)),
            duration: envelope.metadata.duration
        ))
    }

    /// Sets a shared variable (for Code nodes).
    mutating func setVariable(_ key: String, value: String) {
        // Trim the key at the single write boundary so runtime and `WorkflowValidation` (which compares trimmed names) agree;
        // a key stored as ' status' would never match a Router rule reading 'status'.
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedKey != key {
            wfStateLogger.notice("Variable name '\(key)' carries surrounding whitespace — stored under trimmed key '\(normalizedKey)'. CONSEQUENCE: readers using the trimmed name (which is what validation checks) resolve it; the untrimmed spelling would have silently resolved to nothing.")
        }
        wfStateLogger.info("Variable set: '\(normalizedKey)' = \(String(value.prefix(200))) (\(value.count) chars)")
        variables[normalizedKey] = value
    }

    /// Sets which output ports are active for a node (used by condition nodes).
    /// Only edges from active ports will be followed for downstream execution.
    mutating func setActiveOutputPorts(_ ports: Set<String>, for nodeID: UUID) {
        wfStateLogger.info("Port activation: node=\(nodeID) activePorts=[\(ports.sorted().joined(separator: ", "))]")
        activeOutputPorts[nodeID] = ports
    }

    // MARK: - Query

    /// Returns the full output for a specific node, if available.
    func output(for nodeID: UUID) -> NodeOutput? {
        nodeOutputs[nodeID]
    }

    /// Returns all upstream node outputs for a given node based on edge topology.
    func upstreamOutputs(for nodeID: UUID, edges: [WorkflowEdge]) -> [NodeOutput] {
        let upstreamNodeIDs = edges
            .filter { $0.targetNodeID == nodeID }
            .map(\.sourceNodeID)
        return upstreamNodeIDs.compactMap { nodeOutputs[$0] }
    }

    // MARK: - The edge-liveness predicate (single source of truth)

    // Why: routing and data passing must agree on which edges are live; do not inline a copy of this predicate.
    /// Whether this incoming edge is live, i.e. the upstream actually sent something down it.
    /// Two rules in order: liveness (upstream completed, or an activated `error` route; catches `.canceled`), then ports.
    /// Routing (`shouldExecuteNode`) and data (`upstreamResultEnvelopes`) share this single predicate.
    func edgeIsLive(_ edge: WorkflowEdge) -> Bool {
        let upstreamID = edge.sourceNodeID
        guard let output = nodeOutputs[upstreamID] else { return false }

        let isCompleted: Bool
        if case .completed = output.status {
            isCompleted = true
        } else {
            isCompleted = false
        }

        // A user skip keeps downstream alive: the node's recorded output is its forwarded input, so it counts as live.
        // `.byUser` activates no ports, so it takes the default-edge rule below (no error port: a skip is not a failure).
        let isUserSkip: Bool
        if case .skipped(reason: .byUser) = output.status {
            isUserSkip = true
        } else {
            isUserSkip = false
        }

        // Error routing: this edge leaves an `error` port that the upstream activated (on failure,
        // or on an upstream-cascade skip so recovery chains don't dead-end).
        let isErrorRoute = edge.sourcePortLabel == WorkflowEdge.errorPortLabel
            && activeOutputPorts[upstreamID]?.contains(WorkflowEdge.errorPortLabel) == true

        guard isCompleted || isUserSkip || isErrorRoute else { return false }

        if let activePorts = activeOutputPorts[upstreamID] {
            // Upstream made an explicit routing decision (condition rule, gate option, or `error`
            // on failure/skip). Only the ports it activated may fire.
            return activePorts.contains(edge.sourcePortLabel ?? "")
        }

        // No explicit port activation and the upstream completed (or was user-skipped): every edge passes except a
        // dedicated `error` branch, since an error handler must never run on success or on a user skip.
        return edge.sourcePortLabel != WorkflowEdge.errorPortLabel
    }

    // Why: do not gate on the skip reason; `.upstreamSkipped` is ambiguous (crash cascade vs Router routing elsewhere),
    // and a cancelled upstream activates nothing, so it does not propagate.
    /// Whether the `error` signal should keep travelling down a branch that is dying here.
    /// Tests the upstream's active ports, not the skip reason: `error` enters `activeOutputPorts` only from a failed node
    /// or a skip that inherited it through this method, so it is present exactly when a real failure started the branch.
    func upstreamSignalledError(for nodeID: UUID, edges: [WorkflowEdge]) -> Bool {
        edges.contains { edge in
            edge.targetNodeID == nodeID
                && activeOutputPorts[edge.sourceNodeID]?.contains(WorkflowEdge.errorPortLabel) == true
        }
    }

    /// Returns upstream results as `NodeResultEnvelope`, filtered to the live incoming edges.
    /// Liveness is decided by `edgeIsLive`, the predicate `shouldExecuteNode` routes on.
    func upstreamResultEnvelopes(for nodeID: UUID, edges: [WorkflowEdge]) -> [NodeResultEnvelope] {
        let incomingEdges = edges.filter { $0.targetNodeID == nodeID }

        let envelopes = incomingEdges.compactMap { edge -> NodeResultEnvelope? in
            let uid = edge.sourceNodeID
            guard let output = nodeOutputs[uid] else { return nil }

            guard edgeIsLive(edge) else {
                let edgePort = edge.sourcePortLabel ?? "(default)"
                let ports = activeOutputPorts[uid].map { "[\($0.sorted().joined(separator: ", "))]" } ?? "(none)"
                wfStateLogger.info("[WF_ROUTE] Upstream '\(output.profileName)' filtered out of node \(nodeID) input: edge port '\(edgePort)' is not live (upstream status=\(Self.statusLabel(output.status)), active ports=\(ports)). CONSEQUENCE: this node will not see that upstream's output.")
                return nil
            }

            return NodeResultEnvelope(
                taskID: UUID(),
                nodeID: uid,
                sourceProfileID: output.sourceProfileID,
                profileName: output.profileName,
                profileType: output.profileType,
                status: output.status,
                output: output.text,
                artifacts: output.artifacts,
                metadata: output.metadata,
                structuredOutput: output.structuredOutput,
                readDocumentIDs: output.readDocumentIDs
            )
        }
        // De-duplicate by upstream node: several edges from one upstream (e.g. default and `error` ports) all pass the
        // port filter on success, so keep one envelope per upstream to avoid injecting its output twice.
        var seenUpstreams = Set<UUID>()
        let dedupedEnvelopes = envelopes.filter { seenUpstreams.insert($0.nodeID).inserted }
        let names = dedupedEnvelopes.map(\.profileName).joined(separator: ", ")
        wfStateLogger.info("Upstream envelopes for node \(nodeID): \(dedupedEnvelopes.count) results from [\(names)]")
        for env in dedupedEnvelopes {
            wfStateLogger.debug("  Upstream '\(env.profileName)': \(env.output.count) chars, preview: \(String(env.output.prefix(200)))")
        }
        return dedupedEnvelopes
    }

    // MARK: - Routing provenance (what makes the join graph-derived)

    // Why: not cached: a stale reachability map is a routing bug, and `WorkflowState` is a value type snapshotted for
    // parallel execution. Fixpoint bounded by node count so a malformed cyclic layout terminates.
    /// For every node, the ancestor output ports it is reachable from (`portReach[node][ancestor]`).
    /// Tells `shouldExecuteNode` whether two incoming branches are alternatives (ports of a common ancestor) or independent.
    /// Pure function of the graph: it says what could happen, not what did.
    static func computePortReach(nodes: [WorkflowNode], edges: [WorkflowEdge]) -> [UUID: [UUID: Set<String>]] {
        var reach: [UUID: [UUID: Set<String>]] = [:]
        var changed = true
        var iterations = 0

        while changed && iterations <= nodes.count {
            changed = false
            iterations += 1

            for edge in edges {
                // What the SOURCE depends on, plus the source's own port for this edge.
                var inherited = reach[edge.sourceNodeID] ?? [:]
                inherited[edge.sourceNodeID, default: []].insert(edge.sourcePortLabel ?? "")

                var target = reach[edge.targetNodeID] ?? [:]
                var grew = false
                for (ancestor, ports) in inherited {
                    let before = target[ancestor]?.count ?? 0
                    target[ancestor, default: []].formUnion(ports)
                    if target[ancestor]!.count != before { grew = true }
                }
                if grew {
                    reach[edge.targetNodeID] = target
                    changed = true
                }
            }
        }
        return reach
    }

    // Why: required branches are the fail-safe: running a synthesiser on 2 of 3 researchers is silent partial output;
    // the join is derived from the graph, not a user setting.
    /// Whether a downstream node should execute: AND across independent inputs, OR within alternatives.
    /// Every incoming branch must be live, except a dead branch with a live sibling on a different port of a common ancestor.
    /// Multiple edges from the same upstream are one branch (OR'd), since an upstream activates one port-outcome per run.
    func shouldExecuteNode(_ nodeID: UUID, edges: [WorkflowEdge], nodes: [WorkflowNode]) -> Bool {
        if case .run = runDecision(for: nodeID, edges: edges, nodes: nodes) { return true }
        return false
    }

    /// Whether a node runs, and when it does not, why.
    /// The reason lets the UI avoid reporting routed-past nodes as failures; `shouldExecuteNode` is a thin yes/no wrapper
    /// so the routing rules keep exactly one implementation.
    func runDecision(for nodeID: UUID, edges: [WorkflowEdge], nodes: [WorkflowNode]) -> NodeRunDecision {
        let incomingEdges = edges.filter { $0.targetNodeID == nodeID }
        let nodeName = nodes.first(where: { $0.id == nodeID })?.displayName ?? nodeID.uuidString

        guard !incomingEdges.isEmpty else {
            wfStateLogger.info("[WF_ROUTE] Routing: '\(nodeName)' → EXECUTE (entry node, no incoming edges)")
            return .run
        }

        let byUpstream = Dictionary(grouping: incomingEdges, by: { $0.sourceNodeID })
        let reach = Self.computePortReach(nodes: nodes, edges: edges)

        // Each branch's provenance: what its upstream depends on plus the ports this branch leaves the upstream by,
        // so a branch off `A.error` is distinguishable from one off `A.default`.
        var provenance: [UUID: [UUID: Set<String>]] = [:]
        var live: [UUID: Bool] = [:]
        for (upstreamID, branchEdges) in byUpstream {
            var p = reach[upstreamID] ?? [:]
            p[upstreamID, default: []].formUnion(branchEdges.map { $0.sourcePortLabel ?? "" })
            provenance[upstreamID] = p
            live[upstreamID] = branchEdges.contains(where: edgeIsLive)
        }

        /// Can both branches be live on the same run? No, if they need different ports of a
        /// common ancestor — that ancestor fires exactly one port-outcome.
        func mutuallyExclusive(_ a: UUID, _ b: UUID) -> Bool {
            guard let pa = provenance[a], let pb = provenance[b] else { return false }
            for (ancestor, portsA) in pa {
                guard let portsB = pb[ancestor], !portsA.isEmpty, !portsB.isEmpty else { continue }
                if portsA.isDisjoint(with: portsB) { return true }
            }
            return false
        }

        var unsatisfied: [String] = []
        var reasons: [NodeSkipReason] = []
        for (upstreamID, isLive) in live where !isLive {
            let excusedBy = live.first { other, otherLive in
                otherLive && mutuallyExclusive(upstreamID, other)
            }
            if excusedBy == nil {
                let name = nodes.first(where: { $0.id == upstreamID })?.displayName ?? upstreamID.uuidString
                unsatisfied.append(name)
                reasons.append(skipReason(forDeadUpstream: upstreamID, branchEdges: byUpstream[upstreamID] ?? []))
            }
        }

        guard !unsatisfied.isEmpty else {
            wfStateLogger.info("[WF_ROUTE] Routing: '\(nodeName)' → EXECUTE (\(live.count) upstream branch(es), \(live.values.filter { $0 }.count) live; any dead branch was an unchosen alternative)")
            return .run
        }

        // Most alarming cause wins — a node fed by both a crashed branch and an unchosen one should
        // report the crash, not the routing.
        let reason = reasons.min(by: { $0.severityRank < $1.severityRank }) ?? .notChosen
        wfStateLogger.info("[WF_ROUTE] Routing: '\(nodeName)' → SKIP (\(reason.rawValue)) — required upstream branch(es) not live: [\(unsatisfied.sorted().joined(separator: ", "))]. CONSEQUENCE: this node and everything downstream of it will not run. These branches are REQUIRED because no live sibling branch is a mutually-exclusive alternative to them (a branch is only optional when a Condition/Gate chose a different port that also reaches here).")
        return .skip(reason)
    }

    /// Classifies a single dead upstream branch from the upstream's recorded status.
    /// A completed upstream means the branch is dead by routing; the port this branch leaves by decides how that reads.
    private func skipReason(forDeadUpstream upstreamID: UUID, branchEdges: [WorkflowEdge]) -> NodeSkipReason {
        guard let output = nodeOutputs[upstreamID] else { return .notReached }
        switch output.status {
        case .failed:  return .upstreamFailed
        case .canceled: return .upstreamCancelled
        case .skipped(reason: .byUser):
            // Cascade exclusion: a user skip keeps its default edges live, so a branch below it is dead only when it leaves
            // by the `error` port, and that handler correctly stood down; never `.upstreamSkipped`, as nothing went wrong.
            let allErrorRoutes = !branchEdges.isEmpty
                && branchEdges.allSatisfy { $0.sourcePortLabel == WorkflowEdge.errorPortLabel }
            return allErrorRoutes ? .errorPortNotTaken : .notChosen
        case .skipped: return .upstreamSkipped
        case .completed:
            // Upstream succeeded, so nothing failed on this branch: an edge leaving the `error` port is a handler with nothing
            // to handle; anything else is ordinary branching.
            let allErrorRoutes = !branchEdges.isEmpty
                && branchEdges.allSatisfy { $0.sourcePortLabel == WorkflowEdge.errorPortLabel }
            return allErrorRoutes ? .errorPortNotTaken : .notChosen
        }
    }

    /// Records (or, when empty, clears) the failures a sub-workflow node's run absorbed. A retried
    /// node's later result replaces its earlier one.
    mutating func recordNestedFailures(_ failures: [String], for nodeID: UUID) {
        nestedFailures[nodeID] = failures.isEmpty ? nil : failures
    }

    /// One line per absorbed failure, prefixed with the sub-workflow node it happened inside.
    func nestedFailureSummaries() -> [String] {
        nestedFailures.flatMap { nodeID, failures -> [String] in
            let owner = nodeOutputs[nodeID]?.profileName ?? "sub-workflow"
            return failures.map { "\(owner) › \($0)" }
        }.sorted()
    }

    /// Every node that actually failed, as "Name: reason".
    /// The run verdict needs this because "no terminal succeeded" and "the run failed" are different questions.
    func failedNodeSummaries() -> [String] {
        nodeOutputs.values.compactMap { output in
            guard case .failed(let reason) = output.status else { return nil }
            return "\(output.profileName): \(reason.localizedDescription)"
        }.sorted()
    }

    // Why: an unfired edge (e.g. `A --error--> Handler` on a successful run) must not exclude `A`, or a successful run
    // has no terminal and reports failure.
    /// Returns outputs from all terminal nodes: the nodes where a path that actually ran ended.
    /// Terminal is decided over live edges (`edgeIsLive`), not drawn ones: a node is terminal when nothing downstream ran.
    func terminalOutputs(edges: [WorkflowEdge], allNodeIDs: [UUID]) -> [NodeOutput] {
        // A node stops being a terminal only when something downstream actually took its output (`consumedUpstreamOutput`);
        // `edgeIsLive` alone says the route was taken and would drop finished answers whose consumer never ran.
        let consumingEdges = edges.filter { edge in
            guard edgeIsLive(edge) else { return false }
            guard let downstream = nodeOutputs[edge.targetNodeID] else { return false }
            return downstream.status.consumedUpstreamOutput
        }
        let nodesWithLiveOutgoing = Set(consumingEdges.map(\.sourceNodeID))
        let terminalNodeIDs = allNodeIDs.filter { !nodesWithLiveOutgoing.contains($0) }

        // Name the rescued nodes (terminal only because their downstream never ran) so they are visible in a field log;
        // a bare terminal count can't tell this from a healthy fan-out.
        let liveButUnconsumed = Set(
            edges.filter { edgeIsLive($0) }.map(\.sourceNodeID)
        ).subtracting(nodesWithLiveOutgoing)
        if !liveButUnconsumed.isEmpty {
            let names = liveButUnconsumed
                .compactMap { nodeOutputs[$0]?.profileName }
                .sorted()
                .joined(separator: ", ")
            wfStateLogger.notice("[WF_EXEC] \(liveButUnconsumed.count) node(s) took a live route to a downstream that never ran: [\(names)]. CONSEQUENCE: each is treated as a terminal so its output still reaches the run's answer, instead of being dropped because an edge it fired was counted as a consumer.")
        }

        return terminalNodeIDs.compactMap { nodeOutputs[$0] }
    }
}

// MARK: - Workflow Log Entry

/// A single entry in the workflow execution log.
struct WorkflowLogEntry: Sendable {
    let timestamp: Date
    let nodeID: UUID
    let profileName: String
    let profileType: ProfileType
    let status: NodeExecutionStatus
    let outputPreview: String
    let duration: TimeInterval
}
