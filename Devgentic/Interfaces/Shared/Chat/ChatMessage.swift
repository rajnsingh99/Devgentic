// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatMessage.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

struct ResponseMessageVariant: Codable, Equatable {

    // Why: a `let` with an initial value is encoded but skipped on decode, so the id would regenerate on every load;
    // it must stay a `var` with a tolerant decoder.
    /// Stable identity for this variant, preserved across a save/load cycle.
    var variantId: UUID = UUID()

    var content: MessageContent
    let backendEntityId: UUID?

    /// Explicit so the tolerant `init(from:)` in the extension below can name the keys; declaring `CodingKeys` here keeps
    /// the memberwise init.
    enum CodingKeys: String, CodingKey {
        case variantId, content, backendEntityId
    }
}

extension ResponseMessageVariant {

    // Why: lives in an extension: an inline `init(from:)` would suppress the memberwise init used by call sites.
    /// Tolerant decoder: a missing `variantId` is minted fresh instead of failing the variant; `content` stays required.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.variantId = (try? container.decode(UUID.self, forKey: .variantId)) ?? UUID()
        self.content = try container.decode(MessageContent.self, forKey: .content)
        self.backendEntityId = try container.decodeIfPresent(UUID.self, forKey: .backendEntityId)
    }
}

/// Holds all response variants for a single agent message.
struct AgentResponse: Codable, Equatable {
    var variants: [ResponseMessageVariant]
    var selectedVariantIndex: Int = 0
    var generationAttempts: Int = 1
}

/// Data model for a tool execution event in the agent timeline; the struct is replaced in place when the tool completes.
/// `failureCategory` is nil on success; on failure it carries the structured cause so EpisodicHistoryFormatter can
/// build constraints without string-matching the output.
struct ToolExecutionData: Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    var params: String   // mutable: refreshed to the actually-executed params on completion (HITL edits)
    var output: String?
    var isSuccess: Bool?
    var failureCategory: ToolFailureCategory? = nil
    var durationMs: Int? = nil
    var isExecuting: Bool
    /// The agent iteration (ReAct step) this tool call belonged to. Lets a resumed run regroup a
    /// flat timeline back into per-iteration assistant(tool_calls)→tool(result) turns (G1 Piece 2).
    /// Optional + nil for legacy rows / non-ReAct paths.
    var stepId: Int? = nil
    /// For file-writing tools: the target file's content just before the write ('' = file did not exist; nil = not
    /// captured). Drives the timeline's 'View changes' diff; size-capped at capture and session-scoped, never persisted
    /// (see `encode(to:)`).
    var preWriteContent: String? = nil
    /// For EDIT tools (find/replace params, no full content): the file read back after a
    /// successful edit — the post-state the params can't provide. Size-capped at capture.
    /// Session-scoped like `preWriteContent`.
    var postWriteContent: String? = nil

    // Why: derived here, not at the consumer: the episodic formatter runs on every request and an O(n^2) diff per
    // write is too slow.
    /// What this call changed on disk, derived from the snapshots once when the tool finishes (persisted, bounded to
    /// 4KB).
    var effect: ActionEffect? = nil
    // Why: not a failure signal: `grep` exits 1 for no match, and counting that as failure would trip
    // `CognitiveCircuitBreaker`.
    /// The command's exit status for shell-family tools, nil for everything else; carried because a verdict cannot be
    /// re-derived.
    var exitCode: Int32? = nil

    /// Longest tool output retained in the timeline; beyond it the output is truncated with an explicit marker.
    /// `TimelineTurnReconstructor` rebuilds a resumed run's tool observations from `output`, so the marker tells the
    /// model it is incomplete.
    static let maxPersistedOutputLength = 32_768

    /// Truncates `text` to `maxPersistedOutputLength`, appending a marker that states what
    /// was dropped. Returns the input unchanged when it already fits. Pure, for testing.
    static func cappedOutput(_ text: String) -> String {
        guard text.count > maxPersistedOutputLength else { return text }
        let dropped = text.count - maxPersistedOutputLength
        return String(text.prefix(maxPersistedOutputLength))
            + "\n\n… [truncated \(dropped) characters — the full output was not retained]"
    }
}

// Backward-compatible Codable: fields absent from older rows decode as optional/nil.
// Encode is explicit so the session-scoped file snapshots are omitted from persistence while still decoding if present.
extension ToolExecutionData: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, params, output, isSuccess, failureCategory, durationMs, isExecuting, stepId, preWriteContent, postWriteContent, effect, exitCode
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(params, forKey: .params)
        try c.encodeIfPresent(output, forKey: .output)
        try c.encodeIfPresent(isSuccess, forKey: .isSuccess)
        try c.encodeIfPresent(failureCategory, forKey: .failureCategory)
        try c.encodeIfPresent(durationMs, forKey: .durationMs)
        try c.encode(isExecuting, forKey: .isExecuting)
        try c.encodeIfPresent(stepId, forKey: .stepId)
        // `preWriteContent`/`postWriteContent` are omitted (session-scoped); `effect` is their bounded summary and is encoded.
        try c.encodeIfPresent(effect, forKey: .effect)
        // Like `effect`: a verdict the next turn cannot re-derive.
        try c.encodeIfPresent(exitCode, forKey: .exitCode)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        params = try c.decode(String.self, forKey: .params)
        output = try c.decodeIfPresent(String.self, forKey: .output)
        isSuccess = try c.decodeIfPresent(Bool.self, forKey: .isSuccess)
        failureCategory = try c.decodeIfPresent(ToolFailureCategory.self, forKey: .failureCategory)
        durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs)
        exitCode = try c.decodeIfPresent(Int32.self, forKey: .exitCode)
        isExecuting = try c.decode(Bool.self, forKey: .isExecuting)
        stepId = try c.decodeIfPresent(Int.self, forKey: .stepId)
        preWriteContent = try c.decodeIfPresent(String.self, forKey: .preWriteContent)
        postWriteContent = try c.decodeIfPresent(String.self, forKey: .postWriteContent)
        effect = try c.decodeIfPresent(ActionEffect.self, forKey: .effect)
    }
}

// Why: a flat String rawValue, not a nested enum carrying `exited(code:)`: nested rawValue changes corrupt timelines.
// `interrupted` is present so a persisted `running` can be reloaded as such after a quit kills the task.
/// How a background task ended, on the wire.
enum BackgroundTaskStatus: String, Codable, Equatable {
    case running
    case exited
    case timedOut
    case stopped
    case interrupted

    var isTerminal: Bool { self != .running }
}

// Why: `outputTail` is bounded: the full log lives in the file at `logPath`, and a live task would otherwise re-encode
// a large blob on every output tick.
/// A `batch_command(background:)` task, as the timeline sees it.
struct BackgroundTaskData: Codable, Equatable, Identifiable {
    /// Timeline identity. Distinct from `taskID`: this keys SwiftUI's `ForEach` and must stay
    /// stable across every in-place update of the row.
    let id: UUID
    /// The registry's handle — `bg_1`. What `get_task_output` / `stop_background_task` take.
    let taskID: String
    /// What the model called this task, when it said. Optional on the wire, so a row written
    /// before this existed still decodes; every surface falls back to the command.
    var name: String?
    let command: String
    let workingDirectory: String
    let startedAt: Date
    var finishedAt: Date?
    var status: BackgroundTaskStatus
    /// Set only for `.exited`. A signal number is NOT an exit code — see the registry's `Status`.
    var exitCode: Int32?
    let logPath: String
    /// The last `maxOutputTail` characters of the log. Never the whole log.
    var outputTail: String
    /// Characters the log holds in total, so the UI can say how much is not shown here.
    var logCharacterCount: Int
    /// The `ResponseMessageVariant.variantId` of the attempt that started this task, so a Redo's reports can be told apart.
    /// Nil on older rows, read as the current attempt.
    var variantID: UUID? = nil

