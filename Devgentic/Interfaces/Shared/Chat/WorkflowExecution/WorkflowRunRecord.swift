// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowRunRecord.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "WorkflowRunRecord")

/// Persistent record of a single workflow execution run.
struct WorkflowRunRecord: Identifiable, Codable, Sendable, Equatable {

    let id: UUID
    let conversationID: UUID
    let workflowProfileID: UUID
    let workflowName: String
    let timestamp: Date
    let userInput: String

    /// Per-node results snapshot.
    var nodeResults: [WorkflowNodeResultSnapshot]
    var finalOutput: String
    var variables: [String: String]
    var status: RunStatus
    var duration: TimeInterval
    var error: String?
    /// The observability trace this run recorded into; the join key between run history and the trace store.
    /// Optional, so records persisted before the column existed decode with nil.
    var traceID: String? = nil

    // No `ranWithUnsavedCanvasEdits` here: that disclosure is live-only. This record is rebuilt field-by-field from
    // promoted columns on `WorkflowRunRecordSD`, so a persisted field needs its own column and decode seams.

    // MARK: - [XUI-11] In-memory trace residency

    // Why: drops traces, not history keys: evicting keys desyncs `loadedRunHistoryConversationIDs` and empties the history.
    /// Returns a copy of this record with every node's `nodeTimeline` dropped, and the number of events discarded.
    /// In-memory only: never call this on a record that is about to be persisted.
    func strippingNodeTimelines() -> (record: WorkflowRunRecord, droppedEvents: Int) {
        var dropped = 0
        var copy = self
        copy.nodeResults = nodeResults.map { snapshot in
            guard let events = snapshot.nodeTimeline, !events.isEmpty else { return snapshot }
            dropped += events.count
            return WorkflowNodeResultSnapshot(
                id: snapshot.id, nodeID: snapshot.nodeID, profileName: snapshot.profileName,
                status: snapshot.status, detail: snapshot.detail, duration: snapshot.duration,
                input: snapshot.input, inputSourceLabel: snapshot.inputSourceLabel,
                nodeTimeline: nil, hasWarnings: snapshot.hasWarnings,
                ranBeforeSkip: snapshot.ranBeforeSkip
            )
        }
        return (copy, dropped)
    }

    // Why: errs toward yes: a false negative shows an empty Timeline tab on a failed run, hiding its evidence.
    /// Whether opening this record needs its traces re-read from the store.
    /// A run whose nodes recorded nothing answers yes every time, costing one indexed single-row fetch per selection.
    nonisolated static func needsTraceHydration(
        _ record: WorkflowRunRecord, liveTimelinesAvailable: Bool
    ) -> Bool {
        // Asks whether the traces are in memory, not whether this is the live run: a run can own the live slot
        // yet have dropped its traces, and keying on identity would leave its Timeline tab empty.
        guard !liveTimelinesAvailable else { return false }
        guard record.status != .running else { return false }
        guard !record.nodeResults.isEmpty else { return false }
        return record.nodeResults.allSatisfy { $0.nodeTimeline?.isEmpty ?? true }
    }

    // MARK: - Run Status

    // Why: an unknown status must never default to `.completed`: it could be a failure state written by a newer build.
    /// The outcome of a workflow run. Hand-written `RawRepresentable` so an unrecognised status is preserved,
    /// not reinterpreted; mirrors `WorkflowNodeResultSnapshot.NodeStatus`. The wire format is a plain String.
    enum RunStatus: RawRepresentable, Codable, Sendable, Equatable {
        case running
        case completed
        /// A node failed but the run still reached an answering terminal (an error port absorbed it, or another branch answered).
        /// Distinct from `.failed` (nothing usable came out) and `.completed` (nothing went wrong).
        case completedWithWarnings
        case failed
        case cancelled
        /// A status written by a newer build, carried verbatim.
        case other(String)

        init?(rawValue: String) {
            switch rawValue {
            case "running":   self = .running
            case "completed": self = .completed
            case "completedWithWarnings": self = .completedWithWarnings
            case "failed":    self = .failed
            case "cancelled": self = .cancelled
            default:          self = .other(rawValue)
            }
        }

        var rawValue: String {
            switch self {
            case .running:                return "running"
            case .completed:              return "completed"
            case .completedWithWarnings:  return "completedWithWarnings"
            case .failed:                 return "failed"
            case .cancelled:              return "cancelled"
            case .other(let raw):         return raw
            }
        }

