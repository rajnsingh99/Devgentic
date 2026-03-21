//
//  AgentModel.swift
//  Devgentic
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

    init(reasoning: String, thought: String? = nil, toolCalls: [PendingToolCall] = []) {
        self.reasoning = reasoning
        self.thought = thought
        self.toolCalls = toolCalls
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
    
    /// The execution block.
    func call(arguments: Arguments) async throws -> String

    /// Multimodal execution: returns text output + optional media artifacts.
    /// Default implementation wraps `call()` for backward compatibility.
    func execute(arguments: Arguments) async throws -> (output: String, artifacts: [MediaArtifact])
}

extension AgentToolProtocol {
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

    /// The closure to execute the tool.
    /// Takes JSON Data (arguments) and returns text output + optional media artifacts.
    let run: @Sendable (Data) async throws -> (output: String, artifacts: [MediaArtifact])

    // [HITL] Updated Init with default for backward compatibility
    init(
        name: String,
        description: String,
        parameters: ToolParameters,
        requiresConfirmation: Bool = false,
        run: @escaping @Sendable (Data) async throws -> (output: String, artifacts: [MediaArtifact])
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.requiresConfirmation = requiresConfirmation
        self.run = run
    }

    /// Convenience init for text-only tools (backward compatibility).
    init(
        name: String,
        description: String,
        parameters: ToolParameters,
        requiresConfirmation: Bool = false,
        textOnlyRun: @escaping @Sendable (Data) async throws -> String
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.requiresConfirmation = requiresConfirmation
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
    case timedOut(toolName: String, duration: TimeInterval)
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
        case .timedOut(let toolName, let duration):
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
struct AgentInput: Sendable {
    let userInput: String

    /// Multimodal user input (images, audio, etc.). Nil for text-only messages.
    let userPayload: Payload?

    // NOTE: Used ONLY by ChatExecutor (Bots). ReActAgentExecutor completely ignores this
    // to enforce the "Zero-History Context" architecture.
    let chatHistory: [ChatMessage]

    let conversationID: UUID
    let tools: [AgentTool]
    let longTermMemory: any LongTermMemoryStrategy

    // Architecture: Split-State (Active State + History)
    let activeState: SessionGraph?
    let recentHistory: String?

    // [Step 3 Architecture Update]
    let generatorStrategy: any CognitiveGenerator
    let workingMemory: any WorkingMemoryStrategy

    // [Phase 2 Rate Limiting]
    // The specific quota profile to enforce for this execution
    let rateLimitCategory: RateLimitCategory

    let instructions: String?

    // The Trace Context for distributed observability
    let traceContext: TraceContext

    /// Resolved input: multimodal if available, text fallback otherwise.
    var resolvedPayload: Payload {
        userPayload ?? [.text(userInput)]
    }

    /// Computed Compatibility Layer
    var persistentMemory: String? {
        guard let state = activeState else { return nil }
        let history = recentHistory ?? "(No recent history)"
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonString = (try? String(data: encoder.encode(state), encoding: .utf8)) ?? "{}"

        return """
        ## 🧠 UNIFIED HIERARCHICAL STATE (FULL GRAPH)
        ```json
        \(jsonString)
        ```

        ## 📜 RECENT ACTIVITY
        \(history)
        """
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
        workingMemory: (any WorkingMemoryStrategy)? = nil,
        rateLimitCategory: RateLimitCategory = .geminiFlash, // Default to strict for safety
        instructions: String? = nil,
        traceContext: TraceContext
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
        self.workingMemory = workingMemory ?? HighContextLinearMemory()
        self.rateLimitCategory = rateLimitCategory

        self.instructions = instructions
        self.traceContext = traceContext
    }
}

// MARK: - Semantic Context Models

struct EnvironmentFacts: Sendable {
    let osVersion: String
    let shellType: String
    let userName: String
    let currentDate: String
}

struct SemanticContext: Sendable {
    // 1. System & Identity
    let instructions: String?
    let environmentFacts: EnvironmentFacts
    
    // 2. Memory & Long-Term State
    let longTermMemory: any LongTermMemoryStrategy
    let compressedStateGraph: String
    let recentHistory: String?
    
    // 3. Current Execution State
    let originalQuery: String
    let currentIteration: Int
    let compiledScratchpad: String
    let latestClarification: String?
    
    // 4. Guardrails & Circuit Breakers
    let negativeConstraints: Set<String>
    let hallucinatedTools: Set<String>
    
    // 5. Capabilities
    let availableTools: [AgentTool]
}

// MARK: - Plan & Execute Models

struct SubTask: Sendable, Codable, Identifiable {
    let id: String
    let description: String
    let toolHint: String?
    var status: SubTaskStatus
    var result: String?
    var dependsOn: [String]?

    init(id: String = UUID().uuidString, description: String, toolHint: String? = nil, status: SubTaskStatus = .pending, result: String? = nil, dependsOn: [String]? = nil) {
        self.id = id
        self.description = description
        self.toolHint = toolHint
        self.status = status
        self.result = result
        self.dependsOn = dependsOn
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

// MARK: - Supervisor Models

struct WorkerTask: Sendable, Identifiable {
    let id: String
    let workerRole: String
    let instruction: String
    let assignedTools: [AgentTool]

    init(id: String = UUID().uuidString, workerRole: String, instruction: String, assignedTools: [AgentTool]) {
        self.id = id
        self.workerRole = workerRole
        self.instruction = instruction
        self.assignedTools = assignedTools
    }
}

struct WorkerResult: Sendable {
    let workerId: String
    let workerRole: String
    let output: String
    let isSuccess: Bool
    let toolsUsed: [String]
}
