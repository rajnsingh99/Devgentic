// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ReflexionValidationTests.swift
//  DevgenticTests
//
//  Red-green validation tests for SelfReflectionCapability production fixes.
//  Each test targets a specific gap ID from the validation plan.
//
//  G1: .toolOutput events now captured in trialSummary (not silently dropped)
//  G2: CompletionStatus now reflects actual tool outcomes (not always .partialSuccess)
//  G3: Episode duplication prevented via suppressEpisodeManagement
//

import XCTest
@testable import devgentic

@MainActor
final class ReflexionValidationTests: XCTestCase {

    // MARK: - Helpers

    private func makeReflexionExecutor(maxTrials: Int = 2, maxIterations: Int = 5) -> any Executor {
        let innerExecutor = ReActAgentExecutor(maxIterations: maxIterations)
        let config = SelfReflectionConfig(maxTrials: maxTrials)
        return SelfReflectionCapability(config: config).wrap(innerExecutor)
    }

    private func makeReflectionResponse(acceptable: Bool, critique: String = "Needs work.") -> String {
        "VERDICT: \(acceptable ? "PASS" : "RETRY")\nCRITIQUE: \(critique)"
    }

    // MARK: - G1: Tool Results Visible to Reflection Evaluator

    func testG1_ToolResults_VisibleToReflectionEvaluator() async throws {
        // Before fix: ReflectionEvaluator always saw "No tools were executed."
        // After fix: The reflection prompt should contain actual tool names and status.
        let tool = TestToolFactory.make(name: "run_tests", output: "All 42 tests passed.")

        let provider = MockLLMProvider(
            steps: [
                // Trial 1: use tool → terminate
                ModernCognitiveStep(
                    reasoning: "Running the test suite.",
                    toolCalls: [TestToolCallFactory.make(name: "run_tests", input: "all")]
                ),
                ModernCognitiveStep(reasoning: "Tests passed."),
                // Trial 2 (after rejection): terminate immediately
                ModernCognitiveStep(reasoning: "Confirmed: all tests pass.")
            ],
            generateResponses: [
                // Reflection after trial 1: rejected (to force inspection of the prompt)
                makeReflectionResponse(acceptable: false, critique: "Need to also check coverage.")
            ]
        )

        let executor = makeReflexionExecutor(maxTrials: 2)
        let input = TestAgentInputFactory.make(query: "Run and verify tests", tools: [tool])

        let stream = executor.execute(model: provider, input: input) { _ in }
        let _ = try await StreamCollector.collect(from: stream)

        // The reflection evaluator calls model.generate() with tool results in the prompt.
        // Check receivedGenerateMessages[0] (the reflection call) for tool data.
        XCTAssertGreaterThanOrEqual(provider.receivedGenerateMessages.count, 1,
                                    "Reflection evaluator should have made at least 1 generate call")

        let reflectionPrompt = provider.receivedGenerateMessages[0]
            .compactMap { $0["content"] }
            .joined(separator: " ")

        // G1 assertion: tool name should appear in the reflection prompt
        XCTAssertTrue(reflectionPrompt.contains("run_tests"),
                      "Reflection prompt should contain the tool name (G1: tool results captured)")

        // Should NOT contain the old "No tools were executed" fallback
        XCTAssertFalse(reflectionPrompt.contains("No tools were executed"),
                       "Reflection prompt should NOT say 'No tools were executed' when tools ran (G1)")
    }

    // MARK: - G2: CompletionStatus Reflects Actual Outcome

    func testG2_CompletionStatus_CorrectWhenToolsSucceed() async throws {
        // Before fix: Status was always "partialSuccess" because toolResults was empty.
        // After fix: Status should be "success" when all tools succeed.
        let tool = TestToolFactory.make(name: "deploy", output: "Deployed successfully.")

        let provider = MockLLMProvider(
            steps: [
                // Trial 1: deploy → terminate
                ModernCognitiveStep(
                    reasoning: "Deploying.",
                    toolCalls: [TestToolCallFactory.make(name: "deploy", input: "prod")]
                ),
                ModernCognitiveStep(reasoning: "Deployment complete."),
                // Trial 2 (won't be reached if accepted)
                ModernCognitiveStep(reasoning: "Done.")
            ],
            generateResponses: [
                // Rejection to force examination of the prompt
                makeReflectionResponse(acceptable: false, critique: "Needs verification.")
            ]
        )

        let executor = makeReflexionExecutor(maxTrials: 2)
        let input = TestAgentInputFactory.make(query: "Deploy to production", tools: [tool])

        let stream = executor.execute(model: provider, input: input) { _ in }
        let _ = try await StreamCollector.collect(from: stream)

        let reflectionPrompt = provider.receivedGenerateMessages[0]
            .compactMap { $0["content"] }
            .joined(separator: " ")

        // G2 assertion: status should reflect actual tool success
        XCTAssertTrue(
            reflectionPrompt.contains("success") || reflectionPrompt.contains("Success"),
            "Reflection prompt should indicate success status when all tools succeeded (G2)"
        )
        XCTAssertFalse(
            reflectionPrompt.contains("partialSuccess") || reflectionPrompt.contains("stalled"),
            "Status should NOT be partialSuccess/stalled when tools succeeded (G2)"
        )
    }

    // MARK: - G1: Tool Output Events Forwarded to Outer Stream

    func testG1_ToolOutputEvents_ForwardedToOuterStream() async throws {
        // Before fix: .toolOutput events from inner executor were silently dropped.
        // After fix: They should be forwarded to the outer Reflexion stream.
        let tool = TestToolFactory.make(name: "scan", output: "Scan complete: 0 vulnerabilities.")

        let provider = MockLLMProvider(
            steps: [
                ModernCognitiveStep(
                    reasoning: "Scanning.",
                    toolCalls: [TestToolCallFactory.make(name: "scan", input: "all")]
                ),
                ModernCognitiveStep(reasoning: "Clean scan.")
            ],
            generateResponses: [
                makeReflectionResponse(acceptable: true, critique: "All clear.")
            ]
        )

        let executor = makeReflexionExecutor(maxTrials: 2)
        let input = TestAgentInputFactory.make(query: "Security scan", tools: [tool])

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        // G1 assertion: .toolOutput events should be present in the outer stream
        let toolOutputs = StreamCollector.toolOutputs(from: events)
        XCTAssertGreaterThan(toolOutputs.count, 0,
                             "Reflexion stream should forward .toolOutput events from inner executor (G1)")
        XCTAssertEqual(toolOutputs[0].toolName, "scan")
        XCTAssertTrue(toolOutputs[0].isSuccess)
    }
}