        // Why: `.other` is not settled: an unknown status may be a new in-flight state.
        /// True when this run is known to have finished, whatever the outcome.
        var isSettled: Bool {
            switch self {
            case .completed, .completedWithWarnings, .failed, .cancelled: return true
            case .running, .other:                                        return false
            }
        }
    }

    // MARK: - Node Result Snapshot (Codable-safe)

    /// Codable snapshot of a node result for persistence.
    /// Mirrors `WorkflowNodeResult` from WorkflowExecutionView but is fully Codable.
    struct WorkflowNodeResultSnapshot: Identifiable, Codable, Sendable, Equatable {
        let id: UUID
        let nodeID: UUID
        let profileName: String
        let status: NodeStatus
        let detail: String
        let duration: TimeInterval
        let input: String?
        let inputSourceLabel: String?
        /// The node's reasoning/tool-call trace, persisted so historical runs (esp. FAILED ones,
        /// where the trace is the debugging evidence) can still render the agent timeline after
        /// the in-memory `WorkflowExecutionState` is gone. Optional → old records decode as nil.
        let nodeTimeline: [TimelineEvent]?
        /// Degraded success (completed on a best-effort answer after an early stop).
        /// Optional → old records decode as nil (= no warnings).
        let hasWarnings: Bool?
        // Why: optional, decoded with `decodeIfPresent`: a failed non-optional decode would drop the whole node and its timeline.
        /// For a `.skipped` node: whether it began executing before the skip settled; nil reads as did not start.
        let ranBeforeSkip: Bool?

        /// Whether the node never ran, derived from the structural status rather than the detail text.
        var didNotRun: Bool {
            if case .skipped = status { return true }
            return false
        }

        /// Failed on its own account. This is what a "N failed" badge means.
        ///
        /// A cancelled node is not a failure either — the user asked for it.
        var isGenuineFailure: Bool {
            status == .failed
        }

        // Why: decoded strictly inside the per-node envelope: a rejected rawValue would make the resilient tier drop the whole node.
        /// A node's recorded status. Hand-written `RawRepresentable` so an unrecognised status is preserved, not rejected.
        enum NodeStatus: RawRepresentable, Codable, Sendable, Equatable {
            case running, completed, failed, cancelled
            /// The node did not run, and why. The reason persists in the rawValue (`skipped:notChosen`), not the free-text detail.
            /// An unknown reason decodes to the neutral `.notChosen`, so it never reads as a failure.
            case skipped(NodeSkipReason)
            /// A status written by a newer build, carried verbatim.
            case other(String)

            init?(rawValue: String) {
                switch rawValue {
                case "running":   self = .running
                case "completed": self = .completed
                case "failed":    self = .failed
                case "cancelled": self = .cancelled
                default:
                    if rawValue.hasPrefix("skipped:") {
                        let raw = String(rawValue.dropFirst("skipped:".count))
                        self = .skipped(NodeSkipReason(rawValue: raw) ?? .notChosen)
                    } else {
                        self = .other(rawValue)
                    }
                }
            }

            var rawValue: String {
                switch self {
                case .running:              return "running"
                case .completed:            return "completed"
                case .failed:               return "failed"
                case .cancelled:            return "cancelled"
                case .skipped(let reason):  return "skipped:\(reason.rawValue)"
                case .other(let raw):       return raw
                }
            }
        }

        // Tolerant decoding: optional fields may be absent
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            nodeID = try c.decode(UUID.self, forKey: .nodeID)
            profileName = try c.decode(String.self, forKey: .profileName)
            status = try c.decode(NodeStatus.self, forKey: .status)
            detail = try c.decode(String.self, forKey: .detail)
            duration = try c.decode(TimeInterval.self, forKey: .duration)
            input = try c.decodeIfPresent(String.self, forKey: .input)
            inputSourceLabel = try c.decodeIfPresent(String.self, forKey: .inputSourceLabel)
            // Lossy on purpose: a bad timeline drops only this node's trace, not the node. Reaching this branch means the
            // container shape changed (key present but not a JSON array), so the failure is logged.
            do {
                nodeTimeline = try c.decodeIfPresent([TimelineEvent].self, forKey: .nodeTimeline)
            } catch {
                nodeTimeline = nil
                logger.error(
                    "[DECODE] Node \(nodeID.uuidString.prefix(8)) (\(profileName)): nodeTimeline is "
                    + "present but undecodable — \(error). CONSEQUENCE: this node's agent trace will "
                    + "not render for this run; its status, detail and duration are unaffected. The "
                    + "stored bytes are NOT overwritten (nothing re-saves a loaded record), so they "
                    + "stay recoverable by a build that understands the shape."
                )
            }
            hasWarnings = try c.decodeIfPresent(Bool.self, forKey: .hasWarnings)
            ranBeforeSkip = try c.decodeIfPresent(Bool.self, forKey: .ranBeforeSkip)
        }

