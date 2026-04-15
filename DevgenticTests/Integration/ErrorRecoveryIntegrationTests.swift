//
//  ErrorRecoveryIntegrationTests.swift
//  DevgenticTests
//
//  Integration tests for the 3 ErrorRecovery.onToolFailure modes
//  (.abort, .skipAndContinue, .fallbackPrompt) and circuit breaker behavior.
//
//  Scripts repeated tool failures to trigger CognitiveCircuitBreaker's
//  shouldAbort condition, then verifies each recovery mode's behavior
//  through the real execution pipeline.
//
//  Mock: LLMProvider (scripted steps)
//  Real: ReActAgentExecutor → ToolExecutionLoop → CognitiveCircuitBreaker → WindowedLinearMemory
//

import XCTest
@testable import devgentic

final class ErrorRecoveryIntegrationTests: XCTestCase {

    // MARK: - Helpers

    /// Builds steps that produce N consecutive tool failures followed by a terminal step.
    /// Uses different input values per iteration to avoid per-tool retry limits.
    private func makeFailureSteps(failureCount: Int, toolName: String = "unstable_tool") -> [ModernCognitiveStep] {
        var steps: [ModernCognitiveStep] = []
        for i in 1...failureCount {
            steps.append(ModernCognitiveStep(
                reasoning: "Attempt \(i) to use the tool.",
                toolCalls: [TestToolCallFactory.make(name: toolName, input: "attempt_\(i)")]
            ))
        }
        // Terminal step (reached only when execution continues past failures)
        steps.append(ModernCognitiveStep(reasoning: "Recovered. Here is the answer from available information."))
        return steps
    }

    // MARK: - Test 1: .abort Mode

    func testErrorRecovery_Abort_TerminatesAfterConsecutiveFailures() async throws {
        // Default ToolFailurePolicy is .abort.
        // After maxConsecutiveToolFailures (default 3) consecutive failures,
        // the circuit breaker triggers and the executor terminates with synthesis.
        let failingTool = TestToolFactory.makeFailing(name: "unstable_tool", error: "Service unavailable")

        let provider = MockLLMProvider(steps: makeFailureSteps(failureCount: 5))

        let executor = ReActAgentExecutor(maxIterations: 10)
        let input = TestAgentInputFactory.make(
            query: "Analyze the system",
            tools: [failingTool],
            errorRecovery: ErrorRecovery(onToolFailure: .abort)
        )

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        // Execution should terminate early (not consume all 5 failure steps)
        XCTAssertLessThan(provider.receivedCognitiveMessages.count, 5,
                          "Abort mode should terminate before consuming all failure steps")

        // Should produce content (synthesized best-effort response)
        let content = StreamCollector.contentText(from: events)
        XCTAssertFalse(content.isEmpty, "Abort mode should still produce synthesized content")

        // Should emit circuit breaker thought
        let thoughts = StreamCollector.thoughts(from: events)
        let hasCircuitBreaker = thoughts.contains { $0.contains("Circuit breaker") || $0.contains("circuit breaker") || $0.contains("recovering") || $0.contains("Recovering") }
        XCTAssertTrue(hasCircuitBreaker, "Should emit circuit breaker/recovery thought on abort")
    }

    // MARK: - Test 2: .skipAndContinue Mode

    func testErrorRecovery_SkipAndContinue_ContinuesAfterFailures() async throws {
        // After consecutive failures trigger the circuit breaker,
        // .skipAndContinue resets counters and lets the agent proceed.
        // The agent then reaches the terminal step.
        let failingTool = TestToolFactory.makeFailing(name: "unstable_tool", error: "Service unavailable")

        let provider = MockLLMProvider(steps: makeFailureSteps(failureCount: 3))

        let executor = ReActAgentExecutor(maxIterations: 10)
        let input = TestAgentInputFactory.make(
            query: "Analyze the system",
            tools: [failingTool],
            errorRecovery: ErrorRecovery(onToolFailure: .skipAndContinue)
        )

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        // Should produce content (agent continued and terminated normally)
        let content = StreamCollector.contentText(from: events)
        XCTAssertFalse(content.isEmpty, "SkipAndContinue should produce content after recovery")

        // Should emit skip/continue thought
        let thoughts = StreamCollector.thoughts(from: events)
        let hasSkipThought = thoughts.contains { $0.contains("skipping") || $0.contains("Skipping") || $0.contains("continuing") || $0.contains("skip") }
        XCTAssertTrue(hasSkipThought, "Should emit skip-and-continue thought")

        // The terminal step should have been reached (4th step consumed)
        // 3 failure iterations + at least 1 post-recovery iteration
        XCTAssertGreaterThan(provider.receivedCognitiveMessages.count, 3,
                             "SkipAndContinue should continue execution past the failure threshold")
    }

