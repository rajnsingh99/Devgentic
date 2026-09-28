// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatMessage.swift
//  Devgentic
//
//  Created by Raj Singh on 22/08/25.
//

import Foundation

struct ResponseMessageVariant: Codable, Equatable {

    /// Stable identity for this variant, preserved across a save/load cycle.
    ///
    /// ⚠️ This was `let variantId: UUID = UUID()`, which is a Swift trap: the SYNTHESIZED encoder
    /// EMITS an immutable property that has an initial value, while the synthesized decoder SKIPS it
    /// (it cannot overwrite a `let` that is already initialized — the compiler warns about exactly
    /// this). So the id was written into `agentResponseData` on every flush and thrown away on every
    /// load, regenerating each time. Two consequences, neither obvious:
    ///
    ///   1. The blob's bytes changed on every load→save cycle even when nothing about the response
    ///      had changed.
    ///   2. `variantId` participates in the synthesized `Equatable`, which propagates through
    ///      `AgentResponse ==` → `ChatMessage ==` → `Conversation ==`. A conversation re-fetched
    ///      from the store therefore NEVER compared equal to the identical in-memory one, forcing
    ///      every consumer of those operators to treat an unchanged response as changed.
    ///
    /// Now a `var` with a declaration default plus a tolerant decoder below, so it round-trips.
    var variantId: UUID = UUID()

    var content: MessageContent
    let backendEntityId: UUID?

    /// ⚠️ Explicit, because the tolerant `init(from:)` in the extension below needs to name it.
    /// Declaring `CodingKeys` here is safe — unlike declaring `init`, it does not suppress the
    /// memberwise initializer the call sites use.
    enum CodingKeys: String, CodingKey {
        case variantId, content, backendEntityId
    }
}

extension ResponseMessageVariant {

    /// ⚠️ In an EXTENSION, not the struct body — declaring `init(from:)` inline would suppress the
    /// memberwise init that `beginRegenerationVariant` and `ChatMessage.init` both use.
    ///
    /// Tolerant on `variantId` specifically: every blob written before this fix carries one, but a
    /// blob written before the field existed does not, and a missing id must not fail the whole
    /// variant. Minting one there is correct — it becomes stable from that save onward.
    /// `content` stays required: a variant with no content is corruption, not an old shape.
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

/// Data model for a tool execution event in the agent timeline.
/// Mutable fields (`output`, `isSuccess`, `failureCategory`, `durationMs`, `isExecuting`)
/// are updated when the tool completes — the struct is replaced in-place in the timeline array.
/// `failureCategory` is nil on success; on failure it carries the structured cause so
/// EpisodicHistoryFormatter can build constraints without string-matching the output.
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
    /// For file-writing tools: the target file's content just before the write ("" = the
    /// file didn't exist; nil = not captured). Set on completion from `ToolOutput`; drives
    /// the timeline's "View changes" → Code Viewer diff. Size-capped at capture.
    ///
    /// SESSION-SCOPED: deliberately NOT persisted (see `encode(to:)`). Keeping it would put
    /// up to a megabyte of file content per write into the message's timeline blob —
    /// which is re-encoded whole on every flush and decoded eagerly on every conversation
    /// load. See `Docs/large-tool-payload-storage.md` for the eventual fix.
    var preWriteContent: String? = nil
    /// For EDIT tools (find/replace params, no full content): the file read back after a
    /// successful edit — the post-state the params can't provide. Size-capped at capture.
    /// Session-scoped like `preWriteContent`.
    var postWriteContent: String? = nil

    /// What this call changed on disk — derived from the snapshots ONCE, when the tool
    /// finishes.
    ///
    /// Computed here rather than where it's consumed because the episodic formatter runs on
    /// EVERY request: deriving it there re-ran an O(n²) LCS for every historical write on
    /// every prompt build (a 4000-line diff measured ~6s in test).
    ///
    /// Unlike the snapshots above this IS persisted — it's a bounded summary (4KB cap), and
    /// a resumed conversation that can't say what it changed can't undo it. See
    /// `Docs/codeviewer-rescope-design.md` §12 D1.
    var effect: ActionEffect? = nil
    /// The COMMAND's exit status for shell-family tools, nil for everything else.
    ///
    /// Not a failure signal — the tool ran fine. `grep` exits 1 for "no match" and `diff` for
    /// "files differ", so classifying non-zero as a tool failure would abort a run after three
    /// consecutive searches (`CognitiveCircuitBreaker` aborts at 3 consecutive failures).
    /// It is carried because a verdict cannot be re-derived: re-running `swift build` after an
    /// edit answers a different question than the original run did.
    var exitCode: Int32? = nil

    /// Longest tool output retained in the timeline. Generous by design: it must not bite
    /// normal tool results, only pathological ones (build logs, huge file dumps). Beyond
    /// this the output is truncated with an explicit marker — never silently.
    ///
    /// This value is load-bearing beyond display: `TimelineTurnReconstructor` rebuilds a
    /// resumed run's LLM tool observations from `output`, so the marker is what tells the
    /// model its view of that observation is incomplete.
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

// Backward-compatible Codable: persisted history from prior builds lacks
// `failureCategory`, `durationMs`, `stepId`, `preWriteContent`, and `postWriteContent` —
// decode them as optional and default to nil.
//
// ENCODE is explicit (not synthesized) so the file-snapshot fields can be OMITTED from
// persistence while still decoding cleanly on the way in. Rationale: the snapshots exist
// to power the timeline's "View changes" affordance during the session that produced the
// write, which is when anyone looks. Persisting them put up to 1MB per write into the
// timeline blob — permanently, re-encoded on every flush. Decode still reads them so any
// rows already written by an earlier build keep working.
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
        // preWriteContent / postWriteContent intentionally omitted — session-scoped.
        // `effect` IS encoded: it is the bounded summary derived from them, and it is what
        // lets a resumed run describe (and undo) what it changed.
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

/// How a background task ended, on the wire.
///
/// ⚠️ A FLAT `String` rawValue, deliberately, rather than mirroring
/// `BackgroundProcessRegistry.Status` — which carries `exited(code:)` as an associated value. A
/// nested enum's rawValue changing is one of the documented corruption classes that used to lose a
/// whole run's timeline; the exit code rides alongside in its own field instead.
///
/// `interrupted` exists from day one although nothing sets it yet: quit KILLS every background
/// task, so a persisted `running` is a lie the moment the app restarts and reload has to be able
/// to say so. Adding the case later would be a wire-format change; adding it now is free.
enum BackgroundTaskStatus: String, Codable, Equatable {
    case running
    case exited
    case timedOut
    case stopped
    case interrupted

