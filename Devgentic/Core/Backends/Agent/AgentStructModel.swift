//
//  AgentStructModel.swift
//  Devgentic
//
//  Created by Raj Singh on 02/02/26.
//

import Foundation
import OpenFoundationModels
import OpenFoundationModelsCore

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
}

// MARK: - Tool Abstraction

/// A type-erased wrapper for tools to decouple the executor from specific library generics.
/// This allows the executor to run any tool given a JSON string or Data.
struct AgentTool: Sendable {
    let name: String
    let description: String
    let parameters: OpenFoundationModelsCore.GenerationSchema
    
    /// The closure to execute the tool.
    /// Takes JSON Data (arguments) and returns a String (output).
    let run: @Sendable (Data) async throws -> String
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
    // Instead of a monolithic string, we now pass structured state + paged history.
    let activeState: MutableActiveState?
    let recentHistory: String?
    
    // Execution Context Flag
    // Signals that this execution is the start of a fresh user turn.
    let isNewRequest: Bool
    
    // [Step 3 Architecture Update]
    // Replaced provider-specific flags (e.g., `isGemini`) with a polymorphic strategy.
    // This allows the Executor to remain agnostic of the underlying provider quirks.
    let generatorStrategy: any CognitiveGenerator
    
    let instructions: String?
    
    // The Trace Context for distributed observability
    let traceContext: TraceContext
    
    /// Computed Compatibility Layer
    /// Allows legacy executors or simple Chat bots to access a text representation of the memory.
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
        
        // Default to NativeStructuredGenerator (OpenAI behavior) if no specific strategy is provided.
        // This ensures backward compatibility for tests or simple bots.
        self.generatorStrategy = generatorStrategy ?? NativeStructuredGenerator()
        
        self.instructions = instructions
        self.traceContext = traceContext
    }
}
