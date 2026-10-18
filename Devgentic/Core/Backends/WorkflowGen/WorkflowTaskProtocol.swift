// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowTaskProtocol.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// MARK: - Task Envelope (Orchestrator → Node)

// MARK: - Result Envelope (Node → Orchestrator)

/// The result returned from an inner node's executor back to the WorkflowExecutor.
/// Contains the synthesized output, artifacts, and execution metadata.
struct NodeResultEnvelope: Sendable, Identifiable {
    /// Unique identifier matching the originating task (also serves as the `Identifiable.id`).
    let taskID: UUID

    var id: UUID { taskID }

    /// The canvas node that produced this result.
    let nodeID: UUID

    /// The BackendProfileModel that was executed.
    let sourceProfileID: UUID

    /// Display name of the profile (for context injection readability).
    let profileName: String

    /// Whether this was a Bot or Agent.
    let profileType: ProfileType

    /// Terminal execution status.
    let status: NodeExecutionStatus

    /// The synthesized text response from the inner executor.
    let output: String

    /// Structured form of the output when the node produced JSON (object/array), from auto-detection of `output` or a
    /// Code node. Enables `{{ input.json.path }}` access and field routing; nil when the output is plain text.
    let structuredOutput: JSONValue?

    /// Media artifacts produced during execution.
    let artifacts: [MediaArtifact]

    /// Execution metadata (timing, token usage, tools invoked).
    let metadata: NodeExecutionMetadata

    /// Ids of the `.document` artifacts in `artifacts` whose text was already inlined into a node on the path that
    /// delivered them here. See `WorkflowExecutor.documentsAlreadyRead`. Empty means nobody has read them, so they are
    /// inlined again.
    let readDocumentIDs: Set<UUID>

    /// Explicit initializer so `structuredOutput` defaults to `nil`; envelope construction sites that do not detect JSON
    /// stay unchanged.
    init(
        taskID: UUID,
        nodeID: UUID,
        sourceProfileID: UUID,
        profileName: String,
        profileType: ProfileType,
        status: NodeExecutionStatus,
        output: String,
        artifacts: [MediaArtifact],
        metadata: NodeExecutionMetadata,
        structuredOutput: JSONValue? = nil,
        readDocumentIDs: Set<UUID> = []
    ) {
        self.taskID = taskID
        self.nodeID = nodeID
        self.sourceProfileID = sourceProfileID
        self.profileName = profileName
        self.profileType = profileType
        self.status = status
        self.output = output
        self.artifacts = artifacts
        self.metadata = metadata
        self.structuredOutput = structuredOutput
        self.readDocumentIDs = readDocumentIDs
    }
}

// MARK: - Node Execution Status

/// Terminal states for a single node's execution within a workflow.
enum NodeExecutionStatus: Sendable {
    /// Node completed successfully.
    case completed

    /// Node encountered an unrecoverable error.
    /// Carries structured `AgentFailureReason` for intelligent retry/routing decisions.
    case failed(AgentFailureReason)

    /// Node was canceled (user or timeout).
    case canceled

    /// Node did not run. See `NodeSkipReason` — "did not run" is NOT one thing.
    case skipped(reason: NodeSkipReason)

    /// Whether this node consumed its upstream's output, i.e. whether a path that actually ran continues through it. A
    /// `.failed` node consumed its input; `.skipped(.byUser)` is the only skip that counts, since it forwards its input
    /// as its own output. Exhaustive, with no `default`.
    var consumedUpstreamOutput: Bool {
        switch self {
        case .completed, .failed: return true
        case .canceled: return false
        case .skipped(let reason): return reason.keepsDownstreamAlive
        }
    }
}

// MARK: - Node Skip Reason

/// Why a node did not run. Typed so consumers do not string-match prose to tell "did not run" from "crashed"; the
/// wording lives in one place (`displayText`).
enum NodeSkipReason: String, Sendable, Codable, Equatable, CaseIterable {
    /// A Condition/Router or Gate activated a different port. Completely normal routing.
    case notChosen
    /// This branch leaves an `error` port and the upstream SUCCEEDED. The happy path.
    case errorPortNotTaken
    /// An upstream node failed.
    case upstreamFailed
    /// An upstream node was itself skipped — a cascade; the root cause is further up.
    case upstreamSkipped
    /// An upstream node was cancelled.
    case upstreamCancelled
    /// The run ended before this node was reached.
    case notReached
    /// The user pressed Skip on this node. The only skip whose downstream runs: the input is forwarded as output, no port
    /// is activated, and default edges below stay live. Every other case means the subtree below is dead (see
    /// `keepsDownstreamAlive`).
    case byUser

