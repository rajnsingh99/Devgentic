//
//  AgentStructModel.swift
//  Devgentic
//
//  Created by Raj Singh on 02/02/26.
//

import Foundation

// MARK: - Cognitive Context Manager (Phase 1)

/// Represents a single observation step in the agent's volatile memory.
/// Replaces the old string-based scratchpad to support hydration/eviction and prevent context overflows.
struct CognitiveObservation: Sendable, Codable {
    let stepId: Int
    let toolName: String
    let shortObservation: String
    let heavyContent: String? 
    var isRequired: Bool
}

// MARK: - Cognitive Definitions (Native Tool Calling Parity)

/// The new, streamlined schema for ReAct loops, mirroring Native Tool Calling API payloads.
/// Replaces the old, heavy CognitiveStep.
struct LeanCognitiveStep: Sendable, Codable {
    /// The agent's reasoning, mapped directly to Native API 'content' blocks.
    let content: String
    
    /// The tool to execute. If nil, empty, or "null", the loop terminates.
    let toolName: String?
    
    /// The arguments for the tool. Required if toolName is present.
    let arguments: [String: AnyCodable]?
    
    enum CodingKeys: String, CodingKey {
        case content
        case toolName = "tool_name"
        case arguments
    }
}

// MARK: - Agent State Definitions

/// Represents the high-level state of the agent in its cognitive loop.
/// Used for tracing and UI feedback (e.g., "Thinking...", "Executing Tool...").
enum AgentStep: String, Codable, Sendable {
    case idle           = "Idle"
    case thinking       = "Reasoning"      // The agent is generating thoughts
    case deciding       = "Deciding"       // The agent is determining which tool to use
    case acting         = "Acting"         // The agent is executing a tool
    case observing      = "Observing"      // The agent is processing the tool output
    case finalizing     = "Finalizing"     // The agent is generating the final answer
    case errorRecovery  = "Recovering"     // The agent encountered an error and is self-correcting

    // [HITL] Phase 1: New State for Tool Gating
    case requestingPermission = "Awaiting Permission" // The agent is waiting for user approval
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
            propsDict[key] = ToolParameterProperty(type: type, description: desc)
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
    /// Takes JSON Data (arguments) and returns a String (output).
    let run: @Sendable (Data) async throws -> String

    // [HITL] Updated Init with default for backward compatibility
    init(
        name: String,
        description: String,
        parameters: ToolParameters,
        requiresConfirmation: Bool = false,
        run: @escaping @Sendable (Data) async throws -> String
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.requiresConfirmation = requiresConfirmation
        self.run = run
    }
}

// MARK: - Tool Execution Results

/// Represents the definitive outcome of a tool execution attempt.
enum ToolExecutionResult: Sendable, Equatable {
    case success(output: String)
    case hallucinated(toolName: String, availableTools: [String])
    case userDenied(toolName: String)
    case timedOut(toolName: String, duration: TimeInterval)
    case semanticFailure(toolName: String, output: String) // E.g., null, empty, or explicit CLI errors
    case systemError(reason: String)
    
    /// The string representation that should be fed back to the LLM as an Observation.
    var llmObservation: String {
        switch self {
        case .success(let output):
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
    
    // NOTE: Used ONLY by ChatExecutor (Bots). ReActAgentExecutor completely ignores this
    // to enforce the "Zero-History Context" architecture.
    let chatHistory: [ChatMessage]
    
    let conversationID: UUID
    let tools: [AgentTool]
    let ragContext: String?

    // Architecture: Split-State (Active State + History)
    let activeState: SessionGraph?
    let recentHistory: String?

    // [Step 3 Architecture Update]
    let generatorStrategy: any CognitiveGenerator

    // [Phase 2 Rate Limiting]
    // The specific quota profile to enforce for this execution
    let rateLimitCategory: RateLimitCategory

    let instructions: String?

    // The Trace Context for distributed observability
    let traceContext: TraceContext

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
        chatHistory: [ChatMessage],
        conversationID: UUID,
        tools: [AgentTool],
        ragContext: String? = nil,
        activeState: SessionGraph? = nil,
        recentHistory: String? = nil,
        generatorStrategy: (any CognitiveGenerator)? = nil,
        rateLimitCategory: RateLimitCategory = .geminiFlash, // Default to strict for safety
        instructions: String? = nil,
        traceContext: TraceContext
    ) {
        self.userInput = userInput
        self.chatHistory = chatHistory
        self.conversationID = conversationID
        self.tools = tools
        self.ragContext = ragContext
        self.activeState = activeState
        self.recentHistory = recentHistory

        self.generatorStrategy = generatorStrategy ?? NativeStructuredGenerator()
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
    let compressedStateGraph: String
    let recentHistory: String?
    
    // 3. Current Execution State
    let originalQuery: String
    let currentIteration: Int
    let activeObservations: [CognitiveObservation]
    let latestClarification: String?
    
    // 4. Guardrails & Circuit Breakers
    let negativeConstraints: Set<String>
    let hallucinatedTools: Set<String>
    
    // 5. Capabilities
    let availableTools: [AgentTool]
}
