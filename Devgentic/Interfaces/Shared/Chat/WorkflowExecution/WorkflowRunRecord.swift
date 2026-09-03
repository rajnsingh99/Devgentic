//
//  WorkflowRunRecord.swift
//  Devgentic
//
//  Created by Raj Singh on 11/04/26.
//
//  Persistable snapshot of a single workflow execution run.
//  Created by freezing a live WorkflowExecutionState when execution completes.
//  Separate from ChatMessage — workflow results have a fundamentally different
//  shape (DAG of node results) than chat messages (linear conversation).
//

import Foundation
import os

private let logger = DGLogger(category: "WorkflowRunRecord")

/// LEGACY ONLY — how records written before 2026-08-15 encoded "this node never ran".
///
/// ⚠️ DO NOT ADD CALLERS. This is a decoder for old data, not a way to classify a node.
///
/// Until 2026-08-15 the event channel had no way to say "skipped": `WorkflowExecutor` built
/// `status: .skipped(reason:)` internally and then yielded `.workflowNodeFailed(…)`, so every
/// not-run node was stored as `.failed` carrying the sentence "Upstream dependency failed" — a
/// sentence that was itself untrue whenever the cause was ordinary routing. Every surface wanting
/// "how many actually failed" had to subtract them by matching that prose. Nine did; three of them
/// got it wrong, so the same node read "Not run" on screen and "Failed" to VoiceOver.
///
/// New records carry `NodeStatus.skipped(NodeSkipReason)` and need none of this. The prefix survives
/// only so a run recorded by an older build still reads correctly after an upgrade.
enum WorkflowNodeOutcome {
    /// The exact sentence pre-2026-08-15 builds wrote for a cascade skip.
    static let legacyUpstreamSkipReason = "Upstream dependency failed"

    /// Prefix matched against an OLD record's `detail`.
    static let legacyUpstreamSkipPrefix = "Upstream dependency"