    var isTerminal: Bool { self != .running }
}

/// A `batch_command(background:)` task, as the timeline sees it.
///
/// ⚠️⚠️ `outputTail` IS BOUNDED AND THAT IS THE POINT. The full log lives in a FILE (`logPath`);
/// this carries only its last few KB. `preWriteContent` / `postWriteContent` on
/// `ToolExecutionData` are excluded from persistence for exactly this reason — *"up to a megabyte
/// of file content per write into the message's timeline blob — which is re-encoded whole on every
/// flush and decoded eagerly on every conversation load"*. A real build log is 375 KB, and a LIVE
/// task would re-encode that blob on every output tick. The UI reads `logPath` directly when it
/// wants the whole thing.
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
    /// The `ResponseMessageVariant.variantId` of the attempt that started this task. A Redo appends
    /// to the SAME timeline, so without this a report from attempt 1 cannot be told from one from
    /// attempt 2 (`TranscriptGrouping` folds the former). Nil on a row written before 2026-09-27 —
    /// read as "current attempt", so nothing old is folded away.
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
    /// A `batch_command(background:)` task, which OUTLIVES the tool call that started it.
    ///
    /// ⚠️ Deliberately NOT a `toolExecution` with `isExecuting: true`. That flag means "the ReAct
    /// loop is blocked here", and every consumer reads it that way — `ActiveStreamManager` finds
    /// the live entry BY it. A background task's tool call has already returned; the task is what
    /// is still running. Overloading the flag would make the loop look stuck on a finished call.
    case backgroundTask(BackgroundTaskData)
    case mediaGeneration(id: UUID, toolName: String, artifact: MediaArtifact?, isComplete: Bool)

    // Capability milestones
    case capabilityMilestone(id: UUID, kind: CapabilityMilestoneKind, detail: String)

    // System-level recoverable warnings (rate limits, memory pressure, parse retries, etc.)
    case warning(id: UUID, category: WarningCategory, text: String)

    /// A Plan & Execute run rendered as one structured card: the step list with live
    /// statuses, each step holding ITS OWN nested timeline (reasoning + tool rows).
    /// Replaces the flat planGenerated/subtaskStarted/subtaskCompleted milestone chips
    /// for chat/code agent runs. Updated in place by `CapabilityCardRouter`.
    case planExecution(PlanRunData)

    /// A Reflexion run rendered as one structured card: attempts with verdicts and the
    /// evaluator's critique, each attempt holding its own nested timeline.
    case reflectionRun(ReflectionRunData)

    /// An event THIS build cannot model, held verbatim so re-encoding preserves it.
    ///
    /// Two things produce one: a case a NEWER build introduced, and a known case whose payload
    /// changed shape (a new required field, a widened type, a new nested enum `rawValue`). Before
    /// this existed, either one threw and the ENTIRE array was lost — one unreadable event deleted
    /// the whole run's timeline.
    ///
    /// ⚠️ `id` is derived from the payload, NOT freshly generated: SwiftUI's `ForEach` keys off it,
    /// so a new UUID per decode would churn the list on every reload.
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

    /// True for an event written by a newer build that this one is preserving verbatim.
    ///
    /// ⚠️ Deliberately NOT folded into `isCapabilityCard`. A card is protected absolutely, so a
    /// timeline made entirely of unknowns would never evict and would breach `maxTimelineEvents`.
    /// This is a THIRD eviction tier instead — see `evictOverflow`.
    var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }

    /// True for the structured capability cards that must survive timeline eviction
    /// (they hold the run's shape; dropping one deletes whole nested sub-timelines).
    var isCapabilityCard: Bool {
        switch self {
        case .planExecution, .reflectionRun: return true
        // A background task's row is the ONLY record of a live process: its id, its log path, and
        // the handle the UI polls. Evicting it while the task runs leaves a process nothing can
        // name. Safe to protect absolutely because there are a handful per conversation, not
        // hundreds — unlike the narrative events this cap exists to bound.
        case .backgroundTask: return true
        default: return false
        }
    }

    /// Depth-first flattening: self plus every event nested inside capability cards
    /// (plan steps, reflection attempts — including a plan card nested in an attempt
    /// when both capabilities are stacked). Consumers that semantically want "every
    /// tool / thought that happened in this run" (episodic memory, native-history
    /// rebuild, resume reconstruction) iterate this instead of the raw array.
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
//
// ⚠️ WHY THIS IS HAND-WRITTEN, AND WHY IT MIRRORS RATHER THAN REPLACES.
//
// The synthesized codec threw on any element it could not model, and because that throw propagates
// out of the ARRAY decode, a single unreadable event destroyed the whole run's timeline. Worse, the
// empty result was then written back over the blob, so the loss became permanent on the next save.
//
// The fix is a catch-all case. But hand-writing `CodingKeys` for all 8 cases — including the `_0`
// key Swift uses for a single UNLABELED associated value — would risk my keys silently diverging
// from the shape ALREADY ON DISK. So instead `KnownTimelineEvent` mirrors the original 8 cases
// exactly and keeps its SYNTHESIZED conformance: the wire format is therefore unchanged by
// construction, not by my care, and the two mapping switches below are exhaustive so the compiler
// catches any case added later.
//
// ⚠️ THE FALLBACK IS TOTAL, not "unrecognised case name only". Measured across 10 corruption
// classes: a total fallback recovers 10/10 with an exact round-trip, while keying on an unknown
// case name alone still loses the ENTIRE array in 4/10 — a new nested enum `rawValue`, a widened
// field type, a malformed UUID, or a new required field all fail INSIDE a case that is perfectly
// recognisable by name.
//
// Because this lives in `TimelineEvent.init(from:)`, it applies at EVERY nesting depth for free —
// including events inside `PlanStepData.events` and `ReflectionAttemptData.events`, where most of a
// real run's events actually live.

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
            // Preserve rather than throw. If even this fails the value is not JSON at all, and the
            // error propagates to the array decode — which `ChatMessageSD.toChatMessage` reports as
            // a total failure and the write-refusal guard then protects.
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

