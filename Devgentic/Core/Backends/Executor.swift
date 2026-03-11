//
//  AgentExecutor.swift
//  Devgentic
//
//  Created by Raj Singh on 28/01/26.
//

import Foundation


// MARK: - Agent Executor Protocol

/// The contract that all Agent Architectures (ReAct, Plan & Execute, etc.) must fulfill.
protocol Executor: Sendable {

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
enum ExecutorFactory {

    /// Creates the appropriate AgentExecutor for the given profile.
    /// - Parameter profile: The backend profile model containing configuration details.
    /// - Returns: A type-erased `AgentExecutor` (either `ChatExecutor` or `ReActAgentExecutor`).
    static func create(for profile: BackendProfileModel) -> any Executor {
        switch profile.profileType {

        case .bot:
            // Bots use the simple pass-through executor.
            // They don't plan, reason, or use tools in a loop.
            return ChatExecutor()

        case .agent:
            // Route to the correct architecture based on the profile's configuration.
            let architecture: AgentArchitecture
            if case .agent(_, let arch, _, _, _, _) = profile.details {
                architecture = arch
            } else {
                architecture = .reAct
            }
            switch architecture {
            case .reAct:
                return ReActAgentExecutor()
            case .planAndExecute:
                return ReActAgentExecutor()
            case .reflexion:
                return ReActAgentExecutor()
            case .supervisor:
                return ReActAgentExecutor()
            }

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
