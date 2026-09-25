// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AgentModel.swift
//  Devgentic5
//
//  Created by Raj Singh on 02/02/26.
//

import Foundation


/// Lightweight result container for parallel tool execution within a single ReAct iteration.
/// Replaces the now-removed CognitiveObservation, which was coupled to ObservationMemoryStore.
 struct ToolObservation: Sendable {
    let stepId: Int
    let toolCallId: String  // The unique ID assigned by the provider API (e.g., Claude's tool_use id, OpenAI's call id)
    let toolName: String
    let result: String      // Full content fed to memoryStrategy.recordObservation
    let summary: String     // Brief description used for logging overview
    let isSuccess: Bool
    let params: String      // Serialised arguments — passed to ExecutionSummary
    let output: String      // LLM-facing output — passed to ExecutionSummary
    let artifacts: [MediaArtifact]  // Media artifacts produced by this tool execution

    // Signal tools (final_answer, ask_user) short-circuit the cognitive loop.
    // When true, the executor breaks the loop and routes `output` per `terminalKind`.
    let isTerminalSignal: Bool
    let terminalKind: TerminalKind?

    /// Structured failure cause (nil on success). Carries `ToolExecutionResult`'s
    /// classification across the loop→executor seam so consumers branch on category
    /// instead of `isSuccess` + string-prefix matching — without it, the executor
    /// couldn't tell a hallucinated name from an ordinary failure and prompt-banned
    /// every failed tool (audit gap #2).
    let failureCategory: ToolFailureCategory?

    init(
        stepId: Int,
        toolCallId: String,
        toolName: String,
        result: String,
        summary: String,
        isSuccess: Bool,
        params: String,
        output: String,
        artifacts: [MediaArtifact],
        isTerminalSignal: Bool = false,
        terminalKind: TerminalKind? = nil,
        failureCategory: ToolFailureCategory? = nil
    ) {
        self.stepId = stepId
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.result = result
        self.summary = summary
        self.isSuccess = isSuccess
        self.params = params
        self.output = output
        self.artifacts = artifacts
        self.isTerminalSignal = isTerminalSignal
        self.terminalKind = terminalKind
        self.failureCategory = failureCategory
    }
}

/// Marker for signal tools that short-circuit the ReAct loop.
/// - `finalAnswer`: model has composed its complete response — exit with success.
/// - `askUser`: model needs clarification — loop is suspended (existing HITL path).
enum TerminalKind: Sendable, Codable, Equatable {
    case finalAnswer
    case askUser
}

/// Mutable parent-span carrier for `APISpyModel`'s per-call telemetry.
///
/// The spy is constructed ONCE per run (before the ReAct loop), but each LLM call must
/// parent under the CURRENT iteration/subtask span — so the executor updates this box as
/// it opens each step span, and the spy reads it at call time. Access is sequential in
/// practice (one cognitive loop, one call at a time); the lock makes the handoff safe
/// anyway so a future concurrent caller degrades to a stale parent, never a torn read.
final class LLMSpanScope: @unchecked Sendable {
    private let lock = NSLock()
    private var _context: TraceContext?

    init(_ context: TraceContext? = nil) { self._context = context }

    func set(_ context: TraceContext?) {
        lock.lock(); _context = context; lock.unlock()
    }

    var context: TraceContext? {
        lock.lock(); defer { lock.unlock() }
        return _context
    }
}

/// Pass-through `LLMProvider` decorator sitting in front of every model on the ReAct,
/// Planning and Reflexion paths. With a `spanScope`, each BLOCKING model call becomes a
/// real `.llmCall` span (child of whatever the executor last put in the scope) carrying
/// per-call duration and token counts in `spans.metadataJSON`, plus the
/// llmRequest/llmResponse event pair — before this, the agent path had ZERO llmCall
/// spans and every run's "Calls" count read 0. Streaming methods stay uninstrumented
/// (the bot path's `chat_call` span covers its one stream); a nil scope is a strict
/// pass-through, so headless/test constructions record nothing new by accident.
struct APISpyModel: LLMProvider {
    let inner: any LLMProvider
    var spanScope: LLMSpanScope? = nil

    var modelName: String { inner.modelName }

    /// Wraps one blocking call in an llmCall span. `messageCount` feeds the request
    /// event; `usage` (extracted from the result AFTER the call) and the measured
    /// duration land in the span's metadata at end.
    private func traced<T>(
        messageCount: Int,
        preview: @escaping (T) -> String,
        usage: @escaping (T) -> TokenUsage?,
        _ body: () async throws -> T
    ) async rethrows -> T {
        guard let parent = spanScope?.context else { return try await body() }

        let callSpan = parent.newSpan()
        let started = Date()
        await TraceRecorder.shared.beginSpan(context: callSpan, name: "llm:\(inner.modelName)", kind: .llmCall, at: started)
        await TraceRecorder.shared.emitLLMRequest(span: callSpan, model: inner.modelName, messageCount: messageCount, at: started)

        do {
            let result = try await body()
            let ended = Date()
            let durationMs = Int(ended.timeIntervalSince(started) * 1000)
            var meta: [String: String] = ["model": inner.modelName, "duration_ms": "\(durationMs)"]
            if let u = usage(result) {
                meta["input_tokens"] = "\(u.inputTokens)"
                meta["output_tokens"] = "\(u.outputTokens)"
                meta["tokens_estimated"] = "\(u.isEstimated)"
            }
            await TraceRecorder.shared.emitLLMResponse(span: callSpan, durationMs: durationMs, preview: preview(result), at: ended)
            await TraceRecorder.shared.endSpan(spanID: callSpan.spanID, status: .completed, at: ended, metadata: meta)
            return result
        } catch {
            let ended = Date()
            let durationMs = Int(ended.timeIntervalSince(started) * 1000)
            await TraceRecorder.shared.endSpan(
                spanID: callSpan.spanID, status: .error, at: ended,
                metadata: ["model": inner.modelName, "duration_ms": "\(durationMs)"]
            )
            throw error
        }
    }

    func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String {
        try await traced(messageCount: messages.count, preview: { String($0.prefix(300)) }, usage: { _ in nil }) {
            try await inner.generate(messages: messages, tools: tools, responseSchema: responseSchema)
        }
    }

    func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error> {
        return inner.stream(messages: messages, tools: tools)
    }

    func generateCognitiveStep(messages: [[String: String]], tools: [[String: Any]]?) async throws -> ModernCognitiveStep {
        try await traced(messageCount: messages.count, preview: Self.stepPreview, usage: { $0.tokenUsage }) {
            try await inner.generateCognitiveStep(messages: messages, tools: tools)
        }
    }

