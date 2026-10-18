// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AgentModel.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation


/// Lightweight result container for parallel tool execution within a single ReAct iteration.
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

    /// Structured failure cause, nil on success.
    /// Carries `ToolExecutionResult`'s classification across the loop-to-executor seam so consumers branch on category.
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
/// The executor updates it as it opens each step span, and the spy reads it at call time.
/// The lock makes the handoff safe; a concurrent caller sees a stale parent, never a torn read.
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

/// Pass-through `LLMProvider` decorator in front of every model on the ReAct, Planning and Reflexion paths.
/// With a `spanScope`, each blocking call becomes an `.llmCall` span with duration, tokens and request/response events.
/// Streaming methods stay uninstrumented; a nil scope is a strict pass-through.
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

    /// Forwards the native-turn overload to the inner provider.
    /// The protocol's default fallback would coerce `tool_calls` arrays into description strings.
    func generateCognitiveStep(nativeMessages: [[String: Any]], tools: [[String: Any]]?) async throws -> ModernCognitiveStep {
        try await traced(messageCount: nativeMessages.count, preview: Self.stepPreview, usage: { $0.tokenUsage }) {
            try await inner.generateCognitiveStep(nativeMessages: nativeMessages, tools: tools)
        }
    }

    /// Forwarded for the same reason as the non-streaming overload above: without it the protocol
    /// default runs, which calls THIS wrapper's non-streaming method — the step would still work,
    /// but nothing would ever stream.
    func generateCognitiveStepStreaming(
        nativeMessages: [[String: Any]],
        tools: [[String: Any]]?,
        onTextDelta: @escaping @Sendable (String) -> Void
    ) async throws -> ModernCognitiveStep {
        try await traced(messageCount: nativeMessages.count, preview: Self.stepPreview, usage: { $0.tokenUsage }) {
            try await inner.generateCognitiveStepStreaming(nativeMessages: nativeMessages, tools: tools, onTextDelta: onTextDelta)
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

    /// The parser/validator verdict about this response; drives the terminator's completion-versus-retry decision.
    /// `.success` implies non-empty `toolCalls`; `.genuineCompletion` implies empty `toolCalls` and no parse error;
    /// `.failed(reason)` implies empty `toolCalls` and a reason-specific corrective alert.
    let parseOutcome: ParseOutcome

    /// Provider data that must be sent back verbatim on this step's assistant turn, or nil.
    /// Currently OpenRouter's `reasoning_details`, which reasoning models need returned with their tool calls.
    /// Opaque: nothing here reads it; the tool-turn adapter only echoes it.
    let reasoningReplay: JSONValue?

    /// The visible reply text when `toolCalls` were recovered from it, not delivered on a structured channel; else nil.
    /// Lets `NativeParsePipeline` return the whole reply when a JSON object in the answer is the answer, not a call.
    let callsRecoveredFromText: String?

    /// Calls the model made in this step that failed validation while sibling calls passed.
    /// The step stays `.success`; the loop reports each rejected call to the model as not run, with the reason.
    let rejectedCalls: [RejectedSiblingCall]

    init(reasoning: String, thought: String? = nil, toolCalls: [PendingToolCall] = [], tokenUsage: TokenUsage? = nil, parseOutcome: ParseOutcome? = nil, reasoningReplay: JSONValue? = nil, callsRecoveredFromText: String? = nil, rejectedCalls: [RejectedSiblingCall] = []) {
        self.rejectedCalls = rejectedCalls
        self.reasoning = reasoning
        self.thought = thought
        self.reasoningReplay = reasoningReplay
        self.callsRecoveredFromText = callsRecoveredFromText
        self.toolCalls = toolCalls
        self.tokenUsage = tokenUsage
        // Default derivation: non-empty tool calls ⇒ success; empty ⇒ genuineCompletion.
        // Callers that detected a parse failure must pass `.failed(reason)` explicitly.
        self.parseOutcome = parseOutcome ?? (toolCalls.isEmpty ? .genuineCompletion : .success)
    }
}

/// A call that failed validation in a step where other calls passed.
struct RejectedSiblingCall: Sendable {
    let call: PendingToolCall
    let reason: ParseFailureReason

    /// What the model is told in place of a result.
    var modelNote: String {
        switch reason {
        case .unknownToolName(let attempted, let suggestions):
            let hint = suggestions.isEmpty ? "" : " Did you mean: \(suggestions.joined(separator: ", "))?"
            return "Not run: there is no tool named '\(attempted)'.\(hint) The other calls in this step did run."
        case .argSchemaMismatch(let attempted, let resolvedTo, let missing, let unexpected):
            var parts: [String] = []
            if !missing.isEmpty { parts.append("missing required: \(missing.joined(separator: ", "))") }
            if !unexpected.isEmpty { parts.append("not accepted: \(unexpected.joined(separator: ", "))") }
            let target = attempted == resolvedTo ? "'\(resolvedTo)'" : "'\(attempted)' (taken as '\(resolvedTo)')"
            return "Not run: \(target) was called with the wrong arguments (\(parts.joined(separator: "; "))). The other calls in this step did run."
        default:
            return "Not run: this call could not be validated (\(String(describing: reason))). The other calls in this step did run."
        }
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
        /// Not yet admitted: another run holds this conversation.
        /// A `ThinkingDetail` rather than an `AgentState` case, so it renders everywhere and is not counted as an iteration.
        case queued = "Waiting its turn"
        /// Admitted in its conversation, but another run on this Mac holds the local model lock.
        /// Distinct from `.queued` because the holder is usually in another conversation; the advisory banner names it.
        case awaitingLocalModel = "Waiting for the local model"
        /// Held until the user chooses Proceed or Stop; the banner above the input says why and counts down to the auto-deny.
        case awaitingConfirmation = "Waiting for you to proceed"
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


// MARK: - Tool Schemas & Protocols

/// Helper utility to concisely construct JSON schemas for tool definitions.
enum SchemaBuilder {
    
    /// Builds a standard object schema from a list of properties.
    /// `properties` are (key, type, description) tuples; `required` lists the mandatory keys.
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

    /// The logical group this tool belongs to, for organising the Tool Library.
    /// Required rather than defaulted so a tool cannot silently land in a default bucket; internal tools use `"Internal"`.
    var category: String { get }

    /// True when this tool's successful output may legitimately contain error-shaped text, such as stderr.
    /// Such tools opt out of `ToolExecutionMediator`'s content-sniffing failure check. Default: false.
    var outputMayContainErrorText: Bool { get }

    /// The ceiling in seconds of a time bound this tool enforces itself, or nil.
    /// The dispatcher's per-tool timeout sits just above it so partial output is not discarded.
    var selfBoundCeiling: TimeInterval? { get }

    /// True when this tool's argument is executed as code, such as a shell command or AppleScript body.
    /// Derived from `ToolCapability.arbitraryCodeExecution` by default; false for tools that do a bounded, named thing.
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

    /// Default: the tool does not bound itself; the dispatcher's timeout is its only bound.
    var selfBoundCeiling: TimeInterval? { nil }

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

    /// If true, the Executor will pause and ask the user before running this tool.
    let requiresConfirmation: Bool

    // Per-tool execution limits
    /// The user's per-tool timeout override in seconds.
    /// Nil means the dispatcher's default applies, not "no limit".
    let timeout: TimeInterval?
    /// Custom message sent to the LLM when this tool times out. Nil uses the default timeout message.
    let timeoutMessage: String?

    /// When true, the executor skips content-sniffing semantic-failure detection for this
    /// tool — a non-throwing return is success even if the output looks like an error. Set
    /// for tools whose legitimate output surfaces error text (shell, build diagnostics). (#19)
    let contentMayLookLikeError: Bool

    /// See `AgentToolProtocol.selfBoundCeiling`.
    let selfBoundCeiling: TimeInterval?

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
        selfBoundCeiling: TimeInterval? = nil,
        run: @escaping @Sendable (Data) async throws -> (output: String, artifacts: [MediaArtifact])
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.requiresConfirmation = requiresConfirmation
        self.timeout = timeout
        self.timeoutMessage = timeoutMessage
        self.contentMayLookLikeError = contentMayLookLikeError
        self.selfBoundCeiling = selfBoundCeiling
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
        selfBoundCeiling: TimeInterval? = nil,
        textOnlyRun: @escaping @Sendable (Data) async throws -> String
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.requiresConfirmation = requiresConfirmation
        self.timeout = timeout
        self.timeoutMessage = timeoutMessage
        self.contentMayLookLikeError = contentMayLookLikeError
        self.selfBoundCeiling = selfBoundCeiling
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

    /// Renders the markdown definition for any (name, description, parameters) triple.
    /// Lets the fit gauges size a tool payload from the registry without constructing executable tools.
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
    /// The call was cancelled before it finished because the run was stopped.
    /// Not a tool failure: it does not count against reliability. `message` is what the model reads when the run goes on.
    case cancelled(toolName: String, message: String? = nil)

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
        case .cancelled(let toolName, let message):
            if let message, !message.isEmpty { return message }
            return "Tool '\(toolName)' was cancelled before it finished because the run was stopped."
        }
    }
    
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    /// Maps the result to a structured `ToolFailureCategory`; returns `nil` for `.success`.
    /// `.semanticFailure` and `.systemError` are each split by the error string prefix produced by `ToolExecutionMediator`.
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
        case .cancelled:
            return .cancelled
        }
    }
}

