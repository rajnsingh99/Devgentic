//
//  WorkflowRunDisplayData.swift
//  Devgentic
//
//  Created by Raj Singh on 11/04/26.
//
//  Unified view adapter that both live WorkflowExecutionState and frozen
//  WorkflowRunRecord can produce. All downstream views render from this
//  struct, eliminating live-vs-historical branching in views.
//
//  The live factory (`from(live:layout:)`) takes the workflow layout so it can
//  pre-populate placeholder cards for nodes that haven't started yet ("pending"
//  status) and derive each node's input from upstream node detail in the same
//  way `WorkflowRunRecord.freeze(...)` does. This lets the new card-strip UI
//  show the full pipeline shape from the very first frame, instead of revealing
//  cards one-by-one as nodes start.
//

import SwiftUI
import os

private let logger = DGLogger(category: "WorkflowRunDisplay")

struct WorkflowRunDisplayData {
    let isLive: Bool
    let isRunning: Bool
    let nodeResults: [NodeDisplayData]
    let finalOutput: String
    /// [XUI-7] ⚠️⚠️ **ALWAYS EMPTY, from both factories.** `from(live:)` reads
    /// `WorkflowExecutionState.variables` and `from(record:)` reads `WorkflowRunRecord.variables`,
    /// and both of those are the never-populated stub — see the long note on
    /// `WorkflowExecutionState.variables` for why the engine's real variables never cross the
    /// stream boundary. Nothing in the app reads THIS field either, so a "Variables" section built
    /// on it would render a confidently-empty table. Wire the capture first.
    let variables: [String: String]
    let totalNodes: Int
    let workflowError: String?
    let userInput: String
    let timestamp: Date
    let status: WorkflowRunRecord.RunStatus?
    /// Wall-clock duration of the run so the header can show "Total time X.Xs".
    /// For live runs, computed from `startedAt`; for historical, from the record.
    let duration: TimeInterval
    /// Join key into the trace store — the title bar's Report button opens the run
    /// report with it. nil for pre-trace-era historical rows; the report panel
    /// renders its own "never recorded" explanation for those, so the button does
    /// not need to guess.
    var traceID: String? = nil
    /// [WF-CS4] This run executed the last-saved graph while the canvas held unsaved edits. Drives
    /// the disclosure row in the run header — see `WorkflowRunEditDisclosure`.
    ///
    /// ⚠️ LIVE RUNS ONLY, by owner decision (2026-08-24). `from(record:)` leaves this false and
    /// cannot do otherwise: `WorkflowRunRecord` is rebuilt from promoted SwiftData columns and has
    /// no column for it, so persisting the disclosure needs a schema version bump nobody has taken
    /// on yet. Do NOT "fix" this by adding the field to `WorkflowRunRecord` alone — it would be
    /// dropped at `decodeRecord` and this comment would become a lie. See the note in that file.
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
        /// For a `.skipped` node: did it BEGIN EXECUTING before the skip settled? nil = the record
        /// predates the field, so the label falls back to the legacy heuristic below rather than
        /// asserting a confident wrong answer.
        ///
        /// ⚠️ Presentational ONLY. `NodeStatus` stays flat and `nodeDidNotRun` stays untouched, so
        /// run roll-ups, the "N failed" badge and the history card keep their current meaning — a
        /// skip is a skip whether or not work was discarded.
        var ranBeforeSkip: Bool? = nil
        /// Why this node did not run. `NodeStatus` is deliberately flat, so the reason would
        /// otherwise die at `mapLiveStatus`/`mapRecordStatus` — which is exactly why the canvas
        /// overlay could not tell a pass-through user skip from a dead branch.
        var skipReason: NodeSkipReason? = nil
        /// Whether this node kind produces a meaningful step-by-step timeline
        /// (agent reasoning + tool calls, or an Action node's tool invocation).
        /// Bots, image generators, and structural transform nodes are single-shot;
        /// their timeline holds only incidental events (e.g. model-load thoughts).
        /// ⚠️ This used to name `WorkflowOutputView`, which hid a Timeline tab and showed
        /// Output directly — that view and the whole `.original` layout were DELETED 2026-07-17.
        /// Today the readers are `WorkflowExecutionTimelineView` (which renders the per-node
        /// `AgentTimelineView` only when this is true) and `hasRenderableTimeline` below.
        let supportsTimeline: Bool

