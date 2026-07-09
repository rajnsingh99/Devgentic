//
//  ResilienceBoundedRetryIntegrationTests.swift
//  DevgenticTests
//
//  Executor-level proof for the Phase-A resilience fix (audit #5): provider
//  errors terminate the run honestly and boundedly. Before the fix, a 5xx
//  storm retried forever (iteration refunded, zero delay) and a 401 burned
//  three "parse failure" retries before blaming the model.
//

import XCTest
@testable import devgentic

/// A provider whose cognitive step always throws the scripted error.
/// Counts calls so tests can assert exact retry budgets.
private final class ThrowingMockProvider: LLMProvider, @unchecked Sendable {
    let modelName = "throwing-mock"
    private let scriptedError: Error
    private(set) var cognitiveCalls = 0

    init(error: Error) {
        self.scriptedError = error
    }

    func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String {
        throw scriptedError
    }

    func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: self.scriptedError) }
    }

    func generateCognitiveStep(messages: [[String: String]], tools: [[String: Any]]?) async throws -> ModernCognitiveStep {
        cognitiveCalls += 1
        throw scriptedError
    }
}

final class ResilienceBoundedRetryIntegrationTests: XCTestCase {

    private func makeCloudError(statusCode: Int, rawBody: String = "Error body") -> CloudProviderError {
        CloudProviderError(
            statusCode: statusCode,
            retryAfterSeconds: nil,
            requestId: "req-itest",
            rawBody: rawBody,
            provider: .anthropic
        )
    }

    /// Test-speed policy: real budgets, millisecond backoff.
    private func makeFastPolicy(maxTransientRetries: Int) -> ResolvedResiliencePolicy {
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

    private func errorMessages(in events: [AgentStreamEvent]) -> [String] {
        events.compactMap { event in
            if case .error(let payload) = event { return String(describing: payload) }
            return nil
        }
    }

    private func parseFailureWarnings(in events: [AgentStreamEvent]) -> [String] {
        events.compactMap { event in
            if case .warning(let category, let message, _, _) = event, category == .parseFailure {
                return message
            }
            return nil
        }
    }

    func testHTTP401_FailsImmediately_NoRetries_NoParseBlame() async throws {
        let provider = ThrowingMockProvider(error: makeCloudError(statusCode: 401))
        let executor = ReActAgentExecutor(maxIterations: 5)
        let input = TestAgentInputFactory.make(query: "Do something")

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        XCTAssertEqual(provider.cognitiveCalls, 1, "Auth failures are deterministic — exactly one attempt")

        let errors = errorMessages(in: events)
        XCTAssertEqual(errors.count, 1, "Should surface exactly one error card")
        XCTAssertTrue(errors[0].contains("Authentication failed"), "Error should name the real cause, got: \(errors)")

        XCTAssertTrue(parseFailureWarnings(in: events).isEmpty,
                      "A provider auth error must never be presented as a model parse failure")
    }

    func testHTTP500Storm_BoundedRetries_ThenHonestFailure() async throws {
        let provider = ThrowingMockProvider(error: makeCloudError(statusCode: 500))
        let executor = ReActAgentExecutor(maxIterations: 5)
        var input = TestAgentInputFactory.make(query: "Do something")
        input.resiliencePolicy = makeFastPolicy(maxTransientRetries: 2)

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        // 1 initial attempt + exactly maxTransientRetries retries, then stop.
        // Before the fix this looped until the user cancelled.
        XCTAssertEqual(provider.cognitiveCalls, 3, "Expected 1 attempt + 2 bounded retries")

        let errors = errorMessages(in: events)
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].contains("unavailable"), "Error should say the provider is unavailable, got: \(errors)")
        XCTAssertTrue(parseFailureWarnings(in: events).isEmpty,
                      "A 5xx storm must never be presented as a model parse failure")
    }

    func testContextOverflow400_SurfacesGuidance() async throws {
        let provider = ThrowingMockProvider(error: makeCloudError(
            statusCode: 400,
            rawBody: #"{"error":{"message":"prompt is too long: 210000 tokens > 200000 maximum"}}"#
        ))
        let executor = ReActAgentExecutor(maxIterations: 5)
        let input = TestAgentInputFactory.make(query: "Do something")

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        XCTAssertEqual(provider.cognitiveCalls, 1, "Context overflow is deterministic — exactly one attempt")
        let errors = errorMessages(in: events)
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].contains("context window"), "Should explain the overflow, got: \(errors)")
    }
}