// MARK: - Tool Argument Error (Phase 10)

/// A descriptive error thrown when tool argument decoding fails.
/// Includes the tool name, required parameters and the raw JSON received.
struct ToolArgumentError: Error, LocalizedError {
    let toolName: String
    let detail: String
    var errorDescription: String? { detail }
}

// MARK: - Execution Input

/// The standard payload required to initialize any Agent Executor.
/// Sub-run inputs must copy and mutate an existing input (`var derived = input`) rather than call the initializer,
/// since defaulted parameters let a forgotten field be dropped silently.
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

    /// Code runs only: the project's `AGENTS.md` + memory listing, read when the run started
    /// (`AgentConnect.codeProjectKnowledge`). Its own layer — see `SemanticContext.projectKnowledge`.
    var projectKnowledge: String? = nil

    /// MCP server-authored guidance on how to drive this run's tools, rendered as `<tool_guidance>`.
    /// Separate from `knowledgeBaseContext`; gated per server, so only servers with a tool in this run contribute.
    var toolGuidanceContext: String? = nil

    // Used only by `ChatExecutor` (bots); `ReActAgentExecutor` ignores it.
    var chatHistory: [ChatMessage]

    /// Bot path only: whether prior-turn images in `chatHistory` are re-attached to the request.
    /// Agents ignore it; they carry history images via `nativeHistoryTurns`.
    var botHistoryImagesEnabled: Bool = false

    var conversationID: UUID
    var tools: [AgentTool]
    var longTermMemory: any LongTermMemoryStrategy

    /// The project folder a Code session is confined to; nil for every other profile type, which stay unconfined.
    /// `WorkspaceBoundary` turns it into a boundary the tool loop applies.
    var workspaceRoot: String? = nil

    // Architecture: Split-State (Active State + History)
    var activeState: SessionGraph?
    var recentHistory: String?

    // [Step 3 Architecture Update]
    var generatorStrategy: any CognitiveGenerator
    var workingMemory: any WorkingMemoryStrategy

    // Bucket key derived from provider and apiKey/baseURL for profile-scoped rate limiting.
    var rateLimitKey: String
    var rateLimitCategory: RateLimitCategory

    var instructions: String?

    // Skills — on-demand discovery layer
    var skillManifests: [SkillManifest]?

    // Resilience configuration from AgentConfig
    var retryPolicy: RetryPolicy
    var errorRecovery: ErrorRecovery

    /// Resolved three-tier resilience policy (transport, cognitive, loop).
    /// Resolved once at the `AgentConnect` seam; minimal constructors get cloud-class defaults derived from `retryPolicy`.
    var resiliencePolicy: ResolvedResiliencePolicy

    /// Whether IC-powered response synthesis is enabled for this run.
    var responseSynthesisEnabled: Bool

    /// Pre-built native history turns for providers that support turn-by-turn conversation; nil for XML episodic memory.
    /// Must stay optional: `ChatExecutor` derives `isNativeFlow` from `!= nil`, and an empty non-nil value is reachable.
    var nativeHistoryTurns: [HistoryTurn]?

    /// [G3/G5] When true, the inner executor skips episode append/close because
    /// the wrapping capability (Planning or Reflexion) owns the episode lifecycle.
    var suppressEpisodeManagement: Bool

    /// When true, the inner executor never pays for LLM response synthesis.
    /// Wrapper loops (Planning, Reflexion) re-synthesize intermediate output themselves; free synthesis paths still apply.
    var suppressLLMSynthesis: Bool

    /// Workflow execution context — non-nil when this agent is running as a node
    /// within a workflow DAG. Signals downstream components (generators, executors)
    /// to use the workflow-specific prompt pipeline: no RAG, no history, clean task+input.
    var workflowContext: WorkflowExecutionContext?

    /// Non-nil only when resuming a parked human-in-the-loop run after restart.
    /// Carries in-flight state rebuilt from the persisted timeline; only `ReActAgentExecutor` reads it.
    /// Capability sub-runs copy `input`, so a capability-aware resume must nil this on derived sub-inputs.
    var resumeState: TimelineReconstruction?

    // The Trace Context for distributed observability
    var traceContext: TraceContext

    /// Model tier derived from `LLMProviderConfig.modelMetadata?.tier`; executors use it to tune gates for weaker models.
    /// Nil when the model could not be classified.
    var modelTier: ModelTier?

    /// Char budget for the native turn-by-turn conversation payload (`liveConversationTurns`).
    /// The ReAct loop compacts the oldest tool exchanges once the payload exceeds it. 0 disables compaction.
    var nativeContextBudgetChars: Int

    /// The window (tokens) the model runs under — what a step's REAL prompt count is compared to,
    /// to tell that the provider had to cut the prompt. 0 = unknown (minimal/test constructors).
    var contextWindowTokens: Int = 0

    /// Which part of an oversized tool result survives — the gauge's global setting plus the
    /// profile's per-tool overrides. Defaults to automatic for minimal/test constructors.
    var cutPolicy: ToolCutPolicy

    /// Shared per-run human-interaction memory; nil means the executor creates its own.
    /// Capability wrappers set one instance on sub-inputs so a clarification answered once replays for identical re-asks.
    var interactionMemory: RunInteractionMemory? = nil

    /// Payload size in chars at which the native loop asks the user before sending the next request.
    /// Set for remote endpoints only; 0 disables the gate. See `LargeRequestGate`.
    var largeRequestConfirmChars: Int = 0

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
        // Why: a call site that forgets it silently opts out of the workspace boundary.
        /// Defaulted so existing construction stays unconfined; only `AgentConnect`'s `.code` arm passes a root.
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
    /// Absolute home directory, e.g. "/Users/alice", so small local models do not invent placeholder paths.
    /// Populate with `NSHomeDirectory()`; under App Sandbox that returns the container path, so use `getpwuid` instead.
    let homeDirectory: String
    /// The DAY only — it renders in the system message, which must stay byte-identical across a
    /// conversation's messages (layout B). The time of day is `currentTime`.
    let currentDate: String
    /// The time of day, rendered in the per-message part of the user message, never the system
    /// message: a clock to the minute there changed the prompt's bytes on every message.
    let currentTime: String?

    /// The project folder a Code run is confined to, or nil when the run is unconfined.
    /// When set, the `<environment>` block names the project instead of advertising the home directory.
    let workspaceRoot: String?

    init(osVersion: String, shellType: String, userName: String, homeDirectory: String, currentDate: String, currentTime: String? = nil, workspaceRoot: String? = nil) {
        self.osVersion = osVersion
        self.shellType = shellType
        self.userName = userName
        self.homeDirectory = homeDirectory
        self.currentDate = currentDate
        self.currentTime = currentTime
        self.workspaceRoot = workspaceRoot
    }

    /// The one place the two clock strings are formatted, so every path splits them the same way.
    static func clock(at date: Date = Date()) -> (date: String, time: String) {
        (date.formatted(date: .numeric, time: .omitted), date.formatted(date: .omitted, time: .shortened))
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

    // Per-node workflow execution context, nil for normal chat; `buildStandardMessages` derives the message prefix
    // from it.
    let workflowContext: WorkflowExecutionContext?

    // 11. File-context delivery (2026-07 redesign) — defaulted so construction
    //     sites that don't carry file context (planning, tests) stay untouched.
    /// Current-turn attachment payload rendered at the top of the USER message
    /// (never `<task>`): extracted file text or a stateless read_file path note.
    var attachmentContext: String? = nil

    /// Profile knowledge-source payload rendered as the system `<knowledge_base>`
    /// layer: budgeted content (directInjection) or a path manifest (stateless).
    var knowledgeBaseContext: String? = nil

    /// Code runs only: `AGENTS.md` plus the memory listing, rendered as the last section of the system message.
    /// Kept out of `instructions` because it changes between requests and must sit after the stable prompt for cache reuse.
    var projectKnowledge: String? = nil

    /// MCP server-authored guidance on how to drive this run's tools, rendered as `<tool_guidance>`.
    /// Separate from `knowledgeBaseContext`; gated per server, so only servers with a tool in this run contribute.
    var toolGuidanceContext: String? = nil

    /// Current-turn image attachments, already vision-gated upstream; nil for a non-vision local model.
    /// The only way legacy/dialect generators see current-turn images; the native path reads `input.userPayload`.
    var userImagePayload: Payload? = nil

    /// The span the prompt builder attributes context-injection telemetry to; nil when the site carries no tracing.
    var traceContext: TraceContext? = nil

    /// Every tool name this run offers, a superset of `availableTools` when an iteration withholds a tool from its schema.
    /// Read only to recognise an attempted call (`AttemptedToolCallGrammar`); never offered to the model. Defaults to empty.
    var runToolNames: Set<String> = []
}

