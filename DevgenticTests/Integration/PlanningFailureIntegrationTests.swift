// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  PlanningFailureIntegrationTests.swift
//  DevgenticTests
//
//  Regression cover for Workflow_Production_Readiness.md row WF-CC9 — the last member of the
//  "infrastructure fault reported as a content fault" family (CC6/CC10/CC11/CC12 all closed).
//
//  PlanningCapability's catch-all used to fold ANY plan-generation failure — an MLX model-slot
//  race included — into a silent single-task fallback and then yield `.planGenerated`, i.e.
//  report success: the user saw a plausible-looking 1-step plan card, the run proceeded
//  undecomposed, and nothing anywhere said planning failed.
//
//  Contract now, mirroring the family:
//    • `MLXService.ServiceError` gets ONE bounded 2s re-attempt (the same bound as
//      `LLMRetryStrategy.modelSlotAction` and `TransportRetrier`), then the run FAILS honestly
//      with the slot-race text — no fabricated plan, no false success.
//    • A content fault keeps the single-task fallback, but LOUD: a `.warning(.midRunError)`
//      lands on the timeline before the plan card.
//

import XCTest
@testable import devgentic

@MainActor
final class PlanningFailureIntegrationTests: XCTestCase {

    /// `generate()` throws the scripted errors first (one per call), then serves `responses`
    /// (cycling the last). `generateCognitiveStep()` always terminates in one iteration, so
    /// any subtask that runs finishes immediately.
    private final class FlakyPlanProvider: LLMProvider, @unchecked Sendable {
        let modelName = "mock-flaky-planner"
        private var errors: [Error]
        private var responses: [String]
        private(set) var generateCalls = 0
        private(set) var cognitiveStepCalls = 0

        init(errors: [Error], responses: [String]) {
            self.errors = errors
            self.responses = responses
        }

        func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String {
            generateCalls += 1
            if !errors.isEmpty { throw errors.removeFirst() }
            let response = responses.first ?? "ok"
            if responses.count > 1 { responses.removeFirst() }
            return response
        }

        func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func generateCognitiveStep(messages: [[String: String]], tools: [[String: Any]]?) async throws -> ModernCognitiveStep {
            cognitiveStepCalls += 1
            return ModernCognitiveStep(reasoning: "Task complete.")
        }
    }

    /// ⚠️ A failed XCTAssert is NON-FATAL by default, so execution falls through to the NEXT
    /// line — and an unguarded `array[0]` after a failed `.count` assertion then TRAPS, killing
    /// the test HOST and taking every sibling method's verdict with it. That is not theoretical:
    /// it is what made this suite report "0 results" instead of one red test when the CC9 warning
    /// yield was deliberately removed to verify the cover. A regression test that crashes on the
    /// regression it guards cannot fail honestly.
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func makePlanningExecutor(maxSubtasks: Int = 5) -> any Executor {
        let config = PlanningCapabilityConfig(
            maxSubtasks: maxSubtasks,
            parallelSubtasks: false,
            subtaskToolFiltering: false,
            requiresPlanApproval: false,
            clarifyBeforePlanning: false
        )
        return PlanningCapability(config: config).wrap(ReActAgentExecutor(maxIterations: 3))
    }

