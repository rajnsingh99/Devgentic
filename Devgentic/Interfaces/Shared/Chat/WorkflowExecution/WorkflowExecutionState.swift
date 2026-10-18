// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowExecutionState.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import os

private let workflowLogger = DGLogger(category: "WorkflowExecutionState")

// MARK: - Workflow Node Result (Display Model)

/// Lightweight display model for a single node's execution result.
/// Built from `AgentStreamEvent.workflowNode*` events — does not require
/// access to the full `NodeResultEnvelope` (which is internal to WorkflowExecutor).
struct WorkflowNodeResult: Identifiable, Sendable {
    let id: UUID
    let nodeID: UUID
    let profileName: String
    let status: Status
    let detail: String
    let startTime: Date
    var endTime: Date?
    /// Degraded success — the node completed on a best-effort answer after an early stop
    /// (circuit breaker / iteration budget). Badged amber instead of green in the UI.
    var hasWarnings: Bool = false
    // Why: presentational; never feeds `didNotRun`, `isGenuineFailure` or the run roll-ups, since a skip is still a skip.
    /// For a `.skipped` node only: whether it began executing before the skip settled.
    var ranBeforeSkip: Bool = false

    var duration: TimeInterval {
        (endTime ?? Date()).timeIntervalSince(startTime)
    }

    enum Status: Sendable, Equatable {
        case running
        case completed
        case failed
        /// The node did not run. Not a failure; carries the structural cause.
        case skipped(NodeSkipReason)
        /// The user stopped the run while this node was in flight. Also not a failure.
        case cancelled
    }
}

// MARK: - Execution State

/// Observable state manager for a single workflow execution run.
/// Fed by ActiveStreamManager's workflow-specific event processing.
@Observable
final class WorkflowExecutionState {

    /// Per-node results, ordered by event arrival.
    var nodeResults: [WorkflowNodeResult] = []

    /// Synthesised final output from terminal nodes.
    var finalOutput: String = ""

    /// Overall progress.
    var completedNodes: Int = 0
    var totalNodes: Int = 0

    /// Whether the workflow is currently executing.
    var isRunning: Bool = false

    /// Error if the entire workflow failed.
    var workflowError: String?

    // Why: distinct from `workflowError != nil`, which a cancel also sets; conflating them records a Stop as Failed.
    /// Whether this run ended because the user stopped it.
    var wasCancelled: Bool = false

    // Why: the chat bubble must not read it: an error-handled run legitimately shows a plain completed chip there.
    /// True when at least one node failed yet the run still reached an answering terminal.
    /// Carried from the engine via `.workflowRunFinished`; used by workflow-specific surfaces only.
    var completedDespiteNodeFailure: Bool = false

    /// True when the run started while its canvas held unsaved edits, so the graph that executed
    /// (loaded from disk) differs from the one on screen. Set once at run start; a disclosure, never a gate.
    var ranWithUnsavedCanvasEdits: Bool = false

    // Why: to populate it, add a stream event carrying a variables snapshot and cap the values before `freeze` persists them.
    /// Workflow variables for the run; currently never populated, so always empty.
    /// The engine's variables live in a local `WorkflowState` and no stream event carries them here.
    var variables: [String: String] = [:]

    /// Per-node timeline events for expanded node detail views.
    /// Keyed by nodeID, populated by ActiveStreamManager when sourceNodeID is present.
    var nodeTimelines: [UUID: [TimelineEvent]] = [:]

    // Why: `isRunning == false` is not enough: until `hasFrozenRecord` the traces exist only here and a release would lose them.
    /// Drops this run's per-node traces once they are persisted, keeping the state object itself.
    /// Returns the number of events released; refuses while the run is running or its record is unfrozen.
    @discardableResult
    func releaseSettledTraces() -> Int {
        let resident = nodeTimelines.values.reduce(0) { $0 + $1.count }
        guard resident > 0 else { return 0 }
        let runID = runRecordID.map { String($0.uuidString.prefix(8)) } ?? "<no id>"
        guard !isRunning else {
            workflowLogger.debug("[WORKFLOW] Run \(runID) is still in flight — keeping \(resident) live node timeline event(s) resident. CONSEQUENCE: its trace keeps growing in memory until it settles and is frozen; nothing is dropped.")
            return 0
        }
        guard hasFrozenRecord else {
            workflowLogger.notice("[WORKFLOW] Run \(runID) has settled but its record is not yet frozen — keeping \(resident) live node timeline event(s) resident. CONSEQUENCE: nothing is released until finalize() copies the trace into the record; dropping it now would persist every node with no timeline, permanently, with nothing in the store to re-read.")
            return 0
        }
        nodeTimelines = [:]
        return resident
    }