    /// G12: forward the native-turn overload to the inner provider. Without this
    /// explicit forward, the protocol's default fallback runs — which coerces
    /// `tool_calls` arrays into Swift description strings via `"\(value)"` and
    /// breaks the native-turn request shape before it ever reaches the real provider.
    func generateCognitiveStep(nativeMessages: [[String: Any]], tools: [[String: Any]]?) async throws -> ModernCognitiveStep {
        try await traced(messageCount: nativeMessages.count, preview: Self.stepPreview, usage: { $0.tokenUsage }) {
            try await inner.generateCognitiveStep(nativeMessages: nativeMessages, tools: tools)
        }
    }

    func generateWithUsage(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> (text: String, usage: TokenUsage?) {
        try await traced(messageCount: messages.count, preview: { String($0.text.prefix(300)) }, usage: { $0.usage }) {
            try await inner.generateWithUsage(messages: messages, tools: tools, responseSchema: responseSchema)
        }
    }

    func generateWithUsage(payload: [ProviderMessage], tools: [[String: Any]]?, responseSchema: Any?) async throws -> (text: String, usage: TokenUsage?) {
        try await traced(messageCount: payload.count, preview: { String($0.text.prefix(300)) }, usage: { $0.usage }) {
            try await inner.generateWithUsage(payload: payload, tools: tools, responseSchema: responseSchema)
        }
    }

    func streamWithUsage(messages: [[String: String]], tools: [[String: Any]]?, onUsage: (@Sendable (TokenUsage) -> Void)?) -> AsyncThrowingStream<String, Error> {
        return inner.streamWithUsage(messages: messages, tools: tools, onUsage: onUsage)
    }

    /// A cognitive step's most informative one-liner: the thought when present,
    /// else the tool call names, else the reasoning prefix.
    private static func stepPreview(_ step: ModernCognitiveStep) -> String {
        if let thought = step.thought, !thought.isEmpty { return String(thought.prefix(300)) }
        if !step.toolCalls.isEmpty { return "tools: " + step.toolCalls.map(\.name).joined(separator: ", ") }
        return String(step.reasoning.prefix(300))
    }
}

// MARK: - Cognitive Definitions (Native Tool Calling Parity)

/// Represents a single tool execution request from the LLM.
struct PendingToolCall: Sendable, Codable, Equatable, Identifiable {
    let id: String // Usually provided by the native API (e.g., Claude's tool_use id)
    let name: String
    let arguments: [String: JSONValue]
}

/// The modern schema for ReAct loops, supporting parallel tool execution natively.
struct ModernCognitiveStep: Sendable {
    /// The agent's reasoning, internal monologue, or conversational text that is NOT the raw thought trace.
    let reasoning: String

    /// Optional: The internal reasoning trace (Thinking) from the provider.
    /// This is separate from the 'reasoning' block which is intended for conversational text.
    let thought: String?

    /// An array of tools to execute. If empty, the loop terminates.
    let toolCalls: [PendingToolCall]

    /// Token usage for this cognitive step, extracted from the provider's API response.
    /// `nil` when the provider doesn't report usage (e.g. mid-stream) or parsing failed.
    let tokenUsage: TokenUsage?

    /// The verdict rendered by the parser/validator about this response.
    /// Drives the terminator's completion vs. retry decision and, on failure,
    /// carries the typed reason used to build a targeted corrective alert.
    ///
    /// Invariants:
    ///   - `.success`            ⇒ `toolCalls` is non-empty
    ///   - `.genuineCompletion`  ⇒ `toolCalls` is empty, no parse error
    ///   - `.failed(reason)`     ⇒ `toolCalls` is empty, retry with reason-specific alert
    let parseOutcome: ParseOutcome

    init(reasoning: String, thought: String? = nil, toolCalls: [PendingToolCall] = [], tokenUsage: TokenUsage? = nil, parseOutcome: ParseOutcome? = nil) {
        self.reasoning = reasoning
        self.thought = thought
        self.toolCalls = toolCalls
        self.tokenUsage = tokenUsage
        // Default derivation: non-empty tool calls ⇒ success; empty ⇒ genuineCompletion.
        // Callers that detected a parse failure must pass `.failed(reason)` explicitly.
        self.parseOutcome = parseOutcome ?? (toolCalls.isEmpty ? .genuineCompletion : .success)
    }
}

// MARK: - Agent State Definitions

enum AgentStateCategory: String, Codable, Sendable {
    case idle, thinking, acting, interaction, completed, error
}

enum AgentState: Codable, Equatable, Sendable {
    case idle
    case thinking(ThinkingDetail)
    case acting(ActingDetail)
    case interaction(InteractionDetail)
    case completed
    case error(String)

    enum ThinkingDetail: String, Codable, Equatable, Sendable {
        case reasoning = "Reasoning"      // ReAct: Internal monologue
        case planning = "Planning"       // Plan & Execute: Constructing sub-tasks
        case reflecting = "Reflecting"    // Reflexion: Self-critique
        case finalizing = "Finalizing"    // Finishing response
        case errorRecovery = "Recovering" // Self-correction
        case preparing = "Preparing"      // RAG: Context retrieval and rewriting
        /// Admitted nowhere yet — another run holds this conversation.
        ///
        /// ⚠️ Without this a queued run is indistinguishable from a slow one: the indicator says
        /// "Reasoning" while nothing is reasoning, and a message sent from ChatOps while the user
        /// is typing locally looks like the app has stalled. The label is what turns "it's broken"
        /// into "it's second in line".
        ///
        /// A `ThinkingDetail` rather than a new `AgentState` case: the label is `detail.rawValue`,
        /// so this renders everywhere without touching a switch, and `EvaluationLogger` counts
        /// iterations by comparing specific cases — so waiting correctly does not count as one.
        case queued = "Waiting its turn"
    }

    enum ActingDetail: Codable, Equatable, Sendable {
        case tool(name: String)
        case subtask(current: Int, total: Int)
    }

    enum InteractionDetail: Codable, Equatable, Sendable {
        case permission(toolName: String)
        case clarification
        case planReview
        case gate
    }
    
    var category: AgentStateCategory {
        switch self {
        case .idle: return .idle
        case .thinking: return .thinking
        case .acting: return .acting
        case .interaction: return .interaction
        case .completed: return .completed
        case .error: return .error
        }
    }
    
