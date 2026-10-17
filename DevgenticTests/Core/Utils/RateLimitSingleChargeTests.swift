// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RateLimitSingleChargeTests.swift
//  DevgenticTests
//
//  One model request = one rate-limit token. The ReAct loop (and Planning/Reflexion) used to take a
//  token with `wait(forKey:)` before each step, and `CloudRequestPipeline` took another for the same
//  HTTP request — every limit was halved. Callers above the HTTP layer now use the non-consuming
//  `waitForCapacity`.
//

import XCTest
@testable import devgentic

final class RateLimitSingleChargeTests: XCTestCase {

    // MARK: - The primitive

    func testWaitForCapacityNeverConsumes() async {
        let limiter = GlobalRateLimiter()
        let key = "single-charge-\(UUID())"
        await limiter.wait(forKey: key, category: .openRouterFree)          // burst 5 → 4 left
        for _ in 0..<10 {
            let waited = await limiter.waitForCapacity(forKey: key, category: .openRouterFree)
            XCTAssertEqual(waited, 0, "capacity was available, so there was nothing to wait for")
        }
        let left = await limiter.availableTokens(forKey: key) ?? 0
        XCTAssertEqual(left, 4, accuracy: 0.2, "ten capacity checks must not take a single token")
    }

    func testWaitForCapacityIsFreeForUnmeteredAndUnknownBuckets() async {
        let limiter = GlobalRateLimiter()
        let local = await limiter.waitForCapacity(forKey: "x", category: .local)
        let unknown = await limiter.waitForCapacity(forKey: "never-created-\(UUID())", category: .openRouter)
        XCTAssertEqual(local, 0)
        XCTAssertEqual(unknown, 0)
    }

    // MARK: - The wiring: a real executor run

    /// Charges the SHARED limiter once per model call, exactly as `CloudRequestPipeline` does.
    private final class PipelineChargingProvider: LLMProvider, @unchecked Sendable {
        let modelName = "pipeline-charging-mock"
        private let key: String
        private var steps: [ModernCognitiveStep]

        init(key: String, steps: [ModernCognitiveStep]) {
            self.key = key
            self.steps = steps
        }

        func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String { "" }
        func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func generateCognitiveStep(messages: [[String: String]], tools: [[String: Any]]?) async throws -> ModernCognitiveStep {
            await GlobalRateLimiter.shared.wait(forKey: key, category: .openRouterFree)
            return steps.isEmpty ? ModernCognitiveStep(reasoning: "Done.") : steps.removeFirst()
        }
    }

    /// Two model calls must cost two tokens. With the executor's own consuming wait restored this
    /// run costs four, and the assertion fails.
    func testAnAgentRunIsChargedOncePerModelCall() async throws {
        let key = "single-charge-run-\(UUID())"
        let tool = TestToolFactory.make(name: "list_directory", output: "a.txt")
        let provider = PipelineChargingProvider(key: key, steps: [
            ModernCognitiveStep(reasoning: "", toolCalls: [TestToolCallFactory.make(name: "list_directory", input: "/tmp")]),
            ModernCognitiveStep(reasoning: "It contains a.txt."),
        ])
        var input = TestAgentInputFactory.make(
            query: "list it", tools: [tool],
            generatorStrategy: NativeStructuredGenerator(toolTurnAdapter: OpenAIToolTurnAdapter()))
        input.rateLimitKey = key
        input.rateLimitCategory = .openRouterFree

        _ = try await StreamCollector.collect(
            from: ReActAgentExecutor(maxIterations: 4).execute(model: provider, input: input) { _ in })

        let available = await GlobalRateLimiter.shared.availableTokens(forKey: key)
        let left = try XCTUnwrap(available)
        XCTAssertEqual(left, 3, accuracy: 0.5, "burst 5 − 2 model calls; 1 left would mean every step was charged twice")
    }
}
