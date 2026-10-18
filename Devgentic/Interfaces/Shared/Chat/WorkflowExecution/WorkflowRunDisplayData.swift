// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowRunDisplayData.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import os

private let logger = DGLogger(category: "WorkflowRunDisplay")

/// A view adapter that both live `WorkflowExecutionState` and frozen `WorkflowRunRecord` can produce.
/// The live factory takes the layout to pre-populate pending cards, showing the full pipeline from the first frame.
struct WorkflowRunDisplayData {
    let isLive: Bool
    let isRunning: Bool
    let nodeResults: [NodeDisplayData]
    let finalOutput: String
    /// Always empty from both factories: they read `variables` stubs that are never populated, and nothing reads this field.
    /// Wire the capture before building a "Variables" section on it.
    let variables: [String: String]
    let totalNodes: Int
    let workflowError: String?
    let userInput: String
    let timestamp: Date
    let status: WorkflowRunRecord.RunStatus?
    /// Wall-clock duration of the run so the header can show "Total time X.Xs".
    /// For live runs, computed from `startedAt`; for historical, from the record.
    let duration: TimeInterval
    /// Join key into the trace store; the title bar's Report button opens the run report with it.
    /// nil for historical rows without a trace; the report panel explains that itself.
    var traceID: String? = nil
    // Why: adding the field to `WorkflowRunRecord` alone would be dropped at `decodeRecord`
    /// This run executed the last-saved graph while the canvas held unsaved edits; drives the run header's disclosure row.
    /// Live runs only: `from(record:)` leaves it false because `WorkflowRunRecord` has no column for it.
    var ranWithUnsavedCanvasEdits: Bool = false
    /// The run's record identity (live: `state.runRecordID`, historical: `record.id`),
    /// passed as the report panel's stable id. Not a chat message id.
    var runID: UUID? = nil

    struct NodeDisplayData: Identifiable {
        let id: UUID
        let nodeID: UUID
        let profileName: String
        let status: NodeStatus
        let detail: String
        let duration: TimeInterval
        let input: String?
        let inputSourceLabel: String?
        let nodeTimeline: [TimelineEvent]
        let isStreaming: Bool
        /// Degraded success: completed on a best-effort answer after an early stop
        /// (circuit breaker / iteration budget). Badged amber instead of green.
        var hasWarnings: Bool = false
        /// For a `.skipped` node: did it begin executing before the skip settled? nil means the record lacks the field.
        /// Presentational only: `NodeStatus` stays flat, so run roll-ups and the failed badge are unchanged.
        var ranBeforeSkip: Bool? = nil
        /// Why this node did not run. `NodeStatus` is flat, so the reason is carried separately
        /// for the canvas overlay to tell a user skip from a dead branch.
        var skipReason: NodeSkipReason? = nil
        /// Whether this node kind produces a meaningful step-by-step timeline (agent reasoning and tool calls,
        /// or an Action's tool call). Bots, image generators and structural nodes are single-shot.
        let supportsTimeline: Bool

        /// Per-node skip eligibility: profile kinds only (bot, agent, sub-workflow). Structural kinds never offer skip,
        /// and a node of unknowable kind is not skippable; the engine enforces the same rule.
        var isUserSkippable: Bool = false

        /// Running-skip eligibility, narrower than `isUserSkippable`: bot and agent only, never sub-workflow.
        /// A running sub-workflow takes a path the running-skip racer never enters, so the button would promise too much.
        var isRunningSkippable: Bool = false

        enum NodeStatus: Sendable {
            case pending, running, completed, failed, skipped, cancelled
            /// A status written by a newer build. The node finished, so its detail, duration and trace render,
            /// but how it ended is unclassified; the run-level `.other` likewise renders "Unknown".
            case unknown

            var icon: String {
                switch self {
                case .pending:   return "circle.dotted"
                case .running:   return "arrow.trianglehead.2.clockwise"
                case .completed: return "checkmark.circle.fill"
                case .failed:    return "xmark.circle.fill"
                case .skipped:   return "arrow.right.circle.fill"
                case .cancelled: return "stop.circle.fill"
                case .unknown:   return "questionmark.circle.fill"
                }
            }

