// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  NativeTurnPairingIntegrationTests.swift
//  DevgenticTests
//
//  Regression tests for the native turn-pairing invariant (audit #4): every
//  tool call serialized into the assistant turn must have a matching tool
//  result turn. executeToolCalls drops calls without producing observations
//  (exact-duplicate dedup, same-path write dedup, final_answer siblings) —
//  the executor must serialize the assistant turn from the EXECUTED calls,
//  or Claude/OpenAI reject the history with a 400 and Gemini errors on the
//  functionCall/functionResponse count mismatch.
//
//  MockLLMProvider receives the native turn array via the protocol's default
//  downgrade: the assistant turn's `tool_calls` array arrives JSON-encoded as
//  a string, and each tool result arrives as a `role:"tool"` message — so the
//  pairing is observable by decoding the captured second request.
//

import XCTest
@testable import devgentic

final class NativeTurnPairingIntegrationTests: XCTestCase {

    /// Decodes the JSON-encoded `tool_calls` array from a downgraded assistant message.
    private func decodedToolCalls(in message: [String: String]) throws -> [[String: Any]] {
        let json = try XCTUnwrap(message["tool_calls"], "Assistant message should carry tool_calls")
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    private func assertPairing(in request: [[String: String]], expectedCount: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let assistantMessage = try XCTUnwrap(
            request.first(where: { $0["tool_calls"] != nil }),
            "Request should contain an assistant turn with tool_calls", file: file, line: line
        )
        let toolCalls = try decodedToolCalls(in: assistantMessage)
        let toolResults = request.filter { $0["role"] == "tool" }

        XCTAssertEqual(toolCalls.count, expectedCount, "Assistant turn should carry only executed calls", file: file, line: line)
        XCTAssertEqual(
            toolCalls.count, toolResults.count,
            "Every serialized tool call must have a matching tool result turn", file: file, line: line
        )
    }

    func testDuplicateToolCalls_AssistantTurnMatchesResults() async throws {
        // The model emits the same call twice (distinct ids, identical name+args).
        // Exact dedup executes it once — the assistant turn must then carry ONE
        // call paired with ONE result, not two calls and one result.
        let tool = TestToolFactory.make(name: "search", output: "Found 3 results")
        let provider = MockLLMProvider(steps: [
            ModernCognitiveStep(
                reasoning: "Searching twice by mistake.",
                toolCalls: [
                    TestToolCallFactory.make(name: "search", input: "swift actors"),
                    TestToolCallFactory.make(name: "search", input: "swift actors")
                ]
            ),
            ModernCognitiveStep(reasoning: "Done.")
        ])

        let executor = ReActAgentExecutor(maxIterations: 5)
        let input = TestAgentInputFactory.make(
            query: "Research swift actors",
            tools: [tool],
            generatorStrategy: NativeStructuredGenerator()
        )

        let stream = executor.execute(model: provider, input: input) { _ in }
        _ = try await StreamCollector.collect(from: stream)

        XCTAssertEqual(provider.receivedCognitiveMessages.count, 2)
        try assertPairing(in: provider.receivedCognitiveMessages[1], expectedCount: 1)
    }

    func testRejectedFinalAnswerWithSibling_DroppedSiblingNotSerialized() async throws {
        // final_answer alongside a sibling: the sibling is dropped by the fast-path,
        // and the empty answer makes final_answer non-terminal — the loop continues.
        // The next request must pair 1 call (final_answer) with 1 result; the
        // never-executed sibling must not appear in the assistant turn.
        //
        // final_answer must be REGISTERED here (mirroring AgentConnect's always-on
        // injection): the native path runs NativeParsePipeline validation, which
        // silently drops unregistered names before the loop ever sees them. The
        // stub's run closure never executes — the loop intercepts by name.
        let tool = TestToolFactory.make(name: "search", output: "OK")
        let finalAnswerStub = AgentTool(
            name: "final_answer",
            description: "Terminator stub mirroring production registration.",
            parameters: SchemaBuilder.object(
                properties: [("answer", "string", "The final response.")],
                required: ["answer"]
            ),
            textOnlyRun: { _ in "unused — intercepted by the loop fast-path" }
        )
        let provider = MockLLMProvider(steps: [
            ModernCognitiveStep(
                reasoning: "Wrapping up while also searching.",
                toolCalls: [
                    PendingToolCall(id: UUID().uuidString, name: "final_answer", arguments: ["answer": .string("")]),
                    TestToolCallFactory.make(name: "search", input: "loose end")
                ]
            ),
            ModernCognitiveStep(reasoning: "Here is my actual answer.")
        ])

        let executor = ReActAgentExecutor(maxIterations: 5)
        let input = TestAgentInputFactory.make(
            query: "Summarize the findings",
            tools: [finalAnswerStub, tool],
            generatorStrategy: NativeStructuredGenerator()
        )

        let stream = executor.execute(model: provider, input: input) { _ in }
        _ = try await StreamCollector.collect(from: stream)

        XCTAssertEqual(provider.receivedCognitiveMessages.count, 2)
        let secondRequest = provider.receivedCognitiveMessages[1]
        try assertPairing(in: secondRequest, expectedCount: 1)

        let assistantMessage = try XCTUnwrap(secondRequest.first(where: { $0["tool_calls"] != nil }))
        let names = try decodedToolCalls(in: assistantMessage).compactMap {
            ($0["function"] as? [String: Any])?["name"] as? String
        }
        XCTAssertEqual(names, ["final_answer"], "Dropped sibling must not be serialized into the assistant turn")
    }
}
