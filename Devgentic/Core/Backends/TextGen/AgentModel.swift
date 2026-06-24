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

struct APISpyModel: LLMProvider {
    let inner: any LLMProvider

    var modelName: String { inner.modelName }

    func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String {
        return try await inner.generate(messages: messages, tools: tools, responseSchema: responseSchema)
    }

    func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error> {
        return inner.stream(messages: messages, tools: tools)
    }

    func generateCognitiveStep(messages: [[String: String]], tools: [[String: Any]]?) async throws -> ModernCognitiveStep {
        return try await inner.generateCognitiveStep(messages: messages, tools: tools)
    }

    /// G12: forward the native-turn overload to the inner provider. Without this
    /// explicit forward, the protocol's default fallback runs — which coerces
    /// `tool_calls` arrays into Swift description strings via `"\(value)"` and
    /// breaks the native-turn request shape before it ever reaches the real provider.
    func generateCognitiveStep(nativeMessages: [[String: Any]], tools: [[String: Any]]?) async throws -> ModernCognitiveStep {
        return try await inner.generateCognitiveStep(nativeMessages: nativeMessages, tools: tools)
    }

    func generateWithUsage(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> (text: String, usage: TokenUsage?) {
        return try await inner.generateWithUsage(messages: messages, tools: tools, responseSchema: responseSchema)
    }

    func generateWithUsage(payload: [ProviderMessage], tools: [[String: Any]]?, responseSchema: Any?) async throws -> (text: String, usage: TokenUsage?) {
        return try await inner.generateWithUsage(payload: payload, tools: tools, responseSchema: responseSchema)
    }

    func streamWithUsage(messages: [[String: String]], tools: [[String: Any]]?, onUsage: (@Sendable (TokenUsage) -> Void)?) -> AsyncThrowingStream<String, Error> {
        return inner.streamWithUsage(messages: messages, tools: tools, onUsage: onUsage)
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

    /// True when this tool's SUCCESSFUL output may legitimately begin with or contain
    /// "error"-shaped text — e.g. a shell tool surfacing stderr, or a build-error reader
    /// whose whole purpose is to return compiler errors. Such tools opt out of
    /// `ToolExecutionMediator`'s content-sniffing semantic-failure check: a non-throwing
    /// return is treated as success (#19). Default: false.
    var outputMayContainErrorText: Bool { get }

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
        var def = "### \(self.name)\n"
        def += "- Description: \(self.description)\n"
        
        if !self.parameters.properties.isEmpty {
            def += "- Arguments:\n"
            for (key, param) in self.parameters.properties {
                let req = self.parameters.required.contains(key) ? "required" : "optional"
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

    // NOTE: Used ONLY by ChatExecutor (Bots). ReActAgentExecutor completely ignores this
    // to enforce the "Zero-History Context" architecture.
    var chatHistory: [ChatMessage]

    var conversationID: UUID
    var tools: [AgentTool]
    var longTermMemory: any LongTermMemoryStrategy

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
    var skillFolderPath: String?

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
    var nativeHistoryTurns: [[String: String]]?

    /// [G3/G5] When true, the inner executor skips episode append/close because
    /// the wrapping capability (Planning or Reflexion) owns the episode lifecycle.
    var suppressEpisodeManagement: Bool

    /// Workflow execution context — non-nil when this agent is running as a node
    /// within a workflow DAG. Signals downstream components (generators, executors)
    /// to use the workflow-specific prompt pipeline: no RAG, no history, clean task+input.
    var workflowContext: WorkflowExecutionContext?

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

    /// Resolved input: multimodal if available, text fallback otherwise.
    var resolvedPayload: Payload {
        userPayload ?? [.text(userInput)]
    }

    init(
        userInput: String,
        userPayload: Payload? = nil,
        chatHistory: [ChatMessage],
        conversationID: UUID,
        tools: [AgentTool],
        longTermMemory: any LongTermMemoryStrategy,
        activeState: SessionGraph? = nil,
        recentHistory: String? = nil,
        generatorStrategy: (any CognitiveGenerator)? = nil,
        workingMemory: any WorkingMemoryStrategy,
        rateLimitKey: String = "geminiFlash",
        rateLimitCategory: RateLimitCategory = .geminiFlash,
        instructions: String? = nil,
        skillManifests: [SkillManifest]? = nil,
        skillFolderPath: String? = nil,
        retryPolicy: RetryPolicy = RetryPolicy(),
        errorRecovery: ErrorRecovery = ErrorRecovery(),
        resiliencePolicy: ResolvedResiliencePolicy? = nil,
        responseSynthesisEnabled: Bool = false,
        nativeHistoryTurns: [[String: String]]? = nil,
        suppressEpisodeManagement: Bool = false,
        workflowContext: WorkflowExecutionContext? = nil,
        traceContext: TraceContext,
        modelTier: ModelTier? = nil,
        nativeContextBudgetChars: Int = 0
    ) {
        self.userInput = userInput
        self.userPayload = userPayload
        self.chatHistory = chatHistory
        self.conversationID = conversationID
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
        self.skillFolderPath = skillFolderPath
        self.retryPolicy = retryPolicy
        self.errorRecovery = errorRecovery
        self.resiliencePolicy = resiliencePolicy ?? .resolved(for: .cloud, legacy: retryPolicy)
        self.responseSynthesisEnabled = responseSynthesisEnabled
        self.nativeHistoryTurns = nativeHistoryTurns
        self.suppressEpisodeManagement = suppressEpisodeManagement
        self.workflowContext = workflowContext
        self.traceContext = traceContext
        self.modelTier = modelTier
        self.nativeContextBudgetChars = nativeContextBudgetChars
    }
}

// MARK: - Semantic Context Models

struct EnvironmentFacts: Sendable {
    let osVersion: String
    let shellType: String
    let userName: String
    let currentDate: String
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
    let nativeHistoryTurns: [[String: String]]?

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

    // 8. Workflow — per-node task description (nil for normal chat)
    let taskDescription: String?

    // 9. Prompt layer configuration — controls which optional layers are included
    let promptLayerConfig: PromptLayerConfig

    // 10. Workflow context — full per-node execution context (nil for normal chat).
    //     When non-nil, `buildStandardMessages` auto-derives the user-message
    //     prefix from `workflowContext.userMessagePrefix(wrapping:)` so every
    //     generator inherits workflow behavior with zero per-generator code.
    let workflowContext: WorkflowExecutionContext?
}

// MARK: - Agent Failure Reasons

/// Typed failure signals enabling intelligent retry/skip/reroute decisions.
/// Replaces opaque error strings with structured reasons the workflow layer can act on.
enum AgentFailureReason: Sendable, Codable, Equatable {
    case iterationBudgetExhausted(iterations: Int, bestEffortOutput: String?)
    case consecutiveParseFailures(count: Int, lastError: String)
    case consecutiveToolFailures(count: Int, lastTool: String, lastError: String)
    case repetitiveActionLoop(action: String, count: Int)
    case executionTimeout(elapsed: TimeInterval, limit: TimeInterval)
    case modelError(provider: String, error: String)
    case cancelled

    var isRetryable: Bool {
        switch self {
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
        case .iterationBudgetExhausted(let iterations, _):
            "Iteration budget exhausted after \(iterations) iterations"
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
        case .iterationBudgetExhausted:
            return "The agent ran out of iterations. Simplify the node's task or raise its iteration limit."
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
