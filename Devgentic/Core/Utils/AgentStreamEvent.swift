//
//  AgentStreamEvent.swift
//  Devgentic
//
//  Created by Raj Singh on [Date].
//

import Foundation

/// Structured representation of a single reasoning thought for the UI.
struct AgentThought: Sendable, Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    
    init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

/// Represents the distinct types of events emitted during an Agent's execution loop.
/// This structured stream allows the UI to render "Thinking", "Artifacts", and "Text" separately.
enum AgentStreamEvent: Sendable {
    
    /// Generic "thinking" / narration channel. Used for:
    ///   - Extended thinking traces (step.thought — e.g. Claude thinking blocks, OpenAI o-series reasoning_content, Ollama thinking)
    ///   - Progress narration from capabilities (plan subtask status, reflection trials, workflow node progress)
    ///   - Executor-level status (throttle, format correction, synthesis progress)
    /// For the LLM's visible assistant monologue (step.reasoning), use `.reasoning` instead.
    /// - sourceNodeID: When emitted from a workflow node, identifies which node produced this thought.
    case thought(_ message: String, id: UUID = UUID(), sourceNodeID: UUID? = nil)

    /// The LLM's visible assistant monologue — specifically the `step.reasoning`
    /// field produced by the model alongside its tool calls. Distinct from `.thought`
    /// which is used for extended-thinking traces and system narration.
    ///
    /// This separation lets analytics, scratchpad injection, and UI rendering treat
    /// model-authored prose differently from system-authored status text.
    /// - sourceNodeID: When emitted from a workflow node, identifies which node produced this reasoning.
    case reasoning(_ message: String, id: UUID = UUID(), sourceNodeID: UUID? = nil)

    /// The agent is about to execute a tool.
    /// - name: The tool name (e.g., "list_directory")
    /// - params: The raw JSON parameters being passed (for debugging/visibility)
    /// - sourceNodeID: When emitted from a workflow node, identifies which node invoked this tool.
    case toolCall(name: String, params: String, sourceNodeID: UUID? = nil)
    
    /// [HITL] Phase 3: Explicit Permission Request
    /// The agent pauses and asks the user for permission to proceed.
    /// - toolName: The name of the sensitive tool (e.g. "delete_file")
    /// - params: The parameters needed for the tool (e.g. path)
    /// - operationID: Unique identifier for this HITL operation (for multi-surface dedup)
    case requestConfirmation(toolName: String, params: String, operationID: UUID = UUID(), sourceNodeID: UUID? = nil)

    /// [E1] A workflow Gate node is asking the user to pick one of `options`. The choice routes the
    /// workflow to the matching output port. `deadline` is the absolute auto-reject time (live countdown).
    case requestGate(prompt: String, options: [String], operationID: UUID = UUID(), deadline: Date? = nil, sourceNodeID: UUID? = nil)

    /// The tool executed successfully. Carries the observation payload for the LLM + UI.
    /// - durationMs: optional wall-clock execution time (from dispatch to completion)
    /// - sourceNodeID: When emitted from a workflow node, identifies which node produced this output.
    case toolSucceeded(ToolOutput, durationMs: Int? = nil, sourceNodeID: UUID? = nil)

    /// The tool failed. Category drives negativeConstraints policy, episodic-memory retrieval
    /// weighting, and UI affordance. Replaces the boolean `ToolOutput.isSuccess == false` signal
    /// with a structured classification.
    /// - category: machine-readable cause (userDenied / permissionRejected / executionThrew / timeout / invalidArgs / notFound / cancelled)
    /// - suggestion: optional human-readable remediation hint (surface in UI)
    case toolFailed(ToolOutput, category: ToolFailureCategory, suggestion: String? = nil, sourceNodeID: UUID? = nil)
    
    /// A chunk of the final text response (streaming token).
    /// This is what populates the main chat bubble.
    case content(String)
    
    /// The agent needs clarification from the user before it can proceed.
    /// - question: The question to display to the user
    /// - operationID: Unique identifier for this HITL operation (for multi-surface dedup)
    case requestClarification(question: String, operationID: UUID = UUID(), sourceNodeID: UUID? = nil, options: [String]? = nil, multiline: Bool = false)

    /// A terminal error. Carries a `StructuredError` (category + message +
    /// optional relatedPath/suggestion). Legacy `.error("string")` call sites
    /// keep compiling via `StructuredError`'s string-literal/interpolation
    /// conformance (defaulting to the `.executionFailed` category).
    case error(StructuredError)

