//
//  CapabilityCompositionTests.swift
//  DevgenticTests
//
//  Tests for stacking Planning + Self-Reflection capabilities.
//  Verifies that the decorator pattern works when both capabilities
//  wrap the same inner ReActAgentExecutor.
//
//  KNOWN LIMITATION (as of Build 98.9):
//  Both PlanningExecutorWrapper and SelfReflectionExecutorWrapper assert that their
//  innerExecutor is ReActAgentExecutor. This means they CANNOT be composed — stacking
//  Planning(Reflection(ReAct)) or Reflection(Planning(ReAct)) will hit an assertion failure.
//
//  These tests verify each capability individually with different configurations.
//  Composition support requires relaxing the inner-executor assertion to accept any Executor.
//

import XCTest
@testable import devgentic

final class CapabilityCompositionTests: XCTestCase {

    // MARK: - Helpers

    // MARK: - Test 1: Planning with Non-Default Config

    func testPlanning_WithToolFilteringAndMaxSubtasks_ExecutesCorrectly() async throws {
        // Planning with maxSubtasks=2, subtaskToolFiltering=true, parallel=false
        // Verifies all config fields flow through execution.
        let tool = TestToolFactory.make(name: "analyze", output: "Analysis complete")

        let plan = """
        1. Analyze the data [analyze]
        2. Summarize findings
        """

        let provider = MockLLMProvider(
            steps: [
                // Subtask 1, ReAct: tool call + terminate
                ModernCognitiveStep(
                    reasoning: "Analyzing data.",
                    toolCalls: [TestToolCallFactory.make(name: "analyze", input: "dataset")]
                ),
                ModernCognitiveStep(reasoning: "Analysis shows positive trend."),
                // Subtask 2, ReAct: no tools, just answer
                ModernCognitiveStep(reasoning: "Summary: The data shows a positive trend in Q1.")
            ],
            generateResponses: [plan]
        )

        let config = PlanningCapabilityConfig(
            maxSubtasks: 2,
            parallelSubtasks: false,
            subtaskToolFiltering: true,
            requiresPlanApproval: false
        )
        let inner = ReActAgentExecutor(maxIterations: 5)
        let executor = PlanningCapability(config: config).wrap(inner)

        let input = TestAgentInputFactory.make(query: "Analyze the dataset", tools: [tool])
        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        // Should produce final content
        let content = StreamCollector.contentText(from: events)
        XCTAssertFalse(content.isEmpty, "Should produce final content")

        // Should show planning thoughts (2 subtasks, 2 levels)
        let thoughts = StreamCollector.thoughts(from: events)
        let hasPlanningThought = thoughts.contains {
            $0.contains("Plan") || $0.contains("plan") || $0.contains("level") || $0.contains("Subtask")
        }
        XCTAssertTrue(hasPlanningThought, "Should show planning activity")

        // Tool should have been called
        let toolOutputs = StreamCollector.toolOutputs(from: events)
        XCTAssertFalse(toolOutputs.isEmpty, "Tool should have been called")
    }

    // MARK: - Test 2: Reflection with Multiple Trials

    func testReflection_WithMaxTrials_RejectsAndRetries() async throws {
        // Reflection wrapping ReAct, maxTrials=2.
        // Trial 1: ReAct calls tool + terminates → Reflection rejects
        // Trial 2: ReAct calls tool + terminates → last trial, no reflection
        let tool = TestToolFactory.make(name: "compute", output: "Result: 42")

        // Reflection rejects trial 1
        let reflectionReject = """
        VERDICT: RETRY
        CRITIQUE: Incomplete.
        REVISION: Add variance.
        """

        let provider = MockLLMProvider(
            steps: [
                // Trial 1: tool call + terminate
                ModernCognitiveStep(
                    reasoning: "Computing...",
                    toolCalls: [TestToolCallFactory.make(name: "compute", input: "v1")]
                ),
                ModernCognitiveStep(reasoning: "First attempt."),
                // Trial 2: tool call + terminate
                ModernCognitiveStep(
                    reasoning: "Computing with variance...",
                    toolCalls: [TestToolCallFactory.make(name: "compute", input: "v2")]
                ),
                ModernCognitiveStep(reasoning: "Improved result.")
            ],
            generateResponses: [reflectionReject]
        )

        let inner = ReActAgentExecutor(maxIterations: 5)
        let executor = SelfReflectionCapability(
            config: SelfReflectionConfig(maxTrials: 2)
        ).wrap(inner)

        let input = TestAgentInputFactory.make(query: "Compute statistics", tools: [tool])
        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        // Should produce content from trial 2
        let content = StreamCollector.contentText(from: events)
        XCTAssertFalse(content.isEmpty, "Should produce final content")

        // Should have reflection/trial activity — STRUCTURED events now (the reflection
        // card consumes them); the old narrative thoughts were removed as duplicates.
        let trialsStarted = events.compactMap { event -> Int? in
            if case .reflectionTrialStarted(let trial, _) = event { return trial }
            return nil
        }
        XCTAssertEqual(trialsStarted, [1, 2], "Both trials should start (trial 2 after rejection)")
        let hasRetry = events.contains { if case .reflectionRetrying = $0 { return true }; return false }
        XCTAssertTrue(hasRetry, "Trial 1's rejection should emit reflectionRetrying with the critique")

        // Should have tool calls from trials
        let toolOutputs = StreamCollector.toolOutputs(from: events)
        XCTAssertGreaterThanOrEqual(toolOutputs.count, 1, "Should have tool calls from trials")
    }
}
