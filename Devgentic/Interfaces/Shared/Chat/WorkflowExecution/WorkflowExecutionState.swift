// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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

    /// [WF-RU4] True when at least one node genuinely failed, YET the run still reached a
    /// successful/answering terminal — the engine's own root-level verdict, carried across the
    /// stream boundary via `.workflowRunFinished` because `WorkflowRunRecord.freeze` has no live
    /// graph topology of its own to determine "is there an answering terminal" (it would have to
    /// duplicate the engine's edge-liveness logic to derive this independently).
    ///
    /// ⚠️ Deliberately NOT read by anything that drives the CHAT BUBBLE. An error-handled run (or
    /// one where an unrelated parallel branch delivered the answer) legitimately shows a plain
    /// green completed chip there — the delivered answer is exactly as complete as a clean run's.
    /// This flag exists only for the WORKFLOW-SPECIFIC surfaces (`freeze`'s persisted `RunStatus`,
    /// the Execution view's pill/step-counter), which — unlike the chat bubble — already show the
    /// individual failed node in red on its own row, so their SUMMARY must not silently agree the
    /// run was entirely clean.
    var completedDespiteNodeFailure: Bool = false

    /// [WF-CS4] True when this run started while its own canvas held unsaved edits — so the graph
    /// that executed (loaded from disk) is not the graph the user was looking at.
    ///
    /// ⚠️ A DISCLOSURE, never a gate: nothing branches execution on this. The run proceeds exactly
    /// as before; the flag only makes the existing, documented behaviour visible at the moment it
    /// matters. See `WorkflowRunEditDisclosure` for why disclosing beats saving or prompting here.
    ///
    /// Decided ONCE at `WorkflowRunBootstrap.begin` and never recomputed: the user may save the
    /// canvas while the run is in flight, and the answer must stay true of the graph that actually
    /// ran — the same reasoning that makes `WorkflowRunTicket.layoutSnapshot` a start-time capture.
    var ranWithUnsavedCanvasEdits: Bool = false

    /// [XUI-7] ⚠️⚠️ **NEVER POPULATED. ALWAYS `[:]`.** This is a stub, and the doc comment it
    /// replaces ("Shared workflow variables (written by Code nodes)") actively misled: that
    /// sentence is true of the ENGINE's `WorkflowState.variables`, which is a DIFFERENT type.
    ///
    /// The engine's field works — `WorkflowState.setVariable` is fed by Code-node `outputVariable`,
    /// and Router rules and templates read it. But `WorkflowState` is a struct local to the
    /// executor's stream closure, while this is an `@Observable` class rebuilt from
    /// `AgentStreamEvent`s, and there is no event case carrying variables across that boundary. So
    /// nothing writes this, `WorkflowRunRecord.freeze` copies the empty map into every run record,
    /// and `WorkflowRunRecordSD` faithfully persists `{}` for every run ever executed.
    ///
    /// ⚠️ **THE READ SIDE IS DEAD TOO**, which is why this is documented rather than fixed (owner
    /// decision, 2026-09-02). `WorkflowRunDisplayData.variables` is assigned from both factories and
    /// read by ZERO call sites app-wide — no Variables panel exists. Nothing is corrupted and
    /// nothing is lost that anyone reads.
    ///
    /// ⚠️ **WIRING THIS UP BUYS ALMOST NOTHING**, and that is the substantive reason, not the
    /// effort: every variable's value is ALREADY persisted verbatim in the same row. A Code node's
    /// output is simultaneously `variableUpdates[name]` and the node's `detail`, so capture would
    /// add only the name→value MAPPING — itself recoverable by joining the persisted layout's
    /// `config.outputVariable` to the node id. It would also roughly double the stored bytes for
    /// Code-node output, uncapped (a Code node whose template is `{{ input }}` copies an LLM's
    /// whole response into a variable, and there is no `maxPersistedNodeTimelineEvents` equivalent).
    ///
    /// **If you are here to build a Variables panel: wire the CAPTURE first.** Add a
    /// `case workflowVariablesSnapshot([String: String])` to `AgentStreamEvent`, yield it from the
    /// executor's serial drain right after the `state.setVariable` folds (⚠️ NOT from
    /// `.workflowRunFinished`, which is yielded only on the SUCCESS branch — precisely the runs
    /// where variables are least diagnostic), assign it here, and cap the VALUES on the way into
    /// `freeze`. Wiring the capture WITHOUT a reader is strictly worse than this comment: pure
    /// write cost, still nothing visible.
    var variables: [String: String] = [:]

    /// Per-node timeline events for expanded node detail views.
    /// Keyed by nodeID, populated by ActiveStreamManager when sourceNodeID is present.
    var nodeTimelines: [UUID: [TimelineEvent]] = [:]

    /// Drops this run's per-node traces once they have been PERSISTED, keeping the state object
    /// itself (register XUI-15). Returns the number of events released, for the caller's log.
    ///
    /// ⚠️ THE STATE OBJECT SURVIVES ON PURPOSE. `workflowExecutionStates` is keyed by conversation
    /// and holds `runRecordID`, `isRunning` and the HITL wiring; evicting the ENTRY is the
    /// dangerous shape XUI-11 rejected. Dropping only the traces keeps every identity and every
    /// binding intact, and the run view re-reads them from the store exactly as it does for a
    /// historical run.
    ///
    /// ⚠️ REFUSES WHILE RUNNING, and that is not defensive: a scheduled, ChatOps, QuickAccess or
    /// Jarvis run continues in a conversation that is not on screen, and its trace is being
    /// appended to as it goes. Dropping it mid-flight would delete the evidence of a run in
    /// progress and leave the events after the drop looking like the whole story.
    ///
    /// ⚠️ REFUSES UNTIL THE RECORD IS FROZEN (register CF-28), and "settled" is NOT that.
    /// `isRunning` goes false inside `handleStreamEnd`/`handleError`, but the freeze that copies
    /// these timelines into the persisted record runs only after the stream's
    /// `await finalizeMessage` and a further main-queue hop — see `hasFrozenRecord`. Inside that
    /// window the store holds only the `.running` stub, so a release here is not "re-read later"
    /// but LOST: `WorkflowRunRecord.freeze` reads `nodeTimelines` per node and persists nil for
    /// an absent one, and XUI-11/XUI-14 removed every other in-memory copy. The refusal is
    /// logged with the run id because the switch sweep that calls this cannot tell "nothing to
    /// release" from "kept on purpose".
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

    /// [CF-28] True once `WorkflowRunRecord.freeze` has copied this state — timelines included —
    /// into the record that `WorkflowRunTicket.finalize()` persists. Set only through
    /// `markRecordFrozen()`, which `finalize()` calls on BOTH of its paths: the natural one
    /// (stream `onComplete`) and the quit-time `forceFinalizeActiveRuns`, which is the same
    /// `finalize()`.
    ///
    /// ⚠️ THIS IS NOT `!isRunning`, AND THE GAP BETWEEN THEM IS A DATA-LOSS WINDOW. `isRunning`
    /// goes false inside `handleStreamEnd` → `handleFinalOutput`/`handleError`, while
    /// `ActiveStreamManager` is still inside its consume task. The freeze runs only after that
    /// task's `await finalizeMessage(...)` — a genuine suspension, it awaits
    /// `TraceRecorder.endTrace` — and then `onComplete()` → a `DispatchQueue.main.async` hop in
    /// every coordinator → `workflowTicket?.finalize()`. Main-actor work landing in that window
    /// (the conversation-switch sweep's `releaseSettledTraces()` was the one that shipped) sees a
    /// settled run whose traces exist ONLY here: the store still holds the `.running` stub, and
    /// `freeze` persists `nodeTimeline: nil` for every node missing from `nodeTimelines`. So
    /// "may these traces be dropped?" has to mean "have they been captured?", which is this
    /// flag — not "has the run stopped?".
    private(set) var hasFrozenRecord = false

    /// Called by `WorkflowRunTicket.finalize()` the moment `WorkflowRunRecord.freeze` returns —
    /// before the (fire-and-forget, off-main-encoded) persist task even starts. That is the
    /// right instant: `freeze` has COPIED the timelines into the record VALUE the persist task
    /// encodes, so the live copy plays no further part regardless of when the write lands.
    func markRecordFrozen() {
        hasFrozenRecord = true
    }

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
        // [CF-30] Any resolution supersedes a pending retry. `handleNodeFailed` clears it too:
        // the failure of attempt N arrives BEFORE the retry-scheduled for attempt N+1, so clearing
        // here and re-adding there is what makes a terminal failure leave the flag off.
        retryPendingNodeIDs.remove(nodeID)
        totalNodes = total
        isRunning = true

        if let idx = nodeResults.firstIndex(where: { $0.nodeID == nodeID }) {
            // [WF-RU12] A `started` for a node that already has a `.failed` row is a RETRY —
            // the executor emits started/failed PER ATTEMPT (`executeProfileNodeWithRetry`,
            // and the structural bounded path). This guard used to swallow the re-start
            // entirely, which left the row red-and-finished while attempts 2…N burned tokens
            // underneath it: both Skip buttons (gated on `.pending`/`.running`) vanished on
            // exactly the runaway node they exist for, and `settleInFlightWork` (which only
            // repairs `.running` rows) persisted a Stop mid-retry as a genuine failure.
            // Reopen the row instead. `.failed` ONLY: retries never follow `.completed`,
            // `.skipped` or `.cancelled` (`WorkflowRetryPolicy.stopsRetrying`), so a started
            // event against any other status is out-of-order noise and keeps the old guard.
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
        // [CF-30] Any resolution supersedes a pending retry. `handleNodeFailed` clears it too:
        // the failure of attempt N arrives BEFORE the retry-scheduled for attempt N+1, so clearing
        // here and re-adding there is what makes a terminal failure leave the flag off.
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
        // [CF-30] Any resolution supersedes a pending retry. `handleNodeFailed` clears it too:
        // the failure of attempt N arrives BEFORE the retry-scheduled for attempt N+1, so clearing
        // here and re-adding there is what makes a terminal failure leave the flag off.
        retryPendingNodeIDs.remove(nodeID)
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
        // [WF-RU10] Mirrors `handleNodeSkipped`'s `.byUser` arm just below: THIS node's own
        // failure is the one moment nothing else is guaranteed to close its dangling tool rows.
        // `settleInFlightWork` (the run-level backstop) fires only from `handleError`, which a
        // node failing into an activated `error` port never reaches — the run keeps going and can
        // complete normally. `freeze()`'s own close acts on a value-type COPY of `nodeTimelines`
        // and never writes back (Dictionary subscript-get returns a copy), so it repairs only the
        // PERSISTED record — the LIVE `nodeTimelines` the Execution view reads while
        // `executionState` is still attached stays open, and `AgentTimelineView` renders any row
        // with `isExecuting == true` as an indefinite spinner. Closing here, at the node's own
        // failure, fixes the view for the rest of THIS run instead of only the next time it's
        // reopened from a fresh record.
        if var events = nodeTimelines[nodeID], !events.isEmpty {
            let closed = DanglingToolRowCloser.close(&events, outcome: .failed)
            if closed > 0 {
                nodeTimelines[nodeID] = events
                workflowLogger.info("[WF_EVENT] Node '\(profileName)' failed with \(closed) tool row(s) still executing — closed with failure semantics. CONSEQUENCE: the rows settle as 'Interrupted before the tool finished.' instead of spinning for the rest of the run.")
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
    /// [CF-30] Nodes whose last attempt FAILED but which the executor has already committed to
    /// retrying. Set by `handleNodeRetryScheduled` before the back-off begins, cleared the moment
    /// the node reaches any other resolution.
    ///
    /// ⚠️ `@ObservationIgnored`: nothing renders this, and a run that retries several nodes would
    /// otherwise invalidate every observing view for a value none of them read. Its only consumer
    /// is `settleInFlightWork`.
    @ObservationIgnored private(set) var retryPendingNodeIDs: Set<UUID> = []

    /// [CF-30] The executor has decided to retry this node and is about to wait out the back-off.
    ///
    /// Records ONLY the pending-retry fact. The row keeps the `.failed` status and detail of the
    /// attempt that just ended — WF-CC4 established that a node must not claim to be retrying
    /// until the retry actually starts, because a Stop during the delay means it never will.
    func handleNodeRetryScheduled(nodeID: UUID, profileName: String, attemptsRemaining: Int) {
        retryPendingNodeIDs.insert(nodeID)
    }

    func handleNodeCancelled(nodeID: UUID, profileName: String) {
        // [CF-30] Any resolution supersedes a pending retry. `handleNodeFailed` clears it too:
        // the failure of attempt N arrives BEFORE the retry-scheduled for attempt N+1, so clearing
        // here and re-adding there is what makes a terminal failure leave the flag off.
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

    /// The text an upstream node actually CONTRIBUTES to a downstream node's displayed input.
    ///
    /// ⚠️ [CF-31] For every status but ONE this is simply `detail`. The exception is
    /// `.skipped(.byUser)`: `handleNodeSkipped` stores the skip SENTENCE as that node's detail
    /// ("Skipped by you — its input was passed downstream unchanged."), while the engine forwards
    /// the node's own INPUT downstream — `WorkflowExecutor`'s user-skip arm builds `passThrough`
    /// from the node's upstream envelopes, or from the run's own query at an entry node. Reading
    /// `detail` therefore showed the node that is RUNNING RIGHT NOW the skip sentence where its
    /// input belongs: the one string it is guaranteed not to have received. Every other skip
    /// reason keeps `detail`, because `NodeSkipReason.keepsDownstreamAlive` is false for all of
    /// them — nothing below them ever runs to preview anything.
    ///
    /// ⚠️ A PREVIEW, not a byte-for-byte reconstruction. `WorkflowInputAssembler.compileForWorkflow`
    /// has its own separators and status filter; this mirrors the surrounding preview code's
    /// "\n\n" join so the live factory and `freeze` keep agreeing with each other. What it fixes
    /// is the SOURCE of the text, which is the half that was wrong.
    ///
    /// `nonisolated static` and pure (WF-UI5): both factories call it, and the pass-through
    /// recursion — the part a reader cannot verify by inspection — is what the test pins.
    ///
    /// - Parameter resultsByNodeID: every result of the run, so the walk back up the edges costs
    ///   a lookup rather than a scan.
    /// - Parameter userInput: the run's own input, forwarded verbatim by a skipped ENTRY node.
    nonisolated static func upstreamInputContribution(
        of result: WorkflowNodeResult,
        resultsByNodeID: [UUID: WorkflowNodeResult],
        edges: [WorkflowEdge],
        userInput: String,
        visited: Set<UUID> = []
    ) -> String {
        guard case .skipped(.byUser) = result.status else { return result.detail }
        // A layout is a DAG by construction (`WorkflowLayout.topologicalSort` returns nil on a
        // cycle) — but this walks EDGES, not that sorted order, so a corrupt layout must not
        // recurse forever. Chained user skips are the normal case here, not the exotic one.
        guard !visited.contains(result.nodeID) else {
            workflowLogger.error("[WORKFLOW] Input preview for node \(result.nodeID.uuidString.prefix(8)) ('\(result.profileName)') hit a CYCLE walking back through user-skipped upstreams. CONSEQUENCE: this node's contribution falls back to its skip sentence, so one downstream input preview reads wrong; the run itself is unaffected — the engine forwarded the real text.")
            return result.detail
        }
        var seen = visited
        seen.insert(result.nodeID)

        let upstreamIDs = edges.filter { $0.targetNodeID == result.nodeID }.map(\.sourceNodeID)
        let upstreamResults = upstreamIDs.compactMap { resultsByNodeID[$0] }
        // Mirrors the engine's own rule: with no upstream envelopes the skip forwards the run's
        // input ("An entry node's input is the user's query itself — forwarding '' there would
        // hand downstream a blank task").
        guard !upstreamResults.isEmpty else { return userInput }
        return upstreamResults
            .map {
                upstreamInputContribution(of: $0, resultsByNodeID: resultsByNodeID,
                                          edges: edges, userInput: userInput, visited: seen)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
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
            // [WF-RU1] A run whose failure is already settled must not have that failure
            // re-narrated as its ANSWER: on the failed path the message content was replaced by
            // the `.error` card, so `finalText` here is the error text — feeding it to
            // `handleFinalOutput` is exactly the laundering this row filed (`finalOutput` carried
            // "Execution Failed: …" while `record.error` froze nil). `handleError` already
            // stamped `isRunning`/`completedAt`; `finalOutput` stays whatever real output the
            // run produced before failing (usually empty — a failed run has no answer).
            guard workflowError == nil else { return }
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
        // [CF-30] `.running` OR retry-pending. A node whose attempt failed and whose retry the
        // executor had already committed to is, from the user's point of view, still in flight —
        // the run was going to keep working on it. Leaving it `.failed` put a red "1 failed"
        // badge beside the run's own amber "Cancelled" pill for a failure the user pre-empted and
        // the engine had not given up on. `handleNodeStarted` already reopens such a row once the
        // retry actually STARTS (WF-RU12); this covers the back-off window before that, which is
        // unreachable any other way because the executor's cancel event cannot be delivered.
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

    // [CF-33] ⚠️ THERE IS DELIBERATELY NO `reset()`. One existed, with zero production callers,
    // and it cleared ten of this class's eighteen stored properties — leaving `wasCancelled`,
    // `completedDespiteNodeFailure`, `ranWithUnsavedCanvasEdits`, `traceID`, `startedAt`,
    // `userInput`, `workflowProfileID` and `variables` behind. `WorkflowRunRecord.freeze` returns
    // `.cancelled` whenever `state.wasCancelled` and stamps `traceID: state.traceID`, so the first
    // caller it ever got would have persisted the NEXT run as "Cancelled", pointing at the
    // PREVIOUS run's trace, with the previous run's start time.
    //
    // Every run gets a fresh state at `WorkflowRunBootstrap.begin`, which is the shape that makes
    // the whole class of stale-field bugs unrepresentable. If a reuse path is ever genuinely
    // wanted, add the property to the initializer FIRST so a new field cannot be forgotten here —
    // do not resurrect a hand-written list.
}
