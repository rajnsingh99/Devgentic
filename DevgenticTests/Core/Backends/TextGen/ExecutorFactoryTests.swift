//
//  ExecutorFactoryTests.swift
//  DevgenticTests
//
//  Pins ExecutorFactory's profileType → executor routing, specifically that
//  configured execution limits actually reach the executor. Regression for the
//  .code fallthrough bug: ProfileType.code had no factory case, fell through
//  @unknown default to a bare ReActAgentExecutor(), and silently capped every
//  Code run at the default 15 iterations while the profile carried 20.
//

import XCTest
@testable import devgentic

final class ExecutorFactoryTests: XCTestCase {

    private func makeAgentConfig(maxIterations: Int?) -> AgentConfig {
        AgentConfig(
            llmConfig: ProviderConfig(apiProvider: .mlx, modelName: "test-model"),
            tools: [],
            maxIterations: maxIterations,
            executionTimeout: 300,
            retryPolicy: RetryPolicy(maxRetries: 3, backoffStrategy: .exponential),
            errorRecovery: ErrorRecovery(
                onToolFailure: .fallbackPrompt,
                onIterationExhaustion: .synthesizeBestEffort
            ),
            capabilities: AgentCapabilities(),
            historyStrategy: .pointer
        )
    }

    // MARK: - Code Profile (the regression)

    /// Pre-fix this failed: .code hit @unknown default → bare executor → 15.
    func testCodeProfile_ThreadsConfiguredMaxIterations() {
        let profile = BackendProfileSnapshot(
            displayName: "Code Session",
            details: .code(makeAgentConfig(maxIterations: 20)),
            fileContextStrategy: .stateless
        )
        let executor = ExecutorFactory.create(for: profile)
        let react = executor as? ReActAgentExecutor
        XCTAssertNotNil(react, "Code profiles must run the plain ReAct executor")
        XCTAssertEqual(react?.maxIterations, 20, "Configured Code max-steps must reach the executor")
    }

    func testCodeProfile_NilMaxIterations_DefaultsTo15() {
        let profile = BackendProfileSnapshot(
            displayName: "Code Session",
            details: .code(makeAgentConfig(maxIterations: nil)),
            fileContextStrategy: .stateless
        )
        let react = ExecutorFactory.create(for: profile) as? ReActAgentExecutor
        XCTAssertEqual(react?.maxIterations, 15)
    }

    // MARK: - Agent Profile (baseline, already worked)

    func testAgentProfile_ThreadsConfiguredMaxIterations() {
        let profile = BackendProfileSnapshot(
            displayName: "Agent",
            details: .agent(makeAgentConfig(maxIterations: 40)),
            fileContextStrategy: .stateless
        )
        let react = ExecutorFactory.create(for: profile) as? ReActAgentExecutor
        XCTAssertNotNil(react)
        XCTAssertEqual(react?.maxIterations, 40)
    }
}