    // MARK: - Test 3: .fallbackPrompt Mode

    func testErrorRecovery_FallbackPrompt_InjectsCorrectiveAndContinues() async throws {
        // After consecutive failures trigger the circuit breaker,
        // .fallbackPrompt injects a corrective system alert and continues.
        let failingTool = TestToolFactory.makeFailing(name: "unstable_tool", error: "Service unavailable")

        let provider = MockLLMProvider(steps: makeFailureSteps(failureCount: 3))

        let executor = ReActAgentExecutor(maxIterations: 10)
        let input = TestAgentInputFactory.make(
            query: "Analyze the system",
            tools: [failingTool],
            errorRecovery: ErrorRecovery(onToolFailure: .fallbackPrompt)
        )

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        // Should produce content (agent continued after fallback prompt)
        let content = StreamCollector.contentText(from: events)
        XCTAssertFalse(content.isEmpty, "FallbackPrompt should produce content after recovery")

        // Should emit fallback/alternative approach thought
        let thoughts = StreamCollector.thoughts(from: events)
        let hasFallbackThought = thoughts.contains { $0.contains("alternative") || $0.contains("Alternative") || $0.contains("fallback") || $0.contains("different approach") }
        XCTAssertTrue(hasFallbackThought, "Should emit alternative approach thought")

        // The terminal step should have been reached
        XCTAssertGreaterThan(provider.receivedCognitiveMessages.count, 3,
                             "FallbackPrompt should continue execution past the failure threshold")
    }

    // MARK: - Test 3b: .fallbackPrompt with Custom Message

    func testErrorRecovery_FallbackPrompt_CustomMessage_InjectedIntoMemory() async throws {
        // Same as Test 3, but with a custom fallbackMessage.
        // The custom message should appear in the working memory scratchpad
        // (visible via MockCognitiveGenerator which includes scratchpad in messages).
        let failingTool = TestToolFactory.makeFailing(name: "unstable_tool", error: "Service unavailable")
        let customMessage = "Switch to answering from cached knowledge only."

        let provider = MockLLMProvider(steps: makeFailureSteps(failureCount: 3))

        let executor = ReActAgentExecutor(maxIterations: 10)
        let input = TestAgentInputFactory.make(
            query: "Analyze the system",
            tools: [failingTool],
            errorRecovery: ErrorRecovery(onToolFailure: .fallbackPrompt, fallbackMessage: customMessage)
        )

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        // Should produce content
        let content = StreamCollector.contentText(from: events)
        XCTAssertFalse(content.isEmpty, "Custom fallback should produce content")

        // Verify the custom message was injected into working memory.
        // After the circuit breaker fires, the next cognitive step should see
        // the custom fallback message in the scratchpad (which MockCognitiveGenerator
        // includes in the messages sent to the provider).
        let postFailureMessages = provider.receivedCognitiveMessages.dropFirst(3) // skip failure iterations
        let hasCustomMessage = postFailureMessages.contains { messages in
            messages.contains { entry in
                (entry["content"] ?? "").contains("cached knowledge")
            }
        }
        XCTAssertTrue(hasCustomMessage,
                      "Custom fallback message should appear in working memory after circuit breaker fires")
    }

    // MARK: - Test 4: Successful Tool Resets Failure Counter