        /// Per-node SKIP eligibility (D2.1): PROFILE kinds only — bot, agent, sub-workflow.
        /// Structural kinds never render the button (a Router bypass is ill-defined, a Gate's
        /// skip IS a decision, a Trigger's skip makes the run meaningless), and the record path /
        /// orphaned-result path leave the default: a node whose kind is unknowable is not
        /// skippable. The engine enforces the same restriction independently.
        var isUserSkippable: Bool = false

        /// RUNNING-skip eligibility (Phase B increment 5) — strictly narrower than
        /// `isUserSkippable`: bot/agent only, NEVER sub-workflow. A pending sub-workflow node is
        /// skippable (the pre-dispatch consult handles it), but a RUNNING one is not — it executes
        /// down the structural path, which the running-skip racer never enters (increment 8,
        /// deferred). Rendering the button there would offer an action the engine cannot honour.
        var isRunningSkippable: Bool = false

        enum NodeStatus: Sendable {
            case pending, running, completed, failed, skipped, cancelled
            /// A status written by a NEWER build than this one. The node FINISHED (its detail,
            /// duration and trace are real and must render) — we just cannot classify how.
            ///
            /// ⚠️ This used to map to `.pending`, whose vocabulary is "Waiting" with no duration
            /// and a waiting-for-execution panel — so a node that finished days ago under a newer
            /// build read as never having started, and its decoded trace was suppressed. The
            /// run-LEVEL `.other` already renders "Unknown"; the node level now agrees.
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

    /// Builds display data from a live execution state. When `layout` is provided,
    /// pending placeholder cards are pre-populated for layout nodes that haven't
    /// started yet, and per-node inputs are derived from upstream `detail` (or
    /// `state.userInput` for source nodes). When `layout` is nil, behaviour falls
    /// back to "started nodes only" — same as the previous implementation.
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

        // Freeze the duration once the run reaches a terminal state. Without this,
        // every view re-render (selection change, hover, canvas toggle, etc.) would
        // recompute against `Date()` and the "Total time" string would tick up
        // indefinitely while the state lingers in memory.
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
            // Normally nil for a live run — the derived heuristics are the right answer while it
            // is still going. A CANCEL is the exception: `handleError` sets `workflowError` too,
            // so every heuristic downstream reads "failed" and the user's own Stop came back as a
            // red "Failed" pill for the whole window between stopping and the record freezing.
            // The run genuinely is cancelled at this point, live or not.
            //
            // [WF-RU4] `completedDespiteNodeFailure` is the SAME kind of exception: the derived
            // `hasGenuineFailure` heuristic (used when this is nil) has no way to know a
            // successful terminal exists, so without this a run whose error handling worked
            // exactly as designed would flash red "Failed" for the same live-window gap.
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