    var headline: String {
        switch self {
        case .idle: return "Idle"
        case .thinking(let detail): return detail.rawValue
        case .acting(.tool(let name)): return "Using tool: \(name)"
        case .acting(.subtask(let c, let t)): return "Step \(c) of \(t)"
        case .interaction(.permission(let tool)): return "Awaiting Permission: \(tool)"
        case .interaction(.clarification): return "Awaiting Clarification"
        case .interaction(.planReview): return "Awaiting Plan Approval"
        case .interaction(.gate): return "Awaiting Decision"
        case .completed: return "Completed"
        case .error(let msg): return "Error: \(msg)"
        }
    }
}


// MARK: - Tool Schemas & Protocols (Migrated)

// NOTE: ToolParameterProperty and ToolParameters are defined in ToolModel.swift
// to act as a single source of truth across the app.

/// Helper utility to concisely construct JSON schemas for tool definitions.
enum SchemaBuilder {
    
    /// Builds a standard object schema from a list of properties.
    /// - Parameters:
    ///   - properties: An array of tuples containing (Key, Type, Description).
    ///   - required: An array of keys that are mandatory.
    static func object(properties: [(String, String, String)], required: [String]) -> ToolParameters {
        var propsDict: [String: ToolParameterProperty] = [:]
        for (key, type, desc) in properties {
            let items = (type == "array") ? ["type": "string"] : nil
            propsDict[key] = ToolParameterProperty(type: type, description: desc, items: items)
        }
        return ToolParameters(type: "object", properties: propsDict, required: required)
    }
    
    /// Returns an empty schema for tools that take no arguments.
    static func empty() -> ToolParameters {
        return ToolParameters(type: "object", properties: [:], required: [])
    }
}

/// The native protocol all locally executed tools must conform to.
protocol AgentToolProtocol: Sendable {
    /// The strictly typed arguments structure the tool expects.
    associatedtype Arguments: Decodable & Sendable
    
    /// The exact string name the LLM must output to invoke this tool.
    var name: String { get }
    
    /// The instruction block injected into the LLM's system prompt explaining how and when to use this tool.
    var description: String { get }
    
    /// The JSON schema describing the `Arguments` structure to the LLM.
    var parameterSchema: ToolParameters { get }

    /// The logical group this tool belongs to, used to organise the Tool Library.
    ///
    /// Declared on the protocol as of 2026-07-31, completing a migration that had been left at
    /// "Step 3": `NativeToolWrapper` was reading this by `Mirror` REFLECTION, because the
    /// protocol did not require it. Reflection meant a tool that simply omitted the property
    /// silently landed in a default bucket, and the compiler could not say so.
    ///
    /// Deliberately required rather than defaulted. A default is what made the omission
    /// invisible in the first place, and every tool has a group it belongs in — including the
    /// internal ones, which use `"Internal"` and are never surfaced in the Library at all.
    var category: String { get }

    /// True when this tool's SUCCESSFUL output may legitimately begin with or contain
    /// "error"-shaped text — e.g. a shell tool surfacing stderr, or a build-error reader
    /// whose whole purpose is to return compiler errors. Such tools opt out of
    /// `ToolExecutionMediator`'s content-sniffing semantic-failure check: a non-throwing
    /// return is treated as success (#19). Default: false.
    var outputMayContainErrorText: Bool { get }

    /// True when this tool's ARGUMENT is executed as code — a shell command, or an AppleScript
    /// body. Such a tool cannot be bounded by validating its arguments, because the argument IS
    /// a program; the only real control is whether the profile grants it at all.
    ///
    /// Derived from `ToolCapability.arbitraryCodeExecution` by default, so the answer is the
    /// same one every other part of the app gets and there is nothing to keep in sync. Default:
    /// false, for the ~40 tools that do a bounded, named thing.
    var executesArbitraryCode: Bool { get }

    /// The execution block.
    func call(arguments: Arguments) async throws -> String

    /// Multimodal execution: returns text output + optional media artifacts.
    /// Default implementation wraps `call()` for backward compatibility.
    func execute(arguments: Arguments) async throws -> (output: String, artifacts: [MediaArtifact])
}

extension AgentToolProtocol {
    /// Default: tools do NOT surface error-shaped text on success (so the semantic-failure
    /// heuristic applies). Error-surfacing tools (shell, build diagnostics) override to true.
    var outputMayContainErrorText: Bool { false }

    /// Answered from the one shared set rather than per-tool, so a tool and the permission
    /// banner can never disagree about what the tool is. A tool may still override, but the
    /// set is what `ToolCapabilityTests` checks against the actual source.
    var executesArbitraryCode: Bool { ToolCapability.executesArbitraryCode(name) }

    func execute(arguments: Arguments) async throws -> (output: String, artifacts: [MediaArtifact]) {
        let text = try await call(arguments: arguments)
        return (text, [])
    }
}

/// Typealias for backwards compatibility. This prevents existing files from breaking
/// because they declare compliance to `DevgenticTool`.
typealias DevgenticTool = AgentToolProtocol


// MARK: - Tool Abstraction

/// A type-erased wrapper for tools to decouple the executor from specific library generics.
/// This allows the executor to run any tool given a JSON string or Data.
struct AgentTool: Sendable {
    let name: String
    let description: String
    let parameters: ToolParameters

    // [HITL] Phase 1: Sensitivity Flag
    /// If true, the Executor will pause and ask the user before running this tool.
    let requiresConfirmation: Bool

    // Per-tool execution limits
    /// Optional per-tool timeout in seconds. Nil means no per-tool limit.
    let timeout: TimeInterval?
    /// Custom message sent to the LLM when this tool times out. Nil uses the default timeout message.
    let timeoutMessage: String?

    /// When true, the executor skips content-sniffing semantic-failure detection for this
    /// tool — a non-throwing return is success even if the output looks like an error. Set
    /// for tools whose legitimate output surfaces error text (shell, build diagnostics). (#19)
    let contentMayLookLikeError: Bool

    /// The closure to execute the tool.
    /// Takes JSON Data (arguments) and returns text output + optional media artifacts.
    let run: @Sendable (Data) async throws -> (output: String, artifacts: [MediaArtifact])

    // [HITL] Updated Init with default for backward compatibility
    init(
        name: String,
        description: String,
        parameters: ToolParameters,
        requiresConfirmation: Bool = false,
        timeout: TimeInterval? = nil,
        timeoutMessage: String? = nil,
        contentMayLookLikeError: Bool = false,
        run: @escaping @Sendable (Data) async throws -> (output: String, artifacts: [MediaArtifact])
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.requiresConfirmation = requiresConfirmation
        self.timeout = timeout
        self.timeoutMessage = timeoutMessage
        self.contentMayLookLikeError = contentMayLookLikeError
        self.run = run
    }