    // [HITL/P6] Workflow HITL moved to the unified InteractionCenter; the per-run
    // pendingInteractions container + the in-canvas WorkflowInteractionPanel were removed.

    /// The user's typed input that kicked off this workflow run. Used as the
    /// "input" displayed on source nodes (those without upstream edges) in the
    /// new card UI. Set by `MessagingCoordinator` when execution starts.
    var userInput: String = ""

    /// The workflow profile this run belongs to. Lets `WorkflowRunDisplayData`
    /// load the layout for live runs to render pending placeholder cards and
    /// compute per-node inputs from upstream edges.
    var workflowProfileID: UUID?

    /// Wall-clock start time of the run. Lets the title bar show "Total time"
    /// while the run is still live.
    var startedAt: Date = Date()

    /// Wall-clock end time of the run, set when the workflow reaches a terminal state.
    /// When non-nil, the displayed duration freezes at `completedAt - startedAt` instead of tracking the current date.
    var completedAt: Date?

    /// ID of the persisted `WorkflowRunRecord` this live state is bound to.
    /// Set when the initial `.running` record is inserted and reused for the final upsert.
    var runRecordID: UUID?

    // Why: not equivalent to `!isRunning`: between the two the traces exist only here and a drop would lose them.
    /// True once `WorkflowRunRecord.freeze` has copied this state, timelines included, into the record to persist.
    /// Set only through `markRecordFrozen()`.
    private(set) var hasFrozenRecord = false

    /// Marks the record as frozen; called by `WorkflowRunTicket.finalize()` as soon as `freeze` returns.
    /// `freeze` has already copied the timelines into the record value, so the live copy is not needed for it.
    func markRecordFrozen() {
        hasFrozenRecord = true
    }

    /// The run's observability trace ID, stamped when the trace is created.
    /// Persisted on the `WorkflowRunRecord` so run history and the trace store share a join key.
    var traceID: String?

    // MARK: - Per-Node Timeline

    /// Appends a timeline event to a specific node's timeline.
    func appendNodeTimelineEvent(_ event: TimelineEvent, for nodeID: UUID) {
        nodeTimelines[nodeID, default: []].append(event)
        // Caps per-node timeline growth (memory, persistence, render) with the shared overflow eviction.
        ChatMessage.evictOverflow(&nodeTimelines[nodeID, default: []], context: "workflow-node")
    }

    // MARK: - Event Ingestion

    func handleNodeStarted(nodeID: UUID, profileName: String, index: Int, total: Int) {
        // Any resolution supersedes a pending retry. A failure arrives before the next retry-scheduled event,
        // so clearing here and re-adding there leaves a terminal failure with the flag off.
        retryPendingNodeIDs.remove(nodeID)
        totalNodes = total
        isRunning = true

        if let idx = nodeResults.firstIndex(where: { $0.nodeID == nodeID }) {
            // A `started` event for a node whose row is `.failed` is a retry (events arrive per attempt); reopen the row.
            // Only `.failed` reopens: a start after any other status is out-of-order noise and is ignored.
            guard nodeResults[idx].status == .failed else { return }
            nodeResults[idx] = WorkflowNodeResult(
                id: nodeResults[idx].id, nodeID: nodeID, profileName: profileName,
                status: .running, detail: String(localized: "Retrying..."),
                // Original start survives, mirroring handleNodeCompleted — the row's duration
                // is the node's total wall time across attempts, not the last attempt's.
                startTime: nodeResults[idx].startTime
            )
            workflowLogger.info("[WF_EVENT] Node '\(profileName)' re-started after a failed attempt — row reopened as running. CONSEQUENCE: the timeline shows the retry instead of a finished red 'Failed', the Skip buttons stay reachable, and a Stop mid-retry settles the node cancelled rather than counting it as a genuine failure.")
            return
        }

        nodeResults.append(WorkflowNodeResult(
            id: UUID(), nodeID: nodeID, profileName: profileName,
            status: .running, detail: "Running...",
            startTime: Date()
        ))
    }

