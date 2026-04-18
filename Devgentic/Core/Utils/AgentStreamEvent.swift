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
    
    /// The agent is reasoning. Use this to update a "Thinking..." UI component.
    /// Wrapped with a stable ID to fix SwiftUI ForEach layout jumps.
    /// - sourceNodeID: When emitted from a workflow node, identifies which node produced this thought.
    case thought(_ message: String, id: UUID = UUID(), sourceNodeID: UUID? = nil)

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
    case requestClarification(question: String, operationID: UUID = UUID(), sourceNodeID: UUID? = nil)

    /// A non-fatal warning or error message to display in the trace/debug log.
    case error(String)

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

    /// A workflow node has failed.
    case workflowNodeFailed(nodeID: UUID, profileName: String, error: String)

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
    case requestPlanReview(subtasks: [SubTask], operationID: UUID = UUID())

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

    var displayName: String {
        switch self {
        case .retry:            return "Retry"
        case .throttle:         return "Throttled"
        case .memoryPressure:   return "Memory"
        case .parseFailure:     return "Parse"
        case .formatCorrection: return "Format"
        case .contextPressure:  return "Context"
        case .circuitBreaker:   return "Loop Guard"
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
        case .retry, .throttle, .memoryPressure, .parseFailure, .formatCorrection:
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

    /// Episode-memory status tag consumed by `EpisodicHistoryFormatter` and surfaced
    /// inside the `<episodic_memory>` XML block injected into prompts. Shorter than
    /// `displayName` and chosen to be unambiguous when the LLM reads prior failures.
    var episodeStatusTag: String {
        switch self {
        case .userDenied:         return "DENIED"
        case .permissionRejected: return "PERMISSION_DENIED"
        case .executionThrew:     return "FAILED"
        case .timeout:            return "TIMEOUT"
        case .invalidArgs:        return "INVALID_ARGS"
        case .notFound:           return "NOT_FOUND"
        case .cancelled:          return "CANCELLED"
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

/// [HITL] Data Model for the Permission Card
struct PendingToolConfirmation: Sendable, Identifiable, Codable, Equatable {
    let id: UUID
    let toolName: String
    let params: String

    init(id: UUID = UUID(), toolName: String, params: String) {
        self.id = id
        self.toolName = toolName
        self.params = params
    }
}

/// Data Model for Agent Clarification Requests
struct PendingClarification: Sendable, Identifiable, Codable, Equatable {
    let id: UUID
    let question: String

    init(id: UUID = UUID(), question: String) {
        self.id = id
        self.question = question
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

// MARK: - Unified HITL Interaction Enum

/// A single enum representing all possible Human-in-the-Loop interaction types.
/// Only one interaction can be pending at a time per message.
/// Adding a new HITL type only requires adding a case here — Swift exhaustive
/// switch enforces handling in all consumers at compile time.
enum PendingInteraction: Sendable, Codable, Equatable, Identifiable {
    case toolConfirmation(PendingToolConfirmation)
    case clarification(PendingClarification)
    case planReview(PendingPlanReview)

    var id: UUID {
        switch self {
        case .toolConfirmation(let c): return c.id
        case .clarification(let c): return c.id
        case .planReview(let p): return p.id
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