    /// Small enough that a handful of tasks cannot bloat the message blob, large enough to carry a
    /// build's verdict — the last ~200 chars of an xcodebuild log.
    static let maxOutputTail = 4_000

    var elapsed: TimeInterval { (finishedAt ?? Date()).timeIntervalSince(startedAt) }
}

enum TimelineEvent: Codable, Equatable, Identifiable {
    /// Generic thinking / narration — extended thinking traces (step.thought), capability
    /// progress, executor status. The source is typically the system rather than the model's
    /// own monologue. For the model's visible prose, use `.reasoning`.
    case thought(id: UUID, text: String)
    /// LLM's visible assistant monologue (step.reasoning). Visually similar to `.thought`
    /// but semantically distinct so analytics / scratchpad injection / future UI treatment
    /// can differentiate model-authored prose from system narration.
    case reasoning(id: UUID, text: String)
    case toolExecution(ToolExecutionData)
    // Why: not a `toolExecution` with `isExecuting: true`: that flag means the ReAct loop is blocked there, and
    // consumers read it so.
    /// A `batch_command(background:)` task, which outlives the tool call that started it.
    case backgroundTask(BackgroundTaskData)
    case mediaGeneration(id: UUID, toolName: String, artifact: MediaArtifact?, isComplete: Bool)

    // Capability milestones
    case capabilityMilestone(id: UUID, kind: CapabilityMilestoneKind, detail: String)

    // System-level recoverable warnings (rate limits, memory pressure, parse retries, etc.)
    case warning(id: UUID, category: WarningCategory, text: String)

    /// A Plan & Execute run rendered as one structured card: the step list with live statuses, each step holding its own
    /// nested timeline (reasoning + tool rows). Updated in place by `CapabilityCardRouter`.
    case planExecution(PlanRunData)

    /// A Reflexion run rendered as one structured card: attempts with verdicts and the
    /// evaluator's critique, each attempt holding its own nested timeline.
    case reflectionRun(ReflectionRunData)

    // Why: `id` is derived from the payload, not freshly generated: SwiftUI's ForEach keys off it and a new UUID
    // would churn the list.
    /// An event this build cannot model, held verbatim so re-encoding preserves it. Produced by a case a newer build
    /// introduced or a known case whose payload changed shape.
    case unknown(id: UUID, caseName: String, payload: PreservedJSON)

    var id: UUID {
        switch self {
        case .thought(let id, _): return id
        case .reasoning(let id, _): return id
        case .toolExecution(let data): return data.id
        case .backgroundTask(let data): return data.id
        case .mediaGeneration(let id, _, _, _): return id
        case .capabilityMilestone(let id, _, _): return id
        case .warning(let id, _, _): return id
        case .planExecution(let data): return data.id
        case .reflectionRun(let data): return data.id
        case .unknown(let id, _, _): return id
        }
    }

    // Why: not folded into `isCapabilityCard`: cards are never evicted, so all-unknown timelines would breach the
    // cap; see `evictOverflow`.
    /// True for an event written by a newer build that this one is preserving verbatim.
    var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }

    /// True for the structured capability cards that must survive timeline eviction
    /// (they hold the run's shape; dropping one deletes whole nested sub-timelines).
    var isCapabilityCard: Bool {
        switch self {
        case .planExecution, .reflectionRun: return true
        // A background task's row is the only record of a live process (id, log path, UI handle), so it is never evicted;
        // safe because there are only a handful per conversation.
        case .backgroundTask: return true
        default: return false
        }
    }

    /// Depth-first flattening: self plus every event nested inside capability cards (plan steps, reflection attempts).
    /// Consumers that want every tool/thought in a run (episodic memory, history rebuild, resume) iterate this.
    var flattenedIncludingNested: [TimelineEvent] {
        switch self {
        case .planExecution(let data):
            return [self] + data.steps.flatMap { $0.events.flatMap(\.flattenedIncludingNested) }
        case .reflectionRun(let data):
            return [self] + data.attempts.flatMap { $0.events.flatMap(\.flattenedIncludingNested) }
        default:
            return [self]
        }
    }
}

// MARK: - TimelineEvent Codable (forward-compatible)
// Hand-written codec that mirrors the synthesized one: `KnownTimelineEvent` keeps the original cases' synthesized
// conformance, so the wire format is unchanged; a total fallback preserves anything unreadable as `.unknown`.

/// The eight cases as they were before `.unknown`, with their conformance still synthesized.
/// Exists only to pin the on-disk wire format; never stored, never surfaced.
private enum KnownTimelineEvent: Codable {
    case thought(id: UUID, text: String)
    case reasoning(id: UUID, text: String)
    case toolExecution(ToolExecutionData)
    case backgroundTask(BackgroundTaskData)
    case mediaGeneration(id: UUID, toolName: String, artifact: MediaArtifact?, isComplete: Bool)
    case capabilityMilestone(id: UUID, kind: CapabilityMilestoneKind, detail: String)
    case warning(id: UUID, category: WarningCategory, text: String)
    case planExecution(PlanRunData)
    case reflectionRun(ReflectionRunData)
}

extension TimelineEvent {