            /// Theme-aware status color — single source of truth for node / connector / outcome cards.
            func color(_ theme: any Theme) -> Color {
                switch self {
                case .completed:          return theme.successColor
                case .failed:             return theme.errorColor
                case .running:            return theme.accentColor
                case .pending, .skipped, .unknown:  return theme.secondaryText
                // Amber, not red: the user asked for this. A cancelled node rendered in the
                // failure colour reported the user's own Stop back to them as a fault.
                case .cancelled:          return theme.warningColor
                }
            }

            var label: String {
                switch self {
                case .pending:   return String(localized: "Waiting")
                case .running:   return String(localized: "Running...")
                case .completed: return String(localized: "Completed")
                case .failed:    return String(localized: "Failed")
                case .skipped:   return String(localized: "Not run")
                case .cancelled: return String(localized: "Cancelled")
                case .unknown:   return String(localized: "Unknown")
                }
            }
        }
    }

    // MARK: - Factory: Live Execution State

    /// Builds display data from a live execution state. With `layout`, pending placeholder cards are pre-populated
    /// and inputs derive from upstream `detail` (or `state.userInput` for sources); without it, only started nodes appear.
    static func from(live state: WorkflowExecutionState, layout: WorkflowLayout? = nil) -> WorkflowRunDisplayData {
        let nodes: [NodeDisplayData]
        if let layout, !layout.nodes.isEmpty {
            nodes = buildNodesFromLayout(state: state, layout: layout)
        } else {
            nodes = state.nodeResults.map { result in
                NodeDisplayData(
                    id: result.id,
                    nodeID: result.nodeID,
                    profileName: result.profileName,
                    status: mapLiveStatus(result.status),
                    detail: result.detail,
                    duration: result.duration,
                    input: nil,
                    inputSourceLabel: nil,
                    nodeTimeline: state.nodeTimelines[result.nodeID] ?? [],
                    isStreaming: result.status == .running,
                    hasWarnings: result.hasWarnings,
                    ranBeforeSkip: result.ranBeforeSkip,
                    skipReason: liveSkipReason(result.status),
                    // No layout available to resolve the node kind — preserve the
                    // prior behavior of showing the toggle whenever a timeline exists.
                    supportsTimeline: true
                )
            }
        }

        // Freezes the duration once the run is terminal, or each re-render recomputes against `Date()`.
        let endReference = state.completedAt ?? Date()
        let elapsed = endReference.timeIntervalSince(state.startedAt)

        return WorkflowRunDisplayData(
            isLive: true,
            isRunning: state.isRunning,
            nodeResults: nodes,
            finalOutput: state.finalOutput,
            variables: state.variables,
            totalNodes: state.totalNodes > 0 ? state.totalNodes : nodes.count,
            workflowError: state.workflowError,
            userInput: state.userInput,
            timestamp: state.startedAt,
            // Normally nil for a live run, but a cancel and `completedDespiteNodeFailure` are set explicitly.
            // The derived `hasGenuineFailure` heuristic would show such a run as a red "Failed" pill while live.
            status: state.wasCancelled ? .cancelled
                : state.completedDespiteNodeFailure ? .completedWithWarnings
                : nil,
            duration: elapsed,
            traceID: state.traceID,
            ranWithUnsavedCanvasEdits: state.ranWithUnsavedCanvasEdits,
            runID: state.runRecordID
        )
    }

