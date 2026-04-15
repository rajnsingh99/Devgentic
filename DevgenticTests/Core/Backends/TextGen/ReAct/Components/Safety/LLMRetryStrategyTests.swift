//
//  LLMRetryStrategyTests.swift
//  DevgenticTests
//
//  Unit tests for LLMRetryStrategy — parse failure counting, backoff
//  behavior, HTTP 429 handling, network timeouts, and model unloaded detection.
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
        requestId: String? = "req-123"
    ) -> CloudProviderError {
        CloudProviderError(
            statusCode: statusCode,
            retryAfterSeconds: retryAfterSeconds,
            requestId: requestId,
            rawBody: "Error body",
            provider: .anthropic
        )
    }

    // MARK: - Parse Failure Counting

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

    // MARK: - Backoff Strategies

    func testExponentialBackoff_HTTP429_ProducesIncreasingDelays() {
        var strategy = LLMRetryStrategy(maxConsecutiveParseFailures: 10, backoffStrategy: .exponential)
        var delays: [TimeInterval] = []

        for _ in 1...4 {
            let action = strategy.handleError(makeCloudError(statusCode: 429))
            if case .throttle(let seconds, _) = action {
                delays.append(seconds)
            }
        }

        XCTAssertEqual(delays.count, 4, "All 4 should produce throttle actions")
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

    // MARK: - Cloud Provider Errors

    func testHTTP429_CloudProvider_ReturnsThrottle() {
        var strategy = LLMRetryStrategy()
        let action = strategy.handleError(makeCloudError(statusCode: 429))

        if case .throttle = action {} else {
            XCTFail("Expected .throttle for HTTP 429, got \(action)")
        }
    }

    func testHTTP5xx_CloudProvider_ReturnsNetworkRetry() {
        var strategy = LLMRetryStrategy()
        let action = strategy.handleError(makeCloudError(statusCode: 500))

        if case .networkRetry = action {} else {
            XCTFail("Expected .networkRetry for HTTP 500, got \(action)")
        }
    }

    func testHTTP4xx_NonRetryable_TreatedAsParseFailure() {
        var strategy = LLMRetryStrategy(maxConsecutiveParseFailures: 3)
        let action = strategy.handleError(makeCloudError(statusCode: 400))

        // 400 is not 429 or 5xx — falls through to parse failure path
        if case .parseRetry(_, let attempt, _) = action {
            XCTAssertEqual(attempt, 1, "Should increment parse failure counter")
        } else if case .abort = action {
            // Also acceptable if threshold is 1
        } else {
            XCTFail("Expected parse failure handling for HTTP 400, got \(action)")
        }
    }

    // MARK: - Network & Model Errors

    func testNetworkTimeout_URLError_ReturnsNetworkRetry() {
        var strategy = LLMRetryStrategy()
        let action = strategy.handleError(URLError(.timedOut))

        if case .networkRetry = action {} else {
            XCTFail("Expected .networkRetry for URLError.timedOut, got \(action)")
        }
    }

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
        // Trigger some errors to increment counters
        _ = strategy.handleError(makeCloudError(statusCode: 429))
        _ = strategy.handleError(makeGenericError())
        XCTAssertGreaterThan(strategy.consecutiveRetries, 0)
        XCTAssertGreaterThan(strategy.consecutiveParseFailures, 0)

        strategy.resetParseFailures()
        XCTAssertEqual(strategy.consecutiveRetries, 0)
        XCTAssertEqual(strategy.consecutiveParseFailures, 0)
    }
}