    func handleNodeCompleted(nodeID: UUID, profileName: String, summary: String, hasWarnings: Bool = false) {
        // Any resolution supersedes a pending retry. A failure arrives before the next retry-scheduled event,
        // so clearing here and re-adding there leaves a terminal failure with the flag off.
        retryPendingNodeIDs.remove(nodeID)
        if let idx = nodeResults.firstIndex(where: { $0.nodeID == nodeID }) {
            nodeResults[idx] = WorkflowNodeResult(
                id: nodeResults[idx].id, nodeID: nodeID, profileName: profileName,
                status: .completed, detail: summary,
                startTime: nodeResults[idx].startTime, endTime: Date(),
                hasWarnings: hasWarnings
            )
        } else {
            nodeResults.append(WorkflowNodeResult(
                id: UUID(), nodeID: nodeID, profileName: profileName,
                status: .completed, detail: summary,
                startTime: Date(), endTime: Date(),
                hasWarnings: hasWarnings
            ))
        }
    }

    func handleNodeFailed(nodeID: UUID, profileName: String, error: String, suggestion: String? = nil) {
        // Any resolution supersedes a pending retry. A failure arrives before the next retry-scheduled event,
        // so clearing here and re-adding there leaves a terminal failure with the flag off.
        retryPendingNodeIDs.remove(nodeID)
        // Folds the remediation suggestion into `detail` so every run card (live and persisted) shows it.
        let detail = suggestion.map { "\(error)\n\n💡 \($0)" } ?? error
        if let idx = nodeResults.firstIndex(where: { $0.nodeID == nodeID }) {
            nodeResults[idx] = WorkflowNodeResult(
                id: nodeResults[idx].id, nodeID: nodeID, profileName: profileName,
                status: .failed, detail: detail,
                startTime: nodeResults[idx].startTime, endTime: Date()
            )
        } else {
            nodeResults.append(WorkflowNodeResult(
                id: UUID(), nodeID: nodeID, profileName: profileName,
                status: .failed, detail: detail,
                startTime: Date(), endTime: Date()
            ))
        }
        // Closes this node's dangling tool rows at its own failure: a node failing into an `error` port does not end the run,
        // so run-level settling never fires and `freeze` repairs only the persisted copy, not the live timelines.
        if var events = nodeTimelines[nodeID], !events.isEmpty {
            let closedRows = DanglingToolRowCloser.closeReporting(&events, outcome: .failed)
            if !closedRows.isEmpty {
                nodeTimelines[nodeID] = events
                workflowLogger.info("[WF_EVENT] Node '\(profileName)' failed with \(closedRows.count) tool row(s) still executing — closed with failure semantics. CONSEQUENCE: the rows settle as 'Interrupted before the tool finished.' instead of spinning for the rest of the run.")
                postLiveWriteCompletions(closedRows, context: "node '\(profileName)' failure")
            }
        }
    }

