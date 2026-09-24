// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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
    /// - stepId: The agent iteration (ReAct step) this call belongs to. Persisted onto the
    ///   timeline so a resumed run can regroup a flat timeline into per-iteration turns (G1).
    case toolCall(name: String, params: String, sourceNodeID: UUID? = nil, stepId: Int? = nil)
    
    /// [HITL] Phase 3: Explicit Permission Request
    /// The agent pauses and asks the user for permission to proceed.
    /// - toolName: The name of the sensitive tool (e.g. "delete_file")
    /// - params: The parameters needed for the tool (e.g. path)
    /// - operationID: Unique identifier for this HITL operation (for multi-surface dedup)

    /// Human-readable name of the node that raised this, for the banner title. Carried
    /// SEPARATELY from `sourceNodeID` because that id is the APPROVAL-SCOPE key and, for a
    /// request forwarded out of a sub-workflow, it names an INNER node the parent's
    /// `WorkflowExecutionState.nodeResults` has never heard of (the child's node events are
    /// deliberately suppressed). Resolving the title from the id therefore always missed and
    /// every nested request rendered as a bare "Permission required". One field cannot be both
    /// the security key and the display key.
    case requestConfirmation(toolName: String, params: String, operationID: UUID = UUID(), sourceNodeID: UUID? = nil, sourceNodeName: String? = nil)

    /// [E1] A workflow Gate node is asking the user to pick one of `options`. The choice routes the
    /// workflow to the matching output port. `deadline` is the absolute auto-reject time (live countdown).
    /// ⚠️ New associated values MUST be defaulted and appended. This event SUSPENDS the executor,
    /// and the sub-workflow forwarder ends in `default:` — a swallowed suspending
    /// event is a permanent hang, not a visible failure, because the executor is already parked on
    /// the operationID and nothing times out. Defaulted values keep every existing positional
    /// binding compiling while a NEW case would silently fall into those `default:` arms.
    case requestGate(prompt: String, options: [String], operationID: UUID = UUID(), deadline: Date? = nil, sourceNodeID: UUID? = nil, inputText: String? = nil, highlights: [RuleMatchSpan] = [], sourceNodeName: String? = nil)

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
    case requestClarification(question: String, operationID: UUID = UUID(), sourceNodeID: UUID? = nil, options: [String]? = nil, multiline: Bool = false, sourceNodeName: String? = nil)

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
    case workflowNodeCompleted(nodeID: UUID, profileName: String, summary: String, hasWarnings: Bool = false)

    /// A workflow node has failed. `suggestion` carries an optional actionable
    /// remediation hint (derived from the typed `AgentFailureReason`) that the UI
    /// folds into the node's failure detail.
    case workflowNodeFailed(nodeID: UUID, profileName: String, error: String, suggestion: String? = nil)

    /// A workflow node DID NOT RUN. Not a failure — see `NodeSkipReason`.
    ///
    /// ⚠️ This case exists because the channel used to have no way to say it. A skip was squeezed
    /// through `workflowNodeFailed` carrying the prose "Upstream dependency failed", so:
    ///   • every node on an unchosen Router branch was reported as an upstream FAILURE on a run
    ///     where nothing failed;
    ///   • `.skipped` was declared in both the live and the persisted status enums and was
    ///     **unreachable in both** — the UI drew a "Skipped" icon, colour and label that no run
    ///     could ever produce;
    ///   • nine surfaces string-matched the message back into "did not run", and three of them
    ///     forgot, so one node read "Not run" on screen and "Failed" to VoiceOver.
    /// Emit this — never `workflowNodeFailed` — for a node that did not execute.
    /// `ranBeforeSkip` = did this node BEGIN EXECUTING before the skip settled?
    ///
    /// ⚠️ Deliberately NON-defaulted so the compiler forces every emit site to answer. The two
    /// user-skip settle sites produce the IDENTICAL `.skipped(reason: .byUser)` — correct for the
    /// engine (both keep downstream edges live and forward the input unchanged) but it left the UI
    /// no way to tell "never started" from "started, worked, output discarded", so a node that had
    /// just burned an 829ms model call was tagged "Not run" (observed on-device 2026-08-23).
    /// The criterion is positional and checkable: a site AFTER the node's `workflowNodeStarted`
    /// yields true. Carried structurally rather than inferred UI-side, because the executor knows
    /// it by control flow while the UI could only guess from row presence.
    case workflowNodeSkipped(nodeID: UUID, profileName: String, reason: NodeSkipReason, ranBeforeSkip: Bool)

    /// A workflow node was cancelled mid-flight. Distinct from failure: the user asked for it.
    case workflowNodeCancelled(nodeID: UUID, profileName: String)

    /// [CF-30] A failed attempt WILL be retried, emitted before the retry back-off begins.
    ///
    /// ⚠️ Its whole purpose is to be delivered BEFORE a Stop can arrive. The executor already
    /// yields `.workflowNodeCancelled` when the back-off sleep is cancelled, but that event can
    /// never be acted on: `ActiveStreamManager`'s consumer calls `try Task.checkCancellation()`
    /// at the top of the loop body, so once the task is cancelled it throws before switching on
    /// whatever was yielded. Anything the UI must know about a cancelled retry therefore has to
    /// be recorded while the run is still healthy — which is what this is.
    ///
    /// Carries no delay: the UI must NOT render "retrying" from it. WF-CC4 deliberately moved
    /// that claim to AFTER the sleep so an attempt cancelled mid-delay never says it is retrying
    /// when it never will. This only marks the row as retry-pending so `settleInFlightWork` can
    /// settle it as cancelled rather than leaving a genuine-looking failure behind.
    case workflowNodeRetryScheduled(nodeID: UUID, profileName: String, attemptsRemaining: Int)

    /// Overall workflow progress update.
    case workflowProgress(completed: Int, total: Int)

    /// [WF-RU4] The RUN-LEVEL verdict on whether any node genuinely failed — distinct from
    /// `.executionFinished`'s `outcome`, which drives the CHAT BUBBLE's chip and must NOT change
    /// for this case. An error-handled run (or one where an unrelated parallel branch delivered
    /// the answer) legitimately shows a plain green completed chip in chat: the DELIVERED answer
    /// is exactly as complete as a clean run's. This tells the WORKFLOW-SPECIFIC surfaces (the
    /// persisted run record, the Execution view's pill/step-counter) that a node failed anyway,
    /// so THEY can say so honestly without touching what the chat bubble shows. Yielded once,
    /// alongside `.executionFinished(outcome: .completed)`, at the exact point the engine already
    /// computes `successfulTerminals`/`failedNodes` — `freeze()` has no live graph topology of its
    /// own to determine "is there an answering terminal", so it cannot derive this independently
    /// without duplicating the engine's own edge-liveness logic.
    case workflowRunFinished(hadGenuineFailure: Bool)

    // MARK: - Capability Events (Planning, Self-Reflection, Delegation)

    /// Planning capability: a plan has been generated. Carries the full structured plan
    /// so the UI can render a live plan card (step list + statuses), not just a count.
    case planGenerated(subtasks: [SubTask])

    /// Planning capability: the user approved the plan (possibly edited in review).
    /// Carries the FINAL plan that will execute — the UI replaces its step list with
    /// this, since review edits can add/remove/reword steps.
    case planApproved(subtasks: [SubTask])

    /// Planning capability: a subtask has started execution.
    /// - id: the SubTask.id — stable join key for the plan card's step row.
    case subtaskStarted(id: String, index: Int, total: Int, description: String)

    /// Planning capability: a subtask has finished.
    /// - outcome: the inner run's terminal outcome (nil = clean completion assumed);
    ///   `.completedWithWarnings` marks a forced-termination (degraded) step,
    ///   `.failed` a hard failure — drives the step row's status icon honestly.
    /// - durationMs: wall-clock for the step, measured by the capability.
    case subtaskCompleted(id: String, index: Int, total: Int, summary: String, outcome: ExecutionOutcome? = nil, durationMs: Int? = nil)

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
    case requestPlanReview(subtasks: [SubTask], operationID: UUID = UUID(), sourceNodeID: UUID? = nil, sourceNodeName: String? = nil)

    // MARK: - History Compaction

    /// IC-powered history compaction completed successfully.
    ///
    /// (There is deliberately no `compactionStarted` counterpart any more: compaction runs
    /// in the background, so a "started" chip could persist with no terminal row whenever
    /// the stream ends first — reading as a hang forever. The completed/failed chips stand
    /// alone; `CapabilityMilestoneKind.compactionStarted` survives only so historical
    /// persisted timelines still decode.)
    /// - turnsCompacted: Number of turns that were summarized into the checkpoint.
    /// - summaryPreview: First ~120 chars of the checkpoint summary for UI display.
    /// - checkpoint: The synthetic `.checkpoint` message itself. Carried across the stream
    ///   boundary because the backend layer has no persistence access — the UI layer saves
    ///   it and inserts it into the live history. Without this the checkpoint died with the
    ///   request, so every later turn re-summarized the same turns from scratch (a full IC
    ///   load + inference per request) and no checkpoint ever survived a restart.
    case compactionCompleted(turnsCompacted: Int, summaryPreview: String, checkpoint: ChatMessage)

    /// IC-powered history compaction failed or timed out.
    ///
    /// Without this, a failure was silent: the catch site only logged, so a user who had
    /// just waited through a multi-second IC stall saw nothing at all — indistinguishable
    /// from the model simply being slow. The run continues with uncompacted history.
    /// - reason: Short, user-facing cause (timeout, empty summary, model unavailable).
    case compactionFailed(reason: String)

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
/// ⚠️ Hand-written `RawRepresentable` so an unrecognised category is PRESERVED, not rejected.
/// Highest growth probability of the six — new warning kinds are added routinely.
///
/// ⚠️ `CaseIterable` cannot be synthesized alongside an associated-value case, so `allCases` is
/// hand-written below and deliberately EXCLUDES `.other` (it is not a fixed member of the
/// vocabulary). Verified 2026-08-04: no `allCases` consumer exists repo-wide, so nothing changes
/// meaning; it is kept only so the conformance does not silently disappear from the API.
enum WarningCategory: RawRepresentable, Sendable, Codable, Equatable, CaseIterable {
    case retry             // transient network / backend blip — retry in progress
    case throttle          // rate limit hit — backing off
    case memoryPressure    // scratchpad budget utilization high
    case parseFailure      // malformed JSON / XML from model
    case formatCorrection  // model described tool in prose instead of structured call
    case contextPressure   // nearing iteration / compaction threshold
    case circuitBreaker    // repetitive-action / loop safeguard tripping (imminent or already aborted)
    case resourceUnavailable // an attached/upstream file couldn't be read (report-and-skip)
    case midRunError       // a failure the run survived (failed workflow node / planning subtask) — demoted from an `.error` card when prose streamed after it (ASM-1)

