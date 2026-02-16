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


// MARK: - Agent Executor Protocol

/// The contract that all Agent Architectures (ReAct, Plan & Execute, etc.) must fulfill.
protocol AgentExecutor: Sendable {
    
    var architecture: AgentArchitecture { get }
    
    // Returns AgentStreamEvent for UI consumption
    func execute(
        model: any OpenFoundationModels.LanguageModel,
        input: AgentInput,
        onTraceUpdate: @escaping @Sendable (AgentTraceLog) -> Void
    ) -> AsyncThrowingStream<AgentStreamEvent, Error>
}

// MARK: - Agent Executor Factory

/// The centralized factory for instantiating Agent Executors.
/// Determines the execution strategy (Simple Chat vs. Agentic Loop) based on the profile configuration.
enum AgentExecutorFactory {
    
    /// Creates the appropriate AgentExecutor for the given profile.
    /// - Parameter profile: The backend profile model containing configuration details.
    /// - Returns: A type-erased `AgentExecutor` (either `ChatExecutor` or `ReActAgentExecutor`).
    static func create(for profile: BackendProfileModel) -> any AgentExecutor {
        switch profile.profileType {
            
        case .bot:
            // Bots use the simple pass-through executor.
            // They don't plan, reason, or use tools in a loop.
            return ChatExecutor()
            
        case .agent:
            // Agents use the ReAct (Reasoning + Acting) loop.
            // They can use tools, generate thoughts, and execute complex plans.
            return ReActAgentExecutor()
            
        case .workflow:
            // Future extensibility for Workflow profiles.
            // For now, we fallback to ReAct as it is the most capable.
            return ReActAgentExecutor()
            
        @unknown default:
            // Safety fallback for future enum cases
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
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            
            // FIX: Unwraps the generated content to simple dictionary before encoding.
            // This prevents passing the internal library wrapper (e.g. "structure": { ... }) to the tool.
            let unwrappedAny = ReActNativeToolWrapper.unwrap(content: content)
            
            // If the unwrapped content is already a dictionary, we are good.
            // If it's a primitive (unlikely for tool args), we wrap it in a dict or encode as is.
            if let dict = unwrappedAny as? [String: Any] {
                // We must use JSONSerialization for [String: Any] as it's not Encodable
                self.rawData = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
            } else {
                // Fallback: Try to encode the unwrapped value if possible, or the content itself if all else fails
                // This handles edge cases where the model returns a single string argument
                if let stringVal = unwrappedAny as? String {
                     // Some tools might accept a single string, but usually tools expect JSON objects.
                     // We try to wrap it if it looks like a single arg tool, but for now let's strict encode.
                     self.rawData = try JSONEncoder().encode([stringVal])
                } else {
                     self.rawData = try encoder.encode(content)
                }
            }
        }
    }
    
    typealias Output = String
    
    func call(arguments: Arguments) async throws -> String {
        return try await agentTool.run(arguments.rawData)
    }
    
    // MARK: - Recursive Unwrapper Helper
    
    /// Recursively converts `GeneratedContent` (Structure, Array, Primitives) into Swift native types (`[String: Any]`, `[Any]`, `String`, etc.).
    /// This is critical because `JSONEncoder().encode(GeneratedContent)` encodes the *enum metadata*, not the JSON value.
    private static func unwrap(content: OpenFoundationModelsCore.GeneratedContent) -> Any? {
        // Updated to match the specific `GeneratedContent.Kind` definition provided in the file.
        // - Integers are covered by .number(Double)
        // - Structure has two associated values (properties, orderedKeys)
        // - No .blob or .integer cases exist
        
        switch content.kind {
        case .structure(let properties, _):
            var dict: [String: Any] = [:]
            for (key, value) in properties {
                if let unwrappedValue = unwrap(content: value) {
                    dict[key] = unwrappedValue
                }
            }
            return dict
            
        case .array(let items):
            return items.compactMap { unwrap(content: $0) }
            
        case .string(let value):
            return value
            
        case .number(let value):
            // The model uses Double for all numbers.
            // JSONSerialization will handle writing this correctly as a number.
            return value
            
        case .bool(let value):
            return value
            
        case .null:
            return nil
            
        // Removed .blob, .integer, .double as they are not members of the provided Kind enum.
        @unknown default:
            return nil
        }
    }
}