    /// Collects events AND the terminal error (the slot-race run finishes `finish(throwing:)`).
    private func collectWithError(
        from stream: AsyncThrowingStream<AgentStreamEvent, Error>
    ) async -> (events: [AgentStreamEvent], thrown: Error?) {
        var events: [AgentStreamEvent] = []
        do {
            for try await event in stream { events.append(event) }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    private func planGeneratedCounts(_ events: [AgentStreamEvent]) -> [Int] {
        events.compactMap { if case .planGenerated(let subtasks) = $0 { return subtasks.count }; return nil }
    }

    private func midRunWarnings(_ events: [AgentStreamEvent]) -> [String] {
        events.compactMap {
            if case .warning(let category, let message, _, _) = $0, category == .midRunError { return message }
            return nil
        }
    }

    /// The slot race is INFRASTRUCTURE: after the bounded re-attempt also loses, the run must
    /// FAIL with the slot-race text — never fabricate a single-step plan and report success.
    func testSlotRaceTwice_FailsTheRunHonestly_NoFabricatedPlan() async throws {
        let race = { MLXService.ServiceError.modelIdentityMismatch(expected: "qwen-7b", actual: "llama-3b") }
        let provider = FlakyPlanProvider(errors: [race(), race()], responses: ["1. Should never be reached"])
        let executor = makePlanningExecutor()
        let input = TestAgentInputFactory.make(query: "Summarize the logs")

        let stream = executor.execute(model: provider, input: input) { _ in }
        let (events, thrown) = await collectWithError(from: stream)

        XCTAssertTrue(planGeneratedCounts(events).isEmpty,
                      "an infrastructure fault must never produce a plan card — that is the filed lie")
        let finished = events.compactMap { if case .executionFinished(let outcome, let reason) = $0 { return (outcome, reason) }; return nil }
        XCTAssertEqual(finished.last?.0, .failed, "the run must fail, not succeed undecomposed")
        XCTAssertTrue(thrown is MLXService.ServiceError,
                      "the slot-race error must propagate typed, got \(String(describing: thrown))")
        XCTAssertEqual(provider.generateCalls, 2,
                       "exactly one bounded re-attempt — the same 1-retry budget as the agent and bot paths")
    }

    /// One lost race, then a clean plan: the bounded re-attempt must recover invisibly.
    func testSlotRaceOnce_BoundedRetryRecovers() async throws {
        let provider = FlakyPlanProvider(
            errors: [MLXService.ServiceError.modelIdentityMismatch(expected: "qwen-7b", actual: "llama-3b")],
            responses: ["1. Read the log file\n2. Summarize the errors", "Summary of results."]
        )
        let executor = makePlanningExecutor()
        let input = TestAgentInputFactory.make(query: "Summarize the logs")

        let stream = executor.execute(model: provider, input: input) { _ in }
        let (events, thrown) = await collectWithError(from: stream)

        XCTAssertNil(thrown, "one lost race is recoverable — the retry re-runs the load")
        XCTAssertEqual(planGeneratedCounts(events), [2], "the REAL 2-step plan, not a fallback")
        XCTAssertTrue(midRunWarnings(events).isEmpty, "a recovered race needs no planning warning")
    }

    /// ⚠️ RENAMED ON REVIEW. This was `testContentFailure_FallsBackToSingleTaskLoudly`, which was
    /// wrong twice over: an `NSError` thrown by the provider is not a content fault, and — more
    /// importantly — `PlanGeneratorStrategy.parsePlan` NEVER THROWS on unparseable output (it
    /// returns a single-step fallback plan), so no content fault can reach that catch arm at all.
    /// The old name made the content path look covered while nothing touched it.
    ///
    /// What this actually pins: an UNCLASSIFIED error (one `isInfrastructureFault` does not
    /// recognise) still degrades rather than killing the run, and says so on the timeline.
    /// The genuinely silent content path — `parsePlan`'s own fallback — is filed as WF-EX12.
    func testUnclassifiedPlanningError_FallsBackToSingleTaskLoudly() async throws {
        let provider = FlakyPlanProvider(
            errors: [NSError(domain: "Test", code: 9, userInfo: [NSLocalizedDescriptionKey: "unclassified hiccup"])],
            responses: ["Summary of results."]
        )
        let executor = makePlanningExecutor()
        let input = TestAgentInputFactory.make(query: "Summarize the logs")

        let stream = executor.execute(model: provider, input: input) { _ in }
        let (events, thrown) = await collectWithError(from: stream)

        XCTAssertNil(thrown, "a content fault degrades, it does not kill the run")
        XCTAssertEqual(planGeneratedCounts(events), [1], "the single-task fallback still runs the task")
        let warnings = midRunWarnings(events)
        guard warnings.count == 1 else {
            return XCTFail("the fallback must announce itself — expected exactly 1 .midRunError warning, got \(warnings.count): \(warnings)")
        }
        XCTAssertTrue(warnings[0].contains("Planning failed"), "got: \(warnings)")
        XCTAssertGreaterThan(provider.cognitiveStepCalls, 0, "the fallback task must actually execute")
    }

    /// [WF-CC9, widened on review] The rethrow must cover the WHOLE provider family, not just MLX.
    /// The first version of the fix rethrew only `MLXService.ServiceError`, which left the
    /// identical lie — a fabricated 1-step plan reported as a completed run — in place for every
    /// cloud and Ollama fault.
    func testCloudProviderFailure_AlsoFailsTheRunRatherThanFabricatingAPlan() async throws {
        let authFailure = CloudProviderError(statusCode: 401, retryAfterSeconds: nil,
                                             requestId: "req-1", rawBody: "invalid key",
                                             provider: .anthropic)
        let provider = FlakyPlanProvider(errors: [authFailure], responses: ["1. never reached"])
        let executor = makePlanningExecutor()
        let input = TestAgentInputFactory.make(query: "Summarize the logs")

        let stream = executor.execute(model: provider, input: input) { _ in }
        let (events, thrown) = await collectWithError(from: stream)

        XCTAssertTrue(planGeneratedCounts(events).isEmpty,
                      "a provider auth failure must not fabricate a plan — planning never happened")
        XCTAssertNotNil(thrown, "the run must fail, not report .completed for an undecomposed task")
        let finished = events.compactMap { if case .executionFinished(let outcome, _) = $0 { return outcome }; return nil }
        XCTAssertEqual(finished.last, .failed)
    }

    /// The predicate itself, asserted directly — it is the one decision separating "fail honestly"
    /// from "degrade to one task", and a future provider type added without a thought here would
    /// silently rejoin the fabricate-a-plan path.
    func testInfrastructureFaultPredicateCoversTheProviderFamily() {
        XCTAssertTrue(PlanningCapability.isInfrastructureFault(
            MLXService.ServiceError.modelIdentityMismatch(expected: "a", actual: "b")))
        XCTAssertTrue(PlanningCapability.isInfrastructureFault(
            CloudProviderError(statusCode: 500, retryAfterSeconds: nil, requestId: nil, rawBody: "", provider: .anthropic)))
        XCTAssertTrue(PlanningCapability.isInfrastructureFault(LLMProviderError.httpError(429, "rate limited")))
        XCTAssertTrue(PlanningCapability.isInfrastructureFault(
            TransportFatalError(reason: "exhausted", category: .providerServerError)))
        XCTAssertTrue(PlanningCapability.isInfrastructureFault(URLError(.notConnectedToInternet)))

        XCTAssertFalse(PlanningCapability.isInfrastructureFault(
            NSError(domain: "Test", code: 1)),
            "an unclassified error still degrades — only the KNOWN plumbing family kills the run")
    }
}