// MARK: - Agent Failure Reasons

/// Typed failure signals enabling retry, skip and reroute decisions in the workflow layer.
/// `iterationBudgetExhausted` comes from `ErrorRecovery.onIterationExhaustion`: an empty best effort or `.failHard`
/// fails, while usable partial text completes with warnings.
enum AgentFailureReason: Sendable, Codable, Equatable {
    case iterationBudgetExhausted(iterations: Int)
    case consecutiveParseFailures(count: Int, lastError: String)
    case consecutiveToolFailures(count: Int, lastTool: String, lastError: String)
    case repetitiveActionLoop(action: String, count: Int)
    case executionTimeout(elapsed: TimeInterval, limit: TimeInterval)
    /// A workflow Gate's own configured timer ran out with nobody answering; the one timer allowed on a human.
    case gateExpired(limit: TimeInterval)
    case modelError(provider: String, error: String)
    case cancelled

    var isRetryable: Bool {
        switch self {
        // Retried like any profile-node failure; the costliest reason, since each attempt spends a full iteration budget.
        case .iterationBudgetExhausted: true
        case .consecutiveParseFailures: true
        case .consecutiveToolFailures: false
        case .repetitiveActionLoop: false
        case .executionTimeout: true
        case .gateExpired: false   // an unanswered question is not fixed by asking again
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
        case .gateExpired(let limit):
            "Gate expired: nobody answered within \(ToolExecutionMediator.describe(limit))"
        case .modelError(let provider, let error):
            "Model error from \(provider): \(error)"
        case .cancelled:
            "Execution cancelled"
        }
    }

