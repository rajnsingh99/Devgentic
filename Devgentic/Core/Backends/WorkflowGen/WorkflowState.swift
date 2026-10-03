// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowState.swift
//  Devgentic
//
//  Created by Raj Singh on 11/04/26.
//
//  Typed workflow execution state. Stores full per-node outputs (not truncated),
//  shared mutable variables, and execution log.
//  Upstream input assembly happens at injection time (WorkflowInputAssembler),
//  not at storage time.
//

import Foundation
import os

private let wfStateLogger = DGLogger(category: "WorkflowState")

// MARK: - Node Output

/// Full output from a single node's execution. Unlike NodeResultEnvelope
/// (which carries profile metadata for UI/tracing), NodeOutput focuses on
/// the data a downstream node needs: text, artifacts, status.
/// Whether a node runs, and — when it does not — why. See `WorkflowState.runDecision(for:edges:nodes:)`.
enum NodeRunDecision: Sendable, Equatable {
    case run
    case skip(NodeSkipReason)
}

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
}

// MARK: - Workflow State

/// Typed workflow execution state that tracks per-node outputs and shared variables.
///
/// - Stores `NodeOutput` (text + artifacts + metadata) instead of full `NodeResultEnvelope`
/// - `variables` for shared mutable state (Code nodes can write)
/// - Context compression happens at injection time (per-LLM-node), not storage time
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
            sourceProfileID: envelope.sourceProfileID
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
        // ⚠️ TRIMMED KEY (register EIO-5). `WorkflowValidation` compares TRIMMED names on both
        // sides when it lints "does a Code node write this variable?", but the runtime stored the
        // raw key — so an `outputVariable` saved as " status" passed validation against a Router
        // rule reading "status", then wrote key " status" and the rule's lookup found nothing:
        // `.equals`/`.contains` never matched and `.isEmpty`/`.notContains` matched EVERYTHING,
        // silently routing the wrong branch. Trimming at the single write boundary makes runtime
        // and validator agree by construction; readers keep exact-match lookups.
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

    /// Is this one incoming edge "live" — i.e. did the upstream actually send something down it?
    ///
    /// ⚠️ THE ONE PLACE THIS IS DECIDED. Routing ("does the node run?", `shouldExecuteNode`) and
    /// data ("what does it receive?", `upstreamResultEnvelopes`) are two questions over the same
    /// edges, and EVERY historical case where they answered differently was a bug (WF13, and the
    /// `.canceled` data leak found 2026-08-12). They used to be two implementations with a comment
    /// telling the next reader to keep them in step; they are now one predicate called twice, so
    /// agreement is structural rather than maintained by hand. Do not inline a copy of this.
    ///
    /// Two rules, in order:
    ///   1. LIVENESS — the upstream completed, or this is an activated `error` route. The per-node
    ///      failure policy (`skipDependents`/`stopWorkflow`/`continueAll`) was retired 2026-08-12:
    ///      failure routing is expressed on the CANVAS by wiring the `error` port. Leave it unwired
    ///      and the branch stops, which is exactly what `skipDependents` always was.
    ///      ⚠️ This rule is what catches `.canceled`. `.failed` and cascade-`.skipped` both activate
    ///      `["error"]` and so would be caught by rule 2 alone; `.canceled` activates NOTHING, and
    ///      without this rule it falls through to the default-edge allow and reads as a success.
    ///   2. PORT MATCH — if the upstream made an explicit routing decision, only the ports it
    ///      activated may fire.
    func edgeIsLive(_ edge: WorkflowEdge) -> Bool {
        let upstreamID = edge.sourceNodeID
        guard let output = nodeOutputs[upstreamID] else { return false }

        let isCompleted: Bool
        if case .completed = output.status {
            isCompleted = true
        } else {
            isCompleted = false
        }

        // Phase A user-skip (D2.1): the ONE skip that keeps downstream alive. The node's recorded
        // output IS its forwarded input, so treating it as live is what makes "Skip" honest —
        // without this arm the button would be skipAll wearing a Skip label. `.byUser` activates
        // no ports, so it flows through the default-edge rule below, where the error-branch
        // exclusion still applies (a user skip is an instruction, not a failure — no error port).
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

        // No explicit port activation, and liveness above means the upstream COMPLETED (or was
        // skipped by the user, which forwards its input and is not a failure). Every edge passes
        // EXCEPT a dedicated `error` branch — an error handler must never run on success, and a
        // user skip must never masquerade as a failure.
        return edge.sourcePortLabel != WorkflowEdge.errorPortLabel
    }

    /// Whether the `error` signal should keep travelling down a branch that is dying HERE.
    ///
    /// ⚠️ THE PREDICATE FOR "may a skipped node activate its `error` port". A skip used to activate
    /// `error` UNCONDITIONALLY, which meant an error handler wired to a node that was merely
    /// ROUTED PAST fired on a run where nothing failed — a recovery branch running against a
    /// healthy workflow, with the run still reporting success. (Sharpest shape: `A → Handler` on
    /// `A.error`, `Handler → Notify` on `Handler.error`. A SUCCEEDS, Handler correctly stands down
    /// with `.errorPortNotTaken` — and then told Notify that Handler had failed.)
    ///
    /// ⚠️ The test is the upstream's ACTIVE PORTS, deliberately NOT the skip reason. Two reasons:
    ///   1. `NodeSkipReason.indicatesProblem` is documented as presentation-only, and `.upstreamSkipped`
    ///      is genuinely ambiguous — it covers both "cascade from a crash" and "cascade from a Router
    ///      going the other way". Gating on it fixes the first hop and re-breaks the second.
    ///   2. `error` only ever enters `activeOutputPorts` from a node that FAILED (the four driver
    ///      failure paths) or from a skip that inherited it through this very method. So the flag IS
    ///      the provenance: it is present on a dead branch exactly when a real failure started it.
    /// That makes the propagation correct at ANY depth without a separate cascade-tracking channel,
    /// and leaves every `NodeSkipReason` label — which users read — untouched.
    ///
    /// ⚠️ A CANCELLED upstream activates nothing (see `edgeIsLive` rule 1), so it does not propagate
    /// either. That is intended: Stop is a teardown, not a failure to recover from.
    func upstreamSignalledError(for nodeID: UUID, edges: [WorkflowEdge]) -> Bool {
        edges.contains { edge in
            edge.targetNodeID == nodeID
                && activeOutputPorts[edge.sourceNodeID]?.contains(WorkflowEdge.errorPortLabel) == true
        }
    }

    /// Returns upstream results as NodeResultEnvelope, filtered to the LIVE incoming edges.
    ///
    /// "Live" is decided by `edgeIsLive` — the same predicate `shouldExecuteNode` routes on — so a
    /// node can never receive data down an edge that did not fire. See that method for the rules.
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
                structuredOutput: output.structuredOutput
            )
        }
        // De-duplicate by upstream node. When a node has multiple edges from the same
        // upstream (e.g. wired to both its default and `error` ports), an upstream with
        // no explicit port activation (success) passes the port filter on every edge —
        // keep a single envelope per upstream so its output isn't injected twice.
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

    /// For every node, which ancestor output ports it is reachable from:
    /// `portReach[node][ancestor] = the set of that ancestor's ports with a path to node`.
    ///
    /// This is what lets the engine work out, with no user input, whether two incoming branches are
    /// **alternatives** (they hang off different ports of a common ancestor, so at most one can ever
    /// be live) or **independent** (both are genuinely expected). See `shouldExecuteNode`.
    ///
    /// Pure function of the graph — no run state — so it says nothing about what *did* happen, only
    /// what *could*. Fixpoint rather than topological order so a malformed layout with a cycle
    /// terminates instead of hanging; the iteration bound is the node count, since a simple path
    /// cannot be longer than that.
    ///
    /// Cost is O(V·E) per call on a graph of tens of nodes — negligible, and deliberately not
    /// cached: a stale reachability map is a routing bug, and `WorkflowState` is a value type
    /// snapshotted for parallel execution.
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

    /// Whether a downstream node should execute.
    ///
    /// ## The join is DERIVED from the graph — there is no user setting
    ///
    /// A user setting ("Wait for all / Any one") cannot express the correct behaviour for a node
    /// that has both independent and mutually-exclusive upstreams. The rule is:
    ///
    /// > **AND across independent inputs, OR within alternatives.**
    /// >
    /// > Every incoming branch is REQUIRED to be live, *except* a dead branch that has a live
    /// > sibling depending on a different port of a common ancestor — an alternative that won.
    ///
    /// Worked through, in order of how often it bites:
    ///
    /// - **Diamond over a Condition** (C→A on "True", C→B on "False", A and B→M). One arm always
    ///   cascade-skips. A and B are exclusive on C, so the dead arm is excused by the live one and
    ///   M runs. Under the old default this merge could NEVER run — the single most common broken
    ///   canvas shape.
    /// - **N parallel branches, one fails.** Nothing is exclusive, so every branch is required and M
    ///   skips. ⚠️ **This is the fail-safe half and it must stay** — running a synthesiser on 2 of 3
    ///   researchers is silent partial output.
    /// - **M wired to ONE arm of a Condition plus an independent node.** The arm's branch has no
    ///   live exclusive sibling reaching M, so it stays required: routing away from that arm skips
    ///   M, which is what drawing an edge from a single port means.
    /// - **M wired to `A.error` and to a node downstream of `A.default`.** Exclusive on A's own
    ///   ports, so M runs whichever way A went — the finaliser pattern, free.
    /// - **Independent branch + an exclusive pair.** The pair OR-satisfies each other, the
    ///   independent one is still required. ⚠️ Neither old setting could express this.
    /// - **Diamond where the TAKEN arm fails.** The exclusive group has no *live* member, so nothing
    ///   is excused and M skips. Failure safety needs no separate mechanism: a failed branch simply
    ///   is not live.
    ///
    /// Multiple edges from the SAME upstream are still one branch, OR'd — an upstream activates
    /// exactly one port-outcome per run, so per-edge AND would make a default+`error` double-wire
    /// permanently unreachable.
    func shouldExecuteNode(_ nodeID: UUID, edges: [WorkflowEdge], nodes: [WorkflowNode]) -> Bool {
        if case .run = runDecision(for: nodeID, edges: edges, nodes: nodes) { return true }
        return false
    }

    /// Whether a node runs, and — when it does not — WHY.
    ///
    /// ⚠️ The reason is the point. `shouldExecuteNode` answers only yes/no, and for a long time that
    /// was all the engine told anyone: every non-running node was reported to the UI as a failure
    /// carrying the literal "Upstream dependency failed". On a healthy conditional workflow that
    /// sentence is simply untrue — the Router routed, nothing failed — and the user was shown a
    /// failure they then had to go looking for. Deciding the reason HERE is what makes it honest,
    /// because this is the only place that knows which branch was dead and what its upstream did.
    ///
    /// `shouldExecuteNode` is kept as a thin wrapper so the routing rules below have exactly one
    /// implementation; the two must never be allowed to become separate answers to the same
    /// question (see `edgeIsLive` for what that cost last time).
    func runDecision(for nodeID: UUID, edges: [WorkflowEdge], nodes: [WorkflowNode]) -> NodeRunDecision {
        let incomingEdges = edges.filter { $0.targetNodeID == nodeID }
        let nodeName = nodes.first(where: { $0.id == nodeID })?.displayName ?? nodeID.uuidString

        guard !incomingEdges.isEmpty else {
            wfStateLogger.info("[WF_ROUTE] Routing: '\(nodeName)' → EXECUTE (entry node, no incoming edges)")
            return .run
        }

        let byUpstream = Dictionary(grouping: incomingEdges, by: { $0.sourceNodeID })
        let reach = Self.computePortReach(nodes: nodes, edges: edges)

        // Each branch's provenance = what its upstream depends on, plus the ports THIS branch
        // leaves the upstream by (so a branch off `A.error` is distinguishable from one off
        // `A.default` even though both share the upstream).
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

    /// Classifies a single dead upstream branch.
    ///
    /// The upstream's own recorded status answers most of it. The interesting case is a COMPLETED
    /// upstream: the branch is dead not because anything went wrong but because the upstream made a
    /// routing decision — and whether that reads as "the error handler correctly stood down" or
    /// "the workflow branched elsewhere" depends on which port this branch leaves by.
    private func skipReason(forDeadUpstream upstreamID: UUID, branchEdges: [WorkflowEdge]) -> NodeSkipReason {
        guard let output = nodeOutputs[upstreamID] else { return .notReached }
        switch output.status {
        case .failed:  return .upstreamFailed
        case .canceled: return .upstreamCancelled
        case .skipped(reason: .byUser):
            // Cascade exclusion (D2.1): a user skip keeps its default edges LIVE, so a branch
            // below one is only dead when it leaves exclusively by the `error` port — and a user
            // skip is not a failure, so that handler correctly stood down. Never `.upstreamSkipped`
            // here: "an earlier node in this branch did not run" is a problem-indicating cascade
            // sentence, and nothing went wrong.
            let allErrorRoutes = !branchEdges.isEmpty
                && branchEdges.allSatisfy { $0.sourcePortLabel == WorkflowEdge.errorPortLabel }
            return allErrorRoutes ? .errorPortNotTaken : .notChosen
        case .skipped: return .upstreamSkipped
        case .completed:
            // Upstream succeeded, so nothing failed anywhere on this branch. An edge leaving the
            // `error` port is the handler that correctly had nothing to handle; anything else is
            // ordinary branching.
            let allErrorRoutes = !branchEdges.isEmpty
                && branchEdges.allSatisfy { $0.sourcePortLabel == WorkflowEdge.errorPortLabel }
            return allErrorRoutes ? .errorPortNotTaken : .notChosen
        }
    }

    /// Every node that actually FAILED, as "Name: reason".
    ///
    /// The run verdict needs this because "no terminal succeeded" and "the run failed" are different
    /// questions. A workflow whose every terminal was skipped by ordinary routing has failed nothing;
    /// one whose mid-graph node crashed has, even though the crash is not itself a terminal — and
    /// reporting the terminals alone described the symptom while hiding the cause.
    func failedNodeSummaries() -> [String] {
        nodeOutputs.values.compactMap { output in
            guard case .failed(let reason) = output.status else { return nil }
            return "\(output.profileName): \(reason.localizedDescription)"
        }.sorted()
    }

    /// Returns outputs from all terminal nodes — the nodes where a path that actually RAN ended.
    ///
    /// ⚠️ "Terminal" is decided over LIVE edges, not drawn ones, and the difference is a whole class
    /// of wrong run verdicts. This used to be `Set(edges.map(\.sourceNodeID))` — every edge on the
    /// canvas, taken or not — so on the most ordinary error-handling shape there is:
    ///
    ///     Input → A,  A --error--> Handler
    ///
    /// a SUCCESSFUL run had no terminal at all. `A` was excluded because it has an outgoing edge
    /// (the error edge, which never fired), and `Handler` — correctly skipped — was the only
    /// terminal. The run reported "all terminal nodes failed", A's answer was never emitted, and the
    /// user was shown a failure for a workflow that had just done exactly what it was asked to.
    ///
    /// `edgeIsLive` is the same predicate routing and data-passing already use, so a node is a
    /// terminal precisely when nothing downstream of it ran — which is what the word means.
    func terminalOutputs(edges: [WorkflowEdge], allNodeIDs: [UUID]) -> [NodeOutput] {
        // ⚠️ TWO conditions, and the second is load-bearing. `edgeIsLive` is a property of the
        // edge's SOURCE alone — it answers "was this route taken", never "did anything come of
        // it". Filtering on liveness by itself therefore excluded a node whose downstream was
        // reached but never ran, and that node's answer was then owned by nobody: not by itself
        // (not a terminal) and not by the consumer (which never produced anything).
        //
        // The shape that exposed it is an ordinary fan-in. R1, R2, R3 → Synthesizer; R3 fails, so
        // the join correctly skips the Synthesizer. R1 and R2 completed, their edges are live, and
        // both were struck from the terminal set — leaving only the failed R3 and the skipped
        // Synthesizer, no answering terminal at all, and a run that reported "The workflow failed"
        // while discarding two finished agent answers the user had already paid for.
        //
        // The silent variant is worse: `A → M` plus a Router `C → M` on port "yes". Route "no" and
        // M skips as `.notChosen`, nothing fails, C is the only terminal — so the run reports
        // COMPLETED and presents the Router's pass-through text as the answer while A's real
        // output is dropped without a word.
        //
        // `consumedUpstreamOutput` is the missing half: a node stops being a terminal only when
        // something downstream actually TOOK its output. This is also what the paragraph above
        // has always claimed ("a node is a terminal precisely when nothing downstream of it ran")
        // — the doc was right and the code was weaker than its own contract.
        let consumingEdges = edges.filter { edge in
            guard edgeIsLive(edge) else { return false }
            guard let downstream = nodeOutputs[edge.targetNodeID] else { return false }
            return downstream.status.consumedUpstreamOutput
        }
        let nodesWithLiveOutgoing = Set(consumingEdges.map(\.sourceNodeID))
        let terminalNodeIDs = allNodeIDs.filter { !nodesWithLiveOutgoing.contains($0) }

        // Name the RESCUED nodes specifically. A node that is a terminal only because its
        // downstream never ran is the case this method used to get wrong, so it is the one worth
        // being able to see in a field log — a bare terminal count cannot distinguish "3 terminals"
        // here from "3 terminals" in a healthy fan-out.
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