    /// A node that DID NOT RUN — or, since Phase B, one the user skipped MID-FLIGHT.
    /// Never routed through `handleNodeFailed` — that was the bug.
    func handleNodeSkipped(nodeID: UUID, profileName: String, reason: NodeSkipReason, ranBeforeSkip: Bool) {
        let detail = reason.displayText
        if let idx = nodeResults.firstIndex(where: { $0.nodeID == nodeID }) {
            nodeResults[idx] = WorkflowNodeResult(
                id: nodeResults[idx].id, nodeID: nodeID, profileName: profileName,
                status: .skipped(reason), detail: detail,
                startTime: nodeResults[idx].startTime, endTime: Date(),
                // Stored as told by the executor, never re-derived from row presence: a pending skip can become a running skip.
                hasWarnings: nodeResults[idx].hasWarnings,
                ranBeforeSkip: ranBeforeSkip
            )
        } else {
            nodeResults.append(WorkflowNodeResult(
                id: UUID(), nodeID: nodeID, profileName: profileName,
                status: .skipped(reason), detail: detail,
                startTime: Date(), endTime: Date(),
                ranBeforeSkip: ranBeforeSkip
            ))
        }
        // A running skip can abandon an in-flight tool; close its rows with skip semantics (no failure badge or count).
        // `.byUser` only: a cascade skip never ran, so it has no rows to close.
        if case .byUser = reason, var events = nodeTimelines[nodeID], !events.isEmpty {
            let closedRows = DanglingToolRowCloser.closeForUserSkipReporting(&events)
            if !closedRows.isEmpty {
                nodeTimelines[nodeID] = events
                workflowLogger.info("[WF_EVENT] Node '\(profileName)' skipped by user with \(closedRows.count) tool row(s) still executing — closed with skip semantics. CONSEQUENCE: the rows settle as 'Interrupted — the node was skipped by you' instead of spinning for the rest of the run and freezing as red failures.")
                postLiveWriteCompletions(closedRows, context: "user skip of node '\(profileName)'")
            }
        }
    }

    // Why: `@ObservationIgnored`: nothing renders it, and it would invalidate every observing view for a value none reads.
    /// Nodes whose last attempt failed but which the executor has already committed to retrying.
    /// Set by `handleNodeRetryScheduled` before the back-off, cleared when the node reaches any other resolution.
    @ObservationIgnored private(set) var retryPendingNodeIDs: Set<UUID> = []

    /// The conversation this run belongs to, stamped once by `WorkflowRunBootstrap.begin`.
    /// Used only by `postLiveWriteCompletions` to address Code Viewer tabs; nil when the state was built without one.
    @ObservationIgnored var conversationID: UUID?

    // Why: node rows live in `nodeTimelines`, which the message-level finalize loop does not walk, so tabs would stay active.
    /// Settles the live Code Viewer tab for every abandoned file write in `rows`.
    /// Reports `isSuccess: false` with no pre-write content; a row that opened no tab is a harmless no-op.
    private func postLiveWriteCompletions(_ rows: [DanglingToolRowCloser.ClosedRow], context: String) {
        guard !rows.isEmpty else { return }
        guard let conversationID else {
            workflowLogger.error("[WORKFLOW] \(rows.count) abandoned tool row(s) settled at \(context) but this run has NO conversationID, so no live-write completion can be addressed. CONSEQUENCE: a Code Viewer tab opened for one of these writes stays marked 'agent is writing this file' for the rest of the session and its ⌘S is refused as on-disk drift.")
            return
        }
        for row in rows {
            guard let payload = AgentLiveWriteEvent.completed(
                toolName: row.name,
                params: row.params,
                isSuccess: false,
                preWriteContent: nil,
                conversationID: conversationID
            ) else { continue }
            NotificationCenter.default.post(
                name: AgentLiveWriteEvent.completed, object: nil,
                userInfo: [AgentLiveWriteEvent.payloadKey: payload]
            )
            workflowLogger.warning("[WORKFLOW] No completion event ever arrived for the live write of '\(payload.fileName)' (settled at \(context)); posting a failed completion now. CONSEQUENCE: if that file has a live tab it settles as rejected — the proposal never reached disk — instead of claiming the agent is still writing it.")
        }
    }

    // Why: a node must not claim to be retrying until the retry starts: a Stop during the delay means it never will.
    /// The executor has decided to retry this node and is about to wait out the back-off.
    /// Records only the pending-retry fact; the row keeps the `.failed` status of the attempt that just ended.
    func handleNodeRetryScheduled(nodeID: UUID, profileName: String, attemptsRemaining: Int) {
        retryPendingNodeIDs.insert(nodeID)
    }

    func handleNodeCancelled(nodeID: UUID, profileName: String) {
        // Any resolution supersedes a pending retry. A failure arrives before the next retry-scheduled event,
        // so clearing here and re-adding there leaves a terminal failure with the flag off.
        retryPendingNodeIDs.remove(nodeID)
        let detail = String(localized: "Cancelled before the node finished.")
        if let idx = nodeResults.firstIndex(where: { $0.nodeID == nodeID }) {
            nodeResults[idx] = WorkflowNodeResult(
                id: nodeResults[idx].id, nodeID: nodeID, profileName: profileName,
                status: .cancelled, detail: detail,
                startTime: nodeResults[idx].startTime, endTime: Date()
            )
        } else {
            nodeResults.append(WorkflowNodeResult(
                id: UUID(), nodeID: nodeID, profileName: profileName,
                status: .cancelled, detail: detail,
                startTime: Date(), endTime: Date()
            ))
        }
    }

