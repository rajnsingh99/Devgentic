// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BotResilienceIntegrationTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

/// A bot provider whose `stream` throws (before yielding any chunk) for the first
/// `failuresBeforeSuccess` attempts, then streams `successText`. Counts attempts.
private final class FlakyBotProvider: LLMProvider, @unchecked Sendable {
    let modelName = "flaky-bot"
    private let scriptedError: Error
    private let failuresBeforeSuccess: Int
    private let successText: String
    private let lock = NSLock()
    private var _attempts = 0

    var streamAttempts: Int { lock.lock(); defer { lock.unlock() }; return _attempts }

    init(error: Error, failuresBeforeSuccess: Int, successText: String = "Hello from the model.") {
        self.scriptedError = error
        self.failuresBeforeSuccess = failuresBeforeSuccess
        self.successText = successText
    }

    func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error> {
        lock.lock(); _attempts += 1; let attempt = _attempts; lock.unlock()
        let err = scriptedError
        let success = successText
        let failures = failuresBeforeSuccess
        return AsyncThrowingStream { continuation in
            if attempt <= failures {
                continuation.finish(throwing: err)   // fail BEFORE yielding any token
            } else {
                continuation.yield(success)
                continuation.finish()
            }
        }
    }

    func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String {
        throw scriptedError
    }

    func generateCognitiveStep(messages: [[String: String]], tools: [[String: Any]]?) async throws -> ModernCognitiveStep {
        ModernCognitiveStep(reasoning: "unused")
    }
}

/// Yields `chunks` then throws — exercises the post-emission path, which must
/// surface the error WITHOUT retrying (retrying would re-render the chunks).
private final class MidStreamThrowProvider: LLMProvider, @unchecked Sendable {
    let modelName = "midstream-throw"
    private let chunks: [String]
    private let scriptedError: Error
    private let lock = NSLock()
    private var _attempts = 0
    var streamAttempts: Int { lock.lock(); defer { lock.unlock() }; return _attempts }

    init(chunks: [String], error: Error) {
        self.chunks = chunks
        self.scriptedError = error
    }

    func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error> {
        lock.lock(); _attempts += 1; lock.unlock()
        let chunks = self.chunks
        let err = scriptedError
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish(throwing: err)
        }
    }

    func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String {
        throw scriptedError
    }

    func generateCognitiveStep(messages: [[String: String]], tools: [[String: Any]]?) async throws -> ModernCognitiveStep {
        ModernCognitiveStep(reasoning: "unused")
    }
}

final class BotResilienceIntegrationTests: XCTestCase {

    private func cloudError(_ status: Int) -> CloudProviderError {
        CloudProviderError(statusCode: status, retryAfterSeconds: nil, requestId: "req-bot", rawBody: "err", provider: .anthropic)
    }

    /// Cloud-class transport with millisecond backoff for test speed.
    private func fastPolicy(maxTransientRetries: Int) -> ResolvedResiliencePolicy {
        ResolvedResiliencePolicy(
            transport: TransportResiliencePolicy(
                providerClass: .cloud,
                maxTransientRetries: maxTransientRetries,
                maxThrottleRetries: 2,
                baseBackoff: 0.01,
                maxBackoff: 0.02,
                connectionRefusedIsFatal: false,
                endpointHint: nil,
                backoffStrategy: .fixed
            ),
            cognitive: CognitiveResiliencePolicy(maxParseFailures: 3),
            loop: LoopResiliencePolicy(maxConsecutiveToolFailures: 3, maxRepetitiveActions: 3, maxConsecutiveDenials: 2)
        )
    }

    private func botInput(policy: ResolvedResiliencePolicy) -> AgentInput {
        var input = TestAgentInputFactory.make(query: "Say hello")
        input.resiliencePolicy = policy
        return input
    }