    /// Convenience init for text-only tools (backward compatibility).
    init(
        name: String,
        description: String,
        parameters: ToolParameters,
        requiresConfirmation: Bool = false,
        timeout: TimeInterval? = nil,
        timeoutMessage: String? = nil,
        contentMayLookLikeError: Bool = false,
        textOnlyRun: @escaping @Sendable (Data) async throws -> String
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.requiresConfirmation = requiresConfirmation
        self.timeout = timeout
        self.timeoutMessage = timeoutMessage
        self.contentMayLookLikeError = contentMayLookLikeError
        self.run = { data in
            let text = try await textOnlyRun(data)
            return (text, [])
        }
    }
}

// MARK: - Tool UI & Prompt Extensions

extension AgentTool {
    /// Flattens the tool schema into a concise Markdown definition for smaller models.
    func toMarkdownDefinition() -> String {
        Self.markdownDefinition(name: name, description: description, parameters: parameters)
    }

    /// The same rendering for any (name, description, parameters) triple.
    ///
    /// Extracted so the fit gauges can SIZE a tool payload straight from the registry without
    /// constructing executable tools — measuring the real serializer rather than approximating
    /// it, the same discipline the history and episodic terms use.
    static func markdownDefinition(name: String, description: String, parameters: ToolParameters) -> String {
        var def = "### \(name)\n"
        def += "- Description: \(description)\n"

        if !parameters.properties.isEmpty {
            def += "- Arguments:\n"
            for (key, param) in parameters.properties {
                let req = parameters.required.contains(key) ? "required" : "optional"
                def += "  - `\(key)` (\(param.type), \(req)): \(param.description)\n"
            }
        }
        return def
    }
}

// MARK: - Tool Execution Results

/// Represents the definitive outcome of a tool execution attempt.
enum ToolExecutionResult: Sendable, Equatable {
    case success(output: String, artifacts: [MediaArtifact] = [])
    case hallucinated(toolName: String, availableTools: [String])
    case userDenied(toolName: String)
    case timedOut(toolName: String, duration: TimeInterval, message: String? = nil)
    case semanticFailure(toolName: String, output: String) // E.g., null, empty, or explicit CLI errors
    case systemError(reason: String)

    /// Media artifacts (empty for non-success cases).
    var artifacts: [MediaArtifact] {
        if case .success(_, let a) = self { return a }
        return []
    }

    /// The string representation that should be fed back to the LLM as an Observation.
    var llmObservation: String {
        switch self {
        case .success(let output, _):
            return output
        case .hallucinated(let toolName, let available):
            return "System Error: Tool not found. '\(toolName)' does not exist. Available tools: \(available.joined(separator: ", ")). Use ONLY these tools or provide a `finalAnswer`."
        case .userDenied(let toolName):
            return "System Security: User explicitly denied permission to execute tool '\(toolName)'. Do not retry this exact action."
        case .timedOut(let toolName, let duration, let message):
            // A custom timeoutMessage (when set) is surfaced to the LLM; the result still
            // classifies as a timeout failure (see `isSuccess` / `failureCategory`).
            if let message, !message.isEmpty { return message }
            return "System Error: Tool '\(toolName)' timed out after \(Int(duration)) seconds. The operation took too long."
        case .semanticFailure(_, let output):
            return output.isEmpty ? "System Error: Empty tool response." : output
        case .systemError(let reason):
            return "System Error: Failed to execute tool: \(reason)"
        }
    }
    
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    /// Maps the result to a structured `ToolFailureCategory` for `.toolFailed` events,
    /// `EpisodicHistoryFormatter` constraint policy, and episodic-memory retrieval weights.
    /// Returns `nil` for `.success` — callers should emit `.toolSucceeded` in that case.
    ///
    /// `.semanticFailure` is ambiguous at the call site (it covers both preflight argument
    /// validation errors and tool-side semantic failures like empty output); we distinguish
    /// via the error string prefix produced by `ToolExecutionMediator.validateRequiredArguments`.
    /// `.systemError` is similarly split between permission-preflight failures and generic throws.
    var failureCategory: ToolFailureCategory? {
        switch self {
        case .success:
            return nil
        case .userDenied:
            return .userDenied
        case .hallucinated:
            return .notFound
        case .timedOut:
            return .timeout
        case .semanticFailure(_, let output):
            let validationMarkers = [
                "is required but was not provided",
                "cannot be empty",
                "cannot be null",
                "cannot be an empty array",
                "cannot be an empty object"
            ]
            return validationMarkers.contains(where: { output.contains($0) }) ? .invalidArgs : .executionThrew
        case .systemError(let reason):
            return reason.contains("Missing required macOS permissions") ? .permissionRejected : .executionThrew
        }
    }
}

// MARK: - Tool Argument Error (Phase 10)

/// A descriptive error thrown when tool argument decoding fails.
/// Replaces the cryptic Foundation `DecodingError` with an actionable message
/// that includes the tool name, required parameters, and the raw JSON received.
struct ToolArgumentError: Error, LocalizedError {
    let toolName: String
    let detail: String
    var errorDescription: String? { detail }
}

// MARK: - Execution Input

/// The standard payload required to initialize any Agent Executor.
///
/// Derivation contract: code that builds a sub-run input from an existing one
/// (capability wrappers — Planning subtasks, Reflexion trials) MUST copy-and-
/// mutate (`var derived = input; derived.field = …`) instead of calling the
/// initializer with hand-forwarded fields. The init's defaulted parameters mean
/// the compiler can't flag a forgotten forward, so re-initializing silently
/// drops every field added after the call site was written (this is how
/// `userPayload`/`modelTier`/`workflowContext` got lost — audit gap #7).
/// Properties are `var` solely to enable this; value semantics keep each
/// executor's copy isolated.
struct AgentInput: Sendable {
    var userInput: String

    /// Multimodal user input (images, audio, etc.). Nil for text-only messages.
    var userPayload: Payload?

    /// Current-turn attachment payload destined for the USER message: extracted file
    /// text (directInjection) or a read_file path note (stateless). Kept separate from
    /// `userInput` so the system `<task>` block carries only the typed query.
    var attachmentContext: String? = nil

    /// Static profile knowledge-source payload for the system `<knowledge_base>` layer:
    /// budgeted content (directInjection) or a path manifest (stateless).
    var knowledgeBaseContext: String? = nil