    init(from decoder: Decoder) throws {
        do {
            switch try KnownTimelineEvent(from: decoder) {
            case .thought(let id, let text):        self = .thought(id: id, text: text)
            case .reasoning(let id, let text):      self = .reasoning(id: id, text: text)
            case .toolExecution(let data):          self = .toolExecution(data)
            case .backgroundTask(let data):         self = .backgroundTask(data)
            case .mediaGeneration(let id, let toolName, let artifact, let isComplete):
                self = .mediaGeneration(id: id, toolName: toolName, artifact: artifact, isComplete: isComplete)
            case .capabilityMilestone(let id, let kind, let detail):
                self = .capabilityMilestone(id: id, kind: kind, detail: detail)
            case .warning(let id, let category, let text):
                self = .warning(id: id, category: category, text: text)
            case .planExecution(let data):          self = .planExecution(data)
            case .reflectionRun(let data):          self = .reflectionRun(data)
            }
        } catch {
            // Preserve rather than throw; if even this fails the value is not JSON, and the error propagates to the array decode.
            let payload = try PreservedJSON(from: decoder)
            let entry = payload.singleKeyEntry
            self = .unknown(
                id: (entry?.value ?? payload).stableIdentity,
                caseName: entry?.key ?? "<malformed>",
                payload: payload
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        let known: KnownTimelineEvent
        switch self {
        case .thought(let id, let text):        known = .thought(id: id, text: text)
        case .reasoning(let id, let text):      known = .reasoning(id: id, text: text)
        case .toolExecution(let data):          known = .toolExecution(data)
        case .backgroundTask(let data):         known = .backgroundTask(data)
        case .mediaGeneration(let id, let toolName, let artifact, let isComplete):
            known = .mediaGeneration(id: id, toolName: toolName, artifact: artifact, isComplete: isComplete)
        case .capabilityMilestone(let id, let kind, let detail):
            known = .capabilityMilestone(id: id, kind: kind, detail: detail)
        case .warning(let id, let category, let text):
            known = .warning(id: id, category: category, text: text)
        case .planExecution(let data):          known = .planExecution(data)
        case .reflectionRun(let data):          known = .reflectionRun(data)

        case .unknown(_, _, let payload):
            // Re-emit exactly what was read, at whatever depth this sits. The parent's encoder sees
            // a single value, so nothing upstream needs to know this element is opaque.
            var container = encoder.singleValueContainer()
            try container.encode(payload)
            return
        }
        try known.encode(to: encoder)
    }
}

// MARK: - Capability Card Data (Plan & Execute)

/// Live status of one plan step, the UI vocabulary for `PlanStepData` (distinct from the planner's `SubTaskStatus`).
/// Hand-written `RawRepresentable` so an unrecognised status is preserved, not rejected; Codable and equality are
/// rawValue-based.
enum PlanStepStatus: RawRepresentable, Codable, Equatable, Sendable {
    case pending, running, completed
    /// Ended early but usable (inner run finished `.completedWithWarnings`, e.g. circuit-breaker abort).
    case warning
    case failed
    case cancelled
    /// A status written by a newer build, carried verbatim.
    case other(String)

    init?(rawValue: String) {
        switch rawValue {
        case "pending": self = .pending
        case "running": self = .running
        case "completed": self = .completed
        case "warning": self = .warning
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        default: self = .other(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .pending: return "pending"
        case .running: return "running"
        case .completed: return "completed"
        case .warning: return "warning"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        case .other(let raw): return raw
        }
    }

    /// True for a status written by a newer build. Named rather than pattern-matched at call
    /// sites so predicates that must account for it are greppable.
    var isUnrecognised: Bool {
        if case .other = self { return true }
        return false
    }
}

/// One step of a plan card: identity + live status + its own nested timeline.
struct PlanStepData: Codable, Equatable, Identifiable {
    let id: String            // SubTask.id (stable across review edits)
    var title: String
    var toolHints: [String]?
    var status: PlanStepStatus
    var summary: String?      // completion summary from the capability (≤150 chars)
    var durationMs: Int?
    var events: [TimelineEvent]

    init(
        id: String,
        title: String,
        toolHints: [String]? = nil,
        status: PlanStepStatus = .pending,
        summary: String? = nil,
        durationMs: Int? = nil,
        events: [TimelineEvent] = []
    ) {
        self.id = id
        self.title = title
        self.toolHints = toolHints
        self.status = status
        self.summary = summary
        self.durationMs = durationMs
        self.events = events
    }
}

enum PlanRunPhase: String, Codable, Equatable, Sendable {
    case awaitingApproval, executing, finished
}

/// The whole Plan & Execute run as one timeline entity, updated in place while streaming.
struct PlanRunData: Codable, Equatable, Identifiable {
    let id: UUID
    var phase: PlanRunPhase
    var steps: [PlanStepData]
    var outcome: ExecutionOutcome?    // set when the run finishes
    var startedAt: Date
    var finishedAt: Date?

    init(
        id: UUID = UUID(),
        phase: PlanRunPhase = .executing,
        steps: [PlanStepData] = [],
        outcome: ExecutionOutcome? = nil,
        startedAt: Date = Date(),
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.phase = phase
        self.steps = steps
        self.outcome = outcome
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    /// Number of steps that finished successfully; `.other` is deliberately not counted, since counting it would
    /// overstate progress.
    var completedCount: Int {
        steps.filter { $0.status == .completed || $0.status == .warning }.count
    }

    /// True when any step warned, failed, or has an unrecognised status; `.other` counts as degraded because it cannot be
    /// verified.
    var hasDegradedSteps: Bool {
        steps.contains { $0.status == .warning || $0.status == .failed || $0.status.isUnrecognised }
    }
}

// MARK: - Capability Card Data (Reflexion)

/// Hand-written `RawRepresentable` so an unrecognised attempt status is preserved, not rejected (as `PlanStepStatus`).
enum ReflectionAttemptStatus: RawRepresentable, Codable, Equatable, Sendable {
    case running
    case evaluating
    case rejected     // evaluator said RETRY — critique carries why
    case accepted     // evaluator said PASS
    /// Ran to completion without an evaluator verdict (the final trial is never evaluated).
    case completed
    case failed
    case cancelled
    /// A status written by a newer build, carried verbatim.
    case other(String)

    init?(rawValue: String) {
        switch rawValue {
        case "running": self = .running
        case "evaluating": self = .evaluating
        case "rejected": self = .rejected
        case "accepted": self = .accepted
        case "completed": self = .completed
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        default: self = .other(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .running: return "running"
        case .evaluating: return "evaluating"
        case .rejected: return "rejected"
        case .accepted: return "accepted"
        case .completed: return "completed"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        case .other(let raw): return raw
        }
    }
}

/// One Reflexion trial: its verdict, the evaluator's critique, and its nested timeline.
struct ReflectionAttemptData: Codable, Equatable, Identifiable {
    var id: Int { trial }
    let trial: Int
    var status: ReflectionAttemptStatus
    var critique: String?
    var durationMs: Int?
    var events: [TimelineEvent]

    init(
        trial: Int,
        status: ReflectionAttemptStatus = .running,
        critique: String? = nil,
        durationMs: Int? = nil,
        events: [TimelineEvent] = []
    ) {
        self.trial = trial
        self.status = status
        self.critique = critique
        self.durationMs = durationMs
        self.events = events
    }
}

/// The whole Reflexion run as one timeline entity, updated in place while streaming.
struct ReflectionRunData: Codable, Equatable, Identifiable {
    let id: UUID
    var maxTrials: Int
    var attempts: [ReflectionAttemptData]
    var acceptedTrial: Int?
    var outcome: ExecutionOutcome?
    var startedAt: Date
    var finishedAt: Date?

    init(
        id: UUID = UUID(),
        maxTrials: Int,
        attempts: [ReflectionAttemptData] = [],
        acceptedTrial: Int? = nil,
        outcome: ExecutionOutcome? = nil,
        startedAt: Date = Date(),
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.maxTrials = maxTrials
        self.attempts = attempts
        self.acceptedTrial = acceptedTrial
        self.outcome = outcome
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

/// Describes the type of capability milestone for timeline rendering. Hand-written `RawRepresentable` so an
/// unrecognised milestone is preserved; the row still renders `detail` with a generic icon.
enum CapabilityMilestoneKind: RawRepresentable, Codable, Equatable, Sendable {
    // Planning
    case planGenerated          // "Planned 3 subtasks"
    case planReviewRequested    // "Plan awaiting approval"
    case subtaskStarted         // "Subtask 1/3: Research APIs"
    case subtaskCompleted       // "Subtask 1/3 complete"

    // Self-Reflection
    case reflectionTrialStarted // "Trial 1/3 started"
    case reflectionEvaluating   // "Evaluating trial 1..."
    case reflectionRetrying     // "Retrying — critique: ..."
    case reflectionAccepted     // "Result accepted (trial 2)"

    // Agent Delegation
    case delegationStarted      // "Delegating to SecurityReviewer"
    case delegationCompleted    // "SecurityReviewer completed"

    // History Compaction
    case compactionStarted      // "Compacting 15 turns..."
    case compactionCompleted    // "History compacted — 15 turns summarized"
    case compactionFailed       // "History compaction failed — continuing uncompacted"

    /// A milestone written by a newer build, carried verbatim.
    case other(String)

    init?(rawValue: String) {
        switch rawValue {
        case "planGenerated": self = .planGenerated
        case "planReviewRequested": self = .planReviewRequested
        case "subtaskStarted": self = .subtaskStarted
        case "subtaskCompleted": self = .subtaskCompleted
        case "reflectionTrialStarted": self = .reflectionTrialStarted
        case "reflectionEvaluating": self = .reflectionEvaluating
        case "reflectionRetrying": self = .reflectionRetrying
        case "reflectionAccepted": self = .reflectionAccepted
        case "delegationStarted": self = .delegationStarted
        case "delegationCompleted": self = .delegationCompleted
        case "compactionStarted": self = .compactionStarted
        case "compactionCompleted": self = .compactionCompleted
        case "compactionFailed": self = .compactionFailed
        default: self = .other(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .planGenerated: return "planGenerated"
        case .planReviewRequested: return "planReviewRequested"
        case .subtaskStarted: return "subtaskStarted"
        case .subtaskCompleted: return "subtaskCompleted"
        case .reflectionTrialStarted: return "reflectionTrialStarted"
        case .reflectionEvaluating: return "reflectionEvaluating"
        case .reflectionRetrying: return "reflectionRetrying"
        case .reflectionAccepted: return "reflectionAccepted"
        case .delegationStarted: return "delegationStarted"
        case .delegationCompleted: return "delegationCompleted"
        case .compactionStarted: return "compactionStarted"
        case .compactionCompleted: return "compactionCompleted"
        case .compactionFailed: return "compactionFailed"
        case .other(let raw): return raw
        }
    }

    /// SF Symbol for rendering in the timeline.
    var icon: String {
        switch self {
        case .planGenerated: return "list.bullet.clipboard"
        case .planReviewRequested: return "checklist.checked"
        case .subtaskStarted: return "arrow.right.circle"
        case .subtaskCompleted: return "checkmark.circle"
        case .reflectionTrialStarted: return "arrow.trianglehead.2.counterclockwise"
        case .reflectionEvaluating: return "magnifyingglass"
        case .reflectionRetrying: return "arrow.counterclockwise"
        case .reflectionAccepted: return "checkmark.seal"
        case .delegationStarted: return "person.line.dotted.person"
        case .delegationCompleted: return "person.fill.checkmark"
        case .compactionStarted: return "archivebox"
        case .compactionCompleted: return "archivebox.fill"
        case .compactionFailed: return "archivebox.badge.exclamationmark"
        case .other: return "circle.dashed"
        }
    }

    /// Accent color category for visual distinction.
    var colorCategory: MilestoneColor {
        switch self {
        case .planGenerated, .planReviewRequested, .subtaskStarted, .subtaskCompleted: return .planning
        case .reflectionTrialStarted, .reflectionEvaluating, .reflectionRetrying, .reflectionAccepted: return .reflection
        case .delegationStarted, .delegationCompleted: return .delegation
        case .compactionStarted, .compactionCompleted, .compactionFailed: return .compaction
        // A neutral tint rather than borrowing one of the four capability colours — tinting an
        // unrecognised milestone "planning" would assert a family it may not belong to.
        case .other: return .unrecognised
        }
    }

    enum MilestoneColor: String, Codable, Sendable {
        case planning    // blue tint
        case reflection  // purple tint
        case delegation  // green tint
        case compaction  // orange tint
        /// A milestone from a newer build — neutral, claims no capability family.
        case unrecognised
    }
}

/// Lifecycle/persistence state of a message: `.final`, or `.streaming`/`.parkedHITL` when the row was last written
/// mid-run, which marks an interrupted run after a restart; `.parkedHITL` carries the operationID needed to resume.
/// Defaults to `.final`.
enum MessageLifecycleState: Codable, Equatable, Sendable {
    case final
    case streaming
    case parkedHITL(operationID: UUID)

    /// Stable kind string for the split SwiftData columns (the operationID is stored separately).
    var rawKind: String {
        switch self {
        case .final: return "final"
        case .streaming: return "streaming"
        case .parkedHITL: return "parkedHITL"
        }
    }

    /// The parked HITL operation id, if any; the join key between a message and its pending HITL request, for resuming.
    var parkedOperationID: UUID? {
        if case .parkedHITL(let id) = self { return id }
        return nil
    }

    /// Whether the run that produced this message did not reach a clean finish.
    var isInterrupted: Bool { self != .final }

    /// Rebuilds from the persisted `(rawKind, parkedOperationID)` pair. Unknown / absent kinds
    /// decode as `.final`; a `.parkedHITL` that lost its operationID degrades to `.streaming`
    /// (still interrupted, just not resumable).
    static func restore(rawKind: String?, parkedOperationID: UUID?) -> MessageLifecycleState {
        switch rawKind {
        case "streaming": return .streaming
        case "parkedHITL":
            if let parkedOperationID { return .parkedHITL(operationID: parkedOperationID) }
            return .streaming
        default: return .final
        }
    }
}

@Observable
final class ChatMessage: Identifiable, Codable, Equatable, @unchecked Sendable {
    let id: UUID
    let conversationId: UUID
    let timestamp: Date
    let sender: SenderRole
    
    /// The distributed trace ID for the request that produced this message; looks up trace data for the Report UI.
    var traceID: String?

    /// The profile type that generated this message (bot, agent, workflow, imageGen).
    /// Tagged at creation time by ActiveStreamManager — eliminates runtime profile store lookups.
    var profileType: ProfileType?

    /// Where this message originated (local Mac UI, Telegram, Discord, Orb, QuickAccess, a scheduled task, a finished
    /// background task). Persisted via `messageSourceRaw`; rows without it decode as `.localUI`. Distinct from `sender`:
    /// this is what caused the turn.
    var messageSource: MessageSource = .localUI

    // Why: an unpaired assistant message is silently dropped by history pairing (`NativeHistoryConverter`,
    // `EpisodicHistoryFormatter`); keep the stub short: it rides in every later prompt.
    /// Machine-authored scaffolding: a turn nobody typed, written so the exchange pairs (e.g. a woken background-task
    /// report). Rendered as a centered system divider (see `BackgroundTaskDividerView`), not hidden.
    var isSyntheticPrompt: Bool = false
    
    var content: MessageContent
    var agentResponse: AgentResponse?
    var isStreaming: Bool = false

    /// Terminal outcome of the agent run that produced this message; nil while streaming or for older rows.
    /// Drives the 'response may be incomplete' indicator in the bubble.
    var terminalOutcome: ExecutionOutcome? = nil

    /// Optional human-readable reason accompanying `terminalOutcome`. Same nil semantics.
    var terminalReason: String? = nil

    // MARK: - Lifecycle / Run Identity (G1 Piece 1 — in-flight persistence)
    /// `.streaming` while a run is in flight, `.parkedHITL(operationID:)` while it awaits the user, `.final` once finished.
    /// Persisted so an interrupted run is distinguishable after restart. Defaults to `.final`.
    var lifecycleState: MessageLifecycleState = .final

    /// The provider/model/dialect that actually produced this message, captured at run start.
    /// `apiProvider`/`modelDialect` guard resume against a model switch; nil for older rows and user messages.
    var apiProvider: String? = nil
    var modelName: String? = nil
    var modelDialect: String? = nil

    // MARK: - Glass Box UI State (Gemini-Style)
    // These properties store the intermediate reasoning and tool outputs.
    // These properties derive chronological reasoning steps and tool outputs from timelineEvents.
    /// Unified thought stream used by the compact `ThinkingDynamicIsland`: both `.thought` (system narration) and
    /// `.reasoning` (model monologue). Callers that must tell them apart read `timelineEvents` directly.
    var thoughts: [AgentThought] {
        flattenedTimelineEvents.compactMap { event in
            switch event {
            case .thought(let id, let text):
                return AgentThought(id: id, text: text)
            case .reasoning(let id, let text):
                return AgentThought(id: id, text: text)
            default:
                return nil
            }
        }
    }

    /// The timeline with capability-card sub-timelines flattened in (depth-first, cards included as markers).
    /// Consumers that want everything that happened (episodic memory, history rebuild, resume, tool scans) iterate this.
    var flattenedTimelineEvents: [TimelineEvent] {
        timelineEvents.flatMap(\.flattenedIncludingNested)
    }

    /// The most recent completed image artifact anywhere in the timeline, including nested card timelines.
    /// An image generation surfaces its result only as a `.mediaGeneration` event, so finalizing promotes it to content.
    var lastCompletedImageArtifact: MediaArtifact? {
        for event in flattenedTimelineEvents.reversed() {
            if case .mediaGeneration(_, _, let artifact?, let isComplete) = event,
               isComplete, artifact.kind == .image {
                return artifact
            }
        }
        return nil
    }

    /// Resolves the content a finalized run displays: the streamed text, else a produced image artifact, else a 'stopped'
    /// placeholder. Pure and static so the finalize path and tests share it.
    static func resolveFinalizedContent(streamed: MessageContent?, imageArtifact: MediaArtifact?) -> MessageContent {
        if let streamed, let text = streamed.textContent,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return streamed
        }
        if let imageArtifact {
            return .mediaArtifact(imageArtifact)
        }
        return .markdownText(Self.stoppedRunPlaceholder)
    }

    /// Synthetic placeholder written when a run ends with no content; deliberately unlocalized because it is persisted
    /// and classified by.
    static let stoppedRunPlaceholder = "*Operation was stopped before a response could be generated.*"

    /// True when `text` is a synthetic stopped-run placeholder (exact match after trimming; a message that merely quotes
    /// the phrase is real content). Used by the RAG gate to keep placeholders out of conversation memory.
    static func isSyntheticPlaceholder(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == stoppedRunPlaceholder
    }

    /// What the bubble shows while a `.draftText` preview is live: the pre-draft content with the draft after it, by the
    /// rule a streamed chunk follows, except that a pre-draft `.error` card is shown as the draft alone and is not
    /// demoted until the real `.content` arrives.
    static func draftDisplayContent(baseline: MessageContent, draft: String) -> MessageContent {
        resolveStreamedChunkMerge(current: baseline, chunk: draft)?.content ?? .markdownText(draft)
    }

    static func resolveStreamedChunkMerge(current: MessageContent, chunk: String) -> (content: MessageContent, demotedError: TimelineEvent?)? {
        if case .error(let title, let details, _, let suggestion) = current {
            // A mid-run `.error` card is not appended onto: the answer starts fresh and the error is demoted to a timeline warning,
            // so the failure stays discoverable and is not merged into the answer text that is persisted and RAG-indexed.
            let headline = "\(title ?? "Error"): \(details)"
            let demoted = TimelineEvent.warning(
                id: UUID(),
                category: .midRunError,
                text: suggestion.map { "\(headline) — \($0)" } ?? headline
            )
            return (content: .markdownText(chunk), demotedError: demoted)
        }
        guard let currentText = current.textContent else { return nil }
        return (content: .markdownText(currentText + chunk), demotedError: nil)
    }

    /// Content for a run that ended in a throw after possibly streaming prose: real prose stays as content and the error
    /// demotes to a timeline warning; an error card or media has no prose to keep, so the card replaces it.
    static func resolveThrownFinalContent(streamed: MessageContent?, errorCard: MessageContent) -> (content: MessageContent, demotedError: TimelineEvent?) {
        guard let streamed else { return (errorCard, nil) }
        if case .error = streamed { return (errorCard, nil) }
        guard let text = streamed.textContent,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              case .error(let title, let details, _, let suggestion) = errorCard else {
            return (errorCard, nil)
        }
        let headline = "\(title ?? "Error"): \(details)"
        let demoted = TimelineEvent.warning(
            id: UUID(),
            category: .midRunError,
            text: suggestion.map { "\(headline) — \($0)" } ?? headline
        )
        return (streamed, demoted)
    }

    /// Terminal outcome for a run whose producer never emitted `.executionFinished`; a structured `.error` content is not
    /// `.completed`.
    static func resolveFallbackOutcome(threwError: Error?, content: MessageContent) -> (outcome: ExecutionOutcome, reason: String?) {
        if let threwError {
            return (.failed, threwError.localizedDescription)
        }
        if case .error(let title, let details, _, _) = content {
            return (.failed, "\(title ?? "Error"): \(details)")
        }
        return (.completed, nil)
    }

    /// Regeneration attempts allowed per message (Retry button gate + the mutation
    /// guard below share this — they had drifted into two literal `5`s).
    static let maxGenerationAttempts = 5

    // Why: a single write: reading `agentResponse` while a `modify` access is open is an exclusivity trap under @Observable.
    /// Prepares this message for a regeneration attempt in one write access: appends the fresh variant, selects it, bumps the
    /// attempt count, flips `isStreaming`. Returns `false` (no mutation) at the attempt cap or when there is no response.
    @discardableResult
    func beginRegenerationVariant(backendEntityId: UUID?) -> Bool {
        guard var response = agentResponse, response.generationAttempts < Self.maxGenerationAttempts else {
            return false
        }
        response.variants.append(ResponseMessageVariant(content: .markdownText(""), backendEntityId: backendEntityId))
        response.selectedVariantIndex = response.variants.count - 1
        response.generationAttempts += 1
        agentResponse = response
        isStreaming = true
        return true
    }

    /// Closes tool rows still marked executing at end of run, including rows nested in capability cards, so a cancel or
    /// failure mid-tool does not leave a spinner running forever. Returns how many were closed.
    @discardableResult
    func closeDanglingToolRows(outcome: ExecutionOutcome?) -> Int {
        DanglingToolRowCloser.close(&timelineEvents, outcome: outcome)
    }

    /// `closeDanglingToolRows`, returning the rows it settled so the caller can post the live-write completion
    /// that a cancelled or thrown run never emits.
    @discardableResult
    func closeDanglingToolRowsReporting(outcome: ExecutionOutcome?) -> [DanglingToolRowCloser.ClosedRow] {
        DanglingToolRowCloser.closeReporting(&timelineEvents, outcome: outcome)
    }

    /// Prepares persisted capability cards for a resumed run: drops dangling tool rows in nested timelines and closes any
    /// unfinished card, since the continuation streams new top-level events and an open card would spin forever.
    func sanitizeCapabilityCardsForResume() {
        func isDangling(_ event: TimelineEvent) -> Bool {
            if case .toolExecution(let data) = event { return data.isExecuting || data.output == nil }
            return false
        }
        func sanitize(_ plan: inout PlanRunData) {
            for s in plan.steps.indices {
                plan.steps[s].events.removeAll(where: isDangling)
                if plan.steps[s].status == .running { plan.steps[s].status = .cancelled }
            }
            if plan.phase != .finished {
                plan.phase = .finished
                plan.finishedAt = plan.finishedAt ?? Date()
            }
        }
        for i in timelineEvents.indices {
            switch timelineEvents[i] {
            case .planExecution(var plan):
                sanitize(&plan)
                timelineEvents[i] = .planExecution(plan)
            case .reflectionRun(var run):
                for a in run.attempts.indices {
                    run.attempts[a].events.removeAll(where: isDangling)
                    for e in run.attempts[a].events.indices {
                        if case .planExecution(var nested) = run.attempts[a].events[e] {
                            sanitize(&nested)
                            run.attempts[a].events[e] = .planExecution(nested)
                        }
                    }
                    if run.attempts[a].status == .running || run.attempts[a].status == .evaluating {
                        run.attempts[a].status = .cancelled
                    }
                }
                run.finishedAt = run.finishedAt ?? Date()
                timelineEvents[i] = .reflectionRun(run)
            default:
                break
            }
        }
    }

    /// Chronological timeline of reasoning steps, tool executions, and capability milestones, in event-loop order.
    /// Capped at `maxTimelineEvents` to bound memory in long-running agents.
    static let maxTimelineEvents = 500

    var timelineEvents: [TimelineEvent] = [] {
        didSet { timelineRevision &+= 1 }
    }

    // Why: both writers null the blob when the timeline is empty, so a failed read would erase the original bytes;
    // it lives on the value object so it reaches both writers across separate fetches.
    /// True when `timelineEventsData` could not be decoded, so `timelineEvents` is empty by failure, not because the run
    /// had no events. Excluded from `CodingKeys` and `==`: it describes this load, not the message.
    @ObservationIgnored var timelineDecodeFailed: Bool = false

    // Why: `contentData` is the conversation: re-encoding the Decode Error card over corrupt bytes would make them
    // unrecoverable.
    /// The placeholder issued when `contentData` could not be decoded at all, or nil if it decoded. Load-scoped and
    /// excluded from `CodingKeys` and `==`; readable JSON of an unknown shape decodes to `MessageContent.unknown`
    /// instead.
    @ObservationIgnored var undecodableContentPlaceholder: MessageContent?

    // Why: the failed decode leaves `agentResponse` nil, which the writers would persist over the unreadable blob.
    /// Set when `agentResponseData` could not be decoded on this load; load-scoped and excluded from `CodingKeys` and `==`.
    @ObservationIgnored var agentResponseDecodeFailed: Bool = false

    // Why: the failed decode leaves `tokenUsage` nil, which the writers would persist over the stored usage and cost.
    /// Set when `tokenUsageData` could not be decoded on this load; load-scoped and excluded from `CodingKeys` and `==`.
    @ObservationIgnored var tokenUsageDecodeFailed: Bool = false

    /// Whether it is safe to persist `content` over the stored blob.
    /// False only when the decode failed and the caller is handing back the very placeholder that was issued.
    var canPersistContent: Bool {
        guard let placeholder = undecodableContentPlaceholder else { return true }
        return (currentAgentContent ?? content) != placeholder
    }

    /// Whether it is safe to persist `agentResponse` over the stored blob: false only when the decode failed and nothing has
    /// replaced the nil it produced, so a regeneration that appends a real variant still writes.
    var canPersistAgentResponse: Bool {
        !(agentResponseDecodeFailed && agentResponse == nil)
    }

    /// Whether it is safe to persist `tokenUsage` over the stored blob: false only when the decode failed and nothing has
    /// replaced the nil it produced, so a run that later reports real usage still writes it.
    var canPersistTokenUsage: Bool {
        !(tokenUsageDecodeFailed && tokenUsage == nil)
    }

    /// Whether it is safe to persist `timelineEvents` over the stored blob: false only when the decode failed and nothing
    /// has been appended since. Never gate on `timelineEvents.isEmpty` alone: user and bot messages legitimately have
    /// empty timelines.
    var canPersistTimeline: Bool {
        !(timelineDecodeFailed && timelineEvents.isEmpty)
    }

    /// True when the timeline is not a faithful record of what the run did. Disqualifies resume: an `.unknown` (or an
    /// unrecognised card's nested events) is invisible to `TimelineTurnReconstructor`.
    var timelineIsDegraded: Bool {
        timelineDecodeFailed || flattenedTimelineEvents.contains(where: \.isUnknown)
    }

    // Why: seeded randomly per instance so two instances of the same persisted message never alias revisions in the
    // store's skip cache.
    /// Change marker for `timelineEvents`, bumped by `didSet` so every mutation path counts; the persistence flush and
    /// `AgentTimelineView` skip work on an unchanged timeline.
    @ObservationIgnored private(set) var timelineRevision: UInt64 = .random(in: UInt64.min ... UInt64.max)

    /// Appends a timeline event, evicting the oldest non-tool events if the cap is exceeded.
    /// Tool execution events are preserved to maintain output correctness; narrative events
    /// (thoughts and reasoning) are trimmed first as they're least valuable historically.
    func appendTimelineEvent(_ event: TimelineEvent) {
        timelineEvents.append(event)
        Self.evictOverflow(&timelineEvents, context: "top-level")
    }

    /// The single eviction rule for any timeline container, top-level or nested in capability cards: oldest narrative
    /// (.thought/.reasoning) first, then the oldest non-card event; a capability card is never evicted.
    static func evictOverflow(_ events: inout [TimelineEvent], context: String) {
        guard events.count > maxTimelineEvents else { return }
        if let firstNarrativeIndex = events.firstIndex(where: {
            switch $0 {
            case .thought, .reasoning: return true
            default: return false
            }
        }) {
            events.remove(at: firstNarrativeIndex)
            DGLogger(category: "ChatMessage").debug("[TIMELINE] Evicted oldest narrative event (\(context), cap \(maxTimelineEvents)).")
        } else if let firstEvictableIndex = events.firstIndex(where: { !$0.isCapabilityCard && !$0.isUnknown }) {
            events.remove(at: firstEvictableIndex)
            DGLogger(category: "ChatMessage").debug("[TIMELINE] Evicted oldest non-card event (\(context), cap \(maxTimelineEvents)).")
        } else if let firstUnknownIndex = events.firstIndex(where: { $0.isUnknown }) {
            // Third tier, deliberately last: an `.unknown` may be a card written by a newer build, so it must not be the first
            // victim, and it is not folded into `isCapabilityCard` because an all-unknown timeline would never evict.
            let dropped = events.remove(at: firstUnknownIndex)
            DGLogger(category: "ChatMessage").error(
                "[TIMELINE] Evicted an UNRECOGNISED event (\(context), cap \(maxTimelineEvents), "
                + "id \(dropped.id.uuidString.prefix(8))). CONSEQUENCE: an event written by a newer "
                + "build is gone from the in-memory record; if this message is re-persisted, a newer "
                + "build reloading it will not get that event back."
            )
        }
    }
    
    // MARK: - Token Usage (Persisted)
    /// Token usage for this message's LLM generation, extracted from provider API responses.
    var tokenUsage: TokenUsage?

    // MARK: - Transient UI State (Not Persisted)
    var agentState: AgentState = .idle

    // [HITL/P6] Live HITL state moved entirely to the unified InteractionCenter (single source of
    // truth). The per-message `pendingInteraction` container and its deprecated shims were removed.

    // MARK: - RAG Indexing State
    // No longer polled; index occurs on stream completion.

    // Rendered `.error` content ships as 'title: details' with a default title of 'Error'; anything measuring or matching
    // an error message must account for that separator and default title.

    // MARK: - Performance Caching
    @ObservationIgnored var cachedMarkdownBlocks: [ContentBlock]? = nil

    /// The exact text `cachedMarkdownBlocks` was parsed from: the cache's key, so a stale render for different text
    /// cannot be reused.
    @ObservationIgnored private var cachedMarkdownSource: String? = nil

    /// Test seam: the text `cachedMarkdownBlocks` was parsed from. Not read by app code — the
    /// cache's correctness is precisely "the blocks match this key", and a test that cannot see
    /// the key can only observe positional block ids, which are identical across a re-parse.
    var cachedMarkdownSourceForTesting: String? { cachedMarkdownSource }

    /// Incremental parser used only while this message is streaming: settled regions parse once and each flush re-parses
    /// the trailing block. Dropped on the first non-streaming access, forcing one full authoritative re-parse. Transient,
    /// never persisted.
    @ObservationIgnored private var streamingMarkdownParser: StreamingMarkdownParser? = nil

    var attachedTextFiles: [AttachedTextFile]?
    var attachedImageFiles: [AttachedImageFile]?
    @ObservationIgnored private var streamTask: Task<Void, Never>?

    /// Computed property to get the currently displayed content for an agent message.
    var currentAgentContent: MessageContent? {
        guard let response = agentResponse,
              response.variants.indices.contains(response.selectedVariantIndex) else {
            return nil
        }
        return response.variants[response.selectedVariantIndex].content
    }

    /// The content actually on screen for this message; search and render share it so they never disagree about which
    /// variant's text a message shows.
    var displayedContent: MessageContent {
        sender == .agent ? (currentAgentContent ?? content) : content
    }

    init(id: UUID = UUID(), conversationId: UUID, timestamp: Date = Date(), sender: SenderRole, content: MessageContent, attachedTextFiles: [AttachedTextFile]? = nil, attachedImageFiles: [AttachedImageFile]? = nil, isStreaming: Bool = false, backendEntityId: UUID? = nil) {
        self.id = id
        self.conversationId = conversationId
        self.timestamp = timestamp
        self.sender = sender
        self.content = content
        self.attachedTextFiles = attachedTextFiles
        self.attachedImageFiles = attachedImageFiles
        self.isStreaming = isStreaming

        if sender == .agent {
            let initialVariant = ResponseMessageVariant(
                content: content,
                backendEntityId: backendEntityId
            )
            self.agentResponse = AgentResponse(variants: [initialVariant])
        }
    }
    
    /// Parsed blocks for `text`, memoised per message; a cache hit requires `cachedMarkdownSource == text`.
    /// `invalidateMarkdownCache()` still forces the per-flush re-parse during streaming.
    func getOrCreateMarkdownBlocks(from text: String) -> [ContentBlock] {
        if isStreaming {
            if let cached = cachedMarkdownBlocks, cachedMarkdownSource == text { return cached }
            let parser = streamingMarkdownParser ?? StreamingMarkdownParser()
            streamingMarkdownParser = parser
            let blocks = parser.parse(text)
            self.cachedMarkdownBlocks = blocks
            self.cachedMarkdownSource = text
            return blocks
        }

        // First non-streaming access after a stream: drop the incremental state and invalidate so the full parse is
        // authoritative.
        if streamingMarkdownParser != nil {
            streamingMarkdownParser = nil
            cachedMarkdownBlocks = nil
            cachedMarkdownSource = nil
        }

        if let cached = cachedMarkdownBlocks, cachedMarkdownSource == text { return cached }
        let blocks = parseMarkdown(text)
        self.cachedMarkdownBlocks = blocks
        self.cachedMarkdownSource = text
        return blocks
    }

    func invalidateMarkdownCache() {
        self.cachedMarkdownBlocks = nil
        self.cachedMarkdownSource = nil
    }

    // Why: must stay pure: it is called detached from background tasks, so touching the markdown caches would add
    // an unsynchronised writer; do not route it back through `getOrCreateMarkdownBlocks`.
    /// Returns parsed ContentBlocks for the RAG indexing pipeline.
    func getBlocksForIndexing() -> [ContentBlock] {
        // Delegates to the indexer's Sendable snapshot parse so the two rules cannot drift.
        IndexableMessage(self).blocksForIndexing()
    }

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id &&
        lhs.conversationId == rhs.conversationId &&
        lhs.content == rhs.content &&
        lhs.isStreaming == rhs.isStreaming &&
        lhs.agentResponse == rhs.agentResponse &&
        lhs.timelineEvents == rhs.timelineEvents
    }
    
    func beginStreamingResponse(from service: BackendOrchestrationService) {
        // Lifecycle management placeholder
    }
    
    // MARK: - Codable (Schema Versioned)

    /// Current schema version of the FULL-OBJECT JSON envelope. Increment when adding/removing
    /// persisted fields.
    // Tags the full-object envelope only; the SwiftData store persists per-field blobs versioned at the `ChatMessageSD`
    // layer, so bumping this constant does not protect on-disk data.
    private static let currentSchemaVersion = 1

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id, conversationId, timestamp, sender, content
        case agentResponse, isStreaming, attachedTextFiles, attachedImageFiles
        case timelineEvents, traceID, profileType, tokenUsage
        case terminalOutcome, terminalReason
        case lifecycleState, apiProvider, modelName, modelDialect
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.id = try container.decode(UUID.self, forKey: .id)
        self.conversationId = try container.decode(UUID.self, forKey: .conversationId)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.sender = try container.decode(SenderRole.self, forKey: .sender)
        self.content = try container.decode(MessageContent.self, forKey: .content)
        self.agentResponse = try container.decodeIfPresent(AgentResponse.self, forKey: .agentResponse)
        self.isStreaming = try container.decode(Bool.self, forKey: .isStreaming)
        self.attachedTextFiles = try container.decodeIfPresent([AttachedTextFile].self, forKey: .attachedTextFiles)
        self.attachedImageFiles = try container.decodeIfPresent([AttachedImageFile].self, forKey: .attachedImageFiles)
        self.traceID = try container.decodeIfPresent(String.self, forKey: .traceID)
        self.profileType = try container.decodeIfPresent(ProfileType.self, forKey: .profileType)
        self.tokenUsage = try container.decodeIfPresent(TokenUsage.self, forKey: .tokenUsage)
        self.terminalOutcome = try container.decodeIfPresent(ExecutionOutcome.self, forKey: .terminalOutcome)
        self.terminalReason = try container.decodeIfPresent(String.self, forKey: .terminalReason)
        self.lifecycleState = try container.decodeIfPresent(MessageLifecycleState.self, forKey: .lifecycleState) ?? .final
        self.apiProvider = try container.decodeIfPresent(String.self, forKey: .apiProvider)
        self.modelName = try container.decodeIfPresent(String.self, forKey: .modelName)
        self.modelDialect = try container.decodeIfPresent(String.self, forKey: .modelDialect)

        self.timelineEvents = try container.decodeIfPresent([TimelineEvent].self, forKey: .timelineEvents) ?? []

        // Transient properties always initialize to defaults
        self.agentState = .idle
        self.cachedMarkdownBlocks = nil
        self.cachedMarkdownSource = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(conversationId, forKey: .conversationId)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(sender, forKey: .sender)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(agentResponse, forKey: .agentResponse)
        try container.encode(isStreaming, forKey: .isStreaming)
        try container.encodeIfPresent(attachedTextFiles, forKey: .attachedTextFiles)
        try container.encodeIfPresent(attachedImageFiles, forKey: .attachedImageFiles)
        try container.encodeIfPresent(traceID, forKey: .traceID)
        try container.encodeIfPresent(profileType, forKey: .profileType)
        try container.encode(timelineEvents, forKey: .timelineEvents)
        try container.encodeIfPresent(tokenUsage, forKey: .tokenUsage)
        try container.encodeIfPresent(terminalOutcome, forKey: .terminalOutcome)
        try container.encodeIfPresent(terminalReason, forKey: .terminalReason)
        try container.encode(lifecycleState, forKey: .lifecycleState)
        try container.encodeIfPresent(apiProvider, forKey: .apiProvider)
        try container.encodeIfPresent(modelName, forKey: .modelName)
        try container.encodeIfPresent(modelDialect, forKey: .modelDialect)
        // agentState, thoughts, artifacts are NOT encoded (transient / computed)
    }

}

// (AttachedTextFile, AttachedImageFile, MessageContent structs remain unchanged)
struct AttachedTextFile: Codable, Equatable, Identifiable {
    var id = UUID(); let name: String; let url: URL; let fileExtension: String; let content: String; let size: Int64
    /// What the model received for this file — `content` stays the FULL file (the code viewer
    /// opens it). nil = not recorded (a sender that never ran the delivery plan).
    var delivery: AttachmentDelivery? = nil
    static func == (lhs: AttachedTextFile, rhs: AttachedTextFile) -> Bool { return lhs.id == rhs.id && lhs.url == rhs.url }
}

struct AttachedImageFile: Codable, Equatable, Identifiable {
    var id = UUID(); let name: String; let url: URL; let fileExtension: String; let binaryData: Data; let size: Int64
    static func == (lhs: AttachedImageFile, rhs: AttachedImageFile) -> Bool { return lhs.id == rhs.id && lhs.url == rhs.url }
}

enum MessageContent: Equatable, Codable {
    case plainText(String)
    case markdownText(String)
    case codeBlock(language: String?, code: String)
    case error(title: String?, details: String, category: AgentErrorCategory? = nil, suggestion: String? = nil)
    case mediaArtifact(MediaArtifact)

    /// A compacted history checkpoint produced by IC-powered summarization.
    /// Contains a structured summary of older conversation turns.
    case checkpoint(summary: String)

    // Why: throwing on an unknown case would let the writers overwrite the original bytes.
    // `contentData` is the conversation, so an unknown case is carried rather than thrown on.
    /// Content this build cannot model, held verbatim so re-encoding preserves it: readable JSON of an unknown shape.
    /// Distinct from the Decode Error card, which is the presentation for genuinely corrupt bytes.
    case unknown(type: String, payload: PreservedJSON)

    enum CodingKeys: String, CodingKey {
        case type, text, language, code, title, details, artifact, summary
        case category, suggestion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "plainText":
            let text = try container.decode(String.self, forKey: .text)
            self = .plainText(text)
        case "markdownText":
            let text = try container.decode(String.self, forKey: .text)
            self = .markdownText(text)
        case "codeBlock":
            let language = try container.decodeIfPresent(String.self, forKey: .language)
            let code = try container.decode(String.self, forKey: .code)
            self = .codeBlock(language: language, code: code)
        case "error":
            let title = try container.decodeIfPresent(String.self, forKey: .title)
            let details = try container.decode(String.self, forKey: .details)
            // Backward-compat: pre-Round-2 error messages have no category/suggestion.
            let category = try container.decodeIfPresent(AgentErrorCategory.self, forKey: .category)
            let suggestion = try container.decodeIfPresent(String.self, forKey: .suggestion)
            self = .error(title: title, details: details, category: category, suggestion: suggestion)
        case "mediaArtifact":
            let artifact = try container.decode(MediaArtifact.self, forKey: .artifact)
            self = .mediaArtifact(artifact)
        case "checkpoint":
            let summary = try container.decode(String.self, forKey: .summary)
            self = .checkpoint(summary: summary)
        default:
            // Preserve, never throw: an unknown `type` is almost always a case a newer build added; capture the whole object
            // so re-encoding is faithful.
            let payload = try PreservedJSON(from: decoder)
            self = .unknown(type: type, payload: payload)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .plainText(let text):
            try container.encode("plainText", forKey: .type)
            try container.encode(text, forKey: .text)
        case .markdownText(let text):
            try container.encode("markdownText", forKey: .type)
            try container.encode(text, forKey: .text)
        case .codeBlock(let language, let code):
            try container.encode("codeBlock", forKey: .type)
            try container.encodeIfPresent(language, forKey: .language)
            try container.encode(code, forKey: .code)
        case .error(let title, let details, let category, let suggestion):
            try container.encode("error", forKey: .type)
            try container.encodeIfPresent(title, forKey: .title)
            try container.encode(details, forKey: .details)
            try container.encodeIfPresent(category, forKey: .category)
            try container.encodeIfPresent(suggestion, forKey: .suggestion)
        case .mediaArtifact(let artifact):
            try container.encode("mediaArtifact", forKey: .type)
            try container.encode(artifact, forKey: .artifact)
        case .unknown(_, let payload):
            // Re-emits exactly what was read via a single-value container; the payload is the whole object, including keys
            // without a CodingKey.
            var single = encoder.singleValueContainer()
            try single.encode(payload)
            return

        case .checkpoint(let summary):
            try container.encode("checkpoint", forKey: .type)
            try container.encode(summary, forKey: .summary)
        }
    }

    var textContent: String? {
        switch self {
        case .plainText(let text): return text
        case .markdownText(let text): return text
        case .codeBlock(_, let code): return code
        case .error(let title, let details, _, _): return "\(title ?? "Error"): \(details)"
        case .mediaArtifact: return nil
        case .checkpoint(let summary): return summary
        // nil, not a placeholder string. `textContent` feeds prompts, RAG and exports — emitting
        // synthetic text would put words into the conversation that nobody said.
        case .unknown: return nil
        }
    }

    /// True for content a newer build wrote that this one is preserving verbatim.
    var isUnrecognised: Bool {
        if case .unknown = self { return true }
        return false
    }
}