    /// A category written by a newer build, carried verbatim.
    case other(String)

    static var allCases: [WarningCategory] {
        [.retry, .throttle, .memoryPressure, .parseFailure, .formatCorrection,
         .contextPressure, .circuitBreaker, .resourceUnavailable, .midRunError]
    }

    init?(rawValue: String) {
        switch rawValue {
        case "retry": self = .retry
        case "throttle": self = .throttle
        case "memoryPressure": self = .memoryPressure
        case "parseFailure": self = .parseFailure
        case "formatCorrection": self = .formatCorrection
        case "contextPressure": self = .contextPressure
        case "circuitBreaker": self = .circuitBreaker
        case "resourceUnavailable": self = .resourceUnavailable
        case "midRunError": self = .midRunError
        default: self = .other(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .retry: return "retry"
        case .throttle: return "throttle"
        case .memoryPressure: return "memoryPressure"
        case .parseFailure: return "parseFailure"
        case .formatCorrection: return "formatCorrection"
        case .contextPressure: return "contextPressure"
        case .circuitBreaker: return "circuitBreaker"
        case .resourceUnavailable: return "resourceUnavailable"
        case .midRunError: return "midRunError"
        case .other(let raw): return raw
        }
    }

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
        case .midRunError:      return "Error"
        // The raw value is the only truthful thing this build knows about the category, and
        // `WarningRow` uppercases whatever it gets — so it reads as a label, not a leak.
        case .other(let raw):   return raw
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
        case .midRunError:      return "exclamationmark.triangle"
        case .other:            return "exclamationmark.triangle"
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
        case .circuitBreaker, .contextPressure, .midRunError:
            return true
        case .retry, .throttle, .memoryPressure, .parseFailure, .formatCorrection, .resourceUnavailable:
            return false
        // ⚠️ Deliberately `false`. Bubbling to the workflow surface asserts "the whole run is at
        // risk", and this build cannot know that about a category it does not recognise. The
        // warning still renders in the node's own timeline, so nothing is hidden — it just does
        // not get promoted on a guess.
        case .other:
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
    /// Degraded success: the run stopped early (circuit-breaker abort, iteration budget) but
    /// synthesized a usable best-effort answer. Chat shows the answer + an amber chip; a workflow
    /// node COMPLETES (output flows downstream, joins satisfied) instead of hard-failing the run.
    case completedWithWarnings
    case failed
    case cancelled

    var displayName: String {
        switch self {
        case .completed:             return "Completed"
        case .completedWithWarnings: return "Completed with warnings"
        case .failed:                return "Failed"
        case .cancelled:             return "Cancelled"
        }
    }
}

/// Classification for `.toolFailed` events — drives negativeConstraints policy,
/// episodic-memory retrieval weight, and UI affordance. Codable so timeline tool events
/// persist with category intact and survive session re-opens.
/// ⚠️ Hand-written `RawRepresentable` so an unrecognised category is PRESERVED, not dropped — the
/// seventh String-raw enum in this persisted blob to get the treatment, and the one the first pass
/// missed (G85).
///
/// It rides `ChatMessageSD.timelineEventsData` inside `TimelineEvent`. Before this, a category
/// written by a newer build failed the strict decode of the event carrying it; the total `.unknown`
/// catch-all preserved the bytes, but the whole tool call rendered as an opaque unrecognised event
/// instead of a failure with a reason. Carrying the rawValue keeps the event legible.
///
/// Stdlib `RawRepresentable where RawValue == String` gives byte-identical `Codable` and
/// rawValue-based `Equatable`, so no call site changes and the wire format is unchanged.
enum ToolFailureCategory: RawRepresentable, Sendable, Codable, Equatable, CaseIterable {
    case userDenied          // Ghost Protocol — user explicitly rejected the call
    case permissionRejected  // sandbox / OS-level permission missing
    case executionThrew      // tool's run closure threw (or returned semantic error)
    case timeout             // per-tool timeout deadline exceeded
    case invalidArgs         // preflight argument validation rejected the call
    case notFound            // tool name hallucinated / not in registry
    case cancelled           // user skipped ask_user or task was cancelled mid-flight
    /// A category written by a newer build, carried verbatim.
    case other(String)