    /// A structured system-level warning — recoverable issue the agent hit during execution.
    /// Distinct from `.thought` (model reasoning) and `.error` (terminal failure).
    /// - category: machine-readable classification for negativeConstraints, episodic memory, and UI affordance
    /// - message: human-readable description
    /// - relatedPath: optional tool name, iteration id, or context identifier the warning pertains to
    case warning(category: WarningCategory, message: String, relatedPath: String? = nil, sourceNodeID: UUID? = nil)

    // MARK: - Workflow Orchestration Events

    /// A workflow node has started execution.
    /// - nodeID: Canvas node identifier
    /// - profileName: Display name of the profile being executed
    /// - index: 1-based index of this node in execution order
    /// - total: Total number of nodes in the workflow
    case workflowNodeStarted(nodeID: UUID, profileName: String, index: Int, total: Int)

    /// A workflow node has completed execution successfully.
    case workflowNodeCompleted(nodeID: UUID, profileName: String, summary: String)

    /// A workflow node has failed. `suggestion` carries an optional actionable
    /// remediation hint (derived from the typed `AgentFailureReason`) that the UI
    /// folds into the node's failure detail.
    case workflowNodeFailed(nodeID: UUID, profileName: String, error: String, suggestion: String? = nil)

    /// Overall workflow progress update.
    case workflowProgress(completed: Int, total: Int)

    /// A loop node has completed one iteration of its body workflow.
    case workflowLoopIteration(nodeID: UUID, profileName: String, iteration: Int, maxIterations: Int)

    // MARK: - Capability Events (Planning, Self-Reflection, Delegation)

    /// Planning capability: a plan has been generated with N subtasks.
    case planGenerated(subtaskCount: Int)

    /// Planning capability: a subtask has started execution.
    case subtaskStarted(index: Int, total: Int, description: String)

    /// Planning capability: a subtask has completed.
    case subtaskCompleted(index: Int, total: Int, summary: String)

    /// Self-Reflection capability: a new trial has started.
    case reflectionTrialStarted(trial: Int, maxTrials: Int)

    /// Self-Reflection capability: evaluating the current trial's output.
    case reflectionEvaluating(trial: Int)

    /// Self-Reflection capability: trial rejected, retrying with critique.
    case reflectionRetrying(trial: Int, critique: String)

    /// Self-Reflection capability: trial accepted, execution complete.
    case reflectionAccepted(trial: Int)

    /// Agent Delegation: a spawned agent has started working on a delegated task.
    case delegationStarted(task: String)

    /// Agent Delegation: a spawned agent has completed its task.
    case delegationCompleted(summary: String)

    // MARK: - Multimodal Events

    /// Long-running media generation progress (e.g., image generation at 45%).
    case mediaProgress(toolName: String, percent: Double, status: String)

    /// A completed media artifact ready for UI rendering.
    case artifactProduced(MediaArtifact)

    // MARK: - Token Usage

    /// Accumulated token usage for the current generation cycle.
    /// Emitted by executors after LLM calls complete.
    case tokenUsage(TokenUsage)

    // MARK: - Plan Review HITL

    /// Planning capability: the generated plan is ready for user review/edit before execution.
    /// Execution is suspended until the user approves, edits, or rejects the plan.
    /// - subtasks: The generated subtask plan (user may edit before approving)
    /// - operationID: Unique identifier for this HITL operation (for multi-surface dedup)
    case requestPlanReview(subtasks: [SubTask], operationID: UUID = UUID(), sourceNodeID: UUID? = nil)

    // MARK: - History Compaction

    /// IC-powered history compaction has started. Emitted before the IC summarization call.
    /// - turnsToCompact: Number of conversation turns being summarized.
    /// - checkpointNumber: Sequential checkpoint number (1-based).
    case compactionStarted(turnsToCompact: Int, checkpointNumber: Int)

    /// IC-powered history compaction completed successfully.
    /// - turnsCompacted: Number of turns that were summarized into the checkpoint.
    /// - summaryPreview: First ~120 chars of the checkpoint summary for UI display.
    case compactionCompleted(turnsCompacted: Int, summaryPreview: String)

    // MARK: - Terminal Outcome

    /// Signals the executor has finished with a known outcome. Emitted as the last
    /// meaningful event before `continuation.finish()`. Drives the final-status
    /// indicator in the agent bubble so users can distinguish a successful answer
    /// from a best-effort synthesis produced after the agent aborted (circuit breaker,
    /// iteration exhaustion) or was cancelled.
    case executionFinished(outcome: ExecutionOutcome, reason: String? = nil)
}