/// Live status of one plan step — the UI vocabulary for `PlanStepData`.
/// (Distinct from `SubTaskStatus`, which belongs to the planner's own model.)
/// ⚠️ Hand-written `RawRepresentable` so an unrecognised status is PRESERVED, not rejected.
/// An unknown value here used to fail `PlanStepData`, which failed `PlanRunData`, which made the
/// WHOLE capability card opaque — taking every nested tool call out of `flattenedTimelineEvents`
/// and disqualifying the run from resuming. Stdlib gives byte-identical Codable and rawValue-based
/// equality, so no call site changes.
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

    /// ⚠️ `.other` is deliberately NOT counted. An unrecognised status might be a new terminal
    /// state or a new in-flight one; counting it as completed would overstate what actually
    /// finished, which is the more misleading of the two errors.
    var completedCount: Int {
        steps.filter { $0.status == .completed || $0.status == .warning }.count
    }

    /// ⚠️ `.other` IS counted as degraded. This build cannot verify the step succeeded, and the
    /// point of the indicator is "do not take this run's output at face value" — which is exactly
    /// the situation. Left to fall through silently, an unreadable status would have rendered as a
    /// clean run.
    var hasDegradedSteps: Bool {
        steps.contains { $0.status == .warning || $0.status == .failed || $0.status.isUnrecognised }
    }
}

// MARK: - Capability Card Data (Reflexion)

/// ⚠️ Hand-written `RawRepresentable` — same reasoning as `PlanStepStatus`: an unknown value made
/// the entire Reflexion card opaque, hiding every nested tool call from resume and episodic memory.
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

/// Describes the type of capability milestone for timeline rendering.
/// ⚠️ Hand-written `RawRepresentable` so an unrecognised milestone is PRESERVED, not rejected.
/// This one degrades gracefully: the row renders `detail` (a plain String), so an unknown kind
/// still shows a fully readable chip — only the icon and tint are generic.
///
/// Worth hardening despite that, because the stream vocabulary is already richer than this enum
/// (`ActiveStreamManager` folds `.planApproved`/`.requestPlanReview` onto `.planGenerated`), so a
/// faithful new case here is a near-term likelihood rather than a hypothetical.
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