    init?(rawValue: String) {
        switch rawValue {
        case "userDenied":         self = .userDenied
        case "permissionRejected": self = .permissionRejected
        case "executionThrew":     self = .executionThrew
        case "timeout":            self = .timeout
        case "invalidArgs":        self = .invalidArgs
        case "notFound":           self = .notFound
        case "cancelled":          self = .cancelled
        default:                   self = .other(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .userDenied:         return "userDenied"
        case .permissionRejected: return "permissionRejected"
        case .executionThrew:     return "executionThrew"
        case .timeout:            return "timeout"
        case .invalidArgs:        return "invalidArgs"
        case .notFound:           return "notFound"
        case .cancelled:          return "cancelled"
        case .other(let raw):     return raw
        }
    }

    /// ⚠️ Hand-written: `CaseIterable` synthesis breaks once a case carries an associated value.
    /// `.other` is excluded because it is unbounded — `allCases` means "the categories this build
    /// knows", which is what any picker or exhaustiveness check actually wants.
    static var allCases: [ToolFailureCategory] {
        [.userDenied, .permissionRejected, .executionThrew, .timeout, .invalidArgs, .notFound, .cancelled]
    }

    var displayName: String {
        switch self {
        case .userDenied:         return "Denied"
        case .permissionRejected: return "Permission"
        case .executionThrew:     return "Error"
        case .timeout:            return "Timeout"
        case .invalidArgs:        return "Invalid Args"
        case .notFound:           return "Not Found"
        case .cancelled:          return "Cancelled"
        case .other:              return "Unknown"
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
        case .other:              return "exclamationmark.circle"
        }
    }

    /// Whether failures of this category should produce a hard `negativeConstraint` (Ghost Protocol ban
    /// on the tool name). Soft failures are transient and the agent may retry with different args.
    ///
    /// ⚠️ `.other` is SOFT. A hard constraint bans the tool outright, and a check that cannot answer
    /// must not block the action (§7 invariant 23) — banning a tool because this build does not
    /// recognise the failure category would turn an unknown into a permanent restriction. The cost of
    /// being wrong the soft way is one retry; the cost of being wrong the hard way is a capability
    /// the agent can no longer use for the rest of the run.
    var producesHardConstraint: Bool {
        switch self {
        case .userDenied, .permissionRejected, .notFound:
            return true
        case .executionThrew, .timeout, .invalidArgs, .cancelled, .other:
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
        // Honest generic: it IS a failure, we just cannot say which kind. `.failed` is the
        // vocabulary's own catch-all and is what reaches the episodic XML.
        case .other:              return .failed
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
    /// For file-writing tools: the target file's content captured JUST BEFORE the write
    /// ("" when the file didn't exist yet; nil when not captured — non-file tool, or the
    /// file was unreadable/over the snapshot cap). Powers the timeline's "View changes"
    /// diff in the Code Viewer.
    let preWriteContent: String?
    /// For EDIT tools (whose params carry only find/replace strings): the file's content
    /// read back JUST AFTER a successful edit — the post-state the params can't provide.
    /// Nil for full-content writers (their params ARE the post-state) and failures.
    let postWriteContent: String?

    init(id: UUID = UUID(), toolName: String, params: String = "", output: String, isSuccess: Bool, preWriteContent: String? = nil, postWriteContent: String? = nil) {
        self.id = id
        self.toolName = toolName
        self.params = params
        self.output = output
        self.isSuccess = isSuccess
        self.preWriteContent = preWriteContent
        self.postWriteContent = postWriteContent
    }
}

// Backward-compatible Codable: legacy persisted data may lack the `params`,
// `preWriteContent`, and `postWriteContent` fields.
extension ToolOutput: Codable {
    enum CodingKeys: String, CodingKey {
        case id, toolName, params, output, isSuccess, preWriteContent, postWriteContent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        toolName = try c.decode(String.self, forKey: .toolName)
        params = try c.decodeIfPresent(String.self, forKey: .params) ?? ""
        output = try c.decode(String.self, forKey: .output)
        isSuccess = try c.decode(Bool.self, forKey: .isSuccess)
        preWriteContent = try c.decodeIfPresent(String.self, forKey: .preWriteContent)
        postWriteContent = try c.decodeIfPresent(String.self, forKey: .postWriteContent)
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

    /// The NATIVE tool name map. [WF-SE3] Callers must not feed it non-native names — the HITL
    /// enqueue path goes through `ToolRiskResolver.resolve`, which consults `NativeToolCatalog`
    /// membership first and MCP `ToolAnnotations` for server tools; this map used alone gave a
    /// third-party tool named `read_file` the native green badge.
    ///
    /// The arbitrary-code tools are asked, not listed. This case used to name `execute_shell`
    /// and `run_applescript` but not `batch_command` — the same `/bin/zsh -c` under another
    /// name — so identical acts were badged "Destructive" and "Modifies" depending on which
    /// tool the model happened to pick. `ToolCapability` is the one answer, and a source test
    /// keeps it honest.
    static func classify(toolName: String) -> HITLRiskTier {
        if ToolCapability.executesArbitraryCode(toolName) { return .destructive }

        switch toolName {
        case "delete_file", "fs_organize_batch",
             // Split out of read/write multiplexers 2026-07-31 precisely so they could be
             // labelled and gated as what they are. Each removes something with no undo:
             // an event, a reminder, a process (SIGKILL), or every tag on a file.
             "delete_calendar_event", "delete_reminder", "kill_process", "replace_finder_tags",
             // Writes instructions that are injected into the model's context on every future run
             // of every profile linked to that skill — the approval is per-conversation, the effect
             // is not, and there is no undo the approving conversation can reach. `.destructive` is
             // what makes `SessionToolApprovals.allow` refuse a durable "allow for this chat" grant
             // for it, inside the actor.
             //
             // ⚠️ Deliberately NOT added to `ToolCapability.arbitraryCodeExecution`. That set is
             // build-enforced in BOTH directions by ToolCapabilityTests: it means "hands its own
             // argument to an interpreter", which `update_skill` does not do, and adding it there
             // to reach `.destructive` faster would fail the test that keeps the set honest.
             "update_skill":
            return .destructive
        case "write_file", "move_file", "copy_file", "create_folder", "fs_watch_folder":
            return .moderate
        case "read_file", "list_directory", "fs_smart_search", "fs_read_metadata",
             "get_system_stats", "web_search":
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
    /// [WF-SE3] True when `risk` rests on the MCP server's own `ToolAnnotations` claims — the
    /// banner appends "(server-declared)" so a third-party assertion never renders
    /// indistinguishably from a native guarantee. Optional so pre-SE3 persisted confirmations
    /// (G1 park/resume) decode as nil.
    var riskIsServerDeclared: Bool?
    /// The on-disk file this tool will write, when the ARGUMENTS do not name one.
    ///
    /// ⚠️⚠️ Exists for `update_project_context`, whose only argument is `content` — the target is
    /// fixed by the run's project, not chosen by the model. Without this the banner had nothing
    /// to preview against and fell back to raw JSON, which is how a paragraph asserting two
    /// methods that do not exist was approved into `.devgentic/context.md` and then injected into
    /// every subsequent conversation for that project (field-observed 2026-09-20).
    ///
    /// ⚠️ Deliberately NOT injected into `arguments`. The banner makes every top-level string
    /// argument editable, and this tool derives its own destination — so an edited path would be
    /// silently ignored and the write would land somewhere other than what was approved. It is a
    /// preview hint, and only that.
    ///
    /// Optional so pre-existing persisted confirmations (G1 park/resume) still decode.
    var previewPath: String?

    init(
        id: UUID = UUID(),
        toolName: String,
        params: String,
        risk: HITLRiskTier = .moderate,
        arguments: JSONValue? = nil,
        riskIsServerDeclared: Bool? = nil,
        previewPath: String? = nil
    ) {
        self.id = id
        self.toolName = toolName
        self.params = params
        self.risk = risk
        self.arguments = arguments
        self.riskIsServerDeclared = riskIsServerDeclared
        self.previewPath = previewPath
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
/// A span of the arbitration input that a specific rule matched, so the banner can paint it in that
/// rule's colour.
///
/// ⚠️ Offsets are in CHARACTERS, measured against the exact `inputText` carried alongside them —
/// never against anything the UI re-derives. `WorkflowRunDisplayData` builds its own per-node input
/// by joining upstreams with `"\n\n"` over layout topology with no liveness filter, while the
/// executor joins the LIVE upstreams with `"\n"`; the two strings differ in separator width AND in
/// which upstreams they contain, so an offset from one is meaningless in the other.
struct RuleMatchSpan: Sendable, Codable, Equatable, Hashable {
    /// The rule label — matches one of `PendingGate.options`, which is also the button title.
    let label: String
    let start: Int
    let end: Int
}

struct PendingGate: Sendable, Identifiable, Codable, Equatable {
    let id: UUID                // operationID for suspension correlation
    let prompt: String
    let options: [String]       // the choices; each maps to an output port of the same label
    let deadline: Date?         // absolute auto-reject time for the live countdown (nil = indefinite)

    /// The text the decision is about, when there is one (Router ambiguity arbitration). Carried in
    /// the payload rather than re-read anywhere, because `highlights` is measured against exactly
    /// this string. `nil` for an ordinary Gate, which has no input to show.
    let inputText: String?

    /// Which rule matched which part of `inputText`. Empty for an ordinary Gate, and empty for
    /// operators that have no locatable span (`equals` gives only the whole field; `does not
    /// contain` / `is empty` / `always` match by absence or unconditionally).
    let highlights: [RuleMatchSpan]

    init(id: UUID = UUID(), prompt: String, options: [String], deadline: Date? = nil,
         inputText: String? = nil, highlights: [RuleMatchSpan] = []) {
        self.id = id
        self.prompt = prompt
        self.options = options
        self.deadline = deadline
        self.inputText = inputText
        self.highlights = highlights
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

    /// The id of the agent MESSAGE whose run raised this request — i.e. which RUN is asking.
    ///
    /// ⚠️⚠️ WHY A RUN ID AND NOT JUST `conversationID`, WHICH IS ALREADY HERE. `conversationID`
    /// answers "where does the banner belong"; it cannot answer "who is asking", and those differ
    /// whenever two root runs share a conversation. `RemoteMirrorService` gates which RUNS it
    /// mirrors (invariant 46: a run is mirrored only when the source that started it matches the
    /// remote session), but `evaluateMessageState` then pulled pending items from
    /// `InteractionCenter.items(for: conversationID)` — CONVERSATION-keyed — so a tool confirmation
    /// raised by a LOCALLY-started run could have its tool name and parameters posted to a
    /// third-party chat, simply because a remote run happened to be observed in the same
    /// conversation. The run gate was correct and the item lookup went around it.
    ///
    /// ⚠️ IT IS THE AGENT MESSAGE ID BECAUSE THAT IS WHAT THE MIRROR ALREADY HOLDS.
    /// `ActiveStreamManager` mints `TraceContext(profile:messageID: agentMessage.id)` for the run,
    /// and the mirror observes that same `agentMessage` — so the two sides join with no new
    /// identifier invented and no new plumbing to keep in step.
    ///
    /// ⚠️ NIL MEANS "RAISED OUTSIDE A RUN", NOT "UNKNOWN RUN" — and the mirror treats it as
    /// not-attributable rather than as a mismatch, so such an item is still posted. Excluding nil
    /// would silently stop mirroring MCP elicitation, whose source→conversation association is made
    /// in `resolveMCPTool` where no run identity is in scope. See §6 of `architecture_readme.md`.
    let runMessageID: UUID?

    init(
        interface: Interface,
        conversationID: UUID,
        nodeID: UUID? = nil,
        nodeName: String? = nil,
        title: String,
        profileID: UUID? = nil,
        runMessageID: UUID? = nil
    ) {
        self.interface = interface
        self.conversationID = conversationID
        self.nodeID = nodeID
        self.nodeName = nodeName
        self.title = title
        self.profileID = profileID
        self.runMessageID = runMessageID
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