/// Classification for `.warning` events — drives UI affordance, negativeConstraints,
/// and episodic memory retrieval. Codable so timeline warnings persist with category intact.
enum WarningCategory: String, Sendable, Codable, Equatable, CaseIterable {
    case retry             // transient network / backend blip — retry in progress
    case throttle          // rate limit hit — backing off
    case memoryPressure    // scratchpad budget utilization high
    case parseFailure      // malformed JSON / XML from model
    case formatCorrection  // model described tool in prose instead of structured call
    case contextPressure   // nearing iteration / compaction threshold
    case circuitBreaker    // repetitive-action / loop safeguard tripping (imminent or already aborted)
    case resourceUnavailable // an attached/upstream file couldn't be read (report-and-skip)

    var displayName: String {
        switch self {
        case .retry:            return "Retry"
        case .throttle:         return "Throttled"
        case .memoryPressure:   return "Memory"
        case .parseFailure:     return "Parse"
        case .formatCorrection: return "Format"
        case .contextPressure:  return "Context"
        case .circuitBreaker:   return "Loop Guard"
        case .resourceUnavailable: return "Attachment"
        }
    }

    /// SF Symbol name for rendering in the timeline.
    var icon: String {
        switch self {
        case .retry:            return "arrow.clockwise"
        case .throttle:         return "hourglass"
        case .memoryPressure:   return "memorychip"
        case .parseFailure:     return "exclamationmark.bubble"
        case .formatCorrection: return "text.badge.xmark"
        case .contextPressure:  return "gauge.with.dots.needle.67percent"
        case .circuitBreaker:   return "arrow.triangle.2.circlepath.circle"
        case .resourceUnavailable: return "doc.badge.exclamationmark"
        }
    }

    /// When `true`, a warning of this category that fires inside a workflow node should
    /// also bubble up to the workflow-level bubble (not only the per-node timeline).
    /// Reserved for categories that indicate the **whole run** is at risk — users need
    /// to see these at the surface even if they haven't drilled into the node.
    /// Transient, node-local signals (retries, throttling, memory pressure) stay scoped
    /// to the node timeline.
    var bubblesToWorkflowLevel: Bool {
        switch self {
        case .circuitBreaker, .contextPressure:
            return true
        case .retry, .throttle, .memoryPressure, .parseFailure, .formatCorrection, .resourceUnavailable:
            return false
        }
    }
}

/// Terminal outcome of an agent execution — tells the UI whether to treat the final
/// content as an authoritative response (`.completed`), a best-effort synthesis after
/// the agent gave up (`.failed`), or the stream stopping mid-flight (`.cancelled`).
/// Emitted as the last event in the stream via `.executionFinished`.
enum ExecutionOutcome: String, Sendable, Codable, Equatable, CaseIterable {
    case completed
    case failed
    case cancelled