    /// MCP server-authored guidance on how to drive THIS run's tools, rendered as `<tool_guidance>`.
    ///
    /// ⚠️ Separate from `knowledgeBaseContext` on purpose (owner decision 2026-08-20). It used to
    /// ride the knowledge layer, which conflated two things: knowledge is the USER's reference
    /// material, this is operating instructions for TOOLS. It also cannot live in
    /// `<available_tools>` — that section renders only for LEGACY (non-native) flows and holds
    /// schemas rather than prose.
    ///
    /// ⚠️ GATED PER SERVER by the caller: only servers with at least one tool in this run's
    /// resolved set contribute. Before that gate every connected server's instructions shipped in
    /// every request — an agent with 3 built-in tools and ZERO MCP tools still received ~2,000
    /// chars explaining how to drive 41 tools it did not have, and on the workflow path that text
    /// became its `<task>`.
    var toolGuidanceContext: String? = nil

    // NOTE: Used ONLY by ChatExecutor (Bots). ReActAgentExecutor completely ignores this
    // to enforce the "Zero-History Context" architecture.
    var chatHistory: [ChatMessage]

    /// BOT path only: whether prior-turn images in `chatHistory` should be re-attached
    /// to the request (vision-capable bots). Set by AgentConnect as
    /// `isBotFlow && profile.supportsVisionInput`. Agents ignore this — they carry
    /// history images via `nativeHistoryTurns`/the native splice. False for non-vision
    /// bots (images omitted), which is why switching to a non-vision model is safe.
    var botHistoryImagesEnabled: Bool = false

    var conversationID: UUID
    var tools: [AgentTool]
    var longTermMemory: any LongTermMemoryStrategy

    /// The project folder a Code session is confined to. Nil for every other profile type, which
    /// is what leaves chat/agent/workflow runs unconfined — they have no user-chosen root.
    ///
    /// ⚠️ Until this existed, `projectPath` reached exactly ONE tool
    /// (`UpdateProjectContextTool`); every filesystem tool was root-blind, so the folder the user
    /// picked described the session without constraining it. `WorkspaceBoundary` turns it into a
    /// boundary the tool loop actually applies.
    var workspaceRoot: String? = nil

    // Architecture: Split-State (Active State + History)
    var activeState: SessionGraph?
    var recentHistory: String?

    // [Step 3 Architecture Update]
    var generatorStrategy: any CognitiveGenerator
    var workingMemory: any WorkingMemoryStrategy

    // [Phase 2 Rate Limiting — profile-scoped]
    // Bucket key derived from (provider + apiKey/baseURL) for profile-scoped rate limiting.
    var rateLimitKey: String
    var rateLimitCategory: RateLimitCategory

    var instructions: String?

    // Skills — on-demand discovery layer
    var skillManifests: [SkillManifest]?

    // Resilience configuration from AgentConfig
    var retryPolicy: RetryPolicy
    var errorRecovery: ErrorRecovery

    /// Resolved three-tier resilience policy (transport/cognitive/loop). Resolved
    /// ONCE at the AgentConnect seam from provider class + the legacy RetryPolicy;
    /// minimal constructors (tests, call_agent) get cloud-class defaults derived
    /// from their `retryPolicy` so the legacy maxRetries linkage is preserved.
    var resiliencePolicy: ResolvedResiliencePolicy

    /// Whether IC-powered response synthesis is enabled for this run.
    var responseSynthesisEnabled: Bool

    /// Pre-built native history turns for providers that support turn-by-turn conversation.
    /// Nil when using XML episodic memory (non-native providers).
    ///
    /// ⚠️ MUST stay OPTIONAL. `ChatExecutor` derives `isNativeFlow` from
    /// `nativeHistoryTurns != nil`, and an empty-but-non-nil value is reachable
    /// (a history of user-only rows yields zero pairs). Letting Swift's natural
    /// non-optional `[HistoryTurn]` shape win here would silently flip the flag
    /// for every non-native run.
    var nativeHistoryTurns: [HistoryTurn]?

    /// [G3/G5] When true, the inner executor skips episode append/close because
    /// the wrapping capability (Planning or Reflexion) owns the episode lifecycle.
    var suppressEpisodeManagement: Bool

    /// When true, the inner executor never pays for LLM (IC) response synthesis.
    /// Wrapper-run loops (Planning subtasks, Reflexion trials) produce INTERMEDIATE
    /// output that the wrapper consumes and re-synthesizes, so a per-run IC
    /// load/generate/unload cycle is pure cost (observed: 6 IC loads in one
    /// 5-subtask MLX run). The synthesizer's free paths (native fast-path,
    /// deterministic single-tool formatting) still apply — only the IC call
    /// degrades to the deterministic builder.
    var suppressLLMSynthesis: Bool

    /// Workflow execution context — non-nil when this agent is running as a node
    /// within a workflow DAG. Signals downstream components (generators, executors)
    /// to use the workflow-specific prompt pipeline: no RAG, no history, clean task+input.
    var workflowContext: WorkflowExecutionContext?

    /// [G1 Piece 2] Non-nil ONLY when resuming a parked-HITL run after restart. Carries the
    /// reconstructed in-flight state (completed tool exchanges + the parked tool + loop bookkeeping)
    /// rebuilt from the persisted message timeline. ReActAgentExecutor reads this to run the resume
    /// preamble (seed prefix → replay completed exchanges → re-run the parked tool → continue at N+1);
    /// every other executor ignores it. Set only for plain-ReAct native runs (the resume trigger
    /// enforces scope). NOTE per the derivation contract above: capability sub-runs copy-and-mutate
    /// `input`, so a wrapper would inherit this — out of scope today (resume excludes capabilities),
    /// but a future capability-aware resume must null it on derived sub-inputs.
    var resumeState: TimelineReconstruction?

    // The Trace Context for distributed observability
    var traceContext: TraceContext

    /// Model tier derived from `LLMProviderConfig.modelMetadata?.tier`. Executors
    /// use this to tune iteration gates / thresholds for weaker models. Nil when
    /// the upstream config couldn't classify the model (cloud models without
    /// metadata default to medium behaviour at the call site).
    var modelTier: ModelTier?

    /// Char budget for the native turn-by-turn conversation payload
    /// (`liveConversationTurns`). Derived from the model context window at the
    /// AgentConnect seam (~75% as chars). The ReAct loop compacts the oldest tool
    /// exchanges once the payload exceeds this, bounding native-path growth that the
    /// scratchpad budget (which the native path never sends) doesn't constrain.
    /// 0 = disabled (no compaction) — the default for minimal/test constructors. (#22)
    var nativeContextBudgetChars: Int

