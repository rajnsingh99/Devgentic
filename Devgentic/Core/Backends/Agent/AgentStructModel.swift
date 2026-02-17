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
    
    // [HITL] Phase 1: New State for Tool Gating
    case requestingPermission = "Awaiting Permission" // The agent is waiting for user approval
}

// MARK: - Tool Abstraction

/// A type-erased wrapper for tools to decouple the executor from specific library generics.
/// This allows the executor to run any tool given a JSON string or Data.
struct AgentTool: Sendable {
    let name: String
    let description: String
    let parameters: OpenFoundationModelsCore.GenerationSchema
    
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
        parameters: OpenFoundationModelsCore.GenerationSchema,
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