    /// Iterates layout nodes (in topological order when possible), merging in the
    /// matching live `WorkflowNodeResult` if present. Nodes that haven't started
    /// yet emit a `.pending` placeholder so the strip shows the full pipeline.
    private static func buildNodesFromLayout(
        state: WorkflowExecutionState,
        layout: WorkflowLayout
    ) -> [NodeDisplayData] {
        // Order: prefer topologicalSort; fall back to layout's intrinsic node order.
        let order: [UUID] = layout.topologicalSort() ?? layout.nodes.map(\.id)
        let nodeByID = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.id, $0) })
        let resultByNodeID = Dictionary(uniqueKeysWithValues: state.nodeResults.map { ($0.nodeID, $0) })

        return order.compactMap { nodeID -> NodeDisplayData? in
            guard let layoutNode = nodeByID[nodeID] else { return nil }

            // Input: upstream details joined, or the user input for source nodes. One contribution per upstream node,
            // in first-seen edge order, matching `WorkflowState.upstreamResultEnvelopes` and the record factory.
            var seenUpstreamIDs = Set<UUID>()
            let upstreamIDs = layout.edges
                .filter { $0.targetNodeID == nodeID }
                .map(\.sourceNodeID)
                .filter { seenUpstreamIDs.insert($0).inserted }
            let allUpstreamResults = upstreamIDs.compactMap { resultByNodeID[$0] }
            // One filtered list drives both the text and the label so they never name a node that contributed nothing.
            // If the filter empties a non-empty list, the unfiltered join is shown so a dead subtree still explains itself.
            let contributing = allUpstreamResults.filter { WorkflowExecutionState.contributesInput($0.status) }
            let upstreamResults = contributing.isEmpty ? allUpstreamResults : contributing
            _ = upstreamResults
            let derivedInput: String? = {
                if !upstreamResults.isEmpty {
                    // Uses `upstreamInputContribution`, not `\.detail`: a user-skipped upstream's detail is the skip sentence.
                    // Bounded: this runs per node per body pass and its only reader shows 200 characters.
                    let combined = upstreamResults
                        .map {
                            WorkflowExecutionState.boundedUpstreamInputContribution(
                                of: $0, resultsByNodeID: resultByNodeID,
                                edges: layout.edges, userInput: state.userInput)
                        }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n\n")
                    return combined.isEmpty ? nil : combined
                }
                return state.userInput.isEmpty ? nil : state.userInput
            }()
            let sourceLabel: String? = {
                if !upstreamResults.isEmpty {
                    return upstreamResults.map(\.profileName).joined(separator: ", ")
                }
                return state.userInput.isEmpty ? nil : "User input"
            }()

            // Hoisted above the live-result branch: a running node always carries a result, so setting this only on
            // the placeholder would lose the flag at the pending to running transition.
            let isProfileKind: Bool = {
                if case .profile = layoutNode.kind { return true }
                return false
            }()

            if let result = resultByNodeID[nodeID] {
                return NodeDisplayData(
                    id: result.id,
                    nodeID: nodeID,
                    profileName: result.profileName,
                    status: mapLiveStatus(result.status),
                    detail: result.detail,
                    duration: result.duration,
                    input: derivedInput,
                    inputSourceLabel: sourceLabel,
                    nodeTimeline: state.nodeTimelines[nodeID] ?? [],
                    isStreaming: result.status == .running,
                    hasWarnings: result.hasWarnings,
                    ranBeforeSkip: result.ranBeforeSkip,
                    skipReason: liveSkipReason(result.status),
                    supportsTimeline: kindSupportsTimeline(layoutNode.kind),
                    isUserSkippable: isProfileKind,
                    isRunningSkippable: isProfileKind && layoutNode.profileType != .workflow
                )
            }

            // Pending placeholder
            return NodeDisplayData(
                id: nodeID,
                nodeID: nodeID,
                profileName: layoutNode.displayName,
                status: .pending,
                detail: "",
                duration: 0,
                input: derivedInput,
                inputSourceLabel: sourceLabel,
                nodeTimeline: [],
                isStreaming: false,
                supportsTimeline: kindSupportsTimeline(layoutNode.kind),
                isUserSkippable: isProfileKind
            )
        }
        + orphanedLiveResults(state: state, nodeByID: nodeByID)
    }

    /// Live results whose node is not in the current layout; appended, never dropped, like the record path.
    /// Reachable when the layout diverges mid-run (a node is deleted and saved while it executes).
    private static func orphanedLiveResults(
        state: WorkflowExecutionState,
        nodeByID: [UUID: WorkflowNode]
    ) -> [NodeDisplayData] {
        let orphans = state.nodeResults.filter { nodeByID[$0.nodeID] == nil }
        guard !orphans.isEmpty else { return [] }
        // Why: this runs on every body pass and every streamed event, so unconditional logging floods the log
        // Logs once per (run, orphan-set), not once per evaluation; a second node leaving the layout gets its own line.
        if shouldLogOrphans(signature: orphanLogSignature(
            runID: state.runRecordID, orphanNodeIDs: orphans.map(\.nodeID))) {
            logger.info("[WORKFLOW] \(orphans.count) live node result(s) not in the current layout — node deleted mid-run, or the layout diverged. Appending rather than hiding live evidence (same policy as the record path). CONSEQUENCE: logged once for this run and this set of orphans; the rows keep rendering for the rest of the run without repeating this line.")
        }
        return orphans.map { result in
            NodeDisplayData(
                id: result.id,
                nodeID: result.nodeID,
                profileName: result.profileName,
                status: mapLiveStatus(result.status),
                detail: result.detail,
                duration: result.duration,
                input: nil,
                inputSourceLabel: nil,
                nodeTimeline: state.nodeTimelines[result.nodeID] ?? [],
                isStreaming: result.status == .running,
                hasWarnings: result.hasWarnings,
                    ranBeforeSkip: result.ranBeforeSkip,
                    skipReason: liveSkipReason(result.status),
                // The node's kind is unknowable without its layout entry; default to showing the
                // timeline — the orphan's live trace is exactly the evidence being preserved.
                supportsTimeline: true
            )
        }
    }

    // MARK: - Orphan log de-duplication

    /// The last (run, orphan-set) that produced an orphan log line; a log memo, deliberately unsynchronised.
    /// A torn read costs at most one duplicated or missed line, and callers are on the main actor.
    nonisolated(unsafe) private static var lastLoggedOrphanSignature: String?

    /// The identity of one orphan situation: which run, and which nodes left its layout.
    /// Sorted so the signature is stable when `nodeResults` reorders across parallel levels.
    nonisolated static func orphanLogSignature(runID: UUID?, orphanNodeIDs: [UUID]) -> String {
        (runID?.uuidString ?? "<no run id>") + "|"
            + orphanNodeIDs.map(\.uuidString).sorted().joined(separator: ",")
    }

    // Why: the memo lives here, not in a pure predicate, so the silence on repeat evaluation can be tested
    /// True the first time a signature is seen, false for every repeat until it changes.
    nonisolated static func shouldLogOrphans(signature: String) -> Bool {
        guard lastLoggedOrphanSignature != signature else { return false }
        lastLoggedOrphanSignature = signature
        return true
    }

    // MARK: - Factory: Frozen Run Record

    /// Builds display data from a persisted record; node timelines come from `liveTimelines` when provided,
    /// else from the snapshot's `nodeTimeline`. `layout` only resolves node kinds, to hide single-shot nodes' Timeline tab.
    static func from(record: WorkflowRunRecord,
                     liveTimelines: [UUID: [TimelineEvent]]? = nil,
                     layout: WorkflowLayout? = nil) -> WorkflowRunDisplayData {
        let nodes = record.nodeResults.map { snapshot in
            // Prefer the in-memory timeline (freshest); fall back to the persisted one.
            let timeline = liveTimelines?[snapshot.nodeID] ?? snapshot.nodeTimeline ?? []
            let supportsTimeline: Bool = {
                guard let layout else { return true }   // unknown layout → preserve prior behavior
                guard let node = layout.nodes.first(where: { $0.id == snapshot.nodeID }) else {
                    // Do not suppress: `false` would drop the node's persisted trace entirely, and a miss is expected.
                    // `runHistory` is keyed by conversation, so nodes of another workflow profile's run miss this lookup.
                    logger.info("[WORKFLOW] Node \(snapshot.nodeID.uuidString.prefix(8)) ('\(snapshot.profileName)') is not in the current layout — deleted, or this run belongs to a different workflow. Showing its persisted trace rather than hiding the evidence.")
                    return true
                }
                return kindSupportsTimeline(node.kind)
            }()
            return NodeDisplayData(
                id: snapshot.id,
                nodeID: snapshot.nodeID,
                profileName: snapshot.profileName,
                status: mapRecordStatus(snapshot.status),
                detail: snapshot.detail,
                duration: snapshot.duration,
                input: snapshot.input,
                inputSourceLabel: snapshot.inputSourceLabel,
                nodeTimeline: timeline,
                isStreaming: false,
                hasWarnings: snapshot.hasWarnings ?? false,
                ranBeforeSkip: snapshot.ranBeforeSkip,
                skipReason: recordSkipReason(snapshot.status),
                supportsTimeline: supportsTimeline
            )
        }
        return WorkflowRunDisplayData(
            isLive: false,
            isRunning: false,
            nodeResults: nodes,
            finalOutput: record.finalOutput,
            variables: record.variables,
            totalNodes: record.nodeResults.count,
            workflowError: record.error,
            userInput: record.userInput,
            timestamp: record.timestamp,
            status: record.status,
            duration: record.duration,
            traceID: record.traceID,
            // Deliberately not set: the disclosure is live-only, and the record has nowhere to carry it.
            runID: record.id
        )
    }

    // MARK: - Helpers

    /// Whether a node kind has a meaningful reasoning and tool-call timeline: agent profiles and Action nodes do.
    /// Bots, image generators and structural nodes are single-shot, so their Timeline tab is hidden.
    static func kindSupportsTimeline(_ kind: WorkflowNodeKind) -> Bool {
        switch kind {
        case .profile(_, let profileType):
            switch profileType {
            case .agent, .code, .workflow: return true
            case .bot, .imageGen:          return false
            }
        case .action:
            return true
        case .condition, .code, .gate, .trigger:
            // Genuinely nothing to show: these evaluate a rule or a template in-process and emit
            // no tool, artifact or agent events.
            return false
        case .unsupported:
            // [WF-PE4] A placeholder never runs, so it can have no timeline.
            return false
        }
    }

    /// The reason behind a `.skipped` live status, before the flattening loses it.
    static func liveSkipReason(_ s: WorkflowNodeResult.Status) -> NodeSkipReason? {
        if case .skipped(let r) = s { return r }
        return nil
    }

    /// The reason behind a `.skipped` persisted status.
    static func recordSkipReason(_ s: WorkflowRunRecord.WorkflowNodeResultSnapshot.NodeStatus) -> NodeSkipReason? {
        if case .skipped(let r) = s { return r }
        return nil
    }

    private static func mapLiveStatus(_ s: WorkflowNodeResult.Status) -> NodeDisplayData.NodeStatus {
        switch s {
        case .running:   return .running
        case .completed: return .completed
        case .failed:    return .failed
        case .skipped:   return .skipped
        case .cancelled: return .cancelled
        }
    }

    private static func mapRecordStatus(_ s: WorkflowRunRecord.WorkflowNodeResultSnapshot.NodeStatus) -> NodeDisplayData.NodeStatus {
        switch s {
        case .running:   return .running
        case .completed: return .completed
        case .failed:    return .failed
        case .skipped:   return .skipped
        case .cancelled: return .cancelled
        // A status from a newer build maps to `.unknown`, which renders neutrally and routes detail, duration and trace.
        case .other:     return .unknown
        }
    }
}