    /// Whether the subtree below this node stayed live; true only for `.byUser`. Exhaustive, with no `default`, so a new
    /// skip reason cannot inherit an answer.
    var keepsDownstreamAlive: Bool {
        switch self {
        case .byUser: return true
        case .notChosen, .errorPortNotTaken, .upstreamFailed,
             .upstreamSkipped, .upstreamCancelled, .notReached: return false
        }
    }

    /// Whether the run actually decided anything about this branch, as opposed to never getting here (only `.notReached`
    /// is false). An edge touching a node the run never reached must stay neutral in the canvas overlay. Exhaustive, with
    /// no `default`.
    var decidedTheBranch: Bool {
        switch self {
        case .notChosen, .errorPortNotTaken, .upstreamFailed,
             .upstreamSkipped, .upstreamCancelled, .byUser: return true
        case .notReached: return false
        }
    }

    /// Whether this skip traces back to something going wrong, as opposed to ordinary routing. Presentation only: a skip
    /// is never counted as a failure.
    var indicatesProblem: Bool {
        switch self {
        case .notChosen, .errorPortNotTaken, .notReached, .byUser: return false
        case .upstreamFailed, .upstreamSkipped, .upstreamCancelled: return true
        }
    }

    /// Tolerant decoding: an unknown raw value decodes as `.notChosen`, the neutral reason, instead of throwing and
    /// taking the containing record down.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = NodeSkipReason(rawValue: raw) ?? .notChosen
    }

    /// The user-facing sentence; the only place this wording lives.
    var displayText: String {
        switch self {
        case .notChosen:
            return String(localized: "Not run — the workflow branched a different way")
        case .errorPortNotTaken:
            return String(localized: "Not run — no error to handle")
        case .upstreamFailed:
            return String(localized: "Not run — an upstream node failed")
        case .upstreamSkipped:
            return String(localized: "Not run — an earlier node in this branch did not run")
        case .upstreamCancelled:
            return String(localized: "Not run — an upstream node was cancelled")
        case .notReached:
            return String(localized: "Not run — the workflow ended first")
        case .byUser:
            // The wording names the consequence (input passed through, downstream ran), since a transformer node's skip means
            // downstream operated on untransformed input.
            return String(localized: "Skipped by you — its input was passed downstream unchanged.")
        }
    }

    /// Ordering used when several dead upstream branches disagree: the most alarming cause wins, so
    /// a node fed by both a crashed branch and an unchosen one reports the crash.
    var severityRank: Int {
        switch self {
        case .upstreamFailed:    return 0
        case .upstreamCancelled: return 1
        case .upstreamSkipped:   return 2
        case .notReached:        return 3
        case .errorPortNotTaken: return 4
        case .notChosen:         return 5
        // Least alarming of all: the user asked for it. When a dead branch is fed by both a
        // crash and a user skip, the crash must win the report.
        case .byUser:            return 6
        }
    }
}

// MARK: - Execution Constraints

/// Per-node execution limits enforced by the WorkflowExecutor.
struct ExecutionConstraints: Sendable {
    /// Maximum wall-clock time for this node (seconds). Default: 120s.
    let maxDuration: TimeInterval

    /// Optional override for the inner executor's max iteration count.
    let maxIterations: Int?

    static let `default` = ExecutionConstraints(maxDuration: 120, maxIterations: nil)

    init(maxDuration: TimeInterval = 120, maxIterations: Int? = nil) {
        self.maxDuration = maxDuration
        self.maxIterations = maxIterations
    }
}

// MARK: - Node Execution Metadata

/// Telemetry data collected during a single node's execution.
struct NodeExecutionMetadata: Sendable {
    /// When this node started executing.
    let startTime: Date

    /// When this node finished executing.
    let endTime: Date

    /// Number of reasoning iterations consumed (for agent nodes).
    let iterationsUsed: Int

    /// Names of tools invoked during execution.
    let toolsInvoked: [String]

    /// Estimated token count for the output.
    let tokenEstimate: Int

    /// Computed duration in seconds.
    var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }

    /// Convenience initializer with defaults for simple bot nodes.
    static func simple(start: Date, end: Date, output: String) -> NodeExecutionMetadata {
        NodeExecutionMetadata(
            startTime: start,
            endTime: end,
            iterationsUsed: 1,
            toolsInvoked: [],
            tokenEstimate: output.count / 4
        )
    }
}