    var displayName: String {
        switch self {
        case .completed: return "Completed"
        case .failed:    return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

/// Classification for `.toolFailed` events — drives negativeConstraints policy,
/// episodic-memory retrieval weight, and UI affordance. Codable so timeline tool events
/// persist with category intact and survive session re-opens.
enum ToolFailureCategory: String, Sendable, Codable, Equatable, CaseIterable {
    case userDenied          // Ghost Protocol — user explicitly rejected the call
    case permissionRejected  // sandbox / OS-level permission missing
    case executionThrew      // tool's run closure threw (or returned semantic error)
    case timeout             // per-tool timeout deadline exceeded
    case invalidArgs         // preflight argument validation rejected the call
    case notFound            // tool name hallucinated / not in registry
    case cancelled           // user skipped ask_user or task was cancelled mid-flight

    var displayName: String {
        switch self {
        case .userDenied:         return "Denied"
        case .permissionRejected: return "Permission"
        case .executionThrew:     return "Error"
        case .timeout:            return "Timeout"
        case .invalidArgs:        return "Invalid Args"
        case .notFound:           return "Not Found"
        case .cancelled:          return "Cancelled"
        }
    }

    /// SF Symbol name for rendering in the timeline.
    var icon: String {
        switch self {
        case .userDenied:         return "hand.raised.fill"
        case .permissionRejected: return "lock.shield"
        case .executionThrew:     return "exclamationmark.triangle.fill"
        case .timeout:            return "clock.badge.exclamationmark"
        case .invalidArgs:        return "text.badge.xmark"
        case .notFound:           return "questionmark.circle"
        case .cancelled:          return "xmark.circle"
        }
    }

    /// Whether failures of this category should produce a hard `negativeConstraint` (Ghost Protocol ban
    /// on the tool name). Soft failures are transient and the agent may retry with different args.
    var producesHardConstraint: Bool {
        switch self {
        case .userDenied, .permissionRejected, .notFound:
            return true
        case .executionThrew, .timeout, .invalidArgs, .cancelled:
            return false
        }
    }

    /// Typed projection into the `ActionStatus` vocabulary used by `MemoryAction`
    /// and the episodic XML emitters. Each `ToolFailureCategory` case maps 1:1
    /// to an `ActionStatus` failure case. Render to a prompt-friendly lowercase
    /// XML attribute via `actionStatus.xmlValue`.
    var actionStatus: ActionStatus {
        switch self {
        case .userDenied:         return .denied
        case .permissionRejected: return .permissionDenied
        case .executionThrew:     return .failed
        case .timeout:            return .timeout
        case .invalidArgs:        return .invalidArgs
        case .notFound:           return .notFound
        case .cancelled:          return .cancelled
        }
    }
}

/// Structured output from a tool execution.
/// Used to render "Artifacts" in the UI (e.g., a file list card).
struct ToolOutput: Sendable, Identifiable, Equatable {
    let id: UUID
    let toolName: String
    let params: String
    let output: String
    let isSuccess: Bool

    init(id: UUID = UUID(), toolName: String, params: String = "", output: String, isSuccess: Bool) {
        self.id = id
        self.toolName = toolName
        self.params = params
        self.output = output
        self.isSuccess = isSuccess
    }
}

// Backward-compatible Codable: legacy persisted data may lack the `params` field.
extension ToolOutput: Codable {
    enum CodingKeys: String, CodingKey {
        case id, toolName, params, output, isSuccess
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        toolName = try c.decode(String.self, forKey: .toolName)
        params = try c.decodeIfPresent(String.self, forKey: .params) ?? ""
        output = try c.decode(String.self, forKey: .output)
        isSuccess = try c.decode(Bool.self, forKey: .isSuccess)
    }
}

/// Severity classification for a tool-confirmation HITL (A1) — drives the banner accent/icon so a
/// destructive `delete_file` no longer renders identically to a benign `list_directory`.
enum HITLRiskTier: String, Sendable, Codable, Equatable, CaseIterable {
    case safe        // read-only / idempotent — no state change
    case moderate    // mutates state, generally recoverable
    case destructive // irreversible or high-impact (delete, shell, applescript)

    /// Short banner label.
    var label: String {
        switch self {
        case .safe:        return "Read-only"
        case .moderate:    return "Modifies"
        case .destructive: return "Destructive"
        }
    }

    /// SF Symbol for the risk badge.
    var icon: String {
        switch self {
        case .safe:        return "eye"
        case .moderate:    return "pencil"
        case .destructive: return "exclamationmark.triangle.fill"
        }
    }

    /// Best-effort classification by tool name. Native tools are mapped explicitly; unknown / MCP
    /// tools default to `.moderate`. (MCP annotation-driven refinement — `readOnlyHint` /
    /// `destructiveHint` from `ToolAnnotations` — is a follow-on.)
    static func classify(toolName: String) -> HITLRiskTier {
        switch toolName {
        case "delete_file", "execute_shell", "run_applescript", "fs_organize_batch":
            return .destructive
        case "write_file", "move_file", "copy_file", "create_folder", "fs_watch_folder":
            return .moderate
        case "read_file", "list_directory", "fs_smart_search", "fs_read_metadata",
             "get_system_stats", "read_session_history", "web_search":
            return .safe
        default:
            return .moderate
        }
    }
}

/// [HITL] Data Model for the Permission Card
struct PendingToolConfirmation: Sendable, Identifiable, Codable, Equatable {
    let id: UUID
    let toolName: String
    let params: String
    /// A1: severity tier driving the banner's colour/icon.
    let risk: HITLRiskTier
    /// A1: structured arguments for an expandable, pretty-printed view (nil if `params` wasn't JSON).
    let arguments: JSONValue?

    init(
        id: UUID = UUID(),
        toolName: String,
        params: String,
        risk: HITLRiskTier = .moderate,
        arguments: JSONValue? = nil
    ) {
        self.id = id
        self.toolName = toolName
        self.params = params
        self.risk = risk
        self.arguments = arguments
    }
}

/// Data Model for Agent Clarification Requests
struct PendingClarification: Sendable, Identifiable, Codable, Equatable {
    let id: UUID
    let question: String
    /// A5: optional suggested answers rendered as one-tap choice buttons (nil/empty = free text).
    let options: [String]?
    /// A5: render a multi-line editor instead of a single-line field.
    let multiline: Bool

    init(id: UUID = UUID(), question: String, options: [String]? = nil, multiline: Bool = false) {
        self.id = id
        self.question = question
        self.options = options
        self.multiline = multiline
    }
}

/// Data Model for Plan Review HITL — the user can edit subtasks before approving.
struct PendingPlanReview: Sendable, Identifiable, Codable, Equatable {
    let id: UUID                // operationID for suspension correlation
    var subtasks: [SubTask]     // mutable — user can edit before approving

    init(id: UUID = UUID(), subtasks: [SubTask]) {
        self.id = id
        self.subtasks = subtasks
    }
}

/// Data Model for a Workflow Gate HITL (E1). The user picks one of N options; that choice routes the
/// workflow to the matching output port (per-option branching, like a Condition node but human-decided).
struct PendingGate: Sendable, Identifiable, Codable, Equatable {
    let id: UUID                // operationID for suspension correlation
    let prompt: String
    let options: [String]       // the choices; each maps to an output port of the same label
    let deadline: Date?         // absolute auto-reject time for the live countdown (nil = indefinite)

    init(id: UUID = UUID(), prompt: String, options: [String], deadline: Date? = nil) {
        self.id = id
        self.prompt = prompt
        self.options = options
        self.deadline = deadline
    }
}

// MARK: - Unified HITL Interaction Enum

/// A single enum representing all possible Human-in-the-Loop interaction types.
/// Only one interaction can be pending at a time per message.
/// Adding a new HITL type only requires adding a case here — Swift exhaustive
/// switch enforces handling in all consumers at compile time.
enum PendingInteraction: Sendable, Codable, Equatable, Identifiable {
    case toolConfirmation(PendingToolConfirmation)
    case clarification(PendingClarification)
    case planReview(PendingPlanReview)
    case gate(PendingGate)

    var id: UUID {
        switch self {
        case .toolConfirmation(let c): return c.id
        case .clarification(let c): return c.id
        case .planReview(let p): return p.id
        case .gate(let g): return g.id
        }
    }

    /// The operation ID used by ExecutionSuspensionService for resume correlation.
    var operationID: UUID { id }

    /// The tool name, if this interaction is a tool confirmation.
    var toolName: String? {
        if case .toolConfirmation(let c) = self { return c.toolName }
        return nil
    }
}

// MARK: - Source-Attributed HITL (InteractionCenter model)

/// Describes WHERE a HITL request originated so a single shared surface can title and route
/// it correctly across the chat, code, and workflow interfaces. Minted at the stream-bridge
/// boundary (`ActiveStreamManager`) where interface mode + workflow node identity are in scope.
struct HITLOrigin: Sendable, Equatable, Codable {
    enum Interface: String, Sendable, Codable {
        case chat, code, workflow, scheduled
    }

    /// Which interface raised the request.
    let interface: Interface
    /// The conversation the request belongs to (filtering + cancel-by-conversation).
    let conversationID: UUID
    /// Workflow node identifier, when `interface == .workflow`; nil otherwise.
    let nodeID: UUID?
    /// Human-readable node / agent name for the banner subtitle (e.g. "Security Agent").
    let nodeName: String?
    /// Banner header text (e.g. "Security Agent · Question" or "Permission required").
    let title: String
    /// The originating agent profile id — lets "Always allow" (A4) flip the tool to auto-approve
    /// in the right profile. nil when unknown.
    let profileID: UUID?

    init(
        interface: Interface,
        conversationID: UUID,
        nodeID: UUID? = nil,
        nodeName: String? = nil,
        title: String,
        profileID: UUID? = nil
    ) {
        self.interface = interface
        self.conversationID = conversationID
        self.nodeID = nodeID
        self.nodeName = nodeName
        self.title = title
        self.profileID = profileID
    }
}

/// A single pending Human-in-the-Loop request, source-attributed, queued by `InteractionCenter`.
/// `id` IS the suspension `operationID` — the universal correlation key used to resume.
struct PendingHITL: Identifiable, Sendable, Equatable, Codable {
    let id: UUID                  // == operationID
    let origin: HITLOrigin
    let kind: PendingInteraction  // reuses the existing 3-case interaction vocabulary
    let timestamp: Date
    let upstreamNodeNames: [String]   // workflow context; empty for chat / code

    init(
        id: UUID,
        origin: HITLOrigin,
        kind: PendingInteraction,
        timestamp: Date = Date(),
        upstreamNodeNames: [String] = []
    ) {
        self.id = id
        self.origin = origin
        self.kind = kind
        self.timestamp = timestamp
        self.upstreamNodeNames = upstreamNodeNames
    }
}
