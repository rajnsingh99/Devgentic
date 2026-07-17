//
//  ReflexionCapabilityIntegrationTests.swift
//  DevgenticTests
//
//  End-to-end integration tests for SelfReflectionCapability (Reflexion architecture).
//  Verifies the trial loop, ReflectionEvaluator LLM evaluation, cross-trial
//  memory seeding (G5), and accumulated critique flow.
//
//  Mock: LLMProvider (scripted ReAct steps + scripted reflection JSON)
//  Real: SelfReflectionCapability → ReActAgentExecutor → ToolExecutionLoop → WindowedLinearMemory
//
//  Sequence contract:
//  - MockLLMProvider.steps[] is consumed by generateCognitiveStep() across all trial ReAct loops.
//  - MockLLMProvider.generateResponses[] is consumed by generate() in ReflectionEvaluator.
//  - Reflection is skipped on the last trial (guard trial < maxTrials).
//

import XCTest
@testable import devgentic

@MainActor
final class ReflexionCapabilityIntegrationTests: XCTestCase {

    // MARK: - Helpers

    /// Builds the Reflexion executor: SelfReflectionCapability wrapping ReActAgentExecutor.
    private func makeReflexionExecutor(maxTrials: Int = 2, maxIterations: Int = 5) -> any Executor {
        let innerExecutor = ReActAgentExecutor(maxIterations: maxIterations)
        let config = SelfReflectionConfig(maxTrials: maxTrials)
        return SelfReflectionCapability(config: config).wrap(innerExecutor)
    }

