//
//  ChatMessage.swift
//  Devgentic
//
//  Created by Raj Singh on 22/08/25.
//

import Foundation

enum GenerationType: String, Codable, CaseIterable, Identifiable {
    case text
    case imageData
    case videoData
    
    var id: String { self.rawValue }
}

struct ResponseMessageVariant: Codable, Equatable {
    let variantId: UUID = UUID()
    var content: MessageContent
    let backendEntityId: UUID?
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
}

// Backward-compatible Codable: persisted history from prior builds lacks
// `failureCategory`, `durationMs`, and `stepId` — decode them as optional and default to nil.
extension ToolExecutionData: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, params, output, isSuccess, failureCategory, durationMs, isExecuting, stepId
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
        isExecuting = try c.decode(Bool.self, forKey: .isExecuting)
        stepId = try c.decodeIfPresent(Int.self, forKey: .stepId)
    }
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

    var id: UUID {
        switch self {
        case .thought(let id, _): return id
        case .reasoning(let id, _): return id
        case .toolExecution(let data): return data.id
        case .mediaGeneration(let id, _, _, _): return id
        case .capabilityMilestone(let id, _, _): return id
        case .warning(let id, _, _): return id
        case .planExecution(let data): return data.id
        case .reflectionRun(let data): return data.id
        }
    }

    /// True for the structured capability cards that must survive timeline eviction
    /// (they hold the run's shape; dropping one deletes whole nested sub-timelines).
    var isCapabilityCard: Bool {
        switch self {
        case .planExecution, .reflectionRun: return true
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

// MARK: - Capability Card Data (Plan & Execute)

/// Live status of one plan step — the UI vocabulary for `PlanStepData`.
/// (Distinct from `SubTaskStatus`, which belongs to the planner's own model.)
enum PlanStepStatus: String, Codable, Equatable, Sendable {
    case pending, running, completed
    /// Ended early but usable (inner run finished `.completedWithWarnings`, e.g. circuit-breaker abort).
    case warning
    case failed
    case cancelled
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

    var completedCount: Int {
        steps.filter { $0.status == .completed || $0.status == .warning }.count
    }
    var hasDegradedSteps: Bool {
        steps.contains { $0.status == .warning || $0.status == .failed }
    }
}

// MARK: - Capability Card Data (Reflexion)

enum ReflectionAttemptStatus: String, Codable, Equatable, Sendable {
    case running
    case evaluating
    case rejected     // evaluator said RETRY — critique carries why
    case accepted     // evaluator said PASS
    /// Ran to completion without an evaluator verdict (the final trial is never evaluated).
    case completed
    case failed
    case cancelled
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
enum CapabilityMilestoneKind: String, Codable, Equatable, Sendable {
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
        }
    }

    /// Accent color category for visual distinction.
    var colorCategory: MilestoneColor {
        switch self {
        case .planGenerated, .planReviewRequested, .subtaskStarted, .subtaskCompleted: return .planning
        case .reflectionTrialStarted, .reflectionEvaluating, .reflectionRetrying, .reflectionAccepted: return .reflection
        case .delegationStarted, .delegationCompleted: return .delegation
        case .compactionStarted, .compactionCompleted: return .compaction
        }
    }

    enum MilestoneColor: String, Codable, Sendable {
        case planning    // blue tint
        case reflection  // purple tint
        case delegation  // green tint
        case compaction  // orange tint
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

    /// Where this message originated from (local Mac UI, Telegram, Discord, etc.).
    /// Transient — not persisted to CoreData. Used by RemoteMirrorService to decide
    /// whether to mirror stream events to a remote transport.
    var messageSource: MessageSource = .localUI
    
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
        return .markdownText("*Operation was stopped before a response could be generated.*")
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

    var timelineEvents: [TimelineEvent] = []

    /// Appends a timeline event, evicting the oldest non-tool events if the cap is exceeded.
    /// Tool execution events are preserved to maintain output correctness; narrative events
    /// (thoughts and reasoning) are trimmed first as they're least valuable historically.
    func appendTimelineEvent(_ event: TimelineEvent) {
        timelineEvents.append(event)
        if timelineEvents.count > Self.maxTimelineEvents {
            // Evict oldest narrative event (.thought or .reasoning) first to stay under budget.
            if let firstNarrativeIndex = timelineEvents.firstIndex(where: {
                switch $0 {
                case .thought, .reasoning: return true
                default: return false
                }
            }) {
                timelineEvents.remove(at: firstNarrativeIndex)
            } else if let firstEvictableIndex = timelineEvents.firstIndex(where: { !$0.isCapabilityCard }) {
                // All narrative gone — drop the oldest tool/milestone, but never a capability
                // card: it holds whole nested sub-timelines (a plan card sits near the start
                // of every planned run, so plain removeFirst() would delete the run's shape).
                timelineEvents.remove(at: firstEvictableIndex)
            }
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

    /// Estimated token count for the message content.
    /// Avoids expensive tokenizer calls for UI display and cost estimation.
    ///
    /// Heuristics by content type:
    /// - Prose / markdown: ~4 characters per token (standard BPE for English)
    /// - Code: ~3 characters per token (shorter identifiers, more symbols)
    /// - Mixed (markdown with code blocks): weighted blend
    var tokenCountEstimate: Int {
        switch content {
        case .codeBlock(_, let code):
            // Pure code: ~3 chars per token (operators, braces, short identifiers)
            return max(1, code.count / 3)
        case .markdownText(let text):
            // If >30% of content is inside ``` blocks, use code ratio for that portion
            let codeCharCount = Self.estimateCodeBlockCharCount(in: text)
            let proseCharCount = max(0, text.count - codeCharCount)
            let codeTokens = codeCharCount / 3
            let proseTokens = proseCharCount / 4
            return max(1, codeTokens + proseTokens)
        case .plainText(let text):
            return max(1, text.count / 4)
        case .error(let title, let details, _, _):
            return max(1, ((title?.count ?? 0) + details.count) / 4)
        case .mediaArtifact:
            return 0
        case .checkpoint(let summary):
            return max(1, summary.count / 4)
        }
    }

    /// Fast estimate of how many characters live inside ``` code fences.
    private static func estimateCodeBlockCharCount(in text: String) -> Int {
        var count = 0
        var inBlock = false
        var blockStart = text.startIndex
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") {
                if inBlock {
                    count += text.distance(from: blockStart, to: line.endIndex)
                    inBlock = false
                } else {
                    blockStart = line.startIndex
                    inBlock = true
                }
            }
        }
        return count
    }

    // MARK: - Performance Caching
    @ObservationIgnored var cachedMarkdownBlocks: [ContentBlock]? = nil

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
    
    func getOrCreateMarkdownBlocks(from text: String) -> [ContentBlock] {
        if isStreaming {
            if let cached = cachedMarkdownBlocks { return cached }
            let parser = streamingMarkdownParser ?? StreamingMarkdownParser()
            streamingMarkdownParser = parser
            let blocks = parser.parse(text)
            self.cachedMarkdownBlocks = blocks
            return blocks
        }

        // First non-streaming access after a stream: drop the incremental state and
        // invalidate so the full parse below becomes the authoritative final result
        // (heals any mid-stream boundary cosmetics — see StreamingMarkdownParser).
        if streamingMarkdownParser != nil {
            streamingMarkdownParser = nil
            cachedMarkdownBlocks = nil
        }

        if let cached = cachedMarkdownBlocks { return cached }
        let blocks = parseMarkdown(text)
        self.cachedMarkdownBlocks = blocks
        return blocks
    }
    
    func invalidateMarkdownCache() {
        self.cachedMarkdownBlocks = nil
    }

    /// Returns parsed ContentBlocks for the RAG indexing pipeline.
    func getBlocksForIndexing() -> [ContentBlock] {
        switch content {
        case .plainText(let text), .markdownText(let text):
            return getOrCreateMarkdownBlocks(from: text)
        case .codeBlock(let language, let code):
            return [ContentBlock(id: "block-0", type: .code(language: language ?? "text", content: code, fileName: nil))]
        case .error, .mediaArtifact:
            return []
        case .checkpoint(let summary):
            return getOrCreateMarkdownBlocks(from: summary)
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
    private static let currentSchemaVersion = 4

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id, conversationId, timestamp, sender, content
        case agentResponse, isStreaming, attachedTextFiles, attachedImageFiles
        case timelineEvents, traceID, profileType, tokenUsage
        case terminalOutcome, terminalReason
        case lifecycleState, apiProvider, modelName, modelDialect
    }

    /// Legacy keys only used for v1 migration — never encoded.
    private enum LegacyCodingKeys: String, CodingKey {
        case thoughts, artifacts, agentState
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1

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

        if version == 1 {
            self.timelineEvents = try Self.migrateV1Timeline(from: decoder)
        } else {
            self.timelineEvents = try container.decodeIfPresent([TimelineEvent].self, forKey: .timelineEvents) ?? []
        }

        // Transient properties always initialize to defaults
        self.agentState = .idle
        self.cachedMarkdownBlocks = nil
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

    // MARK: - V1 Migration

    /// Reconstructs `timelineEvents` from legacy v1 format that stored separate
    /// `thoughts` and `artifacts` arrays alongside `timelineEvents`.
    /// Only invoked when `schemaVersion` is absent or 1.
    private static func migrateV1Timeline(from decoder: Decoder) throws -> [TimelineEvent] {
        // Try the modern key first — v1 data may already have timelineEvents
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let existing = try container.decodeIfPresent([TimelineEvent].self, forKey: .timelineEvents) ?? []
        guard existing.isEmpty else { return existing }

        // Fall back to legacy keys
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        let legacyThoughts = try legacyContainer.decodeIfPresent([AgentThought].self, forKey: .thoughts) ?? []
        let legacyArtifacts = try legacyContainer.decodeIfPresent([ToolOutput].self, forKey: .artifacts) ?? []

        var events: [TimelineEvent] = legacyThoughts.map { .thought(id: $0.id, text: $0.text) }
        events.append(contentsOf: legacyArtifacts.map {
            .toolExecution(ToolExecutionData(id: UUID(), name: $0.toolName, params: "", output: $0.output, isSuccess: $0.isSuccess, isExecuting: false))
        })
        return events
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
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Invalid MessageContent type: \(type)")
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
        }
    }
}