/// Lifecycle / persistence state of a message. For agent messages this distinguishes a
/// fully-finished run from one that was still `.streaming` or `.parkedHITL` (awaiting the
/// user) when the row was last written. After an unexpected restart, a persisted non-`.final`
/// state is the durable "this run was interrupted" marker — and `.parkedHITL` additionally
/// carries the operationID needed to later resume it (G1 Piece 2). Defaults to `.final` so
/// every legacy row and user message reads as completre.
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

    /// The parked HITL operationID, if any — the message↔HITL join key used to resume.
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
    
    /// The distributed trace ID for the request that produced this message.
    /// Set when agent execution begins; used to retrieve trace data for the Report UI.
    var traceID: String?

    /// The profile type that generated this message (bot, agent, workflow, imageGen).
    /// Tagged at creation time by ActiveStreamManager — eliminates runtime profile store lookups.
    var profileType: ProfileType?

    /// Where this message originated from (local Mac UI, Telegram, Discord, Orb, QuickAccess,
    /// a scheduled task, a finished background task).
    ///
    /// ⚠️ DURABLE AS OF 2026-09-23 — `messageSourceRaw` on `ChatMessageSD`, restored by
    /// `toChatMessage()`. This comment previously said the opposite ("TRANSIENT — no column …
    /// do not add a claim here that survives a relaunch") and that was correct for what the
    /// field was then: nothing but log interpolation read it, so persisting it would have been
    /// storage nobody spent. The column was added deliberately when the UI began to branch on
    /// it — an unprompted `.backgroundTask` report renders differently from a typed reply, and a
    /// difference that evaporates on relaunch is worse than no difference at all, because the
    /// same message changes appearance depending on when you look at it.
    ///
    /// ⚠️ Rows written before the column decode as `.localUI`, which is the pre-existing
    /// behaviour and the only honest answer — those rows never recorded a source.
    ///
    /// ⚠️ It is NOT the same question as `sender`. `sender` is who spoke; a woken report is
    /// genuinely `.agent`, written by the agent from the conversation's own profile. This says
    /// what CAUSED the turn, which is why the two must not be collapsed — see `SenderRole`.
    ///
    /// Readers: two log interpolations in `ActiveStreamManager` (`[HISTORY]`, `[STREAM_START]`),
    /// `OrbAmbientRunWatcher` (whether to announce a finished run), and — since the column —
    /// `AgentMessageActionsView` and the timeline divider.
    var messageSource: MessageSource = .localUI

    /// Machine-authored scaffolding: a turn nobody typed, written so the exchange PAIRS.
    ///
    /// ⚠️⚠️ THIS EXISTS BECAUSE AN UNPAIRED ASSISTANT MESSAGE IS SILENTLY DISCARDED. Both
    /// `NativeHistoryConverter.buildPairs` and `EpisodicHistoryFormatter.pairTurns` walk the
    /// history as `user → agent` couples, binding `pendingUser` on a user row and consuming it
    /// on the next agent row. An agent row with no user row in front of it fails the
    /// `let userTurn = pendingUser` binding and is dropped — no warning, no log.
    ///
    /// A woken background-task report was exactly that shape: `BackgroundTaskWakeCoordinator`
    /// built a user message and handed it to `startMessageStream` WITHOUT persisting it, so the
    /// store held `user, agent, agent(orphan), user…` and every report the agent delivered was
    /// gone from its own history by the next turn. The agent told the user a build had finished
    /// and then had no record of having said so.
    ///
    /// The stub closes that. It is deliberately SHORT — unlike the wake prompt it replaces, it
    /// is carried in the prompt on every subsequent turn, so the ~1KB of raw task output the
    /// wake sends this turn (via `promptOverride`) must not be what persists. What persists is
    /// the stub plus the model's report; the report IS the compression.
    ///
    /// ⚠️ NOT a hidden row. It renders as a centered system divider — see
    /// `BackgroundTaskDividerView`. A store that holds a message the screen denies is a
    /// divergence nobody can reason about later; the divider is the honest form of the same
    /// information, and it carries the authoritative status (id, exit code) read from the
    /// snapshot rather than from the model's prose, which a small local model can get wrong.
    var isSyntheticPrompt: Bool = false
    
    var content: MessageContent
    var agentResponse: AgentResponse?
    var isStreaming: Bool = false

    /// Terminal outcome of the agent run that produced this message. `nil` while streaming
    /// or for legacy rows that predate this field. Set by `ActiveStreamManager` when it
    /// receives an `.executionFinished` stream event. Drives the "response may be incomplete"
    /// indicator in the bubble so users can distinguish a proper answer from a best-effort
    /// synthesis produced after circuit-breaker abort / iteration exhaustion / cancellation.
    var terminalOutcome: ExecutionOutcome? = nil

    /// Optional human-readable reason accompanying `terminalOutcome`. Same nil semantics.
    var terminalReason: String? = nil

    // MARK: - Lifecycle / Run Identity (G1 Piece 1 — in-flight persistence)
    /// `.streaming` while a run is in flight, `.parkedHITL(operationID:)` while it awaits the
    /// user, `.final` once finished. Persisted (split into `lifecycleStateRaw` + `parkedOperationID`
    /// columns) so an interrupted run is distinguishable from a finished one after restart and the
    /// parked operationID survives. Defaults to `.final`.
    var lifecycleState: MessageLifecycleState = .final

    /// The provider/model/dialect that actually produced this message, captured immutably at run
    /// start. `apiProvider`/`modelDialect` are the resume-safety guard (detect a model switch
    /// between park and resume); all three give the UI an honest "which model ran" label even after
    /// the originating profile is later edited. Nil for legacy rows / user messages.
    var apiProvider: String? = nil
    var modelName: String? = nil
    var modelDialect: String? = nil

    // MARK: - Glass Box UI State (Gemini-Style)
    // These properties store the intermediate reasoning and tool outputs.
    // These properties derive chronological reasoning steps and tool outputs from timelineEvents.
    /// Unified thought stream used by the compact `ThinkingDynamicIsland`. Includes
    /// both `.thought` (system narration / extended thinking) and `.reasoning` (model
    /// monologue) so the expanded island shows the full cognitive trail regardless
    /// of source. Analytics and scratchpad paths can still distinguish the two by
    /// reading `timelineEvents` directly.
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

    /// The timeline with capability-card sub-timelines flattened in (depth-first, cards
    /// included as markers). Plan & Execute / Reflexion runs nest their per-step and
    /// per-attempt events inside `.planExecution` / `.reflectionRun` — consumers that
    /// want "everything that happened" (episodic memory, native-history rebuild, resume
    /// reconstruction, tool scans) iterate this instead of `timelineEvents`.
    var flattenedTimelineEvents: [TimelineEvent] {
        timelineEvents.flatMap(\.flattenedIncludingNested)
    }

    /// The most recent COMPLETED image artifact anywhere in the timeline (including
    /// nested capability-card sub-timelines). An image generation surfaces its result
    /// ONLY as a `.mediaGeneration` event — nothing sets it as message content — so
    /// without promoting it the bubble falls through to the "stopped" placeholder and
    /// the image is invisible. `resolveFinalizedContent` uses this at finalize.
    var lastCompletedImageArtifact: MediaArtifact? {
        for event in flattenedTimelineEvents.reversed() {
            if case .mediaGeneration(_, _, let artifact?, let isComplete) = event,
               isComplete, artifact.kind == .image {
                return artifact
            }
        }
        return nil
    }

    /// Resolves the content a finalized (non-throwing) run should display. Prefers the
    /// streamed text; failing that, a produced image artifact (image generations stream
    /// no text, so without this they fell through to the placeholder and the image never
    /// rendered — audit gap #2); failing that, a "stopped" placeholder so an empty run
    /// doesn't masquerade as a clean completion. Pure + static for testability — the
    /// finalize path (ActiveStreamManager) and `GeneratedImageRenderGapTests` share it.
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

    /// Synthetic placeholder written when a run ends with no content (cancelled or
    /// empty). Deliberately unlocalized — persisted, and other layers classify by it.
    static let stoppedRunPlaceholder = "*Operation was stopped before a response could be generated.*"

    /// Legacy variant emitted by the pre-refactor executor; persisted rows still carry it.
    static let legacyStoppedRunPlaceholder = "*Operation stopped by user.*"

    /// True when `text` IS a synthetic stopped-run placeholder (exact match after
    /// trimming — a message that merely QUOTES the phrase inside real prose is real
    /// content and must not be treated as synthetic). Used by the RAG gate so
    /// placeholders stop polluting conversation memory (observed on-device
    /// 2026-07-19: a cancelled run's placeholder was embedded and stored).
    static func isSyntheticPlaceholder(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == stoppedRunPlaceholder || trimmed == legacyStoppedRunPlaceholder
    }

    /// Merges an incoming streamed text chunk into the current content. Returns the
    /// new content plus (optionally) a timeline event the caller must append, or
    /// `nil` when the chunk can't merge and content should stay untouched (e.g.
    /// `.mediaArtifact` — the parked media+text decision). Pure + static for
    /// testability, same pattern as `resolveFinalizedContent`; the streaming path
    /// (`ActiveStreamManager.updateMessageContent`) and `StreamedChunkMergeTests`
    /// share it.
    /// What the bubble shows while a `.draftText` preview is live: the pre-draft content with the
    /// draft after it, by the same rule a streamed chunk follows — except that a pre-draft `.error`
    /// card is shown as the draft alone and is NOT demoted (the draft may be withdrawn; the real
    /// `.content` does the demotion when it arrives).
    static func draftDisplayContent(baseline: MessageContent, draft: String) -> MessageContent {
        resolveStreamedChunkMerge(current: baseline, chunk: draft)?.content ?? .markdownText(draft)
    }

    static func resolveStreamedChunkMerge(current: MessageContent, chunk: String) -> (content: MessageContent, demotedError: TimelineEvent?)? {
        if case .error(let title, let details, _, let suggestion) = current {
            // [ASM-1] A mid-run `.error` replaced content with the structured card,
            // but the producer survived it and streamed prose afterwards (a workflow
            // where one node fails and a terminal node succeeds; a planning run
            // where a subtask fails and the loop continues). Appending onto the
            // card's textContent laundered the failure into the answer's opening
            // words — "Execution Failed: Connection refusedHere is the summary…" —
            // destroying the category icon + suggestion, and that merged string is
            // what got persisted and RAG-indexed. Start the answer fresh and demote
            // the error to a timeline warning so the failure stays discoverable.
            // ("Error" fallback matches `textContent`'s — deliberately unlocalized,
            // the string persists and feeds RAG.)
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

    /// [ASM-2] Content for a run that ended in a THROW after possibly streaming prose.
    /// The old chokepoint replaced everything the user watched stream with the error
    /// card — bubble, persistence, and the RAG index all lost the partial answer. When
    /// real prose exists it stays as content and the error demotes to a timeline
    /// warning; the failure remains loud via the `.failed` chip + the retry affordance.
    /// A streamed error card is NOT prose (its `textContent` is the error string), and
    /// media has no text to keep — both fall back to card-replaces, today's behavior.
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

    /// [ASM-4] Terminal outcome for a run whose producer never emitted
    /// `.executionFinished`. The old fallback keyed only on "did a throw reach
    /// finalize" — a producer that yielded a structured `.error` event and then ended
    /// cleanly was stamped `.completed`: a green chip and a `completed` trace status
    /// sitting on top of an error card.
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

    /// [P0 crash fix 2026-07-19] Prepares this message for a regeneration attempt in
    /// ONE write access: appends the fresh variant, selects it, bumps the attempt
    /// count, flips `isStreaming`. Returns `false` (no mutation) at the attempt cap
    /// or when the message has no response to regenerate.
    ///
    /// The coordinator previously did this inline as three optional-chained writes,
    /// one of which READ `agentResponse` on the RHS while the LHS held the `modify`
    /// access — under `@Observable` that is a FATAL Swift exclusivity trap
    /// ("Simultaneous accesses…"), reproduced on-device from the Retry button.
    /// Same crash class the test suite documented earlier: capture a value copy,
    /// mutate it, write back once.
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

    /// [TL-1] Closes tool rows still marked executing at end-of-run — a cancel or failure
    /// mid-tool used to leave the row's spinner running forever, and it PERSISTED that way.
    ///
    /// Walks NESTED card rows too. The earlier version iterated only `timelineEvents` and
    /// documented nested rows as "closed separately by
    /// `CapabilityCardRouter.handleExecutionFinished`" — that was not true: the router closes
    /// step and attempt STATUSES and never touches a nested `ToolExecutionData.isExecuting`.
    /// With Plan & Execute or Reflexion on (most agent runs) tool rows live nested rather than
    /// top-level, so the common case was the uncovered one: a stop mid-tool closed nothing,
    /// logged nothing, and persisted a row that renders an animating spinner forever, with no
    /// output, no failure badge and no way to expand it (`isDisclosable` requires
    /// `!isExecuting`). `sanitizeCapabilityCardsForResume` does reach nested rows but runs only
    /// on the resume path, and REMOVES them rather than closing them.
    ///
    /// Returns how many were closed so the caller can log the repair.
    @discardableResult
    func closeDanglingToolRows(outcome: ExecutionOutcome?) -> Int {
        DanglingToolRowCloser.close(&timelineEvents, outcome: outcome)
    }

    /// `closeDanglingToolRows`, returning the rows it settled so the caller can react to WHICH
    /// tools were abandoned. Used by [CF-9] to post the `AgentLiveWriteEvent.completed` that a
    /// cancelled or thrown run never emits, which is what left a live Code Viewer tab stuck
    /// showing "Agent is writing this file" for the rest of the session.
    @discardableResult
    func closeDanglingToolRowsReporting(outcome: ExecutionOutcome?) -> [DanglingToolRowCloser.ClosedRow] {
        DanglingToolRowCloser.closeReporting(&timelineEvents, outcome: outcome)
    }

    /// [G1 resume] Prepares persisted capability cards for a resumed run: drops dangling
    /// (still-executing / output-less) tool rows inside nested step/attempt timelines and
    /// closes any card the interruption left unfinished — the resumed continuation streams
    /// NEW top-level events, never back into the old card, so an open card would spin forever.
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

    /// Chronological timeline of agent reasoning steps, tool executions, and capability milestones.
    /// Ordering is guaranteed by @MainActor serialization in ActiveStreamManager's event loop.
    /// SwiftUI ForEach preserves insertion order via unique UUID identities.
    /// Capped at `maxTimelineEvents` to prevent unbounded memory growth in long-running agents.
    static let maxTimelineEvents = 500

    var timelineEvents: [TimelineEvent] = [] {
        didSet { timelineRevision &+= 1 }
    }

    /// True when this message was loaded from a store whose `timelineEventsData` could not be
    /// decoded, so `timelineEvents` is EMPTY BY FAILURE rather than because the run had no events.
    ///
    /// ⚠️ This flag is the only thing standing between a read failure and permanent data loss.
    /// Both persistence writers null the blob whenever the in-memory timeline is empty
    /// (`ChatMessageSD.from` and `ChatPersistenceStore.addMessages`), so without it the sequence is:
    /// load an undecodable blob → `timelineEvents == []` → the next flush writes nil → the original
    /// bytes are gone. The `timelineRevision` skip-cache is NOT a safety net: the revision is seeded
    /// randomly per instance, so a freshly-loaded message always looks changed and the very first
    /// flush takes the write branch.
    ///
    /// ⚠️ It lives on the VALUE object, not as a `@Transient` on `ChatMessageSD`, because the
    /// decode happens on one fetched instance while the write happens after a SEPARATE fetch — a
    /// model-side flag would silently reset to false in between and the destructive write would
    /// proceed. This value flows to both writers by construction.
    ///
    /// Deliberately excluded from `CodingKeys` and from `==`: it describes THIS LOAD, not the
    /// message, and two messages differing only by a failed read are the same message.
    @ObservationIgnored var timelineDecodeFailed: Bool = false

    /// The placeholder issued when `contentData` could not be decoded at all, or nil if it decoded.
    ///
    /// ⚠️ `contentData` IS the conversation, so this is the most consequential of the write guards.
    /// A genuinely corrupt blob yields a "Decode Error" card, and BOTH writers used to re-encode
    /// that card straight over the original bytes — so a message that might have been recoverable
    /// by a later build became permanently a Decode Error card instead.
    ///
    /// Stores the placeholder rather than a bare Bool so the setter can tell an opportunistic save
    /// (handing the same card back) from a deliberate replacement, matching the `BackendProfile`
    /// rule. Load-scoped, like `timelineDecodeFailed`, and excluded from `CodingKeys` and `==`.
    ///
    /// Note this is for CORRUPT bytes only. Readable JSON of an unknown shape now decodes to
    /// `MessageContent.unknown` and needs no guard — it is preserved by the codec itself.
    @ObservationIgnored var undecodableContentPlaceholder: MessageContent?

    /// Set when `agentResponseData` could not be decoded on this load.
    ///
    /// ⚠️ The third column of this kind, and the one that was missed. `contentData` and
    /// `timelineEventsData` both got a write refusal; `agentResponseData` did not, even though its
    /// decode-failure path sets `agentResponse = nil` — and nil is exactly what the writers persist.
    /// So a response blob this build cannot read (variants written by a newer build, or genuine
    /// corruption) was turned into NULL the first time the message was re-persisted, which happens
    /// on any resume or in-flight flush of the enclosing conversation.
    ///
    /// Load-scoped and on the VALUE object for the same reason as `timelineDecodeFailed`, and
    /// likewise excluded from `CodingKeys` and `==`.
    @ObservationIgnored var agentResponseDecodeFailed: Bool = false

    /// Whether it is safe to persist `content` over the stored blob.
    ///
    /// False only in the exact case that loses data: the decode failed AND the caller is handing
    /// back the very placeholder we issued. Anything else — a live agent writing real content, a
    /// deliberate replacement — writes normally, so a message never becomes permanently stuck.
    var canPersistContent: Bool {
        guard let placeholder = undecodableContentPlaceholder else { return true }
        return (currentAgentContent ?? content) != placeholder
    }

    /// Whether it is safe to persist `agentResponse` over the stored blob.
    ///
    /// Same shape as the timeline rule, and deliberately NOT the profile rule: false only when the
    /// decode failed AND nothing has replaced it, so the caller is handing back the nil we produced.
    /// A regeneration that appends a real variant onto a failed load still writes — the record stays
    /// repairable rather than frozen.
    var canPersistAgentResponse: Bool {
        !(agentResponseDecodeFailed && agentResponse == nil)
    }

    /// Whether it is safe to persist `timelineEvents` over the stored blob.
    ///
    /// False only in the exact case that loses data: the decode failed AND nothing has been appended
    /// since, so the caller is handing back the empty placeholder. A live run that appended new
    /// events onto a failed load IS written — matching the profile rule that a different value is a
    /// deliberate edit, so the record stays repairable.
    ///
    /// ⚠️ Never gate on `timelineEvents.isEmpty` alone: every user message and every bot message
    /// legitimately has an empty timeline and must still be able to clear its blob.
    var canPersistTimeline: Bool {
        !(timelineDecodeFailed && timelineEvents.isEmpty)
    }

    /// True when the timeline is not a faithful record of what the run actually did.
    ///
    /// ⚠️ Disqualifying for RESUME, which is a different bar from disqualifying for display. An
    /// `.unknown` renders as a visible placeholder — fine for a human reading the history — but it
    /// is invisible to `TimelineTurnReconstructor`, so a completed tool call hiding inside one makes
    /// the model believe that tool never ran. An unrecognised CAPABILITY CARD is worse still: its
    /// entire nested sub-timeline disappears from `flattenedTimelineEvents`.
    var timelineIsDegraded: Bool {
        timelineDecodeFailed || flattenedTimelineEvents.contains(where: \.isUnknown)
    }

    /// [P4/TL-4] Change marker for `timelineEvents`, bumped by `didSet` so EVERY
    /// mutation path counts — append, eviction, in-place card updates, subscript
    /// writes, decode-time assignment. Consumers: the persistence flush skips
    /// re-encoding an unchanged timeline (up to 500 events, every ~2s during a
    /// stream), and `AgentTimelineView`'s Equatable skips regrouping on unrelated
    /// body passes. Seeded randomly per instance so two instances of the SAME
    /// persisted message (reload, regenerate) can never alias revisions in the
    /// store's skip cache — an aliased skip would silently drop timeline writes.
    @ObservationIgnored private(set) var timelineRevision: UInt64 = .random(in: UInt64.min ... UInt64.max)

    /// Appends a timeline event, evicting the oldest non-tool events if the cap is exceeded.
    /// Tool execution events are preserved to maintain output correctness; narrative events
    /// (thoughts and reasoning) are trimmed first as they're least valuable historically.
    func appendTimelineEvent(_ event: TimelineEvent) {
        timelineEvents.append(event)
        Self.evictOverflow(&timelineEvents, context: "top-level")
    }

    /// [TL-2/P3] The single eviction rule for ANY timeline container — the message's
    /// top-level array AND the nested per-step / per-attempt arrays inside capability
    /// cards (which used to bypass the cap entirely, so a runaway capability run grew
    /// its card without bound in memory, persistence, and render). Oldest narrative
    /// (.thought/.reasoning) goes first; then the oldest non-card event; a capability
    /// card is never evicted — it holds whole nested sub-timelines (a plan card sits
    /// near the start of every planned run, so plain removeFirst() would delete the
    /// run's shape).
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
            // ⚠️ THIRD TIER, and deliberately last. An `.unknown` is neither narrative nor a
            // recognisable card, so under the old two-tier rule it was the FIRST non-narrative
            // victim — meaning a capability card written by a newer build would be preferentially
            // deleted, which is the exact opposite of the card-protection rule's intent.
            //
            // It is not folded into `isCapabilityCard` either: a card is protected absolutely, so a
            // timeline made entirely of unknowns would never evict at all and would breach the cap.
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

    // [mm-11] `tokenCountEstimate` and `estimateCodeBlockCharCount` were DELETED here on
    // 2026-09-12. They had ZERO production readers under a doc comment claiming they existed
    // "for UI display and cost estimation" — and the app estimates tokens in six independent
    // inline `count / 4` sites instead, so this was redundant rather than reserved. It carried
    // sixteen dedicated test methods across three classes, all of which went with it: tests for
    // unreachable code cost maintenance and buy nothing.
    //
    // ⚠️ One fact is worth keeping out of it, because it is about the RENDERED form and not about
    // the estimator: `.error` content ships as `"\(title ?? "Error"): \(details)"` — so anything
    // measuring or matching an error message must account for the `": "` separator AND the
    // "Error" default title, not just sum the raw fields. That was the one case where the deleted
    // estimator and the shipped text had disagreed.
    //
    // ⚠️ It also had a latent bug never worth fixing: an UNTERMINATED ``` fence left `inBlock`
    // true at EOF and its characters uncounted, so a streaming message undercounted. If a token
    // estimator is ever wanted here, close that case in the same change.

    // MARK: - Performance Caching
    @ObservationIgnored var cachedMarkdownBlocks: [ContentBlock]? = nil

    /// The exact text `cachedMarkdownBlocks` was parsed from — the cache's KEY.
    ///
    /// ⚠️ Without this the cache was keyed on nothing: `getOrCreateMarkdownBlocks(from:)`
    /// returned whatever it held whenever it was non-nil, ignoring its own `text` argument, so
    /// correctness depended entirely on every writer of the displayed text ALSO calling
    /// `invalidateMarkdownCache()`. The response-variant picker
    /// (`ChatBubbleView`, `selectedVariantIndex`) did not — and since `displayedContent`
    /// resolves through `variants[selectedVariantIndex]`, switching versions re-rendered the
    /// PREVIOUS variant's prose under an animation that made the switch look successful.
    /// Keying on the text makes a stale render unrepresentable rather than a thing every new
    /// call site has to remember.
    @ObservationIgnored private var cachedMarkdownSource: String? = nil

    /// Test seam: the text `cachedMarkdownBlocks` was parsed from. Not read by app code — the
    /// cache's correctness is precisely "the blocks match this key", and a test that cannot see
    /// the key can only observe positional block ids, which are identical across a re-parse.
    var cachedMarkdownSourceForTesting: String? { cachedMarkdownSource }

    /// Incremental parser used ONLY while this message is streaming — settled
    /// regions parse once, and each flush re-parses just the trailing block
    /// instead of the whole accumulated text (the old full-reparse-per-flush was
    /// O(n²) over a response, on the main thread). Dropped on the first
    /// non-streaming access, which also forces one authoritative full re-parse
    /// so the final rendering is exactly what `parseMarkdown` produces.
    /// Transient — never persisted.
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

    /// The content actually on screen for this message.
    ///
    /// `ChatBubbleView.contentToDisplay` and the search path's content selection were the same
    /// expression written twice; search and render must never disagree about WHICH text a
    /// message shows, or a regenerated response is searched in one variant and highlighted in
    /// another. Note user messages use `content` directly, which this matches.
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
    
    /// Parsed blocks for `text`, memoised per message.
    ///
    /// ⚠️ The cache HIT requires `cachedMarkdownSource == text`, not merely a non-nil cache.
    /// See `cachedMarkdownSource` for what returning a differently-sourced cache did. The
    /// external `invalidateMarkdownCache()` calls remain correct and are still what forces the
    /// per-flush re-parse during streaming; the key is a backstop for every writer that does
    /// not call it — the variant picker being the one that did not.
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

        // First non-streaming access after a stream: drop the incremental state and
        // invalidate so the full parse below becomes the authoritative final result
        // (heals any mid-stream boundary cosmetics — see StreamingMarkdownParser).
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

    /// Returns parsed ContentBlocks for the RAG indexing pipeline.
    ///
    /// ⚠️ PURE — it must not touch `cachedMarkdownBlocks`/`cachedMarkdownSource`/
    /// `streamingMarkdownParser`. Its only caller is `RAGIndexingService.indexSingleMessage`,
    /// which both call sites launch DETACHED (`ActiveStreamManager`, `ChatPersistenceStore`)
    /// against the very `ChatMessage` instance the view model holds. `ChatMessage` is
    /// `@unchecked Sendable` and not `@MainActor`, and those fields are plain stored
    /// properties, so routing this through `getOrCreateMarkdownBlocks` put an unsynchronised
    /// background WRITER on a slot the main actor writes from the render path, the per-chunk
    /// invalidate and `trimMarkdownCachesOutsideWindow`. Two unordered reference writes to one
    /// `[ContentBlock]?` is an ARC double-release, and the indexer's 500 ms delay also let it
    /// populate the cache from `content` — which during a regeneration still holds the PREVIOUS
    /// variant — so a retry could render the old answer for a frame.
    ///
    /// `parseMarkdown` is a free function and writes no cache on any `ChatMessage`; this is the
    /// same choice `ChatPersistenceStore.fetchSearchDocuments` and `ChatSearchDecomposition`
    /// already make, and for the same reason. Do not "optimise" this back onto the cache.
    func getBlocksForIndexing() -> [ContentBlock] {
        switch content {
        case .plainText(let text), .markdownText(let text):
            return parseMarkdown(text)
        case .codeBlock(let language, let code):
            return [ContentBlock(id: "block-0", type: .code(language: language ?? "text", content: code, fileName: nil))]
        case .error, .mediaArtifact:
            return []
        case .unknown:
            // Not indexed for RAG. Indexing an opaque payload would put JSON scaffolding into the
            // retrieval corpus and surface it as if it were something the user wrote.
            return []
        case .checkpoint(let summary):
            return parseMarkdown(summary)
        }
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

    /// Current schema version. Increment when adding/removing persisted fields.
    /// - v1: Legacy format with separate `thoughts`/`artifacts` arrays + `agentState` encoded
    /// - v2: Unified `timelineEvents`, removed `thoughts`/`artifacts`/`agentState` from encoding
    // v3: `TimelineEvent.reasoning` case added alongside `.thought` to split the
    // LLM's visible monologue from system narration. v2 data decodes unchanged
    // because Swift's automatic Codable-for-enums handles new cases additively;
    // bumping the version is hygiene for future migration decisions.
    // v4: `TimelineEvent.planExecution` / `.reflectionRun` capability cards added
    // (nested per-step / per-attempt sub-timelines). Additive — v3 data decodes
    // unchanged; legacy planning/reflection runs keep their flat milestone chips.
    //
    // ⚠️ [P5] SCOPE: this version tags the FULL-OBJECT JSON envelope only — which no
    // production code path round-trips (repo-verified 2026-07-19; tests are the sole
    // consumer). The SwiftData store persists PER-FIELD blobs (contentData,
    // timelineEventsData, …) that carry NO version tag, so bumping this constant does
    // NOT protect on-disk data. Migrations for persisted data belong at the
    // ChatMessageSD layer (like the legacy `.image` decode shim in MessageContent).
    // The v1 thoughts/artifacts migration that used to live here was deleted for the
    // same reason: no durable v1 envelope exists anywhere for it to migrate.
    private static let currentSchemaVersion = 4

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

    /// Content THIS build cannot model, held verbatim so re-encoding preserves it.
    ///
    /// ⚠️ This is the highest-stakes catch-all in the app: `contentData` IS the conversation. The
    /// decoder previously ended in `default: throw … "Invalid MessageContent type"`, so a single
    /// case added by a newer build turned the message into a "Decode Error" card — which both
    /// writers then re-encoded over the original bytes. The message text was gone, permanently,
    /// from one enum case.
    ///
    /// Distinct from the Decode Error card, which remains the presentation for genuinely corrupt
    /// bytes. This case means "readable JSON, unknown shape" and is fully recoverable.
    case unknown(type: String, payload: PreservedJSON)

    enum CodingKeys: String, CodingKey {
        case type, text, language, code, title, details, imageUrl, imageAlt, imageData, artifact, summary
        case category, suggestion   // structured error enrichment (Round 2 Phase 4)
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
        case "image":
            // Legacy shim (2026-07-17): `.image` was removed as a case — MediaArtifact is
            // the single image representation, so ONE renderer serves everything. Messages
            // persisted under the old shape convert here and re-encode as artifacts on the
            // next save; this branch is decode-only and never written back.
            let urlString = try container.decodeIfPresent(String.self, forKey: .imageUrl)
            let alt = try container.decodeIfPresent(String.self, forKey: .imageAlt)
            let imageData = try container.decodeIfPresent(Data.self, forKey: .imageData)
            if let imageData {
                self = .mediaArtifact(MediaArtifact(
                    kind: .image,
                    reference: .ephemeralData(imageData),
                    // The legacy case never stored a mime type; sniff the bytes.
                    mimeType: "image/\(ImageExport.fileExtension(for: imageData))",
                    label: alt
                ))
            } else if let url = urlString.flatMap({ URL(string: $0) }) {
                // URL-only legacy images rendered "Image Not Available" anyway (remote
                // references are never auto-fetched); the artifact error card says so too,
                // just through the live renderer.
                self = .mediaArtifact(MediaArtifact(
                    kind: .image, reference: .remoteURL(url),
                    mimeType: "image/png", label: alt
                ))
            } else {
                self = .plainText("[Image unavailable\(alt.map { ": \($0)" } ?? "")]")
            }
        case "mediaArtifact":
            let artifact = try container.decode(MediaArtifact.self, forKey: .artifact)
            self = .mediaArtifact(artifact)
        case "checkpoint":
            let summary = try container.decode(String.self, forKey: .summary)
            self = .checkpoint(summary: summary)
        default:
            // ⚠️ PRESERVE, never throw. A `type` this build does not know is overwhelmingly a case
            // a NEWER build added — not corruption. Throwing here turned the whole message into a
            // Decode Error card that the next save wrote over the original bytes, so one new enum
            // case permanently destroyed the message text. Capture the WHOLE object (not just the
            // known keys) so re-encoding is faithful.
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
            // Re-emit exactly what was read. Uses a single-value container rather than the keyed
            // one above because the payload IS the whole object, including keys this build has no
            // CodingKey for — encoding it key-by-key would silently drop them.
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
