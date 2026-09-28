// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ReasoningHandlingTests.swift
//  DevgenticTests
//
//  Item 7 of the 2026-09-27 OpenRouter review:
//    1. the final answer was ALSO emitted as a `.reasoning` event, so it appeared in the thinking
//       timeline as well as the message;
//    2. OpenRouter's `reasoning` field (its normalised thinking trace) was never read;
//    3. OpenRouter's `reasoning_details` was not echoed back on the assistant turn, which reasoning
//       models routed through OpenRouter need across tool calls.
//

import XCTest
@testable import devgentic

final class ReasoningHandlingTests: XCTestCase {

    private func reasoningTexts(_ events: [AgentStreamEvent]) -> [String] {
        events.compactMap { if case .reasoning(let text, _, _) = $0 { return text } else { return nil } }
    }

    private func contentText(_ events: [AgentStreamEvent]) -> String {
        events.compactMap { if case .content(let text) = $0 { return text } else { return nil } }.joined()
    }

    // MARK: - 1. The final answer is not also a "thought"

    func testFinalAnswerIsDeliveredAsContentOnly() async throws {
        let answer = "The logs folder contains 4 files."
        let provider = MockLLMProvider(steps: [ModernCognitiveStep(reasoning: answer)])
        let input = TestAgentInputFactory.make(query: "what is in logs?")

        let events = try await StreamCollector.collect(
            from: ReActAgentExecutor(maxIterations: 3).execute(model: provider, input: input) { _ in })

        XCTAssertTrue(contentText(events).contains(answer), "the answer must still reach the message")
        XCTAssertFalse(reasoningTexts(events).contains(where: { $0.contains(answer) }),
                       "the answer must not ALSO be rendered in the thinking timeline")
    }

    func testIntermediateMonologueIsStillShown() async throws {
        let tool = TestToolFactory.make(name: "list_directory", output: "a.txt")
        let provider = MockLLMProvider(steps: [
            ModernCognitiveStep(reasoning: "Let me look in the folder first.",
                                toolCalls: [TestToolCallFactory.make(name: "list_directory", input: "/tmp")]),
            ModernCognitiveStep(reasoning: "It contains a.txt."),
        ])
        let input = TestAgentInputFactory.make(query: "list it", tools: [tool])

        let events = try await StreamCollector.collect(
            from: ReActAgentExecutor(maxIterations: 3).execute(model: provider, input: input) { _ in })

        XCTAssertTrue(reasoningTexts(events).contains(where: { $0.contains("Let me look in the folder first.") }),
                      "text beside a tool call is monologue and stays in the timeline")
        XCTAssertFalse(reasoningTexts(events).contains(where: { $0.contains("It contains a.txt.") }))
    }

    // MARK: - 2. OpenRouter's thinking trace is read

    func testReasoningTrace_ReadsBothFieldNames() {
        XCTAssertEqual(OpenAILLMProvider.reasoningTrace(in: ["reasoning_content": "ds"]), "ds")
        XCTAssertEqual(OpenAILLMProvider.reasoningTrace(in: ["reasoning": "or"]), "or")
        XCTAssertEqual(OpenAILLMProvider.reasoningTrace(in: ["reasoning_content": "", "reasoning": "or"]), "or")
        XCTAssertNil(OpenAILLMProvider.reasoningTrace(in: ["content": "x", "reasoning": NSNull()]))
    }

    // MARK: - 3. reasoning_details is echoed back

    private let details: [Any] = [["type": "reasoning.encrypted", "data": "abc==", "id": "r1", "format": "anthropic-claude-v1"]]

    func testReasoningReplay_ParsedVerbatimOrNil() throws {
        let replay = try XCTUnwrap(OpenAILLMProvider.reasoningReplay(in: ["reasoning_details": details]))
        XCTAssertEqual(replay, JSONValue(details))
        XCTAssertNil(OpenAILLMProvider.reasoningReplay(in: ["reasoning_details": []]))
        XCTAssertNil(OpenAILLMProvider.reasoningReplay(in: ["content": "x"]))
    }

    func testOpenAIAdapterAttachesReplay_OthersIgnoreIt() {
        let call = PendingToolCall(id: "c1", name: "read_file", arguments: [:])
        let replay = JSONValue(details)

        let openAI = OpenAIToolTurnAdapter().assistantTurn(toolCalls: [call], reasoning: nil, replay: replay)
        XCTAssertNotNil(openAI["reasoning_details"])

        let plain = OpenAIToolTurnAdapter().assistantTurn(toolCalls: [call], reasoning: nil, replay: nil)
        XCTAssertNil(plain["reasoning_details"], "plain OpenAI turns must be unchanged")

        let ollama = OllamaToolTurnAdapter().assistantTurn(toolCalls: [call], reasoning: nil, replay: replay)
        XCTAssertNil(ollama["reasoning_details"])
    }

    func testValidationKeepsReplay() {
        let tool = TestToolFactory.make(name: "read_file", output: "x")
        let raw = ModernCognitiveStep(reasoning: "", toolCalls: [PendingToolCall(id: "c1", name: "read_file", arguments: [:])],
                                      reasoningReplay: JSONValue(details))
        let validated = NativeParsePipeline(registeredTools: [tool]).validate(step: raw)
        XCTAssertEqual(validated.reasoningReplay, JSONValue(details))
    }

    /// End to end: the second request carries the first step's reasoning_details on its assistant turn.
    func testReplayReachesTheNextRequest() async throws {
        let tool = TestToolFactory.make(name: "read_file", output: "contents")
        let provider = MockLLMProvider(steps: [
            ModernCognitiveStep(reasoning: "", toolCalls: [TestToolCallFactory.make(name: "read_file", input: "/tmp/a")],
                                reasoningReplay: JSONValue(details)),
            ModernCognitiveStep(reasoning: "Done."),
        ])
        let input = TestAgentInputFactory.make(
            query: "read it", tools: [tool],
            generatorStrategy: NativeStructuredGenerator(toolTurnAdapter: OpenAIToolTurnAdapter()))

        _ = try await StreamCollector.collect(
            from: ReActAgentExecutor(maxIterations: 3).execute(model: provider, input: input) { _ in })

        let second = try XCTUnwrap(provider.receivedCognitiveMessages.dropFirst().first)
        let assistant = try XCTUnwrap(second.first(where: { $0["role"] == "assistant" }))
        XCTAssertTrue(assistant["reasoning_details"]?.contains("reasoning.encrypted") == true, "\(assistant)")
    }
}
