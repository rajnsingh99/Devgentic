//
//  WorkflowTaskProtocol.swift
//  Devgentic
//
//  Created by Raj Singh on 13/03/26.
//
//  In-process A2A-inspired protocol types for inter-node communication.
//  These types flow between the WorkflowExecutor (orchestrator) and inner executors (nodes).
//

import Foundation

// MARK: - Task Envelope (Orchestrator → Node)

/// The payload sent from the WorkflowExecutor to an inner node's executor.
/// Contains the original query, upstream results, and execution constraints.
struct WorkflowTaskEnvelope: Sendable {
    /// Unique identifier for this task execution.
    let taskID: UUID

    /// The canvas node this task maps to.
    let nodeID: UUID

    /// The BackendProfileModel being executed at this node.
    let sourceProfileID: UUID

    /// The original user query (or a rewritten sub-query for downstream nodes).
    let query: String

    /// Results from all direct upstream nodes (injected as context).
    let upstreamContext: [NodeResultEnvelope]

    /// Execution constraints (timeouts, iteration caps).
    let constraints: ExecutionConstraints

    /// The downstream model's supported modalities (for context compilation).
    let targetModalities: SupportedModalities

    /// Extracted content from user-attached files (available to every node).
    let fileContext: String?

    init(
        taskID: UUID = UUID(),
        nodeID: UUID,
        sourceProfileID: UUID,
        query: String,
        upstreamContext: [NodeResultEnvelope] = [],
        constraints: ExecutionConstraints = .default,
        targetModalities: SupportedModalities = .textOnly,
        fileContext: String? = nil
    ) {
        self.taskID = taskID
        self.nodeID = nodeID
        self.sourceProfileID = sourceProfileID
        self.query = query
        self.upstreamContext = upstreamContext
        self.constraints = constraints
        self.targetModalities = targetModalities
        self.fileContext = fileContext
    }
}

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

    /// Structured form of the output, when the node produced JSON (object/array).
    /// Populated by auto-detection (parsing `output`) or by a Code node that emits
    /// JSON. Enables downstream `{{ input.json.path }}` access and field routing.
    /// `nil` when the output is plain text.
    let structuredOutput: JSONValue?

    /// Media artifacts produced during execution.
    let artifacts: [MediaArtifact]

    /// Execution metadata (timing, token usage, tools invoked).
    let metadata: NodeExecutionMetadata

    /// Explicit initializer (replaces the synthesized memberwise init) so that
    /// `structuredOutput` can default to `nil` — the many synthetic envelope
    /// construction sites (skips, profile-not-found, structural nodes) keep
    /// compiling unchanged; only producers that detect JSON pass the argument.
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
        structuredOutput: JSONValue? = nil
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

    /// Whether this node CONSUMED its upstream's output — i.e. whether a path that actually ran
    /// continues through it.
    ///
    /// ⚠️ Not the same question as "did it succeed". A `.failed` node ran: it took its input,
    /// tried, and ended the path itself, so its upstream is not the end of anything. That is why
    /// this is a separate predicate rather than a `case .completed` check.
    ///
    /// ⚠️ `.skipped(.byUser)` is TRUE, and it is the only skip that is — the same split
    /// `NodeSkipReason.keepsDownstreamAlive` makes, for the same reason: a user-skipped node
    /// forwards its input as its own output, and `terminalOutputs`' caller surfaces that
    /// pass-through text. Calling it "did not consume" would put the upstream back in the terminal
    /// set and print the same content twice — once bare, once under the skipped node's heading.
    ///
    /// Every other skip means this node never took the input, so whatever fed it is still the end
    /// of a path that ran and still owns an answer nobody else will print.
    ///
    /// Exhaustive on purpose: no `default`, so a new status cannot inherit an answer.
    var consumedUpstreamOutput: Bool {
        switch self {
        case .completed, .failed: return true
        case .canceled: return false
        case .skipped(let reason): return reason.keepsDownstreamAlive
        }
    }
}

// MARK: - Node Skip Reason