    /// Collects events, tolerating the terminal throw — ChatExecutor's established
    /// contract on any error is to yield `.error` and then `finish(throwing:)`, so
    /// the `.error` event arrives before the stream rethrows.
    private func collectTolerant(_ stream: AsyncThrowingStream<AgentStreamEvent, Error>) async -> [AgentStreamEvent] {
        var events: [AgentStreamEvent] = []
        do { for try await event in stream { events.append(event) } } catch { /* expected on fatal */ }
        return events
    }

    private func errors(in events: [AgentStreamEvent]) -> [String] {
        events.compactMap { if case .error(let p) = $0 { return String(describing: p) } else { return nil } }
    }
    private func warnings(in events: [AgentStreamEvent]) -> [String] {
        events.compactMap { if case .warning(_, let m, _, _) = $0 { return m } else { return nil } }
    }

    func testTransientThenRecover_StreamsContent() async throws {
        // 500 on attempt 1 (pre-token), success on attempt 2.
        let provider = FlakyBotProvider(error: cloudError(500), failuresBeforeSuccess: 1)
        let executor = ChatExecutor()
        let stream = executor.execute(model: provider, input: botInput(policy: fastPolicy(maxTransientRetries: 2))) { _ in }
        let events = await collectTolerant(stream)

        XCTAssertEqual(provider.streamAttempts, 2, "Should retry once then succeed")
        XCTAssertEqual(StreamCollector.contentText(from: events), "Hello from the model.")
        XCTAssertTrue(errors(in: events).isEmpty, "A recovered transient must not surface an error")
        XCTAssertFalse(warnings(in: events).isEmpty, "A retry should surface a warning to the user")
    }

    func testAuthError_FailsImmediately_HonestMessage_NoRetry() async throws {
        let provider = FlakyBotProvider(error: cloudError(401), failuresBeforeSuccess: 99)
        let executor = ChatExecutor()
        let stream = executor.execute(model: provider, input: botInput(policy: fastPolicy(maxTransientRetries: 2))) { _ in }
        let events = await collectTolerant(stream)

        XCTAssertEqual(provider.streamAttempts, 1, "Auth failure is deterministic — no retries")
        let errs = errors(in: events)
        XCTAssertEqual(errs.count, 1)
        XCTAssertTrue(errs[0].contains("Authentication failed"), "Bot must surface the honest cause, not a raw error: \(errs)")
        XCTAssertTrue(StreamCollector.contentText(from: events).isEmpty)
    }

    func testMidStreamFailure_SurfacedNotRetried_ContentOnce() async throws {
        // Chunks emitted, THEN a 500. Retrying would re-render — so the failure
        // must surface as an error with the content shown exactly once, no retry.
        let provider = MidStreamThrowProvider(chunks: ["Partial ", "answer"], error: cloudError(500))
        let executor = ChatExecutor()
        let stream = executor.execute(model: provider, input: botInput(policy: fastPolicy(maxTransientRetries: 2))) { _ in }
        let events = await collectTolerant(stream)

        XCTAssertEqual(provider.streamAttempts, 1, "A failure AFTER content was emitted must NOT retry")
        XCTAssertEqual(StreamCollector.contentText(from: events), "Partial answer", "Emitted chunks surface exactly once")
        XCTAssertEqual(errors(in: events).count, 1, "The mid-stream failure is surfaced as an error")
    }

    func testTransientStorm_BoundedThenHonestFatal() async throws {
        // Always 500. Budget 2 → 1 initial + 2 retries = 3 attempts, then fatal.
        let provider = FlakyBotProvider(error: cloudError(500), failuresBeforeSuccess: 99)
        let executor = ChatExecutor()
        let stream = executor.execute(model: provider, input: botInput(policy: fastPolicy(maxTransientRetries: 2))) { _ in }
        let events = await collectTolerant(stream)

        XCTAssertEqual(provider.streamAttempts, 3, "1 attempt + 2 bounded retries, then give up")
        let errs = errors(in: events)
        XCTAssertEqual(errs.count, 1)
        XCTAssertTrue(errs[0].contains("unavailable"), "Should report provider unavailable: \(errs)")
    }
}
