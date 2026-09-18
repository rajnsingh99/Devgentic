// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TransportRetrierTests.swift
//  DevgenticTests
//
//  Phase-C resilience: the bot-path transport retrier (audit #9). Pure decision
//  logic — bounded transient/throttle budgets, typed fatal verdicts, shared
//  classification with the agent path, and Retry-After sanitization. Mirrors the
//  agent-path contract proven in LLMRetryStrategyTests.
//

import XCTest
@testable import devgentic

final class TransportRetrierTests: XCTestCase {

    private func cloudTransport() -> TransportResiliencePolicy {
        ResolvedResiliencePolicy.resolved(for: .cloud).transport
    }
    private func ollamaTransport() -> TransportResiliencePolicy {
        ResolvedResiliencePolicy.resolved(for: .ollama).transport
    }
    private func mlxTransport() -> TransportResiliencePolicy {
        ResolvedResiliencePolicy.resolved(for: .mlx).transport
    }

    private func cloudError(_ status: Int, retryAfter: TimeInterval? = nil, body: String = "err") -> CloudProviderError {
        CloudProviderError(statusCode: status, retryAfterSeconds: retryAfter, requestId: "req-x", rawBody: body, provider: .anthropic)
    }

    // MARK: - Transient

    func test5xx_RetriesWithBackoff_ThenFatal() throws {
        var retrier = TransportRetrier(transport: cloudTransport()) // budget 3
        var delays: [TimeInterval] = []
        for _ in 1...3 {
            let step = try retrier.nextStep(for: cloudError(503))
            XCTAssertEqual(step.category, .retry)
            XCTAssertNil(step.drainPenalty)
            delays.append(step.delay)
        }
        XCTAssertEqual(delays, [1.0, 2.0, 4.0])

        XCTAssertThrowsError(try retrier.nextStep(for: cloudError(503))) { error in
            guard let fatal = error as? TransportFatalError else { return XCTFail("Expected TransportFatalError") }
            XCTAssertEqual(fatal.category, .providerServerError)
            XCTAssertTrue(fatal.reason.contains("unavailable"))
        }
    }

    func testTimeout_IsTransient() throws {
        var retrier = TransportRetrier(transport: cloudTransport())
        let step = try retrier.nextStep(for: URLError(.timedOut))
        XCTAssertEqual(step.category, .retry)
        XCTAssertGreaterThan(step.delay, 0)
    }

    // MARK: - Throttle

    func test429_Throttles_ThenQuotaExhaustedFatal() throws {
        var retrier = TransportRetrier(transport: cloudTransport()) // throttle budget 5
        for _ in 1...5 {
            let step = try retrier.nextStep(for: cloudError(429))
            XCTAssertEqual(step.category, .throttle)
            // chip task_70f0522b (committed): CloudRequestPipeline already drains the bucket for
            // a cloud 429 before throwing CloudProviderError — the caller must NOT drain again.
            // (This assertion pre-dated the chip and asserted the double-drain.)
            XCTAssertNil(step.drainPenalty, "a cloud 429 is already drained by CloudRequestPipeline — a second drain double-penalizes")
        }
        XCTAssertThrowsError(try retrier.nextStep(for: cloudError(429))) { error in
            XCTAssertEqual((error as? TransportFatalError)?.category, .providerQuotaExhausted)
        }
    }

    func test429_HonorsRetryAfter() throws {
        var retrier = TransportRetrier(transport: cloudTransport())
        let step = try retrier.nextStep(for: cloudError(429, retryAfter: 30))
        XCTAssertEqual(step.delay, 30, accuracy: 0.01)
        // chip task_70f0522b: cloud 429s carry NO drain instruction (see above); the drain
        // penalty only exists for pipeline-bypassing providers (LLMProviderError.httpError).
        XCTAssertNil(step.drainPenalty)
    }

    /// The half of the chip contract that DOES drain: a pipeline-bypassing provider's 429
    /// (Ollama/local → LLMProviderError.httpError) reaches the limiter only through the caller.
    func test429_PipelineBypassingProvider_StillDrains() throws {
        var retrier = TransportRetrier(transport: ollamaTransport())
        let step = try retrier.nextStep(for: LLMProviderError.httpError(429, "rate limited"))
        XCTAssertEqual(step.category, .throttle)
        XCTAssertNotNil(step.drainPenalty, "no pipeline drained for this provider — the caller must")
    }

    func test429_AbsurdRetryAfter_FallsBackToBackoff() throws {
        var retrier = TransportRetrier(transport: cloudTransport())
        let neg = try retrier.nextStep(for: cloudError(429, retryAfter: -5))
        XCTAssertGreaterThan(neg.delay, 0, "Negative Retry-After must fall back, never reach a trapping sleep")
        let inf = try retrier.nextStep(for: cloudError(429, retryAfter: .infinity))
        XCTAssertTrue(inf.delay.isFinite)
    }

    // MARK: - Deterministic fatal (no retry)

    func test401_IsAuthFatal_Immediately() {
        var retrier = TransportRetrier(transport: cloudTransport())
        XCTAssertThrowsError(try retrier.nextStep(for: cloudError(401))) { error in
            guard let fatal = error as? TransportFatalError else { return XCTFail("Expected TransportFatalError") }
            XCTAssertEqual(fatal.category, .providerAuth)
            XCTAssertTrue(fatal.reason.contains("API key"))
        }
    }