// MARK: - Run roll-up (the verdict the user reads — WF-UI5)

/// The run-level verdict logic, kept off the view so it is testable.
/// The view keeps only the Color mappings; everything that decides what to say lives here.
extension WorkflowRunDisplayData {

    /// A node that never executed — rendered neutrally, never as the red of a genuine crash.
    func nodeDidNotRun(_ node: NodeDisplayData) -> Bool {
        node.status == .skipped
    }

    /// The status word for a node that did not run; single source for the visible tag, the VoiceOver label and skip text.
    /// A running skip is not "Not run" (it spent model time), so this decides from structure, never from `detail` prose.
    func skipTagLabel(for node: NodeDisplayData) -> String {
        guard nodeDidNotRun(node) else { return node.status.label }
        return nodeRanBeforeSkip(node) ? String(localized: "Skipped") : String(localized: "Not run")
    }

    /// The status word for a node row; the visible tag and the VoiceOver label both go through here, like `skipTagLabel`.
    /// Applies the awaiting, did-not-run and degraded overrides so VoiceOver announces what the tag shows.
    func nodeTagLabel(for node: NodeDisplayData, isAwaiting: Bool) -> String {
        if isAwaiting { return String(localized: "Needs your input") }
        if nodeDidNotRun(node) { return skipTagLabel(for: node) }
        if node.status == .completed, node.hasWarnings {
            return String(localized: "Completed · warnings")
        }
        return node.status.label
    }