            // Compute "input": upstream nodes' detail joined; falls back to
            // user input for source nodes (no upstream edges).
            let upstreamIDs = layout.edges.filter { $0.targetNodeID == nodeID }.map(\.sourceNodeID)
            let upstreamResults = upstreamIDs.compactMap { resultByNodeID[$0] }
            let derivedInput: String? = {
                if !upstreamResults.isEmpty {
                    // [CF-31] `upstreamInputContribution`, NOT `\.detail`. A user-skipped upstream's
                    // detail is the skip SENTENCE, while the engine forwarded that node's own INPUT
                    // down this edge — so the node currently RUNNING previewed the one string it
                    // certainly did not receive. Every other status still resolves to `detail`.
                    let combined = upstreamResults
                        .map {
                            WorkflowExecutionState.upstreamInputContribution(
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

            // Hoisted above the live-result branch: a RUNNING node always carries a result, so it
            // takes that branch — setting skippability only on the pending placeholder was why the
            // flag never survived the pending→running transition (the row is rebuilt from a
            // different construction site with the default false).
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

    /// Live results whose node is NOT in the current layout — appended, never dropped (WF-UI7).
    ///
    /// ⚠️ The two factories used to DISAGREE on this exact question: the record path appends the
    /// orphan and logs ("Showing its persisted trace rather than hiding the evidence"), while this
    /// live path silently `compactMap`-dropped it. The one reachable route is mid-run layout
    /// divergence — delete/replace a node on the canvas, Save, return to Execution: the refreshed
    /// `cachedLayout` no longer contains the node that is EXECUTING RIGHT NOW, and its row —
    /// status, spine, live tool trace — vanished from the timeline while the step counter silently
    /// changed denominator. Same policy as the record path now: evidence is never hidden.
    private static func orphanedLiveResults(
        state: WorkflowExecutionState,
        nodeByID: [UUID: WorkflowNode]
    ) -> [NodeDisplayData] {
        let orphans = state.nodeResults.filter { nodeByID[$0.nodeID] == nil }
        guard !orphans.isEmpty else { return [] }
        // [CF-32] ⚠️ ONCE PER (run, orphan-set), not once per evaluation. This function runs inside
        // `from(live:layout:)`, which `WorkflowDedicatedView.displayData` rebuilds on EVERY body
        // pass — and the view re-evaluates on every streamed workflow event, because
        // `appendNodeTimelineEvent` mutates the `@Observable` `nodeTimelines` per thought and per
        // tool call. Unconditional logging therefore produced dozens of identical lines per second
        // for the whole remainder of a run whose layout diverged: the one route that reaches here
        // is also the one route that makes the line unreadable. The set is part of the key, so a
        // SECOND node leaving the layout still gets its own line.
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

    // MARK: - Orphan log de-duplication (CF-32)

    /// The last (run, orphan-set) that produced an orphan log line.
    ///
    /// ⚠️ `nonisolated(unsafe)` and deliberately unsynchronised. It is a LOG MEMO: the only thing a
    /// torn read can cost is one duplicated or one missed info line, never a wrong display, and
    /// every real caller is `WorkflowDedicatedView.body` on the main actor. Locking a value the
    /// render path touches per frame to protect a log line would be the worse trade.
    /// (`ToolSchemaSizes.sizesByName` is the same pattern.)
    nonisolated(unsafe) private static var lastLoggedOrphanSignature: String?

    /// The identity of one orphan situation: WHICH run, and WHICH nodes left its layout.
    ///
    /// Sorted so the signature does not change when `nodeResults` reorders — arrival order is not
    /// stable across parallel levels, and a signature that flipped with it would log on every
    /// frame again, which is the row.
    nonisolated static func orphanLogSignature(runID: UUID?, orphanNodeIDs: [UUID]) -> String {
        (runID?.uuidString ?? "<no run id>") + "|"
            + orphanNodeIDs.map(\.uuidString).sorted().joined(separator: ",")
    }

    /// True the FIRST time a signature is seen, false for every repeat until it changes.
    ///
    /// ⚠️ The memo lives here rather than in a pure predicate on purpose: "the second identical
    /// evaluation is silent" is the entire fix, and a pure `previous != next` helper would leave
    /// exactly that untested (WF-UI5's rule applied to a side effect).
    nonisolated static func shouldLogOrphans(signature: String) -> Bool {
        guard lastLoggedOrphanSignature != signature else { return false }
        lastLoggedOrphanSignature = signature
        return true
    }

    // MARK: - Factory: Frozen Run Record

    /// Builds display data from a persisted record. When `liveTimelines` is
    /// provided (typically by `WorkflowDedicatedView` when the in-memory
    /// `WorkflowExecutionState` still corresponds to this record), per-node
    /// timelines are pulled from memory; otherwise they fall back to the
    /// timeline persisted in the snapshot (`WorkflowNodeResultSnapshot.nodeTimeline`),
    /// so historical runs — especially FAILED ones, where the trace is the
    /// debugging evidence — still render the agent's reasoning/tool-call trace
    /// after a restart. Records predating timeline persistence fall back to
    /// the static `Output` view only.
    ///
    /// `layout` (the workflow's current layout) is used only to resolve each
    /// node's kind so the Timeline tab can be hidden for single-shot nodes
    /// (bots etc.). Node IDs are stable, so the live layout reliably classifies
    /// a historical run's nodes; if it's missing the tab simply isn't suppressed (the
    /// suppression is a display nicety — hiding a node's whole trace to achieve it is not).
    static func from(record: WorkflowRunRecord,
                     liveTimelines: [UUID: [TimelineEvent]]? = nil,
                     layout: WorkflowLayout? = nil) -> WorkflowRunDisplayData {
        let nodes = record.nodeResults.map { snapshot in
            // Prefer the in-memory timeline (freshest); fall back to the persisted one.
            let timeline = liveTimelines?[snapshot.nodeID] ?? snapshot.nodeTimeline ?? []
            let supportsTimeline: Bool = {
                guard let layout else { return true }   // unknown layout → preserve prior behavior
                guard let node = layout.nodes.first(where: { $0.id == snapshot.nodeID }) else {
                    // Do NOT suppress. `false` drops the node's persisted reasoning/tool-call
                    // trace entirely (the consumer gates the whole AgentTimelineView on this) —
                    // the very evidence `nodeTimeline` was added to keep for FAILED runs — and
                    // the doc comment above already promised the opposite. The miss is EXPECTED,
                    // not exotic: `runHistory` is keyed by conversation with no workflow-profile
                    // filter, so every node of a run belonging to a different workflow profile
                    // misses this lookup.
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
            // [WF-CS4] Deliberately NOT set: the disclosure is live-only and the record has nowhere
            // to carry it. Left at its `false` default rather than faked from anything else.
            runID: record.id
        )
    }

    // MARK: - Helpers

    /// Whether a node kind has a meaningful reasoning/tool-call timeline worth
    /// exposing via the Output/Timeline toggle. Agent profiles (including the
    /// agentic Code and nested Workflow profile types) and Action nodes do; bots,
    /// image generators, and structural transform nodes (condition/code/gate/
    /// trigger) are single-shot output, so their Timeline tab is hidden.
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
        // A status written by a newer build maps to the honest `.unknown`, NOT `.pending`:
        // pending's vocabulary ("Waiting", no duration, waiting-for-execution panel) claimed a
        // finished node never started and suppressed its decoded trace. Unknown renders neutrally
        // and routes the detail/duration/trace like a settled node.
        case .other:     return .unknown
        }
    }
}

// MARK: - Run roll-up (the verdict the user reads — WF-UI5)

/// The run-level verdict logic, extracted OFF the view so it is testable.
///
/// ⚠️ These were private computed properties on `WorkflowExecutionTimelineView` — a second,
/// independent implementation of "what happened to this run" that no test could reach, on a
/// surface with a documented regression history (five "this regressed before" comments). During
/// the 2026-08-15 verification the register's own claim about this surface was HALF-WRONG and no
/// test existed to settle it — which is this extraction's whole justification. The view keeps only
/// the Color mappings; everything that decides WHAT to say lives here.
extension WorkflowRunDisplayData {

    /// A node that never executed — rendered neutrally, never as the red of a genuine crash.
    /// The legacy branch covers records written before 2026-08-15 (no `.skipped` status to read).
    func nodeDidNotRun(_ node: NodeDisplayData) -> Bool {
        if node.status == .skipped { return true }
        return node.status == .failed && WorkflowNodeOutcome.isLegacyUpstreamSkip(detail: node.detail)
    }

    /// The status word shown for a node that did not run — THE single source for the visible tag,
    /// the VoiceOver label, and anything else that names a skip.
    ///
    /// ⚠️ Both surfaces used to hard-code "Not run", which is a lie for a RUNNING skip: that node
    /// started, spent model time and produced output that was then discarded. Observed on-device
    /// 2026-08-23 — a node tagged "Not run" whose own report showed an 829ms model call and a
    /// 1.7s duration next to the tag. The codebase already forbids this wording for `.byUser`
    /// (`UserNodeSkipTests` pins that `byUser.displayText` must not start with "Not run"); the
    /// DETAIL line obeyed it while the TAG directly above contradicted it.
    ///
    /// Decided from the STRUCTURAL fact, never from `detail` prose — prose-matching is this
    /// codebase's recidivist defect (nine surfaces re-derived it, three got it wrong).
    func skipTagLabel(for node: NodeDisplayData) -> String {
        guard nodeDidNotRun(node) else { return node.status.label }
        return nodeRanBeforeSkip(node) ? String(localized: "Skipped") : String(localized: "Not run")
    }

    /// THE status word for a node row — the visible tag AND the VoiceOver label both go through
    /// here, the same shape as `skipTagLabel` above (register XUI-10).
    ///
    /// ⚠️ They used to diverge. The tag applied THREE overrides — awaiting, did-not-run, degraded —
    /// and the label applied only one, so a node parked on a HITL prompt was TAGGED "Needs your
    /// input" and ANNOUNCED "Running...". The single state on this screen that is blocking on the
    /// user was the one state VoiceOver could not learn. An amber "Completed · warnings" row was
    /// likewise announced as a clean "Completed".
    func nodeTagLabel(for node: NodeDisplayData, isAwaiting: Bool) -> String {
        if isAwaiting { return String(localized: "Needs your input") }
        if nodeDidNotRun(node) { return skipTagLabel(for: node) }
        if node.status == .completed, node.hasWarnings {
            return String(localized: "Completed · warnings")
        }
        return node.status.label
    }

    /// Whether a skipped node had already started when the skip landed.
    ///
    /// `nil` means the record was written before the fact was persisted. The legacy tier reads the
    /// two signals that ARE already on disk: a pre-dispatch skip is stamped with two adjacent
    /// `Date()` calls so its duration is ~0 by construction, and it never accumulates a timeline.
    /// It has false negatives (a node skipped microseconds after starting), so it errs toward the
    /// OLD wording and never toward a false "it ran".
    func nodeRanBeforeSkip(_ node: NodeDisplayData) -> Bool {
        if let known = node.ranBeforeSkip { return known }
        return node.duration > 0.05 || !node.nodeTimeline.isEmpty
    }

    /// What to tell the user about a node that did not run. The engine writes the structural cause
    /// into `detail` (`NodeSkipReason.displayText`); the fallback covers pre-2026-08-15 records.
    func notRunMessage(for node: NodeDisplayData) -> String {
        let detail = node.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? String(localized: "Not run") : detail
    }

    /// Whether an expanded row has captured agent evidence worth rendering (register XUI-1).
    ///
    /// THE single gate for every arm that renders a settled `AgentTimelineView` — including
    /// `.skipped` and `.cancelled`. Those two arms used to render only a one-line status while
    /// the trace captured live (and persisted by `freeze`, up to 400 events) sat unreachable:
    /// the same run showed an 829ms model call in the Run Report and nothing at all in the
    /// timeline (observed 2026-08-23). The `expandedContent` guard above the switch was written
    /// to protect exactly this evidence and was a NO-OP for it — both branches rendered the same
    /// bare line for a `.skipped` node.
    func nodeShowsCapturedTrace(_ node: NodeDisplayData) -> Bool {
        node.supportsTimeline && !node.nodeTimeline.isEmpty
    }

    /// What the Final Outcome row's expanded panel shows (register XUI-2). Extracted OFF the view
    /// (the WF-UI5 shape) because the branch ORDER is the defect surface: "no nodes / all
    /// pending" was tested first, so a run that failed BEFORE its first node dispatched —
    /// pre-flight validation, unresolvable config, a reconciled orphan — rendered an hourglass
    /// "Waiting for execution" while its `workflowError` was shown nowhere, directly under a
    /// "Failed" tag. The terminal error now outranks the empty/pending test.
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
        // ⚠️ [XUI-13] STATUS-GATED, and FIRST. Every cancel path leaves a `workflowError` behind —
        // `handleError("Cancelled", cancelled: true)` for a Stop, `reconcileOrphans`' "Interrupted"
        // for a quit — so the error test below cannot tell the user's own Stop from a fault, and
        // reported it back to them in error red under the row's own amber "Cancelled" tag. This is
        // the identical conflation `RunCardBody.of` removed from the history card; the two surfaces
        // had begun to DISAGREE about whether a Stop was a failure, and this is the half that the
        // user is more likely to be looking at (the Final Outcome row expands by default).
        //
        // ⚠️ The `isCancelledRun` gate is load-bearing, not defensive: without it this branch would
        // swallow every genuine failure into the neutral register — strictly worse than the bug —
        // and would re-open XUI-2 by shadowing the error branch it was reordered ahead of.
        //
        // ⚠️ Output BEFORE reason, matching `RunCardBody.of`: a stopped run's partial answer is the
        // useful half and `handleStreamEnd` preserves it deliberately, while the reason is already
        // stated by the tag above. Ordering them the other way re-creates the half of `XUI-5` that
        // HID the output. Unlike the card there is no `.none` — falling through to `.waiting`
        // /`.progress` is correct here, because the timeline row must always render something.
        //
        // ⚠️ An EMPTY error string is not an error, and normalising it here is the second half of
        // making these two surfaces agree: `RunCardBody.of` already does exactly this
        // (`error.flatMap { $0.isEmpty ? nil : $0 }`), so without it the card silently ignored a
        // blank message while this panel drew an error-red line with nothing in it.
        let reason = workflowError.flatMap { $0.isEmpty ? nil : $0 }
        if isCancelledRun {
            if !finalOutput.isEmpty { return .output(finalOutput) }
            if let reason { return .reason(reason) }
        }
        // ⚠️ ORDER IS THE FIX (XUI-2): the error branch sat AFTER the empty/pending branch, and a
        // zero-node failed run satisfies both — the hourglass won and the reason was unreachable.
        if let reason, finalOutput.isEmpty { return .error(reason) }
        if nodeResults.isEmpty || nodeResults.allSatisfy({ $0.status == .pending }) { return .waiting }
        if isRunning && finalOutput.isEmpty { return .progress(synthesising: rowStatus == .running) }
        return .output(finalOutput)
    }

    /// ⚠️ GENUINE failures only. A skipped node is routing, a cancelled node is the user's own
    /// Stop; counting either turned the pill red on healthy runs.
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

    /// The header pill's verdict. ⚠️ The PERSISTED status wins over the derived heuristics — a
    /// `.running` orphan stub must say "Running", and `.other` must say "Unknown", never a
    /// derived "Completed" (see the regression history on the view).
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
            // A record marked completed that nonetheless carries a failed node is reported as
            // failed — the nodes are the evidence, the roll-up is a summary of them. Unreachable
            // for anything `freeze()` writes today (it never persists `.completed` alongside a
            // genuine failure — that combination is exactly what `.completedWithWarnings` is
            // for); kept as a defensive fallback for a pre-fix historical record.
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
        // [WF-RU4] `hasGenuineFailure` is ALSO true for `.completedWithWarnings` (a node really did
        // fail) — gate on `pillVerdict`, not the raw flag, or this run's step counter would say
        // "failed at step 1 of 3" one line under a pill that just said "Completed with warnings".
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
            // Deliberately NOT "failed at step X" — the run reached its natural conclusion with a
            // real answer, so naming the exact step would frame a survived failure as where the
            // run stopped. Just the count: honest without re-alarming what the pill already softened.
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
    /// ⚠️ `.other` renders NEUTRALLY — a question mark, secondary colour, "Unknown". Never a
    /// checkmark and never `successColor`. The whole point of preserving an unrecognised status is
    /// that we do not know whether the run succeeded; a green tick would be the same false claim the
    /// old `?? .completed` made, just moved one layer up.
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
