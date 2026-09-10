// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  AgentExecutor.swift
//  Devgentic
//
//  Created by Raj Singh on 28/01/26.
//

import Foundation


// MARK: - Agent Executor Protocol

/// The contract that all Agent Executors (ReAct, Plan & Execute, etc.) must fulfill.
protocol Executor: Sendable {

    /// A human-readable label for logging (e.g. "ReAct", "Planning → ReAct").
    var executorLabel: String { get }

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
    /// Creates the appropriate executor for the given profile.
    /// Agent profiles always start with ReAct, then stack capability decorators.
    /// Delegation is NOT a wrapper — it's a tool (handled in AgentConnect.resolveExecutableTools).
    static func create(for profile: BackendProfileModel) -> any Executor {
        switch profile.profileType {

        case .bot:
            return ChatExecutor()

        case .agent:
            guard case .agent(let config) = profile.details else {
                return ReActAgentExecutor()
            }

            // Core executor — always ReAct
            var executor: any Executor = ReActAgentExecutor(
                maxIterations: config.maxIterations ?? AgentExecutionDefaults.maxIterations
            )

            // Stack capabilities as decorators
            if let planning = config.capabilities.planning {
                executor = PlanningCapability(config: planning).wrap(executor)
            }

            if let reflection = config.capabilities.selfReflection {
                executor = SelfReflectionCapability(config: reflection).wrap(executor)
            }

            // Agent Delegation is NOT an executor wrapper — it's a tool
            // (handled in AgentConnect.resolveExecutableTools)

            return executor

        case .code:
            // Code mode runs the plain ReAct loop with the profile's configured
            // limits (CodeSessionManager builds the session profile with
            // maxIterations: 20). No capability decorators — Code doesn't stack
            // Planning/Reflexion. Before this case existed, .code fell through
            // @unknown default to a bare ReActAgentExecutor(), silently capping
            // every Code run at the default 15 iterations.
            guard case .code(let config) = profile.details else {
                return ReActAgentExecutor()
            }
            return ReActAgentExecutor(maxIterations: config.maxIterations ?? AgentExecutionDefaults.maxIterations)

        case .workflow:
            return WorkflowExecutor()

        case .imageGen:
            return ChatExecutor()

        @unknown default:
            return ReActAgentExecutor()
        }
    }
}
