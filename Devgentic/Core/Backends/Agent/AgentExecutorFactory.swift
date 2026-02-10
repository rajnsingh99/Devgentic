//
//  AgentExecutorFactory.swift
//  Devgentic
//
//  Created by Raj Singh on 07/02/26.
//

import Foundation
import SwiftAgent

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
        }
    }
}
