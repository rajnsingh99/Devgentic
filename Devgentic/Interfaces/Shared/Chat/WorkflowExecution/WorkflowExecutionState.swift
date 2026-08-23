//
//  WorkflowExecutionState.swift
//  Devgentic
//
//  The LIVE workflow-run state — fed by ActiveStreamManager's workflow event routing, read by
//  WorkflowRunDisplayData and frozen into WorkflowRunRecord at run end.
//
//  ⚠️ Split out of WorkflowExecutionView.swift (WF-UI8): that file's VIEW half
//  (`WorkflowExecutionView` + `AgentOutcomeCard`) had ZERO call sites — dead since the timeline
//  redesign — while THIS state object in the same file was live and heavily consumed. Sharing the
//  file cost real maintenance twice: two sessions fixed accessibility on an equally dead sibling
//  view before it was deleted (2026-08-11), and the 2026-08-15 status-model work had to make the
//  dead view's switches exhaustive just to keep the build green. The dead half is deleted; if a
//  canvas-embedded run view is ever wanted again, build it against WorkflowRunDisplayData like the
//  timeline does.
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
    /// For a `.skipped` node only: did it BEGIN EXECUTING before the skip settled?
    ///
    /// ⚠️ Presentational, and deliberately NOT named `didRun` — `NodeDisplayData.NodeStatus.didRun`
    /// already exists and answers a different question (it is false for every skip). Two properties
    /// answering "did it run" differently in one layer is the trap; this one is scoped to skips by
    /// its name. It must NEVER feed `didNotRun` / `isGenuineFailure` / the run roll-ups — a skip is
    /// still a skip whether or not work was discarded.
    var ranBeforeSkip: Bool = false

    var duration: TimeInterval {
        (endTime ?? Date()).timeIntervalSince(startTime)
    }

    enum Status: Sendable, Equatable {
        case running
        case completed
        case failed
        /// The node did not run. NOT a failure — carries the structural cause.
        ///
        /// ⚠️ This case existed for a long time with NO WRITER: the event channel had no way to say
        /// "skipped", so every not-run node arrived as `.failed` and the UI reconstructed the truth
        /// by string-matching English prose out of the detail field. `workflowNodeSkipped` is what
        /// finally makes it reachable.
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

    /// Whether this run ended because the USER stopped it.
    ///
    /// ⚠️ Distinct from `workflowError != nil`, which a cancel also sets. Without this the two are
    /// indistinguishable by the time `WorkflowRunRecord.freeze` runs, so a deliberate Stop was
    /// persisted and rendered as **Failed** — a red pill and an `xmark.circle.fill` reporting the
    /// user's own action back to them as an error, permanently, with no way to tell a run they
    /// stopped from one that broke. `RunStatus.cancelled` existed and was unreachable, and the
    /// amber "Cancelled" vocabulary in the history card, the run picker and the timeline header
    /// was dead code.
    var wasCancelled: Bool = false

    /// Shared workflow variables (written by Code nodes).
    var variables: [String: String] = [:]

    /// Per-node timeline events for expanded node detail views.
    /// Keyed by nodeID, populated by ActiveStreamManager when sourceNodeID is present.
    var nodeTimelines: [UUID: [TimelineEvent]] = [:]

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

    /// Wall-clock end time of the run. Set when the workflow reaches a terminal
    /// state (`handleFinalOutput` / `handleError`). When non-nil, `WorkflowRunDisplayData`
    /// freezes `duration` at `completedAt - startedAt` instead of recomputing
    /// against the current date on every re-render — otherwise the "Total time"
    /// string would keep ticking up forever as long as the live state stays in memory.
    var completedAt: Date?

    /// ID of the persisted `WorkflowRunRecord` this live state is bound to.
    /// Set when `MessagingCoordinator` inserts an initial `.running` record at
    /// run start; reused when the same record is upserted with the final
    /// `.completed/.failed/.cancelled` payload on completion. Lets the UI
    /// resolve "the in-progress history row" back to this live state.
    var runRecordID: UUID?

    /// The run's observability traceID, stamped by ActiveStreamManager the moment the
    /// trace is minted (Run-Report Phase 5). Rides into the persisted WorkflowRunRecord
    /// so run history and the trace store finally share a join key (old Seam 4).
    var traceID: String?

    // MARK: - Per-Node Timeline

    /// Appends a timeline event to a specific node's timeline.
    func appendNodeTimelineEvent(_ event: TimelineEvent, for nodeID: UUID) {
        nodeTimelines[nodeID, default: []].append(event)
        // [TL-2/P3 sweep] Per-node workflow timelines are the same defect class as the
        // capability-card nested arrays — uncapped growth in memory, persistence, and
        // render. Same rule, same cap.
        ChatMessage.evictOverflow(&nodeTimelines[nodeID, default: []], context: "workflow-node")
    }

    // MARK: - Event Ingestion

    func handleNodeStarted(nodeID: UUID, profileName: String, index: Int, total: Int) {
        totalNodes = total
        isRunning = true

        // Add a running placeholder (avoid duplicates)
        guard !nodeResults.contains(where: { $0.nodeID == nodeID }) else { return }
        nodeResults.append(WorkflowNodeResult(
            id: UUID(), nodeID: nodeID, profileName: profileName,
            status: .running, detail: "Running...",
            startTime: Date()
        ))
    }

    func handleNodeCompleted(nodeID: UUID, profileName: String, summary: String, hasWarnings: Bool = false) {
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
        // Fold the actionable remediation into `detail` so it rides the existing
        // node-detail plumbing and surfaces in every run card (live + persisted)
        // with no adapter/snapshot changes.
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
                // ⚠️ Stored as TOLD, never re-derived from row presence. Row presence is a good
                // proxy but not the fact: the executor knows by control flow which side of the
                // node's start event it is on, and a `WorkflowNodeSkipStore` bridge can turn a
                // PENDING skip request into a running skip after dispatch — so "which button the
                // user pressed" and "did it run" are genuinely different questions.
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
        // A RUNNING-skip can abandon an in-flight tool. Nothing else closes per-node tool rows at
        // node end (only run-end settling — cancel/failure paths — and freeze, whose unconditional
        // close paints the row as a RED failure). Close them here with skip semantics: no badge,
        // no failure count, an output that says what happened. `.byUser` only — a cascade skip
        // never ran, so it has no rows to close, and touching them would hide a real defect.
        if case .byUser = reason, var events = nodeTimelines[nodeID], !events.isEmpty {
            let closed = DanglingToolRowCloser.closeForUserSkip(&events)
            if closed > 0 {
                nodeTimelines[nodeID] = events
                workflowLogger.info("[WF_EVENT] Node '\(profileName)' skipped by user with \(closed) tool row(s) still executing — closed with skip semantics. CONSEQUENCE: the rows settle as 'Interrupted — the node was skipped by you' instead of spinning for the rest of the run and freezing as red failures.")
            }
        }
    }

    /// A node stopped mid-flight by the user. Distinct from failure — the user asked for it, and
    /// showing it as a red "Failed" row under an amber "Cancelled" run pill reported the user's own
    /// action back to them as a fault.
    func handleNodeCancelled(nodeID: UUID, profileName: String) {
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

    func handleProgress(completed: Int, total: Int) {
        completedNodes = completed
        totalNodes = total
    }

    func handleFinalOutput(_ output: String) {
        finalOutput = output
        isRunning = false
        completedAt = Date()
    }

    /// The stream driving this run has ended. `cancelled` is the consumer's `Task.isCancelled`
    /// at the moment its loop exited.
    ///
    /// ⚠️ This is ONE method with a REQUIRED `cancelled:` argument, not an `if` at the call
    /// site, because the `if` is exactly the shape that shipped the defect: a workflow Stop
    /// does NOT throw `CancellationError` — `WorkflowExecutor` ends its cancel arm with
    /// `continuation.finish()` (not `finish(throwing:)`), and a cancelled `AsyncThrowingStream`
    /// TERMINATES rather than throws — so `ActiveStreamManager`'s consume loop fell out of
    /// `for try await` NORMALLY, took the success branch into `handleFinalOutput`, and left
    /// `wasCancelled` false. `freeze` then force-settled the still-`.running` node to `.failed`
    /// and rolled the whole run up as `.failed`: the workflow timeline reported the user's own
    /// Stop back to them as a red "Failed", while the trace store (stamped from the message's
    /// `terminalOutcome` on the same exit) correctly said "Cancelled". Two stores, two answers,
    /// one run. Making the caller name the outcome removes the branch that can be forgotten.
    func handleStreamEnd(finalText: String, cancelled: Bool) {
        guard cancelled else {
            handleFinalOutput(finalText)
            return
        }
        // Keep whatever the run did produce before latching — a Stop discards no evidence.
        // (`handleError` does not set `finalOutput`, and the buggy path did, so omitting this
        // would trade a wrong status for a lost partial answer.)
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

    /// Settles everything the run left mid-flight, so the frozen record cannot claim work is
    /// still happening.
    ///
    /// Nothing did this before: a cancel only set `workflowError`/`isRunning`/`completedAt`, and
    /// the executor's own `workflowNodeFailed(… "Cancelled")` yields are never consumed because
    /// cancelling the consumer throws `CancellationError` out of the `for await` loop first. So
    /// `WorkflowRunRecord.freeze` copied `.running` verbatim and the historical run rendered the
    /// node with a live accent spine badged "Running…" — days later. This is the workflow-side
    /// twin of the chat defect [TL-1] already fixed by `ChatMessage.closeDanglingToolRows`, and
    /// it uses the same shared closer for the node timelines.
    @discardableResult
    func settleInFlightWork(cancelled: Bool) -> (nodes: Int, toolRows: Int) {
        let detail = cancelled
            ? "Cancelled before the node finished."
            : "Interrupted before the node finished."

        var settledNodes = 0
        for i in nodeResults.indices where nodeResults[i].status == .running {
            let previous = nodeResults[i]
            nodeResults[i] = WorkflowNodeResult(
                id: previous.id,
                nodeID: previous.nodeID,
                profileName: previous.profileName,
                // ⚠️ `.cancelled`, not `.failed`, when the user pressed Stop. A cancelled run used
                // to persist its in-flight nodes as genuine failures, so the history card showed a
                // red "1 failed" capsule next to the amber "Cancelled" pill for the same run.
                status: cancelled ? .cancelled : .failed,
                detail: previous.detail.isEmpty ? detail : "\(previous.detail)\n\(detail)",
                startTime: previous.startTime,
                endTime: Date(),
                hasWarnings: previous.hasWarnings
            )
            settledNodes += 1
        }

        var closedRows = 0
        for nodeID in nodeTimelines.keys {
            guard var events = nodeTimelines[nodeID] else { continue }
            let closed = DanglingToolRowCloser.close(&events, outcome: cancelled ? .cancelled : .failed)
            if closed > 0 {
                nodeTimelines[nodeID] = events
                closedRows += closed
            }
        }

        if settledNodes > 0 || closedRows > 0 {
            workflowLogger.warning("[WORKFLOW] Run settled at \(cancelled ? "cancel" : "failure") — force-closed \(settledNodes) node(s) still marked running and \(closedRows) dangling tool row(s). Without this the frozen record renders them as actively executing forever.")
        }
        return (settledNodes, closedRows)
    }

    func reset() {
        nodeResults = []
        finalOutput = ""
        completedNodes = 0
        totalNodes = 0
        isRunning = false
        workflowError = nil
        nodeTimelines = [:]
        completedAt = nil
        runRecordID = nil
    }
}
