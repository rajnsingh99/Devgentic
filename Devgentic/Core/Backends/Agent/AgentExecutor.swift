//
//  AgentExecutor.swift
//  Devgentic
//
//  Created by Raj Singh on 28/01/26.
//

import Foundation
import SwiftAgent


// MARK: - Agent Executor Protocol

/// The contract that all Agent Architectures (ReAct, Plan & Execute, etc.) must fulfill.
protocol AgentExecutor: Sendable {

    var architecture: AgentArchitecture { get }

    // Returns AgentStreamEvent for UI consumption
    func execute(
        model: any LLMProvider,
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