    /// The window (tokens) the model runs under — what a step's REAL prompt count is compared to,
    /// to tell that the provider had to cut the prompt. 0 = unknown (minimal/test constructors).
    var contextWindowTokens: Int = 0

    /// Which part of an oversized tool result survives — the gauge's global setting plus the
    /// profile's per-tool overrides. Defaults to automatic for minimal/test constructors.
    var cutPolicy: ToolCutPolicy

    /// [Loop Safety] Shared per-run human-interaction memory. Nil (the default) means
    /// the executor creates its own — the historical behavior. Capability wrappers
    /// (Planning, Reflexion) set one instance on every derived sub-input so a
    /// clarification answered once — including the pre-plan clarification — replays
    /// for identical `ask_user` re-asks across subtasks and trials instead of
    /// re-raising the banner. Declaration-level default keeps the memberwise init
    /// and every existing construction site untouched.
    var interactionMemory: RunInteractionMemory? = nil

    /// Resolved input: multimodal if available, text fallback otherwise.
    var resolvedPayload: Payload {
        userPayload ?? [.text(userInput)]
    }

    init(
        userInput: String,
        userPayload: Payload? = nil,
        attachmentContext: String? = nil,
        knowledgeBaseContext: String? = nil,
        toolGuidanceContext: String? = nil,
        chatHistory: [ChatMessage],
        botHistoryImagesEnabled: Bool = false,
        conversationID: UUID,
        tools: [AgentTool],
        longTermMemory: any LongTermMemoryStrategy,
        /// ⚠️ Defaulted so every existing construction stays unconfined. Only AgentConnect's
        /// `.code` arm passes it; a new call site that forgets it silently opts OUT of the
        /// workspace boundary, which is why `WorkspaceBoundaryTests` asserts the Code path
        /// supplies it rather than trusting the default.
        workspaceRoot: String? = nil,
        activeState: SessionGraph? = nil,
        recentHistory: String? = nil,
        generatorStrategy: (any CognitiveGenerator)? = nil,
        workingMemory: any WorkingMemoryStrategy,
        rateLimitKey: String = "geminiFlash",
        rateLimitCategory: RateLimitCategory = .geminiFlash,
        instructions: String? = nil,
        skillManifests: [SkillManifest]? = nil,
        retryPolicy: RetryPolicy = RetryPolicy(),
        errorRecovery: ErrorRecovery = ErrorRecovery(),
        resiliencePolicy: ResolvedResiliencePolicy? = nil,
        responseSynthesisEnabled: Bool = false,
        nativeHistoryTurns: [HistoryTurn]? = nil,
        suppressEpisodeManagement: Bool = false,
        suppressLLMSynthesis: Bool = false,
        workflowContext: WorkflowExecutionContext? = nil,
        resumeState: TimelineReconstruction? = nil,
        traceContext: TraceContext,
        modelTier: ModelTier? = nil,
        nativeContextBudgetChars: Int = 0,
        contextWindowTokens: Int = 0,
        cutPolicy: ToolCutPolicy = ToolCutPolicy()
    ) {
        self.userInput = userInput
        self.userPayload = userPayload
        self.attachmentContext = attachmentContext
        self.knowledgeBaseContext = knowledgeBaseContext
        self.toolGuidanceContext = toolGuidanceContext
        self.chatHistory = chatHistory
        self.botHistoryImagesEnabled = botHistoryImagesEnabled
        self.conversationID = conversationID
        self.workspaceRoot = workspaceRoot
        self.tools = tools
        self.longTermMemory = longTermMemory
        self.activeState = activeState
        self.recentHistory = recentHistory

        self.generatorStrategy = generatorStrategy ?? NativeStructuredGenerator()
        self.workingMemory = workingMemory
        self.rateLimitKey = rateLimitKey
        self.rateLimitCategory = rateLimitCategory

        self.instructions = instructions
        self.skillManifests = skillManifests
        self.retryPolicy = retryPolicy
        self.errorRecovery = errorRecovery
        self.resiliencePolicy = resiliencePolicy ?? .resolved(for: .cloud, legacy: retryPolicy)
        self.responseSynthesisEnabled = responseSynthesisEnabled
        self.nativeHistoryTurns = nativeHistoryTurns
        self.suppressEpisodeManagement = suppressEpisodeManagement
        self.suppressLLMSynthesis = suppressLLMSynthesis
        self.workflowContext = workflowContext
        self.resumeState = resumeState
        self.traceContext = traceContext
        self.modelTier = modelTier
        self.nativeContextBudgetChars = nativeContextBudgetChars
        self.contextWindowTokens = contextWindowTokens
        self.cutPolicy = cutPolicy
    }
}

// MARK: - Semantic Context Models

struct EnvironmentFacts: Sendable {
    let osVersion: String
    let shellType: String
    let userName: String
    /// Absolute home directory (e.g. "/Users/alice"). Small local models copy paths
    /// verbatim from context — without a real absolute path to anchor on they emit
    /// training-data placeholders like "/path/to/X". Populate with `NSHomeDirectory()`;
    /// the app is NOT sandboxed (empty Devgentic.entitlements), so it returns the true
    /// home. Under App Sandbox it would silently return the container path — switch to
    /// `getpwuid(getuid())` if sandboxing is ever enabled.
    let homeDirectory: String
    let currentDate: String

    /// The project folder a Code run is confined to, or nil when the run is unconfined.
    ///
    /// ⚠️⚠️ The `<environment>` block used to advertise ONLY the home directory — "use absolute
    /// paths; user folders are under /Users/<name> (Desktop, Documents, Downloads)". For a Code
    /// run that is a direct instruction to leave the project, sitting a few hundred characters
    /// below a system prompt that says the project folder is a boundary. Field-observed
    /// 2026-09-20: with the Code prompt missing entirely, this block was the ONLY path guidance
    /// the model received, and it walked the home directory. It still contradicted the prompt
    /// after that was fixed. When this is set the block names the project instead.
    let workspaceRoot: String?

    init(osVersion: String, shellType: String, userName: String, homeDirectory: String, currentDate: String, workspaceRoot: String? = nil) {
        self.osVersion = osVersion
        self.shellType = shellType
        self.userName = userName
        self.homeDirectory = homeDirectory
        self.currentDate = currentDate
        self.workspaceRoot = workspaceRoot
    }
}

/// Captures an ask_user Q+A pair for prompt injection as a `<clarification>` tag.
struct ClarificationContext: Sendable {
    let query: String    // what the agent asked
    let response: String // what the user answered
}

struct SemanticContext: Sendable {
    // 1. System & Identity
    let instructions: String?
    let environmentFacts: EnvironmentFacts

