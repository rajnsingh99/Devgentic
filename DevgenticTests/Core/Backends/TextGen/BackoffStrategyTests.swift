//
//  BackoffStrategyTests.swift
//  DevgenticTests
//
//  Isolated tests for BackoffStrategy behavior as consumed by LLMRetryStrategy.
//

import XCTest
@testable import devgentic

final class BackoffStrategyTests: XCTestCase {

    private func makeCloudError429() -> CloudProviderError {
        CloudProviderError(
            statusCode: 429,
            retryAfterSeconds: nil,
            requestId: nil,
            rawBody: "Rate limited",
            provider: .anthropic
        )
    }

    func testExponentialBackoff_ProducesIncreasingSequence() {
        var strategy = LLMRetryStrategy(maxConsecutiveParseFailures: 10, backoffStrategy: .exponential)
        var delays: [TimeInterval] = []

        for _ in 1...5 {
            let action = strategy.handleError(makeCloudError429())
            if case .throttle(let seconds, _) = action {
                delays.append(seconds)
            }
        }

        XCTAssertEqual(delays.count, 5)
        for i in 0..<(delays.count - 1) {
            XCTAssertGreaterThan(delays[i + 1], delays[i],
                                 "Exponential: delay[\(i+1)] (\(delays[i+1])) should be > delay[\(i)] (\(delays[i]))")
        }
    }

    func testFixedBackoff_ProducesConstantSequence() {
        var strategy = LLMRetryStrategy(maxConsecutiveParseFailures: 10, backoffStrategy: .fixed)
        var delays: [TimeInterval] = []

        for _ in 1...4 {
            let action = strategy.handleError(makeCloudError429())
            if case .throttle(let seconds, _) = action {
                delays.append(seconds)
            }
        }

        XCTAssertEqual(delays.count, 4)
        let allEqual = delays.allSatisfy { abs($0 - 2.0) < 0.01 }
        XCTAssertTrue(allEqual, "Fixed backoff should always produce 2.0s delays, got \(delays)")
    }

    func testExponentialBackoff_CapsAt64Seconds() {
        var strategy = LLMRetryStrategy(maxConsecutiveParseFailures: 20, backoffStrategy: .exponential)
        var lastDelay: TimeInterval = 0

        // Fire 8 consecutive 429s — retries 1-8
        // pow(2, min(retry, 6)): 2, 4, 8, 16, 32, 64, 64, 64
        for _ in 1...8 {
            let action = strategy.handleError(makeCloudError429())
            if case .throttle(let seconds, _) = action {
                lastDelay = seconds
            }
        }

        XCTAssertEqual(lastDelay, 64.0, accuracy: 0.01,
                       "Exponential backoff should cap at 64s (pow(2, 6))")
    }

    func testBackoffStrategy_AllCases_CoverBothValues() {
        XCTAssertEqual(BackoffStrategy.allCases.count, 2)
        XCTAssertTrue(BackoffStrategy.allCases.contains(.fixed))
        XCTAssertTrue(BackoffStrategy.allCases.contains(.exponential))
    }
}