    /// Whether a skipped node had already started when the skip landed. Unknown reads as "did
    /// not start" — never as a false "it ran".
    func nodeRanBeforeSkip(_ node: NodeDisplayData) -> Bool {
        node.ranBeforeSkip ?? false
    }

    /// What to tell the user about a node that did not run. The engine writes the structural cause
    /// into `detail` (`NodeSkipReason.displayText`).
    func notRunMessage(for node: NodeDisplayData) -> String {
        let detail = node.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? String(localized: "Not run") : detail
    }

    /// Whether an expanded row has captured agent evidence worth rendering.
    /// The single gate for every arm that renders a settled `AgentTimelineView`, including `.skipped` and `.cancelled`.
    func nodeShowsCapturedTrace(_ node: NodeDisplayData) -> Bool {
        node.supportsTimeline && !node.nodeTimeline.isEmpty
    }

    /// What the Final Outcome row's expanded panel shows, kept off the view because branch order is the defect surface.
    /// The terminal error outranks the empty/pending test, so a run that failed before its first node still shows its reason.
    enum FinalOutcomePanel: Equatable {
        /// Live run, nothing dispatched yet — the honest hourglass.
        case waiting
        /// Live run with settled nodes but no final output yet.
        case progress(synthesising: Bool)
        /// Terminal (or failing) run with an error and no final output — show the reason.
        case error(String)
        /// A terminal reason that is NOT a fault — a Stop, or a run reconciled after a quit.
        /// Neutral register: same split, same word, as `RunCardBody.reason` on the history card.
        case reason(String)
        /// The final output (may be empty only for shapes no real run produces — an empty
        /// workflow is refused pre-flight, and every cancel/interrupt path writes an error).
        case output(String)
    }