    // 2. Memory & Long-Term State
    let longTermMemory: any LongTermMemoryStrategy
    let recentHistory: String?
    let nativeHistoryTurns: [HistoryTurn]?

    // 3. Current Execution State
    let originalQuery: String
    let currentIteration: Int
    let compiledScratchpad: String
    let latestClarification: ClarificationContext?

    // 4. Guardrails & Circuit Breakers
    let negativeConstraints: Set<String>
    let hallucinatedTools: Set<String>

    // 5. Capabilities
    let availableTools: [AgentTool]

    // 6. User Personal Profile
    let userProfile: String?

    // 7. Skills — on-demand discovery layer (name + description one-liners)
    let skillManifests: [SkillManifest]?

    // 9. Prompt layer configuration — controls which optional layers are included
    let promptLayerConfig: PromptLayerConfig

    // 10. Workflow context — full per-node execution context (nil for normal chat).
    //     When non-nil, `buildStandardMessages` auto-derives the user-message
    //     prefix from `workflowContext.userMessagePrefix(wrapping:)` so every
    //     generator inherits workflow behavior with zero per-generator code.
    let workflowContext: WorkflowExecutionContext?

    // 11. File-context delivery (2026-07 redesign) — defaulted so construction
    //     sites that don't carry file context (planning, tests) stay untouched.
    /// Current-turn attachment payload rendered at the top of the USER message
    /// (never `<task>`): extracted file text or a stateless read_file path note.
    var attachmentContext: String? = nil

    /// Profile knowledge-source payload rendered as the system `<knowledge_base>`
    /// layer: budgeted content (directInjection) or a path manifest (stateless).
    var knowledgeBaseContext: String? = nil

    /// MCP server-authored guidance on how to drive THIS run's tools, rendered as `<tool_guidance>`.
    ///
    /// ⚠️ Separate from `knowledgeBaseContext` on purpose (owner decision 2026-08-20). It used to
    /// ride the knowledge layer, which conflated two things: knowledge is the USER's reference
    /// material, this is operating instructions for TOOLS. It also cannot live in
    /// `<available_tools>` — that section renders only for LEGACY (non-native) flows and holds
    /// schemas rather than prose.
    ///
    /// ⚠️ GATED PER SERVER by the caller: only servers with at least one tool in this run's
    /// resolved set contribute. Before that gate every connected server's instructions shipped in
    /// every request — an agent with 3 built-in tools and ZERO MCP tools still received ~2,000
    /// chars explaining how to drive 41 tools it did not have, and on the workflow path that text
    /// became its `<task>`.
    var toolGuidanceContext: String? = nil

    /// Current-turn image attachments (already vision-gated upstream — nil for a
    /// non-vision local model). The NATIVE path reads `input.userPayload` directly;
    /// this field is the only channel by which the LEGACY/dialect generators can see
    /// current-turn images, since a generator's sole input is this context. Defaulted,
    /// so text-only construction sites are untouched.
    var userImagePayload: Payload? = nil

    /// The span the prompt builder attributes its CONTEXT-injection telemetry to
    /// (Run-Report Phase 3). Defaulted nil — construction sites that don't carry
    /// tracing (planning fixtures, tests) stay untouched and emit nothing.
    var traceContext: TraceContext? = nil
}

// MARK: - Agent Failure Reasons

/// Typed failure signals enabling intelligent retry/skip/reroute decisions.
/// Replaces opaque error strings with structured reasons the workflow layer can act on.
/// ⚠️ `iterationBudgetExhausted` has a history worth knowing before you touch it.
///
/// It was declared in 6c2c0b4 with three switch arms and NEVER CONSTRUCTED — so `isRetryable`
/// returned `true` for it and `remediation` offered advice that no user could ever see. It was
/// DELETED as dead on 2026-08-19, then REINSTATED the same day once the investigation showed there
/// is a real failure that should carry it. The lesson stands: **a case here is only worth having if
/// something constructs it.** Do not re-add one without a construction site.
///
/// WHAT ACTUALLY HAPPENS ON EXHAUSTION (`ErrorRecovery.onIterationExhaustion` in `ReActAgentExecutor`):
///   • `.synthesizeBestEffort` (the DEFAULT) with usable partial text → `.completedWithWarnings`.
///     The workflow node stays `.completed`. **Not a failure, and not retried.**
///   • `.synthesizeBestEffort` with an EMPTY response → `.failed`. This is the case that was missing:
///     it reaches the workflow node on the DEFAULT policy, so it is not rare.
///   • `.failHard` → `.failed` always.
///
/// ⚠️ Until this was reinstated, both failing paths were classified as `.modelError`, so the node's
/// remediation read "The model provider returned an error. Check connectivity, credentials, and the
/// selected model." for a run that had simply run out of steps.
///
/// ⚠️ NO `bestEffortOutput` PAYLOAD, deliberately. The old shape had one and it would always have
/// been nil: a non-empty best effort produces `.completedWithWarnings`, which never becomes a
/// failure reason at all. A payload that is structurally always nil is the same lie in miniature.
enum AgentFailureReason: Sendable, Codable, Equatable {
    case iterationBudgetExhausted(iterations: Int)
    case consecutiveParseFailures(count: Int, lastError: String)
    case consecutiveToolFailures(count: Int, lastTool: String, lastError: String)
    case repetitiveActionLoop(action: String, count: Int)
    case executionTimeout(elapsed: TimeInterval, limit: TimeInterval)
    case modelError(provider: String, error: String)
    case cancelled

    var isRetryable: Bool {
        switch self {
        // Retried per the owner's rule (a profile-node failure retries). The agent is
        // non-deterministic, so a fresh sample may terminate where this one did not — but it is the
        // most EXPENSIVE reason to retry, since each attempt costs a full iteration budget. The
        // retry sites log it distinctly for exactly that reason.
        case .iterationBudgetExhausted: true
        case .consecutiveParseFailures: true
        case .consecutiveToolFailures: false
        case .repetitiveActionLoop: false
        case .executionTimeout: true
        case .modelError: true
        case .cancelled: false
        }
    }

