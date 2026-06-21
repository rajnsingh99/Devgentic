//
//  LLMRetryStrategyTests.swift
//  DevgenticTests
//
//  Unit tests for LLMRetryStrategy under the Phase-A resilience contract
//  (audit #5): parse-failure counting, bounded transient retries with backoff,
//  bounded 429 throttles, typed fatal verdicts for deterministic 4xx errors
//  (auth, model-not-found, context overflow), provider-class connection-refused
//  handling, and model-unloaded detection.
//

import XCTest
@testable import devgentic

final class LLMRetryStrategyTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a generic NSError that does NOT match 429, timeout, or model-unloaded patterns.
    /// This falls through to the parse failure path.
    private func makeGenericError(_ message: String = "Invalid JSON") -> NSError {
        NSError(domain: "TestDomain", code: 1000, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Creates a CloudProviderError with the given status code.
    private func makeCloudError(
        statusCode: Int,
        retryAfterSeconds: TimeInterval? = nil,
        requestId: String? = "req-123",
        rawBody: String = "Error body"
    ) -> CloudProviderError {
        CloudProviderError(
            statusCode: statusCode,
            retryAfterSeconds: retryAfterSeconds,
            requestId: requestId,
            rawBody: rawBody,
            provider: .anthropic
        )
    }

    private var cloudTransport: TransportResiliencePolicy {
        ResolvedResiliencePolicy.resolved(for: .cloud).transport
    }

    private var ollamaTransport: TransportResiliencePolicy {
        ResolvedResiliencePolicy.resolved(for: .ollama).transport
    }

    // MARK: - Parse Failure Counting (unchanged contract)

    func testParseFailure_IncrementedCorrectly() {
        var strategy = LLMRetryStrategy(maxConsecutiveParseFailures: 3)
        _ = strategy.handleError(makeGenericError())
        XCTAssertEqual(strategy.consecutiveParseFailures, 1)
    }

    func testParseFailure_AbortAtThreshold() {
        var strategy = LLMRetryStrategy(maxConsecutiveParseFailures: 3)
        _ = strategy.handleError(makeGenericError("fail 1"))
        _ = strategy.handleError(makeGenericError("fail 2"))
        let action = strategy.handleError(makeGenericError("fail 3"))

        if case .abort(let reason) = action {
            XCTAssertTrue(reason.contains("trouble processing"), "Abort reason should explain the issue")
        } else {
            XCTFail("Expected .abort on 3rd parse failure, got \(action)")
        }
    }

    func testParseFailure_RetryBelowThreshold() {
        var strategy = LLMRetryStrategy(maxConsecutiveParseFailures: 3)
        _ = strategy.handleError(makeGenericError("fail 1"))
        let action = strategy.handleError(makeGenericError("fail 2"))

        if case .parseRetry(_, let attemptCount, let maxAttempts) = action {
            XCTAssertEqual(attemptCount, 2)
            XCTAssertEqual(maxAttempts, 3)
        } else {
            XCTFail("Expected .parseRetry, got \(action)")
        }
    }

    func testParseFailure_SystemAlertContainsAttemptInfo() {
        var strategy = LLMRetryStrategy(maxConsecutiveParseFailures: 3)
        let action = strategy.handleError(makeGenericError())

        if case .parseRetry(let alert, let attempt, _) = action {
            XCTAssertEqual(attempt, 1)
            XCTAssertTrue(alert.contains("1/3"), "System alert should contain attempt count")
        } else {
            XCTFail("Expected .parseRetry, got \(action)")
        }
    }

    // MARK: - 429 Throttling (bounded)

    func testExponentialBackoff_HTTP429_ProducesIncreasingDelays() {
        var strategy = LLMRetryStrategy(maxConsecutiveParseFailures: 10, backoffStrategy: .exponential)
        var delays: [TimeInterval] = []

        for _ in 1...4 {
            let action = strategy.handleError(makeCloudError(statusCode: 429))
            if case .throttle(let seconds, _) = action {
                delays.append(seconds)
            }
        }

        XCTAssertEqual(delays.count, 4, "All 4 should produce throttle actions (budget is 5)")
        // Exponential: pow(2, 1)=2, pow(2, 2)=4, pow(2, 3)=8, pow(2, 4)=16
        XCTAssertEqual(delays[0], 2.0, accuracy: 0.01)
        XCTAssertEqual(delays[1], 4.0, accuracy: 0.01)
        XCTAssertEqual(delays[2], 8.0, accuracy: 0.01)
        XCTAssertEqual(delays[3], 16.0, accuracy: 0.01)
    }

    func testFixedBackoff_HTTP429_ProducesConstantDelays() {
        var strategy = LLMRetryStrategy(maxConsecutiveParseFailures: 10, backoffStrategy: .fixed)
        var delays: [TimeInterval] = []

        for _ in 1...3 {
            let action = strategy.handleError(makeCloudError(statusCode: 429))
            if case .throttle(let seconds, _) = action {
                delays.append(seconds)
            }
        }

        XCTAssertEqual(delays.count, 3)
        for delay in delays {
            XCTAssertEqual(delay, 2.0, accuracy: 0.01, "Fixed backoff should always be 2.0s")
        }
    }

    func testHTTP429_WithRetryAfterHeader_UsesProvidedValue() {
        var strategy = LLMRetryStrategy()
        let action = strategy.handleError(makeCloudError(statusCode: 429, retryAfterSeconds: 30))

        if case .throttle(let seconds, _) = action {
            XCTAssertEqual(seconds, 30.0, accuracy: 0.01, "Should use the Retry-After value from the error")
        } else {
            XCTFail("Expected .throttle, got \(action)")
        }
    }

    func testHTTP429_ExhaustedBudget_BecomesFatalRateLimit() {
        // Cloud budget is 5 throttle waits; the 6th consecutive 429 gives up
        // with an honest quota message instead of waiting forever.
        var strategy = LLMRetryStrategy()

        for _ in 1...5 {
            let action = strategy.handleError(makeCloudError(statusCode: 429))
            if case .throttle = action {} else {
                XCTFail("Expected .throttle within budget, got \(action)")
            }
        }

        let action = strategy.handleError(makeCloudError(statusCode: 429))
        if case .fatal(let reason, let category) = action {
            XCTAssertEqual(category, .providerQuotaExhausted, "Run-ending quota failures need a fatal-severity category")
            XCTAssertTrue(reason.contains("quota"), "Reason should point at quota, got: \(reason)")
        } else {
            XCTFail("Expected .fatal after exhausting throttle budget, got \(action)")
        }
    }

    func testHTTP429_NegativeOrAbsurdRetryAfter_FallsBackToLocalBackoff() {
        // Real-world proxies send "-1" / past dates / "inf" — these must not
        // reach Task.sleep's trapping UInt64 conversion.
        var strategy = LLMRetryStrategy(backoffStrategy: .fixed)

        let negative = strategy.handleError(makeCloudError(statusCode: 429, retryAfterSeconds: -1))
        if case .throttle(let seconds, _) = negative {
            XCTAssertEqual(seconds, 2.0, accuracy: 0.01, "Negative Retry-After must fall back to local backoff")
        } else {
            XCTFail("Expected .throttle, got \(negative)")
        }

        let infinite = strategy.handleError(makeCloudError(statusCode: 429, retryAfterSeconds: .infinity))
        if case .throttle(let seconds, _) = infinite {
            XCTAssertTrue(seconds.isFinite, "Non-finite Retry-After must be sanitized")
        } else {
            XCTFail("Expected .throttle, got \(infinite)")
        }

        let absurd = strategy.handleError(makeCloudError(statusCode: 429, retryAfterSeconds: 1_000_000_000))
        if case .throttle(let seconds, _) = absurd {
            XCTAssertLessThanOrEqual(seconds, 3600, "Sane ceiling of 1h on honored Retry-After")
        } else {
            XCTFail("Expected .throttle, got \(absurd)")
        }
    }

    // MARK: - Transient Errors (bounded with backoff)

    func testHTTP5xx_RetriesWithBackoffThenFatal() {
        // Cloud budget is 3 transient retries with exponential delays (1, 2, 4),
        // then an honest provider-unavailable fatal — never an infinite loop.
        var strategy = LLMRetryStrategy()
        var delays: [TimeInterval] = []

        for _ in 1...3 {
            let action = strategy.handleError(makeCloudError(statusCode: 503))
            if case .networkRetry(_, let delaySeconds) = action {
                delays.append(delaySeconds)
            } else {
                XCTFail("Expected .networkRetry within budget, got \(action)")
            }
        }
        XCTAssertEqual(delays, [1.0, 2.0, 4.0], "Transient backoff should escalate")

        let action = strategy.handleError(makeCloudError(statusCode: 503))
        if case .fatal(let reason, let category) = action {
            XCTAssertEqual(category, .providerServerError)
            XCTAssertTrue(reason.contains("unavailable"), "Reason should say the provider is unavailable, got: \(reason)")
        } else {
            XCTFail("Expected .fatal after exhausting transient budget, got \(action)")
        }
    }

    func testNetworkTimeout_URLError_CountsAsTransient() {
        var strategy = LLMRetryStrategy()
        let action = strategy.handleError(URLError(.timedOut))

        if case .networkRetry(let message, let delaySeconds) = action {
            XCTAssertGreaterThan(delaySeconds, 0, "Transient retries must back off, not hammer")
            XCTAssertTrue(message.contains("timed out"))
        } else {
            XCTFail("Expected .networkRetry for URLError.timedOut, got \(action)")
        }
        XCTAssertEqual(strategy.consecutiveTransientFailures, 1)
    }

    func testConnectionRefused_CloudTransport_IsTransient() {
        // Cloud: the user's own network may be flapping — retry, don't blame config.
        var strategy = LLMRetryStrategy(transport: cloudTransport)
        let action = strategy.handleError(URLError(.cannotConnectToHost))

        if case .networkRetry = action {} else {
            XCTFail("Expected .networkRetry for cloud connection failure, got \(action)")
        }
    }

    func testConnectionRefused_OllamaTransport_IsFatalWithGuidance() {
        // Ollama: connection-refused means the server isn't running — actionable
        // config problem, fail fast with the endpoint in the message.
        var strategy = LLMRetryStrategy(transport: ollamaTransport)
        let action = strategy.handleError(URLError(.cannotConnectToHost))

        if case .fatal(let reason, let category) = action {
            XCTAssertEqual(category, .providerUnreachable, "Server-not-running is not a timeout — needs its own fatal category")
            XCTAssertTrue(reason.contains("is it running"), "Should ask whether the server is running, got: \(reason)")
            XCTAssertTrue(reason.contains("localhost:11434"), "Should include the endpoint hint, got: \(reason)")
        } else {
            XCTFail("Expected .fatal for Ollama connection-refused, got \(action)")
        }
    }

    func testOfflineInternet_URLError_IsTransientNotParseFailure() {
        // The single most common cloud transport failure (laptop offline) must
        // never be presented as a model parse failure.
        var strategy = LLMRetryStrategy()
        let action = strategy.handleError(URLError(.notConnectedToInternet))

        if case .networkRetry(let message, _) = action {
            XCTAssertTrue(message.contains("internet"), "Should name the real cause, got: \(message)")
        } else {
            XCTFail("Expected .networkRetry for offline internet, got \(action)")
        }
        XCTAssertEqual(strategy.consecutiveParseFailures, 0)
    }

    func testUnlistedURLError_IsTransientNotParseFailure() {
        // ANY URLError is transport-level by definition — no code may fall
        // through to the parse path.
        var strategy = LLMRetryStrategy()
        let action = strategy.handleError(URLError(.secureConnectionFailed))

        if case .networkRetry = action {} else {
            XCTFail("Expected .networkRetry for unlisted URLError, got \(action)")
        }
        XCTAssertEqual(strategy.consecutiveParseFailures, 0)
    }

    // MARK: - Ollama httpError Routing (LLMProviderError, not CloudProviderError)

    func testOllamaHTTP404_ModelNotPulled_IsFatalModelNotFound() {
        var strategy = LLMRetryStrategy(transport: ollamaTransport)
        let action = strategy.handleError(
            LLMProviderError.httpError(404, #"{"error":"model 'llama9' not found, try pulling it first"}"#)
        )

        if case .fatal(_, let category) = action {
            XCTAssertEqual(category, .providerModelNotFound)
        } else {
            XCTFail("Expected .fatal(.providerModelNotFound) for Ollama 404, got \(action)")
        }
        XCTAssertEqual(strategy.consecutiveParseFailures, 0, "Ollama HTTP errors must not be treated as parse failures")
    }

    func testOllamaHTTP500_RunnerCrash_BoundedTransientThenFatal() {
        // Ollama budget is 2 transient retries.
        var strategy = LLMRetryStrategy(transport: ollamaTransport)
        let runnerCrash = LLMProviderError.httpError(500, #"{"error":"model runner has unexpectedly stopped"}"#)

        for _ in 1...2 {
            let action = strategy.handleError(runnerCrash)
            if case .networkRetry = action {} else {
                XCTFail("Expected .networkRetry within Ollama budget, got \(action)")
            }
        }

        let action = strategy.handleError(runnerCrash)
        if case .fatal(let reason, let category) = action {
            XCTAssertEqual(category, .providerServerError)
            XCTAssertTrue(reason.contains("model server"), "Ollama wording should say model server, got: \(reason)")
        } else {
            XCTFail("Expected .fatal after Ollama transient budget, got \(action)")
        }
        XCTAssertEqual(strategy.consecutiveParseFailures, 0)
    }

    func testOllamaHTTP429_QuotaFormattedBody_StillThrottles() {
        // formatHTTPError rewrites OpenAI-compat 429 bodies into text containing
        // neither "429" nor "rate limit" — classification must be status-driven,
        // not description-string-driven.
        var strategy = LLMRetryStrategy(transport: ollamaTransport)
        let action = strategy.handleError(
            LLMProviderError.httpError(429, #"{"error":{"message":"openai quota exceeded"}}"#)
        )

        if case .throttle = action {} else {
            XCTFail("Expected .throttle for httpError 429, got \(action)")
        }
        XCTAssertEqual(strategy.consecutiveParseFailures, 0)
    }

    func testMLXTimeout_FailsFastWithReloadGuidance() {
        // MLX transport budget is 0 — in-process failures fail fast with
        // MLX-appropriate wording, not "provider unavailable, try later".
        var strategy = LLMRetryStrategy(transport: ResolvedResiliencePolicy.resolved(for: .mlx).transport)
        let action = strategy.handleError(URLError(.timedOut))

        if case .fatal(let reason, _) = action {
            XCTAssertTrue(reason.contains("local model"), "MLX wording should say local model, got: \(reason)")
            XCTAssertTrue(reason.contains("reload"), "MLX remedy is reloading the model, got: \(reason)")
        } else {
            XCTFail("Expected immediate .fatal for MLX transient, got \(action)")
        }
    }

    // MARK: - Deterministic 4xx (typed fatal, never parse-retry)

    func testHTTP401_IsFatalAuth() {
        var strategy = LLMRetryStrategy()
        let action = strategy.handleError(makeCloudError(statusCode: 401))

        if case .fatal(let reason, let category) = action {
            XCTAssertEqual(category, .providerAuth)
            XCTAssertTrue(reason.contains("API key"), "Should point at the API key, got: \(reason)")
            XCTAssertTrue(reason.contains("req-123"), "Should carry the request-id for support")
        } else {
            XCTFail("Expected .fatal(.providerAuth) for 401, got \(action)")
        }
        XCTAssertEqual(strategy.consecutiveParseFailures, 0, "Provider errors must not touch the parse counter")
    }

    func testHTTP403_IsFatalAuth() {
        var strategy = LLMRetryStrategy()
        let action = strategy.handleError(makeCloudError(statusCode: 403))

        if case .fatal(_, let category) = action {
            XCTAssertEqual(category, .providerAuth)
        } else {
            XCTFail("Expected .fatal(.providerAuth) for 403, got \(action)")
        }
    }

    func testHTTP404_IsFatalModelNotFound() {
        var strategy = LLMRetryStrategy()
        let action = strategy.handleError(makeCloudError(statusCode: 404))

        if case .fatal(let reason, let category) = action {
            XCTAssertEqual(category, .providerModelNotFound)
            XCTAssertTrue(reason.contains("model"), "Should point at the model name, got: \(reason)")
        } else {
            XCTFail("Expected .fatal(.providerModelNotFound) for 404, got \(action)")
        }
    }

    func testHTTP400_ContextOverflow_IsFatalWithGuidance() {
        var strategy = LLMRetryStrategy()
        let action = strategy.handleError(makeCloudError(
            statusCode: 400,
            rawBody: #"{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 210000 tokens > 200000 maximum"}}"#
        ))

        if case .fatal(let reason, let category) = action {
            XCTAssertEqual(category, .providerCapabilityMissing)
            XCTAssertTrue(reason.contains("context window"), "Should explain the overflow, got: \(reason)")
            XCTAssertTrue(reason.contains("new chat") || reason.contains("compaction"), "Should suggest a remedy, got: \(reason)")
        } else {
            XCTFail("Expected context-overflow .fatal for 400 with overflow body, got \(action)")
        }
    }

    func testHTTP400_Generic_IsFatalBadRequest_WithBodySnippet() {
        var strategy = LLMRetryStrategy(maxConsecutiveParseFailures: 3)
        let action = strategy.handleError(makeCloudError(
            statusCode: 400,
            rawBody: #"{"error":{"message":"tools: unexpected field 'banana'"}}"#
        ))

        if case .fatal(let reason, let category) = action {
            XCTAssertEqual(category, .providerBadRequest)
            XCTAssertTrue(reason.contains("banana"), "Should include the body snippet for triage, got: \(reason)")
        } else {
            XCTFail("Expected .fatal(.providerBadRequest) for generic 400, got \(action)")
        }
        XCTAssertEqual(strategy.consecutiveParseFailures, 0, "4xx must never be treated as a model parse failure")
    }

    // MARK: - Model Unloaded (unchanged contract)

    func testModelUnloaded_MLX_ReturnsModelReload() {
        var strategy = LLMRetryStrategy()
        let error = makeGenericError("No MLX model is currently loaded. Please select a model first.")
        let action = strategy.handleError(error)

        if case .modelReload = action {} else {
            XCTFail("Expected .modelReload for MLX unloaded, got \(action)")
        }
    }

    func testModelUnloaded_Ollama_ReturnsModelReload() {
        var strategy = LLMRetryStrategy()
        let error = makeGenericError("No Ollama model available for inference.")
        let action = strategy.handleError(error)

        if case .modelReload = action {} else {
            XCTFail("Expected .modelReload for Ollama unloaded, got \(action)")
        }
    }

    // MARK: - Reset

    func testResetParseFailures_ResetsAllCounters() {
        var strategy = LLMRetryStrategy()
        _ = strategy.handleError(makeCloudError(statusCode: 429))
        _ = strategy.handleError(makeCloudError(statusCode: 500))
        _ = strategy.handleError(makeGenericError())
        XCTAssertGreaterThan(strategy.consecutiveRetries, 0)
        XCTAssertGreaterThan(strategy.consecutiveTransientFailures, 0)
        XCTAssertGreaterThan(strategy.consecutiveParseFailures, 0)

        strategy.resetParseFailures()
        XCTAssertEqual(strategy.consecutiveRetries, 0)
        XCTAssertEqual(strategy.consecutiveTransientFailures, 0)
        XCTAssertEqual(strategy.consecutiveParseFailures, 0)
    }
}