/// Why a node did not run.
///
/// ⚠️ TYPED, and deliberately so. This was `skipped(reason: String)` carrying the single literal
/// "Upstream dependency failed" for FOUR structurally different causes, which had two consequences:
///
/// 1. **The message was false in two of the four cases.** A Router choosing a different branch, and
///    an `error` handler correctly not firing on a SUCCESSFUL node, both reported an upstream
///    failure on a run where nothing failed at all.
/// 2. **Consumers had to string-match English prose to tell "did not run" from "crashed."** Nine UI
///    surfaces called `detail.hasPrefix("Upstream dependency")`; six got it right and three did not,
///    so the same node read "Not run" on screen and "Failed" to VoiceOver. Rewording the message
///    would have silently broken every failure count in the app.
///
/// The enum is the fix for both: the cause is carried structurally, and the wording lives in exactly
/// one place (`displayText`).
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
    /// The user pressed Skip on this node (Phase A, §0.6 D2.1). ⚠️ THE ONE SKIP WHOSE DOWNSTREAM
    /// RUNS: the node's INPUT was forwarded as its output, no port was activated, and every
    /// default edge below it stayed live. Every other case in this enum means the subtree below
    /// is dead — matchers that assume "skipped ⇒ downstream never ran" must treat this case
    /// separately (`edgeIsLive`, `WorkflowInputAssembler`, and the cascade classifier already do).
    case byUser

    /// Whether the subtree BELOW this node stayed live.
    ///
    /// ⚠️ The rule this type's own `byUser` doc comment demands ("matchers that assume
    /// `skipped ⇒ downstream never ran` must treat this case separately"), given a name so the
    /// next matcher reads it instead of re-deriving it. Three sites already complied by hand
    /// (`edgeIsLive`, `WorkflowInputAssembler`, the cascade classifier) and a fourth — the canvas
    /// run overlay — did not, painting the outgoing edge of a user-skipped node "not taken" even
    /// though the node below it ran and received that node's input over exactly that edge.
    ///
    /// Exhaustive on purpose: no `default`, so a new skip reason cannot inherit an answer.
    var keepsDownstreamAlive: Bool {
        switch self {
        case .byUser: return true
        case .notChosen, .errorPortNotTaken, .upstreamFailed,
             .upstreamSkipped, .upstreamCancelled, .notReached: return false
        }
    }

    /// Whether this skip traces back to something going WRONG, as opposed to ordinary routing.
    ///
    /// Drives presentation only — a skip is NEVER counted as a failure, whatever this returns.
    /// The distinction the user needs is "the Router went the other way" (nothing to do) versus
    /// "something upstream broke" (worth looking at), and before this existed both looked identical.
    var indicatesProblem: Bool {
        switch self {
        case .notChosen, .errorPortNotTaken, .notReached, .byUser: return false
        case .upstreamFailed, .upstreamSkipped, .upstreamCancelled: return true
        }
    }

    /// Tolerant decoding (owner requirement, D2.1 — the loop-node deletion is the cautionary
    /// tale). The synthesized conformance for a String-raw enum THROWS on an unknown rawValue,
    /// which takes the entire containing record down with it. The run-record layer already guards
    /// its own seam (`WorkflowRunRecord.NodeStatus.init(rawValue:)` falls back to `.notChosen`);
    /// this covers every OTHER present or future direct `Codable` crossing, so the NEXT new case
    /// is safe by construction rather than by remembering to guard each consumer.
    /// `.notChosen` as the fallback matches the record layer's choice: the neutral reason —
    /// a future cause must never decode as something going wrong.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = NodeSkipReason(rawValue: raw) ?? .notChosen
    }

    /// The user-facing sentence. ⚠️ THE ONLY PLACE THIS WORDING LIVES — the previous arrangement had
    /// producers and consumers agreeing on a literal by convention, and they drifted.
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
            // Owner-decided wording (D2.1). Deliberately NOT "Not run — …": the consequence half
            // (input passed through, downstream RAN) is the part the user needs, because a
            // transformer node's skip means downstream operated on untransformed input.
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
