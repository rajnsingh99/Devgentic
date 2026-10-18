// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  LastStepAnswerIntegrationTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class LastStepAnswerIntegrationTests: XCTestCase {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    private func countingTool(_ counter: Counter) -> AgentTool {
        AgentTool(name: "search", description: "A test tool.",
                  parameters: SchemaBuilder.object(properties: [("input", "string", "The input value.")], required: ["input"]),
                  textOnlyRun: { _ in counter.bump(); return "search result" })
    }

    private let finalAnswerStub = AgentTool(
        name: "final_answer", description: "Terminator stub mirroring production registration.",
        parameters: SchemaBuilder.object(properties: [("answer", "string", "The final response.")], required: ["answer"]),
        textOnlyRun: { _ in "unused — intercepted by the loop fast-path" })

    private func outcome(_ events: [AgentStreamEvent]) -> ExecutionOutcome? {
        events.compactMap { if case .executionFinished(let outcome, _) = $0 { return outcome }; return nil }.last
    }

    private func run(_ steps: [ModernCognitiveStep], tools: [AgentTool]) async throws -> [AgentStreamEvent] {
        let input = TestAgentInputFactory.make(query: "Find it", tools: tools)
        return try await StreamCollector.collect(
            from: ReActAgentExecutor(maxIterations: 2).execute(model: MockLLMProvider(steps: steps), input: input) { _ in })
    }

    /// Mutation that must turn this red: check the ceiling before the parse outcome again.
    func testAProseAnswerOnTheLastStepIsDelivered() async throws {
        let counter = Counter()
        let events = try await run([
            ModernCognitiveStep(reasoning: "Searching.", toolCalls: [TestToolCallFactory.make(name: "search")]),
            ModernCognitiveStep(reasoning: "The answer is 42."),
        ], tools: [countingTool(counter)])

        XCTAssertTrue(StreamCollector.contentText(from: events).contains("The answer is 42"),
                      StreamCollector.contentText(from: events))
        XCTAssertEqual(outcome(events), .completed, "an answered run is not an exhausted one")
    }

    /// Mutation that must turn this red: decide "exhausted" by the step count alone after the loop.
    func testAFinalAnswerOnTheLastStepIsDelivered() async throws {
        let counter = Counter()
        let events = try await run([
            ModernCognitiveStep(reasoning: "Searching.", toolCalls: [TestToolCallFactory.make(name: "search")]),
            ModernCognitiveStep(reasoning: "Done.", toolCalls: [
                PendingToolCall(id: UUID().uuidString, name: "final_answer", arguments: ["answer": .string("Found it: 7.")])
            ]),
        ], tools: [finalAnswerStub, countingTool(counter)])

        XCTAssertTrue(StreamCollector.contentText(from: events).contains("Found it: 7."),
                      StreamCollector.contentText(from: events))
        XCTAssertEqual(outcome(events), .completed)
    }

    /// Mutation that must turn this red: let `.maxIterationsReached` fall through to tool execution.
    func testAToolCalledOnTheLastStepIsNotRun() async throws {
        let counter = Counter()
        _ = try await run([
            ModernCognitiveStep(reasoning: "Searching.", toolCalls: [TestToolCallFactory.make(name: "search", input: "a")]),
            ModernCognitiveStep(reasoning: "Searching again.", toolCalls: [TestToolCallFactory.make(name: "search", input: "b")]),
        ], tools: [countingTool(counter)])

        XCTAssertEqual(counter.count, 1, "the last step's call would run with no step left to read its result")
    }
}