    var localizedDescription: String {
        switch self {
        case .iterationBudgetExhausted(let iterations):
            "Ran out of steps after \(iterations) iterations without producing an answer"
        case .consecutiveParseFailures(let count, let lastError):
            "\(count) consecutive parse failures (last: \(lastError))"
        case .consecutiveToolFailures(let count, let lastTool, let lastError):
            "\(count) consecutive tool failures on \(lastTool) (last: \(lastError))"
        case .repetitiveActionLoop(let action, let count):
            "Repetitive action loop detected: \(action) repeated \(count) times"
        case .executionTimeout(let elapsed, let limit):
            "Execution timeout after \(Int(elapsed))s (limit: \(Int(limit))s)"
        case .modelError(let provider, let error):
            "Model error from \(provider): \(error)"
        case .cancelled:
            "Execution cancelled"
        }
    }

    /// A short, actionable remediation hint shown to the workflow author when a
    /// node fails with this reason. `nil` when there's nothing useful to suggest
    /// (e.g. a user-initiated cancel). Folded into the node's failure detail so
    /// it surfaces in every run card (Round 2 Phase 4).
    var remediation: String? {
        switch self {
        case .iterationBudgetExhausted(let iterations):
            return "The agent used all \(iterations) of its steps without producing an answer. Simplify the node's task, or raise the profile's Max Iterations."
        case .consecutiveParseFailures:
            return "The model's structured output couldn't be parsed repeatedly. Try a different model or a simpler task."
        case .consecutiveToolFailures(_, let lastTool, _):
            return "The '\(lastTool)' tool kept failing. Check its configuration and the inputs it received."
        case .repetitiveActionLoop:
            return "The agent repeated the same action. Refine the task so the goal is reachable in distinct steps."
        case .executionTimeout(_, let limit):
            return "The node exceeded its \(Int(limit))s timeout. Raise the node timeout or reduce the work it does."
        case .modelError:
            return "The model provider returned an error. Check connectivity, credentials, and the selected model."
        case .cancelled:
            return nil
        }
    }

    /// Best-effort classification of an inner agent's terminal failure TEXT into a typed reason.
    /// The inner stream's `executionFinished(.failed)` only carries a string, so wrap sites would
    /// otherwise blanket-classify everything as `.modelError` — mislabelling e.g. the cognitive
    /// circuit breaker's stale-loop abort and surfacing the wrong remediation ("check credentials"
    /// for a loop the agent was stuck in). Marker strings match `CognitiveCircuitBreaker`'s abort
    /// reasons. Falls back to `.modelError` for anything unrecognized.
    static func classify(agentReasonText text: String, provider: String = "agent") -> AgentFailureReason {
        // ⚠️ TWO DIFFERENT PHRASINGS, and matching only one covers only one path. The executor's
        // `.failHard` arm says "Reached maximum allowed steps (N) without completion." while the
        // `.synthesizeBestEffort` arm's terminalReason says "Reached maximum iterations (N) without
        // explicit completion". The SECOND is the one that matters most: it is the default policy,
        // and it reaches here whenever the agent produced no text. Both are matched on the shared
        // "Reached maximum" prefix plus the parenthesised count, so a reworded message degrades to
        // `.modelError` rather than silently matching the wrong thing.
        if let iterations = exhaustedIterationCount(in: text) {
            return .iterationBudgetExhausted(iterations: iterations)
        }
        if text.contains("Breaking stale loop") {
            // "Tool 'X' has been called N times with the same parameters…"
            let action = text.split(separator: "'").dropFirst().first.map(String.init) ?? "the same action"
            let words = text.split(separator: " ").map(String.init)
            let count = words.firstIndex(of: "times")
                .flatMap { $0 > 0 ? Int(words[$0 - 1]) : nil } ?? 2
            return .repetitiveActionLoop(action: action, count: count)
        }
        return .modelError(provider: provider, error: text)
    }

    /// The iteration count from an exhaustion message, or nil if this is not one.
    ///
    /// Pure and total so the parsing is testable without an executor — the same shape as the rest of
    /// the retry policy work. Returns nil rather than a default count when the number cannot be
    /// read: a wrong count in a remediation string ("you used all 0 of your steps") is worse than
    /// falling back to the generic reason.
    static func exhaustedIterationCount(in text: String) -> Int? {
        guard text.contains("Reached maximum") else { return nil }
        guard let open = text.firstIndex(of: "("),
              let close = text[open...].firstIndex(of: ")") else { return nil }
        let digits = text[text.index(after: open)..<close]
        return Int(digits.trimmingCharacters(in: .whitespaces))
    }
}

/// Error type wrapping an AgentFailureReason for throwing contexts.
struct AgentExecutionError: Error, Sendable {
    let reason: AgentFailureReason
}

// MARK: - Plan & Execute Models

struct SubTask: Sendable, Codable, Identifiable, Equatable, Hashable {
    let id: String
    var description: String
    var toolHints: [String]?
    var status: SubTaskStatus
    var result: String?
    var dependsOn: [String]?

    init(id: String = UUID().uuidString, description: String, toolHints: [String]? = nil, status: SubTaskStatus = .pending, result: String? = nil, dependsOn: [String]? = nil) {
        self.id = id
        self.description = description
        self.toolHints = toolHints
        self.status = status
        self.result = result
        self.dependsOn = dependsOn
    }

    // MARK: - Backward-Compatible Codable

    private enum CodingKeys: String, CodingKey {
        case id, description, toolHints, status, result, dependsOn
        case toolHint // Legacy key — decode only, never encoded
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.description = try container.decode(String.self, forKey: .description)
        self.status = (try? container.decode(SubTaskStatus.self, forKey: .status)) ?? .pending
        self.result = try? container.decode(String.self, forKey: .result)
        self.dependsOn = try? container.decode([String].self, forKey: .dependsOn)

        // New format first, fallback to legacy single-string key
        if let hints = try? container.decode([String].self, forKey: .toolHints) {
            self.toolHints = hints.isEmpty ? nil : hints
        } else if let legacyHint = try? container.decode(String.self, forKey: .toolHint) {
            self.toolHints = legacyHint.isEmpty ? nil : [legacyHint]
        } else {
            self.toolHints = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(description, forKey: .description)
        try container.encodeIfPresent(toolHints, forKey: .toolHints)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(result, forKey: .result)
        try container.encodeIfPresent(dependsOn, forKey: .dependsOn)
    }
}

enum SubTaskStatus: String, Sendable, Codable {
    case pending, inProgress, completed, failed, skipped
}

// MARK: - Reflexion Models

struct ReflectionResult: Sendable {
    let isAcceptable: Bool
    let critique: String
    let suggestedRevisions: String?
    let trial: Int
}

// (Supervisor models WorkerTask/WorkerResult removed — the Supervisor executor was retired; H1 cleanup.)