    /// - Parameter rowStatus: the Final Outcome ROW's own status (drives the "Synthesising…"
    ///   spinner wording), not the run status.
    func finalOutcomePanel(rowStatus: NodeDisplayData.NodeStatus) -> FinalOutcomePanel {
        // Why: the `isCancelledRun` gate keeps genuine failures out of the neutral register and the error branch reachable
        // Status-gated and first: every cancel path leaves a `workflowError`, so a Stop would otherwise show in error red.
        // Output comes before the reason, matching `RunCardBody.of`; an empty error string is normalised to nil.
        let reason = workflowError.flatMap { $0.isEmpty ? nil : $0 }
        if isCancelledRun {
            if !finalOutput.isEmpty { return .output(finalOutput) }
            if let reason { return .reason(reason) }
        }
        // Order matters: a zero-node failed run satisfies both tests, so the error branch must precede the empty/pending branch.
        if let reason, finalOutput.isEmpty { return .error(reason) }
        if nodeResults.isEmpty || nodeResults.allSatisfy({ $0.status == .pending }) { return .waiting }
        if isRunning && finalOutput.isEmpty { return .progress(synthesising: rowStatus == .running) }
        return .output(finalOutput)
    }

    /// Genuine failures only: a skipped node is routing and a cancelled node is the user's own Stop.
    var hasGenuineFailure: Bool {
        workflowError != nil || nodeResults.contains { $0.status == .failed && !nodeDidNotRun($0) }
    }

    /// Nodes that have reached a terminal state (`.unknown` is terminal — it FINISHED, under a
    /// newer build).
    var settledNodeCount: Int {
        nodeResults.filter {
            switch $0.status {
            case .completed, .failed, .skipped, .cancelled, .unknown: return true
            case .pending, .running: return false
            }
        }.count
    }

    var hasRunningNode: Bool { nodeResults.contains { $0.status == .running } }

    /// 1-based "step X of N" — the settled nodes plus the one currently executing.
    var currentStepNumber: Int {
        min(settledNodeCount + (hasRunningNode ? 1 : 0), max(nodeResults.count, 1))
    }

    var isCancelledRun: Bool { status == .cancelled }

    /// True when the record was stamped by a NEWER build with a status this build cannot classify.
    /// The Final Outcome row must not assert success over it (WF-UI1): the pill honestly said
    /// "Unknown" while the row one line below said a green "Completed".
    var hasUnknownPersistedStatus: Bool {
        if case .other = status { return true }
        return false
    }

    /// The Final Outcome row / spine state. `.pending` here means "awaiting inputs", which the
    /// spine and awaiting logic depend on — run-level overrides (cancelled, unknown) are applied
    /// at the ROW, not here.
    var rollupOutcome: NodeDisplayData.NodeStatus {
        if isRunning {
            let allSettled = !nodeResults.isEmpty && settledNodeCount == nodeResults.count
            return allSettled ? .running : .pending
        }
        if workflowError != nil { return .failed }
        if nodeResults.contains(where: { $0.status == .failed && !nodeDidNotRun($0) }) { return .failed }
        if nodeResults.isEmpty { return .pending }
        return .completed
    }

    /// The header pill's verdict. The persisted status wins over derived heuristics: a `.running` orphan says "Running"
    /// and `.other` says "Unknown", never a derived "Completed".
    enum PillVerdict { case running, cancelled, failed, unknown, completed, completedWithWarnings }