    /// Builds a key-value reflection response for MockLLMProvider.generate().
    private func makeReflectionResponse(acceptable: Bool, critique: String = "Needs improvement.", revisions: String? = nil) -> String {
        var lines = [
            "VERDICT: \(acceptable ? "PASS" : "RETRY")",
            "CRITIQUE: \(critique)"
        ]
        if let revisions {
            lines.append("REVISION: \(revisions)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Structured-event helpers
    // Trial boundaries / verdicts are STRUCTURED events now (the plan/reflection
    // cards consume them); the old narrative thoughts ("Starting trial 2…",
    // "Reflection: <critique>") were removed as duplicates.

    private func trialsStarted(_ events: [AgentStreamEvent]) -> [Int] {
        events.compactMap { if case .reflectionTrialStarted(let t, _) = $0 { return t }; return nil }
    }

    private func retryCritiques(_ events: [AgentStreamEvent]) -> [String] {
        events.compactMap { if case .reflectionRetrying(_, let c) = $0 { return c }; return nil }
    }

    private func acceptedTrials(_ events: [AgentStreamEvent]) -> [Int] {
        events.compactMap { if case .reflectionAccepted(let t) = $0 { return t }; return nil }
    }

    // MARK: - Test 1: Single Trial Accepted

    func testReflexion_SingleTrialAccepted_NoRetry() async throws {
        // Trial 1 runs inner ReAct executor → reflection evaluator accepts → no trial 2.
        // Steps: 2 (tool call + termination). GenerateResponses: 1 (acceptance).
        let tool = TestToolFactory.make(name: "analyze", output: "Analysis complete: all metrics healthy.")

        let provider = MockLLMProvider(
            steps: [
                // Trial 1, iteration 1: tool call
                ModernCognitiveStep(
                    reasoning: "Running analysis.",
                    toolCalls: [TestToolCallFactory.make(name: "analyze", input: "metrics")]
                ),
                // Trial 1, iteration 2: terminate
                ModernCognitiveStep(reasoning: "All metrics look good. Task complete.")
            ],
            generateResponses: [
                makeReflectionResponse(acceptable: true, critique: "Goal achieved successfully.")
            ]
        )

        let executor = makeReflexionExecutor(maxTrials: 2)
        let input = TestAgentInputFactory.make(query: "Analyze system metrics", tools: [tool])

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        // Should produce content from trial 1
        let content = StreamCollector.contentText(from: events)
        XCTAssertFalse(content.isEmpty, "Should produce final content")

        // Should NOT start trial 2 (early exit after acceptance)
        XCTAssertFalse(trialsStarted(events).contains(2), "Should not start trial 2 when trial 1 is accepted")

        // Structured acceptance event should be present
        XCTAssertEqual(acceptedTrials(events), [1], "Should emit reflectionAccepted for trial 1")

        // Only 2 cognitive step calls (trial 1 only)
        XCTAssertEqual(provider.receivedCognitiveMessages.count, 2,
                       "Only trial 1 should consume cognitive steps")
    }

    // MARK: - Test 2: Cross-Trial Seeding (G5)

    func testReflexion_TrialRejected_CrossTrialMemorySeeding() async throws {
        // G5 core test: Trial 1 rejected → trial 2 receives seeded working memory.
        //
        // Flow:
        //   Trial 1: analyze tool → "Found 3 critical issues" → terminates
        //   Reflection: rejects (critique: "did not fix the issues")
        //   Trial 2: fix_issues tool → "All issues resolved" → terminates
        //   (No reflection on last trial)
        //
        // Verification: Trial 2's messages should contain "prior_trial" observation
        // with trial 1's output, proving cross-trial memory seeding works.

        let analyzeTool = TestToolFactory.make(name: "analyze", output: "Found 3 critical issues in auth module.")
        let fixTool = TestToolFactory.make(name: "fix_issues", output: "All 3 issues resolved.")

        let provider = MockLLMProvider(
            steps: [
                // Trial 1, iteration 1: analyze
                ModernCognitiveStep(
                    reasoning: "Analyzing the codebase.",
                    toolCalls: [TestToolCallFactory.make(name: "analyze", input: "auth")]
                ),
                // Trial 1, iteration 2: terminate
                ModernCognitiveStep(reasoning: "Found 3 critical issues in auth module."),
                // Trial 2, iteration 1: fix
                ModernCognitiveStep(
                    reasoning: "Fixing the issues found in the previous trial.",
                    toolCalls: [TestToolCallFactory.make(name: "fix_issues", input: "auth")]
                ),
                // Trial 2, iteration 2: terminate
                ModernCognitiveStep(reasoning: "All issues resolved successfully.")
            ],
            generateResponses: [
                // Reflection after trial 1: rejected
                makeReflectionResponse(
                    acceptable: false,
                    critique: "Analysis found issues but did not fix them.",
                    revisions: "Use fix_issues tool to resolve the 3 critical issues."
                )
            ]
        )

        let executor = makeReflexionExecutor(maxTrials: 2)
        let input = TestAgentInputFactory.make(
            query: "Find and fix issues in the auth module",
            tools: [analyzeTool, fixTool]
        )

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        // Should produce content
        let content = StreamCollector.contentText(from: events)
        XCTAssertFalse(content.isEmpty, "Should produce final content from trial 2")

        // Trial 2 should have started
        XCTAssertTrue(trialsStarted(events).contains(2), "Should start trial 2 after rejection")

        // Rejection critique should be carried on the structured retry event (full text)
        XCTAssertTrue(retryCritiques(events).contains { $0.contains("did not fix") },
                      "Reflection critique should be emitted on reflectionRetrying")

        // G5 CORE ASSERTION: Cross-trial memory seeding
        // Trial 2's cognitive step messages should contain the prior_trial observation
        // because SelfReflectionCapability seeds workingMemory.recordObservation() with
        // trial 1's output, and MockCognitiveGenerator includes compiledScratchpad.
        // Trial 2 starts at receivedCognitiveMessages[2].
        XCTAssertGreaterThanOrEqual(provider.receivedCognitiveMessages.count, 3,
                                    "Trial 2 should have generated at least 1 cognitive step call")

        let trial2Messages = provider.receivedCognitiveMessages[2...]
        let trial2Content = trial2Messages.flatMap { $0 }.compactMap { $0["content"] }.joined(separator: " ")

        XCTAssertTrue(
            trial2Content.contains("prior_trial") || trial2Content.contains("critical issues"),
            "Trial 2's working memory should contain seeded prior_trial observation with trial 1's output (G5 validation)"
        )

        // All 4 cognitive steps should have been consumed (2 per trial)
        XCTAssertEqual(provider.receivedCognitiveMessages.count, 4,
                       "Both trials should consume 2 cognitive steps each")

        // 1 generate call for reflection evaluation
        XCTAssertEqual(provider.receivedGenerateMessages.count, 1,
                       "Only 1 reflection evaluation should occur (skipped on last trial)")
    }

    // MARK: - Test 3: Accumulated Critique Across 3 Trials

    func testReflexion_CritiqueAccumulates_AcrossMultipleTrials() async throws {
        // maxTrials=3. Trial 1 rejected, trial 2 rejected, trial 3 runs with accumulated critique.
        // Reflection runs after trial 1 and 2, but NOT after trial 3.
        //
        // Verification: Trial 3's messages should contain critique from BOTH prior trials
        // via the reflexionMemory.compileForPrompt() in instructions.

        let tool = TestToolFactory.make(name: "check", output: "Check result: partial")

        let provider = MockLLMProvider(
            steps: [
                // Trial 1: check → terminate
                ModernCognitiveStep(
                    reasoning: "Running check.",
                    toolCalls: [TestToolCallFactory.make(name: "check", input: "v1")]
                ),
                ModernCognitiveStep(reasoning: "First attempt result."),
                // Trial 2: check → terminate
                ModernCognitiveStep(
                    reasoning: "Retrying with adjustments.",
                    toolCalls: [TestToolCallFactory.make(name: "check", input: "v2")]
                ),
                ModernCognitiveStep(reasoning: "Second attempt result."),
                // Trial 3: check → terminate
                ModernCognitiveStep(
                    reasoning: "Third attempt with all feedback.",
                    toolCalls: [TestToolCallFactory.make(name: "check", input: "v3")]
                ),
                ModernCognitiveStep(reasoning: "Third attempt succeeded.")
            ],
            generateResponses: [
                // Reflection after trial 1: rejected with critique A
                makeReflectionResponse(
                    acceptable: false,
                    critique: "CRITIQUE_ALPHA: Missing error handling.",
                    revisions: "Add try-catch blocks."
                ),
                // Reflection after trial 2: rejected with critique B
                makeReflectionResponse(
                    acceptable: false,
                    critique: "CRITIQUE_BETA: Error handling added but tests not run.",
                    revisions: "Run the test suite after fixing."
                )
            ]
        )

        let executor = makeReflexionExecutor(maxTrials: 3)
        let input = TestAgentInputFactory.make(query: "Fix and verify the auth module", tools: [tool])

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        // All 3 trials should have run
        let started = trialsStarted(events)
        XCTAssertTrue(started.contains(2), "Trial 2 should start after trial 1 rejection")
        XCTAssertTrue(started.contains(3), "Trial 3 should start after trial 2 rejection")

        // 6 cognitive steps total (2 per trial)
        XCTAssertEqual(provider.receivedCognitiveMessages.count, 6,
                       "3 trials x 2 iterations = 6 cognitive step calls")

        // 2 reflection evaluations (after trial 1 and 2, not trial 3)
        XCTAssertEqual(provider.receivedGenerateMessages.count, 2,
                       "Reflection should run after trial 1 and 2, but not trial 3")

        // Both critiques should appear on the structured retry events
        let critiques = retryCritiques(events)
        XCTAssertTrue(critiques.contains { $0.contains("CRITIQUE_ALPHA") }, "Trial 1 critique should be emitted")
        XCTAssertTrue(critiques.contains { $0.contains("CRITIQUE_BETA") }, "Trial 2 critique should be emitted")

        // Content should be produced
        let content = StreamCollector.contentText(from: events)
        XCTAssertFalse(content.isEmpty, "Should produce final content after 3 trials")
    }

    // MARK: - Test 4: Early Acceptance Stops Retrying

    func testReflexion_EarlyAcceptance_StopsBeforeMaxTrials() async throws {
        // maxTrials=3, but trial 2 is accepted → trial 3 never runs.
        // Steps: 4 (2 per trial x 2 trials). GenerateResponses: 2 (reject + accept).

        let tool = TestToolFactory.make(name: "deploy", output: "Deployed successfully.")

        let provider = MockLLMProvider(
            steps: [
                // Trial 1: deploy → terminate
                ModernCognitiveStep(
                    reasoning: "Deploying v1.",
                    toolCalls: [TestToolCallFactory.make(name: "deploy", input: "v1")]
                ),
                ModernCognitiveStep(reasoning: "V1 deployed but with warnings."),
                // Trial 2: deploy → terminate
                ModernCognitiveStep(
                    reasoning: "Deploying v2 with fixes.",
                    toolCalls: [TestToolCallFactory.make(name: "deploy", input: "v2")]
                ),
                ModernCognitiveStep(reasoning: "V2 deployed cleanly."),
                // Trial 3 steps (should NOT be consumed)
                ModernCognitiveStep(reasoning: "This should never execute.")
            ],
            generateResponses: [
                // Reflection after trial 1: rejected
                makeReflectionResponse(acceptable: false, critique: "Deployment had warnings."),
                // Reflection after trial 2: accepted
                makeReflectionResponse(acceptable: true, critique: "Clean deployment. Goal achieved.")
            ]
        )

        let executor = makeReflexionExecutor(maxTrials: 3)
        let input = TestAgentInputFactory.make(query: "Deploy the service", tools: [tool])

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        // Only 4 cognitive steps consumed (trial 1 + trial 2)
        XCTAssertEqual(provider.receivedCognitiveMessages.count, 4,
                       "Only 2 trials should run (4 cognitive steps)")

        // Trial 3 should NOT start
        XCTAssertFalse(trialsStarted(events).contains(3), "Trial 3 should not start when trial 2 is accepted")

        // Structured acceptance event after trial 2
        XCTAssertEqual(acceptedTrials(events), [2], "Should emit reflectionAccepted for trial 2")

        // Content should be produced
        let content = StreamCollector.contentText(from: events)
        XCTAssertFalse(content.isEmpty, "Should produce final content")

        // 2 reflection evaluations (after trial 1 and trial 2)
        XCTAssertEqual(provider.receivedGenerateMessages.count, 2,
                       "Reflection should evaluate both trial 1 and trial 2")
    }

    // MARK: - Test 5: All Trials Rejected — Best Output Produced

    func testReflexion_AllTrialsRejected_StillProducesBestOutput() async throws {
        // maxTrials=2, both trials rejected (but reflection only runs after trial 1).
        // The capability should still emit the best output as content.
        // "Best output" is the last trial's output since bestOutput is updated each trial.

        let tool = TestToolFactory.make(name: "attempt", output: "Partial result.")

        let provider = MockLLMProvider(
            steps: [
                // Trial 1
                ModernCognitiveStep(
                    reasoning: "First attempt.",
                    toolCalls: [TestToolCallFactory.make(name: "attempt", input: "try1")]
                ),
                ModernCognitiveStep(reasoning: "TRIAL_1_OUTPUT: partial result from first try."),
                // Trial 2
                ModernCognitiveStep(
                    reasoning: "Second attempt.",
                    toolCalls: [TestToolCallFactory.make(name: "attempt", input: "try2")]
                ),
                ModernCognitiveStep(reasoning: "TRIAL_2_OUTPUT: better result from second try.")
            ],
            generateResponses: [
                // Reflection after trial 1: rejected
                makeReflectionResponse(acceptable: false, critique: "Incomplete result.")
            ]
        )

        let executor = makeReflexionExecutor(maxTrials: 2)
        let input = TestAgentInputFactory.make(query: "Complete the task", tools: [tool])

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        // Should produce content (best effort from the last trial)
        let content = StreamCollector.contentText(from: events)
        XCTAssertFalse(content.isEmpty, "Should produce content even when all trials are rejected")

        // Both trials should have consumed cognitive steps
        XCTAssertEqual(provider.receivedCognitiveMessages.count, 4,
                       "Both trials should run (4 cognitive steps total)")

        // Trial 2 should have started (proving retry occurred)
        XCTAssertTrue(trialsStarted(events).contains(2), "Trial 2 should start after trial 1 rejection")
    }

    // MARK: - Test 6: A1 — a later FAILED trial must not clobber a good earlier one (#18)

    func testReflexion_LaterFailedTrial_DoesNotClobberEarlierOutput() async throws {
        // Trial 1 produces good content, reflection RETRYs, then trial 2 hits a provider-fatal
        // error → the inner executor finishes with NO content (empty trial output, no retry).
        // Pre-#18 the unconditional `bestOutput = trialOutput` overwrote the good trial-1 result
        // with empty → shipped `.failed` + an empty bubble. A1 keeps the most recent NON-EMPTY
        // output, so the run still COMPLETES with trial 1's answer.
        let tool = TestToolFactory.make(name: "attempt", output: "some data")

        let provider = FaultInjectingMock(
            steps: [
                // Trial 1: tool call → good termination
                ModernCognitiveStep(
                    reasoning: "First attempt.",
                    toolCalls: [TestToolCallFactory.make(name: "attempt", input: "1")]
                ),
                ModernCognitiveStep(reasoning: "TRIAL_1_GOOD_OUTPUT: the complete answer.")
            ],
            generateResponses: [
                makeReflectionResponse(acceptable: false, critique: "Try again.")
            ],
            // Trial 2's first cognitive call (step index 2) throws a provider-fatal error →
            // executor yields .error + finishes with empty content (4xx = fatal, no retry/backoff).
            throwOnStepIndex: 2,
            stepError: CloudProviderError(statusCode: 400, retryAfterSeconds: nil, requestId: nil, rawBody: "bad request", provider: .local)
        )

        let executor = makeReflexionExecutor(maxTrials: 2)
        let input = TestAgentInputFactory.make(query: "Complete the task", tools: [tool])

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        // Trial 2 ran (no early exit) but its empty/failed output did NOT clobber trial 1.
        XCTAssertTrue(trialsStarted(events).contains(2), "Trial 2 should run after RETRY")

        // The run completes with trial 1's content rather than failing empty.
        let content = StreamCollector.contentText(from: events)
        XCTAssertFalse(content.isEmpty, "A failed trial 2 must not clobber trial 1 into an empty result")
        let completed = events.contains { if case .executionFinished(.completed, _) = $0 { return true }; return false }
        XCTAssertTrue(completed, "Run should complete (trial 1 preserved), not fail empty")
        let failedEmpty = events.contains { if case .executionFinished(.failed, _) = $0 { return true }; return false }
        XCTAssertFalse(failedEmpty, "Pre-#18 behavior was empty clobber → .failed; must not happen now")
    }

    // MARK: - Test 7: B — cancellation during reflection propagates, not swallowed (#18)

    func testReflexion_CancellationDuringReflection_PropagatesNotSwallowed() async throws {
        // Trial 1 runs, then the reflection LLM call is cancelled. Pre-#18 the evaluator's
        // catch-all folded CancellationError into a "not acceptable" verdict → trial 2 ran
        // and a bogus critique polluted state. The fix rethrows it → the loop stops at the
        // reflection boundary and the run ends cancelled.
        let tool = TestToolFactory.make(name: "analyze", output: "Some analysis.")
        let provider = FaultInjectingMock(
            steps: [
                ModernCognitiveStep(
                    reasoning: "Analyzing.",
                    toolCalls: [TestToolCallFactory.make(name: "analyze", input: "x")]
                ),
                ModernCognitiveStep(reasoning: "Trial 1 output.")
            ],
            throwOnGenerate: CancellationError()
        )

        let executor = makeReflexionExecutor(maxTrials: 2)
        let input = TestAgentInputFactory.make(query: "Do it", tools: [tool])

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        let thoughts = StreamCollector.thoughts(from: events)
        XCTAssertFalse(trialsStarted(events).contains(2),
                       "Cancellation during reflection must stop the loop, not advance to trial 2")
        XCTAssertEqual(provider.cognitiveCallCount, 2,
                       "Only trial 1's 2 cognitive steps should run; trial 2 must not execute")
        XCTAssertTrue(thoughts.contains { $0.contains("Cancelled") },
                      "Run should report cancellation")
    }

    // MARK: - Test 8: #23 — cancel emits a content placeholder (no empty bubble)

    func testReflexion_Cancel_EmitsStopPlaceholder() async throws {
        // #23: a cancelled Reflexion run must yield a content placeholder so the message bubble
        // isn't left empty (mirrors ReActAgentExecutor). Cancellation fires during the reflection
        // LLM call — a wrapper-level point where no answer content has reached the UI (trial
        // content is accumulated into `trialOutput`, not forwarded).
        let tool = TestToolFactory.make(name: "analyze", output: "Some analysis.")
        let provider = FaultInjectingMock(
            steps: [
                ModernCognitiveStep(
                    reasoning: "Analyzing.",
                    toolCalls: [TestToolCallFactory.make(name: "analyze", input: "x")]
                ),
                ModernCognitiveStep(reasoning: "Trial 1 output.")
            ],
            throwOnGenerate: CancellationError()
        )

        let executor = makeReflexionExecutor(maxTrials: 2)
        let input = TestAgentInputFactory.make(query: "Do it", tools: [tool])

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        let content = StreamCollector.contentText(from: events)
        XCTAssertTrue(content.contains("Operation stopped by user"),
                      "Cancelled Reflexion run must emit the stop placeholder, not an empty bubble; got: '\(content)'")
    }
}

/// Scriptable mock that can inject a thrown error on a specific cognitive-step index
/// (`throwOnStepIndex`) or on the reflection `generate` call (`throwOnGenerate`) — for
/// exercising #18's failed-trial (A1) and cancel-during-reflection (B) paths.
private final class FaultInjectingMock: LLMProvider, @unchecked Sendable {
    let modelName = "fault-mock"
    private let steps: [ModernCognitiveStep]
    private var stepIndex = 0
    private let generateResponses: [String]
    private var generateIndex = 0
    private let throwOnStepIndex: Int?
    private let stepError: Error
    private let throwOnGenerate: Error?
    private(set) var cognitiveCallCount = 0

    init(steps: [ModernCognitiveStep] = [],
         generateResponses: [String] = [],
         throwOnStepIndex: Int? = nil,
         stepError: Error = NSError(domain: "test", code: 1),
         throwOnGenerate: Error? = nil) {
        self.steps = steps
        self.generateResponses = generateResponses
        self.throwOnStepIndex = throwOnStepIndex
        self.stepError = stepError
        self.throwOnGenerate = throwOnGenerate
    }

    func generateCognitiveStep(messages: [[String: String]], tools: [[String: Any]]?) async throws -> ModernCognitiveStep {
        if stepIndex == throwOnStepIndex { throw stepError }
        cognitiveCallCount += 1
        guard stepIndex < steps.count else { return ModernCognitiveStep(reasoning: "No more scripted steps.") }
        let step = steps[stepIndex]
        stepIndex += 1
        return step
    }

    func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String {
        if let throwOnGenerate { throw throwOnGenerate }
        guard generateIndex < generateResponses.count else { return "[]" }
        let response = generateResponses[generateIndex]
        generateIndex += 1
        return response
    }

    func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