    func testErrorRecovery_SuccessResetsCounter_NoAbort() async throws {
        // 2 failures → 1 success → 2 more failures → terminal.
        // The success in between resets consecutiveToolFailures,
        // so abort threshold (3) is never reached.
        let failingTool = TestToolFactory.makeFailing(name: "flaky_tool", error: "Intermittent failure")
        let reliableTool = TestToolFactory.make(name: "stable_tool", output: "Success!")

        let provider = MockLLMProvider(steps: [
            // 2 failures
            ModernCognitiveStep(reasoning: "Try 1.", toolCalls: [TestToolCallFactory.make(name: "flaky_tool", input: "a")]),
            ModernCognitiveStep(reasoning: "Try 2.", toolCalls: [TestToolCallFactory.make(name: "flaky_tool", input: "b")]),
            // 1 success (resets counter)
            ModernCognitiveStep(reasoning: "Switching tools.", toolCalls: [TestToolCallFactory.make(name: "stable_tool", input: "c")]),
            // 2 more failures (counter restarts from 0)
            ModernCognitiveStep(reasoning: "Try 3.", toolCalls: [TestToolCallFactory.make(name: "flaky_tool", input: "d")]),
            ModernCognitiveStep(reasoning: "Try 4.", toolCalls: [TestToolCallFactory.make(name: "flaky_tool", input: "e")]),
            // Terminal
            ModernCognitiveStep(reasoning: "Done with mixed results.")
        ])

        let executor = ReActAgentExecutor(maxIterations: 10)
        let input = TestAgentInputFactory.make(
            query: "Run diagnostics",
            tools: [failingTool, reliableTool],
            errorRecovery: ErrorRecovery(onToolFailure: .abort)
        )

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        // All 6 steps should be consumed (no abort triggered)
        XCTAssertEqual(provider.receivedCognitiveMessages.count, 6,
                       "Success between failures should reset counter — no abort triggered")

        // Should have the successful tool output
        let toolOutputs = StreamCollector.toolOutputs(from: events)
        let successes = toolOutputs.filter(\.isSuccess)
        XCTAssertFalse(successes.isEmpty, "Should have at least 1 successful tool execution")

        // Content should be produced from normal termination
        let content = StreamCollector.contentText(from: events)
        XCTAssertFalse(content.isEmpty, "Should produce content when abort threshold not reached")
    }

    // MARK: - Test 5: Iteration Exhaustion — synthesizeBestEffort

    func testErrorRecovery_IterationExhaustion_SynthesizesBestEffort() async throws {
        // maxIterations=2, but 3+ tool call steps scripted.
        // With .synthesizeBestEffort, the executor should produce content
        // even after exhausting the iteration budget.
        let tool = TestToolFactory.make(name: "search", output: "Found partial results.")

        var steps: [ModernCognitiveStep] = []
        for i in 1...5 {
            steps.append(ModernCognitiveStep(
                reasoning: "Searching round \(i).",
                toolCalls: [TestToolCallFactory.make(name: "search", input: "round_\(i)")]
            ))
        }

        let provider = MockLLMProvider(steps: steps)
        let executor = ReActAgentExecutor(maxIterations: 2)
        let input = TestAgentInputFactory.make(
            query: "Find all related data",
            tools: [tool],
            errorRecovery: ErrorRecovery(onIterationExhaustion: .synthesizeBestEffort)
        )

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        // Should stop at maxIterations
        XCTAssertLessThanOrEqual(provider.receivedCognitiveMessages.count, 2,
                                 "Should stop at maxIterations (2)")

        // Should produce content (best-effort synthesis)
        let content = StreamCollector.contentText(from: events)
        XCTAssertFalse(content.isEmpty, "synthesizeBestEffort should produce content")
    }

    // MARK: - Test 6: Iteration Exhaustion — failHard

    func testErrorRecovery_IterationExhaustion_FailHard() async throws {
        // maxIterations=2, with .failHard the executor should signal an error
        // rather than synthesizing a response.
        let tool = TestToolFactory.make(name: "search", output: "Found partial results.")

        var steps: [ModernCognitiveStep] = []
        for i in 1...5 {
            steps.append(ModernCognitiveStep(
                reasoning: "Searching round \(i).",
                toolCalls: [TestToolCallFactory.make(name: "search", input: "round_\(i)")]
            ))
        }

        let provider = MockLLMProvider(steps: steps)
        let executor = ReActAgentExecutor(maxIterations: 2)
        let input = TestAgentInputFactory.make(
            query: "Find all related data",
            tools: [tool],
            errorRecovery: ErrorRecovery(onIterationExhaustion: .failHard)
        )

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        // Should stop at maxIterations
        XCTAssertLessThanOrEqual(provider.receivedCognitiveMessages.count, 2,
                                 "Should stop at maxIterations (2)")

        // failHard should either produce an error event or throw.
        // The stream may still produce some content/thoughts but the terminal
        // behavior differs from synthesizeBestEffort.
        let thoughts = StreamCollector.thoughts(from: events)
        let hasExhaustionSignal = thoughts.contains {
            $0.contains("maximum") || $0.contains("Maximum") || $0.contains("budget") || $0.contains("exhausted")
        }

        // Either an error signal in thoughts OR the stream threw an error
        // (which StreamCollector.collect would have caught)
        let content = StreamCollector.contentText(from: events)
        XCTAssertTrue(
            hasExhaustionSignal || content.isEmpty,
            "failHard should signal exhaustion or produce no synthesized content"
        )
    }
}