    var pillVerdict: PillVerdict {
        if let status {
            switch status {
            case .running:   return .running
            case .cancelled: return .cancelled
            case .failed:    return .failed
            case .other:     return .unknown
            // [WF-RU4] Trusted directly — `freeze()` only ever writes this when the ENGINE
            // (which alone knows whether an answering terminal exists) said so.
            case .completedWithWarnings: return .completedWithWarnings
            // A record marked completed that carries a failed node is reported as failed: the nodes are the evidence.
            // Defensive fallback; `freeze()` records that combination as `.completedWithWarnings`.
            case .completed: return hasGenuineFailure ? .failed : .completed
            }
        }
        if isRunning { return .running }
        if isCancelledRun { return .cancelled }
        if hasGenuineFailure { return .failed }
        return .completed
    }

    var pillLabel: String {
        switch pillVerdict {
        case .running:               return String(localized: "Running")
        case .cancelled:             return String(localized: "Cancelled")
        case .failed:                return String(localized: "Failed")
        case .unknown:               return String(localized: "Unknown")
        case .completed:             return String(localized: "Completed")
        case .completedWithWarnings: return String(localized: "Completed with warnings")
        }
    }

    /// The header's step counter ("step 2 of 6 · 12s", "failed at step 3 of 6", "6 steps").
    var stepCounterDescription: String {
        let total = nodeResults.count
        let time = DurationFormat.seconds(duration)
        let suffix = time.isEmpty ? "" : " · \(time)"
        guard total > 0 else { return time }

        if isRunning {
            return String(localized: "step \(currentStepNumber) of \(total)\(suffix)")
        }
        if isCancelledRun {
            return String(localized: "stopped\(suffix)")
        }
        // Gate on `pillVerdict`, not the raw flag: `hasGenuineFailure` is also true for `.completedWithWarnings`.
        if pillVerdict == .failed {
            // First genuinely-failed node (skip the not-run cascade) = where it broke.
            let failedIndex = nodeResults.firstIndex { $0.status == .failed && !nodeDidNotRun($0) }
                ?? nodeResults.firstIndex { $0.status == .failed }
            if let failedIndex {
                return String(localized: "failed at step \(failedIndex + 1) of \(total)\(suffix)")
            }
            return String(localized: "failed\(suffix)")
        }
        if pillVerdict == .completedWithWarnings {
            // Shows only the count, not "failed at step X": the run reached a real answer, so naming a step would misframe it.
            let failedCount = nodeResults.filter { $0.status == .failed && !nodeDidNotRun($0) }.count
            return String(localized: "\(total) step\(total == 1 ? "" : "s") · \(failedCount) failed\(suffix)")
        }
        return "\(total) step\(total == 1 ? "" : "s")\(suffix)"
    }
}

// MARK: - Run-level status vocabulary (single source of truth)

/// Canonical icon / color / label for a whole-run status, mirroring
/// `NodeDisplayData.NodeStatus`. The run history list and the dedicated view's
/// run picker delegate here instead of each re-deriving the mapping.
extension WorkflowRunRecord.RunStatus {
    // Why: an unrecognised status means success is unknown, and a green tick would be a false claim
    /// `.other` renders neutrally: a question mark, secondary colour, "Unknown"; never a checkmark or `successColor`.
    var icon: String {
        switch self {
        case .running:               return "circle.fill"
        case .completed:             return "checkmark.circle.fill"
        // [WF-RU4] A distinct icon from both plain success and cancellation — a failure genuinely
        // occurred, it just did not stop the run from producing a real answer.
        case .completedWithWarnings: return "exclamationmark.triangle.fill"
        case .failed:                return "xmark.circle.fill"
        case .cancelled:             return "stop.circle.fill"
        case .other:                 return "questionmark.circle.fill"
        }
    }

    func color(_ theme: any Theme) -> Color {
        switch self {
        case .completed:             return theme.successColor
        case .completedWithWarnings: return theme.warningColor
        case .failed:                return theme.errorColor
        case .cancelled:             return theme.warningColor
        case .running:               return theme.accentColor
        case .other:                 return theme.secondaryText
        }
    }

    var label: String {
        switch self {
        case .running:               return String(localized: "Running")
        case .completed:             return String(localized: "Completed")
        case .completedWithWarnings: return String(localized: "Completed with warnings")
        case .failed:                return String(localized: "Failed")
        case .cancelled:             return String(localized: "Cancelled")
        // Not localized with the rawValue interpolated: the rawValue is a wire token from a newer
        // build, and putting it in front of the user unexplained is worse than saying "Unknown".
        case .other:                 return String(localized: "Unknown")
        }
    }
}