    /// A short, actionable remediation hint shown to the workflow author when a node fails with this reason.
    /// `nil` when there is nothing useful to suggest, such as a user-initiated cancel.
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
        case .gateExpired(let limit):
            return "Nobody answered this gate within its \(ToolExecutionMediator.describe(limit)) timeout, so no option was chosen. Wire its error port to handle no answer, or lengthen or remove the gate timeout."
        case .modelError:
            return "The model provider returned an error. Check connectivity, credentials, and the selected model."
        case .cancelled:
            return nil
        }
    }

    /// Classifies an inner agent's terminal failure text into a typed reason, best effort.
    /// Marker strings match `CognitiveCircuitBreaker`'s abort reasons; falls back to `.modelError` for anything unrecognized.
    static func classify(agentReasonText text: String, provider: String = "agent") -> AgentFailureReason {
        // Matches two phrasings (`.failHard` and `.synthesizeBestEffort`) on the shared "Reached maximum" prefix plus the count.
        if let iterations = exhaustedIterationCount(in: text) {
            return .iterationBudgetExhausted(iterations: iterations)
        }
        if let stop = formatCorrectionsExhausted(in: text) {
            return .consecutiveParseFailures(count: stop.count, lastError: stop.last)
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

    /// Builds the executor's parse-loop stop message (the "On Parse Failure" limit).
    /// Lives next to `formatCorrectionsExhausted(in:)` so the classifier reads exactly what the executor emits.
    static func formatCorrectionsExhaustedMessage(count: Int, last: String, identicalReplies: Bool) -> String {
        identicalReplies
            ? "\(identicalReplyPrefix)\(count)\(formatStopInfix)\(last)) — likely a parser/dialect mismatch."
            : "\(unreadableRepliesPrefix)\(count)\(formatStopInfix)\(last))."
    }

    private static let unreadableRepliesPrefix = "The model's replies could not be read "
    private static let identicalReplyPrefix = "The model sent the same unreadable reply "
    private static let formatStopInfix = " times in a row (last: "

    /// The count and last failure from a `formatCorrectionsExhaustedMessage`, or nil if `text` is
    /// not one. Total, like `exhaustedIterationCount(in:)`: an unreadable count yields nil.
    static func formatCorrectionsExhausted(in text: String) -> (count: Int, last: String)? {
        guard let prefix = [unreadableRepliesPrefix, identicalReplyPrefix].first(where: { text.hasPrefix($0) }) else {
            return nil
        }
        let rest = text.dropFirst(prefix.count)
        guard let infix = rest.range(of: formatStopInfix),
              let count = Int(rest[..<infix.lowerBound]),
              let close = rest[infix.upperBound...].lastIndex(of: ")") else { return nil }
        return (count, String(rest[infix.upperBound..<close]))
    }

    /// Returns the iteration count from an exhaustion message, or nil if this is not one.
    /// Returns nil rather than a default when the number cannot be read.
    static func exhaustedIterationCount(in text: String) -> Int? {
        guard text.contains("Reached maximum") else { return nil }
        guard let open = text.firstIndex(of: "("),
              let close = text[open...].firstIndex(of: ")") else { return nil }
        let digits = text[text.index(after: open)..<close]
        return Int(digits.trimmingCharacters(in: .whitespaces))
    }
}

/// Error type wrapping an `AgentFailureReason` for throwing contexts.
/// Conforms to `LocalizedError` so `localizedDescription` shows the reason instead of Foundation's placeholder.
struct AgentExecutionError: LocalizedError, Sendable {
    let reason: AgentFailureReason

    var errorDescription: String? { reason.localizedDescription }
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

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, description, toolHints, status, result, dependsOn
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.description = try container.decode(String.self, forKey: .description)
        self.status = (try? container.decode(SubTaskStatus.self, forKey: .status)) ?? .pending
        self.result = try? container.decode(String.self, forKey: .result)
        self.dependsOn = try? container.decode([String].self, forKey: .dependsOn)

        let hints = try? container.decode([String].self, forKey: .toolHints)
        self.toolHints = (hints?.isEmpty ?? true) ? nil : hints
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