    // MARK: - Input Preview Resolution

    // Why: applied in the pass-through recursion too, so a full ancestor output is never joined; not applied to frozen records.
    /// Upper bound, in characters, on one upstream's contribution to a live input preview.
    /// The timeline's collapsed row cuts at 200 characters after trimming whitespace; 1,024 keeps that cut stable.
    nonisolated static let livePreviewContributionCap = 1_024

    // Why: status only: the engine also filters by output port, which needs run state that is not available here.
    /// Whether an upstream with this status contributed anything to what the node actually received.
    /// Mirrors `WorkflowInputAssembler.compileForWorkflow`'s usable-results rule for profile nodes, plus `.running`.
    nonisolated static func contributesInput(_ status: WorkflowNodeResult.Status) -> Bool {
        switch status {
        case .completed:         return true
        case .failed:            return true
        case .skipped(.byUser):  return true
        case .running:           return true
        case .cancelled, .skipped: return false
        }
    }

    /// The text one upstream result contributes to a downstream node's input preview.
    /// A user-skipped node contributes the input it passed through, not its skip sentence; other statuses contribute their `detail`.
    /// - Parameter userInput: the run's own input, forwarded verbatim by a skipped ENTRY node.
    nonisolated static func upstreamInputContribution(
        of result: WorkflowNodeResult,
        resultsByNodeID: [UUID: WorkflowNodeResult],
        edges: [WorkflowEdge],
        userInput: String,
        visited: Set<UUID> = []
    ) -> String {
        guard case .skipped(.byUser) = result.status else { return result.detail }
        // Guards against cycles: this walks edges, not the sorted order, so a corrupt layout must not recurse forever.
        guard !visited.contains(result.nodeID) else {
            workflowLogger.error("[WORKFLOW] Input preview for node \(result.nodeID.uuidString.prefix(8)) ('\(result.profileName)') hit a CYCLE walking back through user-skipped upstreams. CONSEQUENCE: this node's contribution falls back to its skip sentence, so one downstream input preview reads wrong; the run itself is unaffected — the engine forwarded the real text.")
            return result.detail
        }
        var seen = visited
        seen.insert(result.nodeID)

        // Same per-source de-dup as the factories that call this: a user skip wired into two ports must contribute once.
        var seenUpstreamIDs = Set<UUID>()
        let upstreamIDs = edges
            .filter { $0.targetNodeID == result.nodeID }
            .map(\.sourceNodeID)
            .filter { seenUpstreamIDs.insert($0).inserted }
        let upstreamResults = upstreamIDs.compactMap { resultsByNodeID[$0] }
        // With no upstream envelopes the skip forwards the run's input, as the engine does for an entry node.
        guard !upstreamResults.isEmpty else { return userInput }
        return upstreamResults
            .map {
                upstreamInputContribution(of: $0, resultsByNodeID: resultsByNodeID,
                                          edges: edges, userInput: userInput, visited: seen)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// [workflow/vm-3] One contribution, bounded for a LIVE preview. See the cap's own note for
    /// why the recursion above is bounded through this too rather than only at the factory.
    nonisolated static func boundedUpstreamInputContribution(
        of result: WorkflowNodeResult,
        resultsByNodeID: [UUID: WorkflowNodeResult],
        edges: [WorkflowEdge],
        userInput: String
    ) -> String {
        let full = upstreamInputContribution(of: result, resultsByNodeID: resultsByNodeID,
                                             edges: edges, userInput: userInput)
        guard full.count > livePreviewContributionCap else { return full }
        return String(full.prefix(livePreviewContributionCap))
    }

    // MARK: - Progress

    func handleProgress(completed: Int, total: Int) {
        completedNodes = completed
        totalNodes = total
    }

    func handleFinalOutput(_ output: String) {
        finalOutput = output
        isRunning = false
        completedAt = Date()
    }

    // Why: `cancelled:` is required, not a call-site `if`: a Stop ends the stream normally, so a missed branch reads as Failed.
    /// Handles the end of the stream driving this run; `cancelled` is the consumer's `Task.isCancelled` at loop exit.
    func handleStreamEnd(finalText: String, cancelled: Bool) {
        guard cancelled else {
            // A run whose failure is already settled must not re-narrate it as its answer: `finalText` here is the error text.
            guard workflowError == nil else { return }
            handleFinalOutput(finalText)
            return
        }
        // Keeps any output the run produced before the Stop; `handleError` does not set `finalOutput`.
        finalOutput = finalText
        handleError("Cancelled", cancelled: true)
    }

    /// - Parameter cancelled: true when the user stopped the run, false for a thrown failure.
    ///   Drives the wording of the synthetic node detail and tool output, mirroring
    ///   `DanglingToolRowCloser`'s outcome-aware text.
    func handleError(_ error: String, cancelled: Bool = false) {
        workflowError = error
        isRunning = false
        completedAt = Date()
        // Latched, never cleared: `freeze` reads it to decide `.cancelled` vs `.failed`, and a
        // cancel is the last thing that happens to a run.
        if cancelled { wasCancelled = true }
        settleInFlightWork(cancelled: cancelled)
    }

    // Why: a cancel only sets error state, so node results and tool rows would otherwise freeze as `.running`.
    /// Settles everything the run left mid-flight, so the frozen record cannot claim work is still happening.
    /// Returns the number of nodes and tool rows settled.
    @discardableResult
    func settleInFlightWork(cancelled: Bool) -> (nodes: Int, toolRows: Int) {
        let detail = cancelled
            ? "Cancelled before the node finished."
            : "Interrupted before the node finished."

        var settledNodes = 0
        // Settleable: `.running`, or retry-pending (failed, but the executor already committed to a retry, so still in flight).
        // `handleNodeStarted` reopens such a row once the retry starts; this covers the back-off window before that.
        let settleable: (WorkflowNodeResult) -> Bool = { [retryPendingNodeIDs] result in
            result.status == .running
                || (result.status == .failed && retryPendingNodeIDs.contains(result.nodeID))
        }
        for i in nodeResults.indices where settleable(nodeResults[i]) {
            let previous = nodeResults[i]
            nodeResults[i] = WorkflowNodeResult(
                id: previous.id,
                nodeID: previous.nodeID,
                profileName: previous.profileName,
                // `.cancelled`, not `.failed`, when the user pressed Stop, so a cancelled run shows no failure badge.
                status: cancelled ? .cancelled : .failed,
                detail: previous.detail.isEmpty ? detail : "\(previous.detail)\n\(detail)",
                startTime: previous.startTime,
                endTime: Date(),
                hasWarnings: previous.hasWarnings
            )
            settledNodes += 1
        }

        var closedRows = 0
        var abandonedWrites: [DanglingToolRowCloser.ClosedRow] = []
        for nodeID in nodeTimelines.keys {
            guard var events = nodeTimelines[nodeID] else { continue }
            let closed = DanglingToolRowCloser.closeReporting(&events, outcome: cancelled ? .cancelled : .failed)
            if !closed.isEmpty {
                nodeTimelines[nodeID] = events
                closedRows += closed.count
                abandonedWrites += closed
            }
        }
        // [cv-3] After the loop, so one post per abandoned row across the whole run rather than
        // per node — and so the row mutations are all committed before any handler observes them.
        postLiveWriteCompletions(abandonedWrites, context: cancelled ? "run cancel" : "run failure")

        if settledNodes > 0 || closedRows > 0 {
            workflowLogger.warning("[WORKFLOW] Run settled at \(cancelled ? "cancel" : "failure") — force-closed \(settledNodes) node(s) still marked running and \(closedRows) dangling tool row(s). Without this the frozen record renders them as actively executing forever.")
        }
        return (settledNodes, closedRows)
    }

    // There is deliberately no `reset()`: each run gets a fresh state at `WorkflowRunBootstrap.begin`.
    // A reuse path would need each property added to the initializer, not a hand-written reset list.
}