    func testContextOverflow_IsFatalWithGuidance() {
        var retrier = TransportRetrier(transport: cloudTransport())
        XCTAssertThrowsError(try retrier.nextStep(for: cloudError(400, body: "prompt is too long: 210000 tokens"))) { error in
            let fatal = error as? TransportFatalError
            XCTAssertEqual(fatal?.category, .providerCapabilityMissing)
            XCTAssertTrue(fatal?.reason.contains("context window") ?? false)
        }
    }

    // MARK: - Provider-class behavior

    func testOllamaConnectionRefused_IsUnreachableFatal() {
        var retrier = TransportRetrier(transport: ollamaTransport())
        XCTAssertThrowsError(try retrier.nextStep(for: URLError(.cannotConnectToHost))) { error in
            let fatal = error as? TransportFatalError
            XCTAssertEqual(fatal?.category, .providerUnreachable)
            XCTAssertTrue(fatal?.reason.contains("is it running") ?? false)
            XCTAssertTrue(fatal?.reason.contains("localhost:11434") ?? false)
        }
    }

    func testMLX_FailsFast_NoTransientRetries() {
        var retrier = TransportRetrier(transport: mlxTransport()) // budget 0
        XCTAssertThrowsError(try retrier.nextStep(for: URLError(.timedOut))) { error in
            XCTAssertEqual((error as? TransportFatalError)?.category, .providerServerError)
            XCTAssertTrue((error as? TransportFatalError)?.reason.contains("local model") ?? false)
        }
    }

    // MARK: - Non-transport errors pass through

    func testNonTransportError_RethrownUnchanged() {
        var retrier = TransportRetrier(transport: cloudTransport())
        let original = NSError(domain: "Test", code: 7, userInfo: [NSLocalizedDescriptionKey: "weird"])
        XCTAssertThrowsError(try retrier.nextStep(for: original)) { error in
            XCTAssertFalse(error is TransportFatalError, "A non-transport error must be rethrown as-is, not wrapped")
            XCTAssertEqual((error as NSError).code, 7)
        }
    }

    // MARK: - [WF-CC12] MLX model-slot race — typed arm, bounded like the agent path

    /// The bot path used to surface this error unretried, only because the classifier's
    /// `guard/else` rethrows what it doesn't recognize — the identical fault on an agent
    /// profile self-heals after one bounded re-attempt (`LLMRetryStrategy.modelSlotAction`).
    func testMLXModelSlotRace_OneBoundedRetry_ThenFatal() throws {
        var retrier = TransportRetrier(transport: mlxTransport())
        let race = MLXService.ServiceError.modelIdentityMismatch(expected: "qwen-7b", actual: "llama-3b")

        let step = try retrier.nextStep(for: race)
        XCTAssertEqual(step.category, .retry)
        XCTAssertEqual(step.delay, 2.0, "same delay as the agent path's modelSlotRetryDelay")
        XCTAssertNil(step.drainPenalty, "a slot race is not a rate limit — nothing to drain")
        XCTAssertTrue(step.message.contains("llama-3b") && step.message.contains("qwen-7b"),
                      "the warning must name both models")

        XCTAssertThrowsError(try retrier.nextStep(for: race)) { error in
            guard let fatal = error as? TransportFatalError else { return XCTFail("Expected TransportFatalError") }
            XCTAssertEqual(fatal.category, .modelUnloaded,
                           "same telemetry category as the agent path — not .providerServerError")
            XCTAssertTrue(fatal.reason.contains("Nothing was answered by the wrong model"),
                          "the fatal message mirrors the agent path verbatim")
        }
    }

    /// The slot with no named squatter ("<none>" = emptied by a concurrent load) must never be
    /// rendered to the user as a model name — mirrors modelSlotAction's holder handling.
    func testMLXSlotRace_EmptiedSlot_NotRenderedAsModelName() throws {
        var retrier = TransportRetrier(transport: mlxTransport())
        let race = MLXService.ServiceError.modelIdentityMismatch(expected: "qwen-7b", actual: "<none>")
        let step = try retrier.nextStep(for: race)
        XCTAssertFalse(step.message.contains("<none>"))
        XCTAssertTrue(step.message.contains("another local model load"))
    }

    /// The slot race has its OWN budget — charging the MLX transient budget (0) would fail on
    /// the first hit, and a slot retry must not eat a later genuine transient's budget.
    func testMLXSlotRetry_DoesNotChargeTransientOrThrottleBudget() throws {
        var retrier = TransportRetrier(transport: mlxTransport())
        _ = try retrier.nextStep(for: MLXService.ServiceError.modelIdentityMismatch(expected: "a", actual: "b"))
        XCTAssertEqual(retrier.transientCount, 0)
        XCTAssertEqual(retrier.throttleCount, 0)
        XCTAssertEqual(retrier.modelSlotCount, 1)
    }

    /// `.noModelLoaded` is deterministic (the request carried no identity to reload) — fail
    /// honestly at once rather than burning a retry on an identical request.
    func testNoModelLoaded_IsImmediatelyFatal() {
        var retrier = TransportRetrier(transport: mlxTransport())
        XCTAssertThrowsError(try retrier.nextStep(for: MLXService.ServiceError.noModelLoaded)) { error in
            guard let fatal = error as? TransportFatalError else { return XCTFail("Expected TransportFatalError") }
            XCTAssertEqual(fatal.category, .modelUnloaded)
        }
    }
}
