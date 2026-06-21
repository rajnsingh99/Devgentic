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
            XCTAssertNotNil(step.drainPenalty, "429 steps must instruct the caller to drain the rate bucket")
        }
        XCTAssertThrowsError(try retrier.nextStep(for: cloudError(429))) { error in
            XCTAssertEqual((error as? TransportFatalError)?.category, .providerQuotaExhausted)
        }
    }

    func test429_HonorsRetryAfter() throws {
        var retrier = TransportRetrier(transport: cloudTransport())
        let step = try retrier.nextStep(for: cloudError(429, retryAfter: 30))
        XCTAssertEqual(step.delay, 30, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(step.drainPenalty), 30, accuracy: 0.01)
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
}
