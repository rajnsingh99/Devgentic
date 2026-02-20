//
//  AgentStructModel.swift
//  Devgentic
//
//  Created by Raj Singh on 02/02/26.
//

import Foundation

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


// MARK: - Execution Input

/// The standard payload required to initialize any Agent Executor.
struct AgentInput: Sendable {
    let userInput: String
    let chatHistory: [ChatMessage]
    let conversationID: UUID
    let tools: [AgentTool]
    let ragContext: String?

    // Architecture: Split-State (Active State + History)
    let activeState: MutableActiveState?
    let recentHistory: String?

    // Execution Context Flag
    let isNewRequest: Bool

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

        return """
        ## 🧠 ACTIVE MEMORY (RAM)
        Status: \(state.subTasks.first(where: { $0.status == "active" })?.description ?? "Idle")

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
        activeState: MutableActiveState? = nil,
        recentHistory: String? = nil,
        isNewRequest: Bool = true,
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
        self.isNewRequest = isNewRequest

        self.generatorStrategy = generatorStrategy ?? NativeStructuredGenerator()
        self.rateLimitCategory = rateLimitCategory

        self.instructions = instructions
        self.traceContext = traceContext
    }
}
