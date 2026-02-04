//
//  AgentExecutor.swift
//  Devgentic
//
//  Created by Raj Singh on 28/01/26.
//

import Foundation
import SwiftAgent
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

// MARK: - Trace Logging

/// A structured record of a single step in the agent's execution trajectory.
/// Captures the raw "Thought -> Action -> Observation" chain for debugging and transparency.
struct AgentTraceLog: Identifiable, Codable, Sendable {
    let id: UUID
    let stepNumber: Int
    let timestamp: Date
    let state: AgentStep
    
    /// The content of the trace.
    let content: String
    
    /// Optional metadata for advanced debugging (e.g., execution time, tool name).
    let metadata: [String: String]?
    
    init(
        id: UUID = UUID(),
        stepNumber: Int,
        state: AgentStep,
        content: String,
        metadata: [String: String]? = nil
    ) {
        self.id = id
        self.stepNumber = stepNumber
        self.timestamp = Date()
        self.state = state
        self.content = content
        self.metadata = metadata
    }
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
// In AgentExecutor.swift

struct AgentInput: Sendable {
    let userInput: String
    let chatHistory: [ChatMessage]
    let conversationID: UUID
    let tools: [AgentTool]
    let ragContext: String?
    let instructions: String?
    
    // NEW: The "Checklist" from the Manager
    let approvedPlan: ExecutionPlan?
    
    init(
        userInput: String,
        chatHistory: [ChatMessage],
        conversationID: UUID,
        tools: [AgentTool],
        ragContext: String? = nil,
        instructions: String? = nil,
        approvedPlan: ExecutionPlan? = nil // Default to nil for backward compatibility
    ) {
        self.userInput = userInput
        self.chatHistory = chatHistory
        self.conversationID = conversationID
        self.tools = tools
        self.ragContext = ragContext
        self.instructions = instructions
        self.approvedPlan = approvedPlan
    }
}

// MARK: - Agent Executor Protocol

/// The contract that all Agent Architectures (ReAct, Plan & Execute, etc.) must fulfill.
protocol AgentExecutor: Sendable {
    
    var architecture: AgentArchitecture { get }
    
    func execute(
        model: any OpenFoundationModels.LanguageModel,
        input: AgentInput,
        onTraceUpdate: @escaping @Sendable (AgentTraceLog) -> Void
    ) -> AsyncThrowingStream<String, Error>
}

// MARK: - Factory

enum AgentExecutorFactory {
    
    static func create(for architecture: AgentArchitecture) -> any AgentExecutor {
        switch architecture {
        case .reAct:
            return ReActAgentExecutor()
            
        case .planAndExecute, .reflexion, .supervisor:
            return ReActAgentExecutor()
        }
    }
}

// MARK: - Native Tool Wrapper

struct ReActNativeToolWrapper: OpenFoundationModels.Tool {
    let agentTool: AgentTool
    
    var name: String { agentTool.name }
    var description: String { agentTool.description }
    var parameters: OpenFoundationModelsCore.GenerationSchema { agentTool.parameters }
    
    struct Arguments: Codable, OpenFoundationModelsCore.ConvertibleFromGeneratedContent {
        let rawData: Data
        
        init(_ content: OpenFoundationModelsCore.GeneratedContent) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            self.rawData = try encoder.encode(content)
        }
    }
    
    typealias Output = String
    
    func call(arguments: Arguments) async throws -> String {
        return try await agentTool.run(arguments.rawData)
    }
}
