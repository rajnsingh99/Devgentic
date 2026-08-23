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
        case failed
        case cancelled
        /// A status written by a newer build, carried verbatim.
        case other(String)

        init?(rawValue: String) {
            switch rawValue {
            case "running":   self = .running
            case "completed": self = .completed
            case "failed":    self = .failed
            case "cancelled": self = .cancelled
            default:          self = .other(rawValue)
            }
        }

        var rawValue: String {
            switch self {
            case .running:        return "running"
            case .completed:      return "completed"
            case .failed:         return "failed"
            case .cancelled:      return "cancelled"
            case .other(let raw): return raw
            }
        }

        /// True when this run is known to have finished, whatever the outcome.
        /// ⚠️ `.other` is deliberately NOT settled — an unknown status may well be a new in-flight
        /// state, and claiming it has settled is the same overreach as the old `?? .completed`.
        var isSettled: Bool {
            switch self {
            case .completed, .failed, .cancelled: return true
            case .running, .other:                return false
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
                    return Array(events.suffix(400))
                }(),
                hasWarnings: result.hasWarnings ? true : nil,
                // Explicit, never defaulted: freeze REPLACES the whole struct, so an omitted
                // argument here silently persists the wrong answer for every historical run.
                ranBeforeSkip: result.ranBeforeSkip
            )
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
            if nodeSnapshots.contains(where: { $0.isGenuineFailure }) { return .failed }
            return .completed
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