    /// True when a legacy `.failed` node did not actually run.
    static func isLegacyUpstreamSkip(detail: String) -> Bool {
        detail.hasPrefix(legacyUpstreamSkipPrefix)
    }
}

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
    /// The observability trace this run recorded into (Run-Report Phase 5) — the join
    /// key between the run-history UI and traces.sqlite. Optional + synthesized-Codable,
    /// so records persisted before the column existed decode with nil.
    var traceID: String? = nil

    // [WF-CS4] ⚠️ THERE IS DELIBERATELY NO `ranWithUnsavedCanvasEdits` HERE — the "this run used the
    // last saved graph while your canvas was dirty" disclosure is LIVE-ONLY (owner decision,
    // 2026-08-24). Adding it to this struct alone would NOT persist it: this record is not stored as
    // a blob, it is rebuilt field-by-field from promoted columns on `WorkflowRunRecordSD`, so a new
    // field needs its own column, its five seams (init / apply / RowSnapshot / rowSnapshot / both
    // decoders) and a `DevgenticSchemaV3` lightweight stage — the traceID precedent. Until someone
    // takes that on, a field here would be silently dropped at `decodeRecord` and every "the record
    // persists it" comment would be false. The flag lives on `WorkflowExecutionState` only.

    // MARK: - [XUI-11] In-memory trace residency

    /// A copy of this record with every node's `nodeTimeline` dropped, plus the number of events
    /// discarded — for the caller's log.
    ///
    /// ⚠️ **IN-MEMORY ONLY. Never call this on a record that is about to be PERSISTED.** The traces
    /// are the debugging evidence a failed run is kept for; the point is that memory does not have
    /// to hold twenty runs' worth of them for every conversation the user happens to visit, not
    /// that they stop existing. `WorkflowRunHistoryStore` keeps the full record, and the run view
    /// re-reads the one run being looked at.
    ///
    /// ⚠️ Why the traces and not the records: `MainApplicationViewModel.workflowRunHistory` is
    /// keyed by conversation and only ever GROWS — nothing removes a key except deleting the
    /// conversation — but evicting keys is the dangerous fix. `loadedRunHistoryConversationIDs` is
    /// a monotone Set private to `ConversationSwitchCoordinator` while the dictionary lives on the
    /// view model and is cleared from `ConversationManagementCoordinator`; drop a key without
    /// clearing that Set and the conversation's history is EMPTY until relaunch, a failure that
    /// file already records happening once. And `WorkflowRunTicket.finalize` inserts on a miss, so
    /// evicting mid-run silently rebuilds the key as a one-element array — with "not the selected
    /// conversation" no help as a predicate, because scheduled, ChatOps, QuickAccess and Jarvis
    /// runs all start in conversations that are not on screen. Dropping traces touches no key, so
    /// none of that applies.
    ///
    /// The traces are also where the bytes are: the history LIST reads only `nodeResults.count`
    /// and the failure flags, and `WorkflowRunDisplayData.from(record:)` — the sole reader of
    /// `snapshot.nodeTimeline` — runs only for the single selected run.
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

    /// Whether opening this record needs its traces re-read from the store (register XUI-11).
    ///
    /// ⚠️ There is deliberately NO "traces were elided" FLAG, and the honest reasons are narrower
    /// than they first look. It is NOT that `[WF-CS4]` forbids it: that note is about PERSISTENCE,
    /// and a flag defaulting to false on every disk read would be exactly right, since a record
    /// that came off disk has its traces. The real costs are that `WorkflowRunRecord` is
    /// `Equatable` and `Codable`, so two otherwise-identical records would compare unequal and the
    /// synthesized coder would gain a key; and that a second structure holding the ids instead is
    /// the shape that produced the `loadedRunHistoryConversationIDs` bug. Neither is fatal, and a
    /// flag remains the option to reach for if the cost below ever matters.
    ///
    /// The cost below, stated accurately: a run whose nodes genuinely recorded nothing answers
    /// "yes" forever, so it re-reads once PER SELECTION rather than once. That is an indexed
    /// single-row fetch (`WorkflowRunRecordSD.id` is `@Attribute(.unique)`) plus an off-main decode
    /// of a blob that, for a run with no traces, is small by construction — and it is paid only by
    /// workflows whose nodes record nothing, which are the ones with nothing to decode. The
    /// alternative error is a false NEGATIVE: an empty Timeline tab on a failed run, indistinguish-
    /// able from a run that never recorded one, losing exactly the evidence traces are kept for.
    ///
    /// `nonisolated static` and pure (WF-UI5): the view's own `if` chain is unreachable from a test.
    nonisolated static func needsTraceHydration(
        _ record: WorkflowRunRecord, liveTimelinesAvailable: Bool
    ) -> Bool {
        // ⚠️ [XUI-15] ASKS WHETHER THE TRACES ARE IN MEMORY, not whether this is the live run.
        // Those were the same question until `WorkflowExecutionState.nodeTimelines` began being
        // dropped for settled runs in conversations the user has left: a run can now still OWN the
        // live slot — same `runRecordID`, HITL wiring intact — while holding none of its trace. A
        // predicate keyed on identity would have skipped hydration for exactly those runs and left
        // their Timeline tabs empty, which is the defect XUI-11's own cold read caught in the
        // identity-keyed version of this line.
        guard !liveTimelinesAvailable else { return false }
        guard record.status != .running else { return false }
        guard !record.nodeResults.isEmpty else { return false }
        return record.nodeResults.allSatisfy { $0.nodeTimeline?.isEmpty ?? true }
    }

    // MARK: - Run Status

    /// ⚠️ Hand-written `RawRepresentable` so an unrecognised status is PRESERVED, not reinterpreted —
    /// the same treatment `WorkflowNodeResultSnapshot.NodeStatus` already has, which this deliberately
    /// mirrors.
    ///
    /// It was `String, Codable`, and `WorkflowRunRecordSD.decodeRecord` resolved it with
    /// `RunStatus(rawValue: statusRaw) ?? .completed`. That default is the worst possible one: a run
    /// written by a NEWER build with a status this build does not know — very plausibly a failure
    /// state — rendered as a green "Completed" with a checkmark. The app asserted success about a run
    /// it could not classify, and the original rawValue was gone the next time the row was written.
    ///
    /// Stdlib `RawRepresentable where RawValue == String` conformances give byte-identical `Codable`
    /// and rawValue-based `Equatable`, so no call site changes and the wire format is unchanged.
    enum RunStatus: RawRepresentable, Codable, Sendable, Equatable {
        case running
        case completed
        /// [WF-RU4] A genuine node failure occurred, but the run still reached a
        /// successful/answering terminal — an error port absorbed it, or an unrelated parallel
        /// branch delivered the answer. Distinct from `.failed` (nothing usable came out) and
        /// from `.completed` (nothing went wrong): collapsing this into either one was the
        /// original defect — the workflow's own roll-up disagreeing with the chat bubble, which
        /// already correctly shows this run's answer as a `.completed` (no chip) success.
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

        /// True when this run is known to have finished, whatever the outcome.
        /// ⚠️ `.other` is deliberately NOT settled — an unknown status may well be a new in-flight
        /// state, and claiming it has settled is the same overreach as the old `?? .completed`.
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
        /// For a `.skipped` node: did it BEGIN EXECUTING before the skip settled?
        ///
        /// ⚠️ OPTIONAL, and decoded with `decodeIfPresent`. A non-optional (even with a default)
        /// would throw on every already-persisted record, and the resilient tier answers a failed
        /// snapshot by DROPPING THE WHOLE NODE — status, duration and up to 400 persisted timeline
        /// events. nil means "written before this build" and the display falls back to a legacy
        /// heuristic rather than to a confident wrong answer.
        let ranBeforeSkip: Bool?

        /// The node never ran.
        ///
        /// ⚠️ Was `status == .failed && detail.hasPrefix("Upstream dependency")` — English prose as
        /// load-bearing control flow. Nine surfaces re-derived that test, three got it wrong, and
        /// rewording the message would have silently broken every failure count in the app. The
        /// status now carries the fact structurally.
        ///
        /// ⚠️ Records written before 2026-08-15 have no `.skipped` status — every skip in them is a
        /// `.failed` carrying the old sentence — so the legacy prose test is retained ONLY as a
        /// fallback for those, never for newly written rows.
        var didNotRun: Bool {
            if case .skipped = status { return true }
            return status == .failed && WorkflowNodeOutcome.isLegacyUpstreamSkip(detail: detail)
        }

        /// Failed on its own account. This is what a "N failed" badge means.
        ///
        /// A cancelled node is not a failure either — the user asked for it.
        var isGenuineFailure: Bool {
            status == .failed && !WorkflowNodeOutcome.isLegacyUpstreamSkip(detail: detail)
        }

        /// ⚠️ Hand-written `RawRepresentable` so an unrecognised status is PRESERVED, not rejected.
        ///
        /// This field is decoded STRICTLY (below), and it sits inside the per-node envelope — so
        /// before this, one unrecognised status rawValue failed the whole snapshot, dropped the node
        /// to `decodeNodeResultsResiliently`, and that tier DELETED the entire node: its detail, its
        /// duration, and its whole `nodeTimeline` (up to ~400 events of agent trace, which for a
        /// FAILED run is the entire debugging evidence). A single new case did that.
        ///
        /// Stdlib `RawRepresentable where RawValue == String` conformances give byte-identical
        /// `Codable` and rawValue-based `Equatable`, so no call site changes.
        enum NodeStatus: RawRepresentable, Codable, Sendable, Equatable {
            case running, completed, failed, cancelled
            /// The node did not run, and WHY. ⚠️ The reason is persisted as part of the rawValue
            /// (`skipped:notChosen`) rather than in the free-text detail, because the detail is what
            /// consumers used to parse English out of. An unknown reason from a newer build decodes
            /// to `.notChosen` — the neutral one — so a future cause never reads as a failure.
            case skipped(NodeSkipReason)
            /// A status written by a newer build, carried verbatim.
            case other(String)

            init?(rawValue: String) {
                switch rawValue {
                case "running":   self = .running
                case "completed": self = .completed
                case "failed":    self = .failed
                case "cancelled": self = .cancelled
                // Bare "skipped" is what builds before 2026-08-15 wrote. They only ever produced
                // the cascade case, so it maps to the honest equivalent rather than to `.other`.
                case "skipped":   self = .skipped(.upstreamSkipped)
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

        // Backward-compatible decoding (old records lack input fields / nodeTimeline)
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
            // Lossy on purpose: dropping only this node's trace beats failing the node.
            //
            // ⚠️ But it used to be lossy AND SILENT, which meant a node's entire agent trace could
            // vanish with nothing in the log to say so. It also PRE-EMPTS the resilient tier: the
            // `try?` swallows the failure here, so the outer `VersionedNodeResults` decode SUCCEEDS
            // and `decodeNodeResultsResiliently` is never reached for a timeline failure.
            //
            // Since `TimelineEvent` gained its total catch-all, an individual event can no longer
            // throw — so reaching this branch now means the CONTAINER shape changed (the key is
            // present but is not a JSON array). Rare, and worth a line when it happens.
            //
            // Deliberately NOT paired with a write-refusal flag like `ChatMessage.canPersistTimeline`:
            // that exists because the chat path nulls its blob on a read failure. Here nothing
            // re-saves a loaded record — every writer builds a fresh record in memory — so the flag
            // would be permanently false and the plumbing dead. The `record` setter that WOULD have
            // made it live has been removed instead; see `WorkflowRunRecordSD`.
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

    /// Freezes a live WorkflowExecutionState into a persistent record.
    /// Trace events retained per node in a FROZEN record (register XUI-6).
    ///
    /// Deliberately BELOW the live cap (`ChatMessage.maxTimelineEvents` = 500), and the asymmetry is
    /// the reason: a live trace exists once, in one `WorkflowExecutionState`, while a persisted one
    /// is decoded for up to `WorkflowRunHistoryStore.maxRecordsPerConversation` records per
    /// conversation and held in the view model's in-memory mirror.
    ///
    /// ⚠️ The TAIL is kept, not the head. On a failure the most recent events are the diagnostic
    /// ones; keeping the head would preserve the setup and discard the evidence.
    static let maxPersistedNodeTimelineEvents = 400

    /// The events a frozen record keeps for one node, and how many it discarded.
    ///
    /// Pure and `nonisolated` (WF-UI5) so BOTH the count and the DIRECTION are assertable — the
    /// direction is the half a reader cannot verify by inspection, and the half that matters.
    /// ⚠️ The `>` here is an EQUIVALENT-MUTANT site, recorded so nobody spends time on it: `>=`
    /// behaves identically, because at exactly the cap the fall-through returns `suffix(cap)` — every
    /// event — and computes `dropped = 0`. The early return is a short-circuit, not a boundary.
    nonisolated static func cappedNodeTimeline(_ events: [TimelineEvent]) -> (kept: [TimelineEvent], dropped: Int) {
        guard events.count > maxPersistedNodeTimelineEvents else { return (events, 0) }
        return (Array(events.suffix(maxPersistedNodeTimelineEvents)),
                events.count - maxPersistedNodeTimelineEvents)
    }

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
        let nodeSnapshots = state.nodeResults.map { result in
            // Compute per-node input from edge topology (Tier 2)
            var inputText: String? = nil
            var sourceLabel: String? = nil
            if let layout {
                let upstreamEdges = layout.edges.filter { $0.targetNodeID == result.nodeID }
                let upstreamNodeIDs = Set(upstreamEdges.map(\.sourceNodeID))
                let upstreamResults = state.nodeResults.filter { upstreamNodeIDs.contains($0.nodeID) }
                if !upstreamResults.isEmpty {
                    inputText = upstreamResults.map(\.detail).joined(separator: "\n\n")
                    sourceLabel = upstreamResults.map(\.profileName).joined(separator: ", ")
                }
            }

            // Defensive settle. `WorkflowExecutionState.settleInFlightWork` (called from
            // `handleError`) is the primary repair, but freeze is the LAST gate before the
            // record becomes permanent, and a node persisted `.running` renders in the
            // historical run with a live accent spine badged "Running…" forever. Anything
            // still in flight here ended without reporting, which is a failure by definition.
            let snapshotStatus: WorkflowNodeResultSnapshot.NodeStatus
            var snapshotDetail = result.detail
            switch result.status {
            case .running:
                unsettledNodes += 1
                // ⚠️ NOT unconditionally `.failed`. A run the user STOPPED did not fail, and its
                // in-flight node did not fail either — `isGenuineFailure` would then count it,
                // rolling the whole run up `.failed` (this backstop was the second half of the
                // Stop-shows-Failed defect). `wasCancelled` is latched before freeze on every
                // cancel path, so this gate can tell the two apart. Wording mirrors
                // `WorkflowExecutionState.settleInFlightWork`, which is the primary repair —
                // reaching here at all means that one did not run.
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
                // Persist the trace (capped from the end — on failure the most recent
                // events are the diagnostic ones). Empty → nil keeps old-record parity.
                // Dangling tool rows are closed on the way in for the same reason as the node
                // status above: `AgentTimelineView` spins any row with `isExecuting == true`.
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

        if droppedTraceEvents > 0 {
            // [XUI-6] The cap is a deliberate bound; the DEFECT was that it was silent. A user
            // looking at a long agent node's trace in the run report could not tell the earliest
            // events had been discarded, and neither could a support bundle.
            logger.notice("[WORKFLOW] freeze() capped the persisted trace of \(truncatedNodes.count) node(s) for '\(workflowName)' at \(Self.maxPersistedNodeTimelineEvents) events each, DROPPING \(droppedTraceEvents) event(s) in total: [\(truncatedNodes.joined(separator: ", "))]. CONSEQUENCE: the run report shows only the LAST \(Self.maxPersistedNodeTimelineEvents) events for those nodes — the earliest reasoning steps and tool calls are gone from the record, though they were visible live. The tail is kept deliberately: on a failure the most recent events are the diagnostic ones.")
        }

        if unsettledNodes > 0 || closedToolRows > 0 {
            logger.warning("[WORKFLOW] freeze() force-settled \(unsettledNodes) node(s) still marked running and \(closedToolRows) dangling tool row(s) for '\(workflowName)'. The live state should already have settled these — a persisted run must never claim to still be executing.")
        }

        // Derived from the SNAPSHOTS, not the live results, so a force-settled node counts.
        //
        // ⚠️ `isGenuineFailure`, NOT `status == .failed`. A node skipped because a Condition or
        // Gate routed the other way is recorded `.failed` with detail "Upstream dependency
        // failed" (see this file's header) — it never ran and nothing went wrong. Rolling that
        // up as a run failure meant EVERY conditional workflow reported EVERY successful run as
        // failed, permanently, in persistence: a red "Failed" pill over a correct answer, a
        // uniformly red history list, and no way to tell a real failure from a taken branch.
        // The distinction already existed 170 lines above and the history card's "N failed"
        // badge already used it; only the roll-ups did not.
        let status: RunStatus = {
            // ⚠️ FIRST, before the error check. A cancel sets `workflowError` too ("Cancelled"),
            // so testing that first made every user Stop indistinguishable from a crash — the run
            // was persisted `.failed` and rendered with a red "Failed" pill, reporting the user's
            // own action back to them as an error. `.cancelled` was unreachable and the amber
            // "Cancelled" states built for it were dead code.
            if state.wasCancelled { return .cancelled }
            if let _ = state.workflowError { return .failed }
            guard nodeSnapshots.contains(where: { $0.isGenuineFailure }) else { return .completed }
            // [WF-RU4] A node genuinely failed. `freeze()` has no live graph topology of its own
            // to know whether the run still reached a successful/answering terminal — that needs
            // the engine's edge-liveness logic, which lives only in `WorkflowState` (the live
            // executor's internal type, not `WorkflowExecutionState`). `completedDespiteNodeFailure`
            // carries the engine's own answer across the stream boundary (`.workflowRunFinished`).
            // Trusted ONLY to upgrade `.failed` to the honest middle value, never to erase the
            // failure to plain `.completed` — if the flag never arrived (nil-safe default `false`,
            // e.g. an older code path), this falls back to today's existing, safe-but-harsh
            // `.failed`, exactly as before this fix.
            return state.completedDespiteNodeFailure ? .completedWithWarnings : .failed
        }()

        // Wall-clock duration (start→finish), matching the live display's computation
        // (WorkflowRunDisplayData.from(live:)). Summing per-node durations disagreed with
        // the live value for parallel/gapped runs, so "Total time" visibly jumped when a
        // run flipped live→historical. (Records frozen before this fix keep their old value.)
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