        init(id: UUID, nodeID: UUID, profileName: String, status: NodeStatus, detail: String, duration: TimeInterval, input: String? = nil, inputSourceLabel: String? = nil, nodeTimeline: [TimelineEvent]? = nil, hasWarnings: Bool? = nil, ranBeforeSkip: Bool? = nil) {
            self.id = id
            self.nodeID = nodeID
            self.profileName = profileName
            self.status = status
            self.detail = detail
            self.duration = duration
            self.input = input
            self.inputSourceLabel = inputSourceLabel
            self.nodeTimeline = nodeTimeline
            self.hasWarnings = hasWarnings
            self.ranBeforeSkip = ranBeforeSkip
        }
    }

    // MARK: - Factory

    // Why: keeps the tail, not the head: on a failure the most recent events are the diagnostic ones.
    /// Trace events retained per node in a frozen record, keeping the tail of the trace.
    /// Below the live cap (`ChatMessage.maxTimelineEvents`): persisted traces are decoded for many records at once.
    static let maxPersistedNodeTimelineEvents = 400

    /// Returns the events a frozen record keeps for one node, and how many it discarded.
    /// Pure and `nonisolated`, so both the count and the direction (tail kept) are assertable.
    nonisolated static func cappedNodeTimeline(_ events: [TimelineEvent]) -> (kept: [TimelineEvent], dropped: Int) {
        guard events.count > maxPersistedNodeTimelineEvents else { return (events, 0) }
        return (Array(events.suffix(maxPersistedNodeTimelineEvents)),
                events.count - maxPersistedNodeTimelineEvents)
    }

    /// Freezes a live `WorkflowExecutionState` into a persistent record.
    /// - Parameter layout: the graph that ran (a start-time capture); decides each node's input preview, the snapshot order
    ///   and which unreached nodes become `skipped(.notReached)`. Nil falls back to arrival order.
    static func freeze(
        from state: WorkflowExecutionState,
        conversationID: UUID,
        workflowProfileID: UUID,
        workflowName: String,
        userInput: String,
        timestamp: Date,
        layout: WorkflowLayout? = nil
    ) -> WorkflowRunRecord {
        var unsettledNodes = 0
        var closedToolRows = 0
        // [XUI-6] Accumulated across the node map so the truncation is reported ONCE per freeze
        // rather than per node. `freeze` runs exactly once per run, so this is not per-frame code.
        var droppedTraceEvents = 0
        var truncatedNodes: [String] = []
        // Built once: the not-reached fill and the pass-through input resolution both look nodes up by id.
        // `uniquingKeysWith` because this is the last gate before persistence: a duplicate nodeID keeps the later row.
        let resultByNodeID = Dictionary(state.nodeResults.map { ($0.nodeID, $0) },
                                        uniquingKeysWith: { _, latest in latest })

        // Per-node input from edge topology (Tier 2), and the label naming where it came from.
        func derivedInput(for nodeID: UUID) -> (text: String?, sourceLabel: String?) {
            guard let layout else { return (nil, nil) }
            // Edge-declaration order, built as `WorkflowRunDisplayData.buildNodesFromLayout` builds it, so both factories agree.
            // De-duplicated by source node (first-seen order), as the engine does; never by `profileName`.
            var seenUpstreamIDs = Set<UUID>()
            let allUpstreamResults = layout.edges
                .filter { $0.targetNodeID == nodeID }
                .map(\.sourceNodeID)
                .filter { seenUpstreamIDs.insert($0).inserted }
                .compactMap { resultByNodeID[$0] }
            // [workflow/vm-1] Same status filter and same fallback as the live factory — this is
            // the FROZEN half of that pair, and the value it persists is the durable one.
            let contributingUpstreams = allUpstreamResults.filter { WorkflowExecutionState.contributesInput($0.status) }
            let upstreamResults = contributingUpstreams.isEmpty ? allUpstreamResults : contributingUpstreams
            guard !upstreamResults.isEmpty else { return (nil, nil) }
            // Uses `upstreamInputContribution`, not `.detail`: a user-skipped upstream's detail is not what the node received.
            // Unlike the live factory, a node with no settled upstream yields `(nil, nil)` and contributions are not length-capped.
            let combined = upstreamResults
                .map {
                    WorkflowExecutionState.upstreamInputContribution(
                        of: $0, resultsByNodeID: resultByNodeID,
                        edges: layout.edges, userInput: userInput)
                }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            return (combined.isEmpty ? nil : combined,
                    upstreamResults.map(\.profileName).joined(separator: ", "))
        }

        func snapshot(for result: WorkflowNodeResult) -> WorkflowNodeResultSnapshot {
            let derived = derivedInput(for: result.nodeID)
            let inputText = derived.text
            let sourceLabel = derived.sourceLabel

            // Defensive settle: freeze is the last gate before the record persists, so anything still in flight here
            // ended without reporting and is recorded as a failure (or a cancel).
            let snapshotStatus: WorkflowNodeResultSnapshot.NodeStatus
            var snapshotDetail = result.detail
            switch result.status {
            case .running:
                unsettledNodes += 1
                // Not unconditionally `.failed`: a run the user stopped did not fail, and counting its in-flight node as a failure
                // would roll the run up `.failed`. `wasCancelled` is latched before freeze on every cancel path.
                snapshotStatus = state.wasCancelled ? .cancelled : .failed
                let note = state.wasCancelled
                    ? "Cancelled before the node finished."
                    : "Interrupted before the node finished."
                snapshotDetail = snapshotDetail.isEmpty ? note : "\(snapshotDetail)\n\(note)"
            case .completed: snapshotStatus = .completed
            case .failed:    snapshotStatus = .failed
            case .skipped(let reason): snapshotStatus = .skipped(reason)
            case .cancelled: snapshotStatus = .cancelled
            }

            return WorkflowNodeResultSnapshot(
                id: result.id,
                nodeID: result.nodeID,
                profileName: result.profileName,
                status: snapshotStatus,
                detail: snapshotDetail,
                duration: result.duration,
                input: inputText,
                inputSourceLabel: sourceLabel,
                // Persists the trace, capped from the end; empty becomes nil. Dangling tool rows are closed on the way in,
                // since `AgentTimelineView` spins any row still executing.
                nodeTimeline: {
                    guard var events = state.nodeTimelines[result.nodeID], !events.isEmpty else { return nil }
                    closedToolRows += DanglingToolRowCloser.close(&events, outcome: .failed)
                    let (kept, dropped) = Self.cappedNodeTimeline(events)
                    if dropped > 0 {
                        droppedTraceEvents += dropped
                        truncatedNodes.append("\(result.nodeID.uuidString.prefix(8)) '\(result.profileName)' -\(dropped)")
                    }
                    return kept
                }(),
                hasWarnings: result.hasWarnings ? true : nil,
                // Explicit, never defaulted: freeze REPLACES the whole struct, so an omitted
                // argument here silently persists the wrong answer for every historical run.
                ranBeforeSkip: result.ranBeforeSkip
            )
        }

        // A layout node the run never reached (no `started`, so no result): `.skipped(.notReached)`, never a genuine failure.
        // Synthesized statuses must answer `NodeSkipReason.decidedTheBranch`; the canvas overlay reads it.
        func notReachedSnapshot(for node: WorkflowNode) -> WorkflowNodeResultSnapshot {
            let derived = derivedInput(for: node.id)
            return WorkflowNodeResultSnapshot(
                id: node.id,
                nodeID: node.id,
                profileName: node.displayName,
                status: .skipped(.notReached),
                detail: NodeSkipReason.notReached.displayText,
                duration: 0,
                input: derived.text,
                inputSourceLabel: derived.sourceLabel,
                nodeTimeline: nil,
                hasWarnings: nil,
                // It never started, so it cannot have run before the skip. Stated, not defaulted:
                // nil would send the display to its legacy duration/timeline heuristic instead.
                ranBeforeSkip: false
            )
        }

        // Built in the layout's topological order with unreached nodes filled in, as the live view does, so switching
        // from the live factory to this one at finalize does not change the rows.
        var notReachedNodes: [String] = []
        let nodeSnapshots: [WorkflowNodeResultSnapshot]
        if let layout, !layout.nodes.isEmpty {
            let order = layout.topologicalSort() ?? layout.nodes.map(\.id)
            let nodeByID = Dictionary(layout.nodes.map { ($0.id, $0) },
                                      uniquingKeysWith: { first, _ in first })
            var placed: Set<UUID> = []
            var ordered: [WorkflowNodeResultSnapshot] = []
            for nodeID in order {
                guard let layoutNode = nodeByID[nodeID] else { continue }
                placed.insert(nodeID)
                if let result = resultByNodeID[nodeID] {
                    ordered.append(snapshot(for: result))
                } else {
                    notReachedNodes.append("\(nodeID.uuidString.prefix(8)) '\(layoutNode.displayName)'")
                    ordered.append(notReachedSnapshot(for: layoutNode))
                }
            }
            // A result whose node is missing from the layout is appended, never dropped: evidence is not hidden.
            ordered += state.nodeResults.filter { !placed.contains($0.nodeID) }.map { snapshot(for: $0) }
            nodeSnapshots = ordered
        } else {
            // No layout snapshot for this run: arrival order, started nodes only; there is nothing to fill in from.
            nodeSnapshots = state.nodeResults.map { snapshot(for: $0) }
        }

        if !notReachedNodes.isEmpty {
            logger.info("[WORKFLOW] freeze() recorded \(notReachedNodes.count) node(s) of '\(workflowName)' that this run never reached, as skipped(.notReached): [\(notReachedNodes.joined(separator: ", "))]. CONSEQUENCE: the historical run keeps the pipeline shape the live view showed — those rows read 'Not run', are never counted as failures, and the step total stays the graph's rather than the number of nodes that happened to start.")
        }

        if droppedTraceEvents > 0 {
            // The cap is a deliberate bound; log it so a truncated trace is never silent.
            logger.notice("[WORKFLOW] freeze() capped the persisted trace of \(truncatedNodes.count) node(s) for '\(workflowName)' at \(Self.maxPersistedNodeTimelineEvents) events each, DROPPING \(droppedTraceEvents) event(s) in total: [\(truncatedNodes.joined(separator: ", "))]. CONSEQUENCE: the run report shows only the LAST \(Self.maxPersistedNodeTimelineEvents) events for those nodes — the earliest reasoning steps and tool calls are gone from the record, though they were visible live. The tail is kept deliberately: on a failure the most recent events are the diagnostic ones.")
        }

        if unsettledNodes > 0 || closedToolRows > 0 {
            logger.warning("[WORKFLOW] freeze() force-settled \(unsettledNodes) node(s) still marked running and \(closedToolRows) dangling tool row(s) for '\(workflowName)'. The live state should already have settled these — a persisted run must never claim to still be executing.")
        }

        // Derived from the snapshots, not the live results, so a force-settled node counts.
        // Uses `isGenuineFailure`, not `status == .failed`: a node that never ran is not a run failure.
        let status: RunStatus = {
            // Checked first: a cancel also sets `workflowError`, so testing the error first would persist a Stop as `.failed`.
            if state.wasCancelled { return .cancelled }
            if let _ = state.workflowError { return .failed }
            guard nodeSnapshots.contains(where: { $0.isGenuineFailure }) else { return .completed }
            // A node failed. `freeze()` cannot see graph topology, so `completedDespiteNodeFailure` carries the engine's verdict;
            // it only upgrades `.failed` to `.completedWithWarnings`, never to plain `.completed`.
            return state.completedDespiteNodeFailure ? .completedWithWarnings : .failed
        }()

        // Wall-clock duration (start to finish), matching the live display; summing node durations disagrees for parallel runs.
        let totalDuration = (state.completedAt ?? Date()).timeIntervalSince(state.startedAt)

        return WorkflowRunRecord(
            id: UUID(),
            conversationID: conversationID,
            workflowProfileID: workflowProfileID,
            workflowName: workflowName,
            timestamp: timestamp,
            userInput: userInput,
            nodeResults: nodeSnapshots,
            finalOutput: state.finalOutput,
            variables: state.variables,
            status: status,
            duration: totalDuration,
            error: state.workflowError,
            traceID: state.traceID
        )
    }
}
