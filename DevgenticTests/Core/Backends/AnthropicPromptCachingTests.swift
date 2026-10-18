// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AnthropicPromptCachingTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class AnthropicPromptCachingTests: XCTestCase {

    private func text(_ role: String, _ text: String) -> [String: Any] { ["role": role, "content": text] }

    private func isMarked(_ message: [String: Any]) -> Bool {
        guard let blocks = message["content"] as? [[String: Any]] else { return false }
        return blocks.contains { $0["cache_control"] != nil }
    }

    private func markedIndices(_ body: [String: Any]) -> [Int] {
        ((body["messages"] as? [[String: Any]]) ?? []).enumerated().filter { isMarked($0.element) }.map(\.offset)
    }

    private func systemIsMarked(_ body: [String: Any]) -> Bool {
        (body["system"] as? [[String: Any]])?.last?["cache_control"] != nil
    }

    private let toolUse: [String: Any] = ["role": "assistant", "content": [
        ["type": "text", "text": "Reading it."],
        ["type": "tool_use", "id": "t1", "name": "read_file", "input": ["path": "a.swift"]],
    ]]
    private let toolResult: [String: Any] = ["role": "user", "content": [
        ["type": "tool_result", "tool_use_id": "t1", "content": "4 lines"],
    ]]

    // MARK: - Placement

    func testTheSystemMessageBecomesOneMarkedBlockWithTheSameText() {
        var body: [String: Any] = ["system": "SYSTEM TEXT", "messages": [text("user", "hi")]]
        AnthropicPromptCaching.markBreakpoints(in: &body)
        let blocks = body["system"] as? [[String: Any]]
        XCTAssertEqual(blocks?.count, 1)
        XCTAssertEqual(blocks?.first?["text"] as? String, "SYSTEM TEXT")
        XCTAssertNotNil(blocks?.first?["cache_control"])
    }

    /// A Bot message: system + history are what the next message shares. The question itself
    /// comes back next time as plain history, without its turn context, so marking it would only
    /// ever be written, never read — a 25% surcharge.
    func testABotRequestMarksTheConversationSoFarButNotTheQuestion() {
        var body: [String: Any] = ["system": "S", "messages": [
            text("user", "first question"), text("assistant", "first answer"), text("user", "turn context + second question"),
        ]]
        XCTAssertEqual(AnthropicPromptCaching.markBreakpoints(in: &body), 2)
        XCTAssertTrue(systemIsMarked(body))
        XCTAssertEqual(markedIndices(body), [1], "only the last history turn")
    }

    func testTheFirstBotMessageMarksOnlyTheSystemMessage() {
        var body: [String: Any] = ["system": "S", "messages": [text("user", "question")]]
        XCTAssertEqual(AnthropicPromptCaching.markBreakpoints(in: &body), 1)
        XCTAssertEqual(markedIndices(body), [])
    }

    /// An agent loop is sent again with a tool result appended: the end of THIS request is the
    /// prefix of the next iteration. The kickoff turn is the current turn, so the history end
    /// before it is marked too — the tool results are not mistaken for the start of a turn.
    func testAnAgentIterationMarksTheHistoryEndAndTheEndOfTheRequest() {
        var body: [String: Any] = ["system": "S", "tools": [["name": "read_file"]], "messages": [
            text("user", "earlier question"), text("assistant", "earlier answer"),
            text("user", "kickoff"), toolUse, toolResult,
        ]]
        XCTAssertEqual(AnthropicPromptCaching.markBreakpoints(in: &body), 3)
        XCTAssertEqual(markedIndices(body), [1, 4])
        let lastBlock = ((body["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]])?.last
        XCTAssertEqual(lastBlock?["type"] as? String, "tool_result", "the breakpoint rides the tool result block itself")
    }

    func testTheFirstIterationOfAFirstMessageMarksTheSystemAndTheKickoff() {
        var body: [String: Any] = ["system": "S", "tools": [["name": "read_file"]], "messages": [text("user", "kickoff")]]
        XCTAssertEqual(AnthropicPromptCaching.markBreakpoints(in: &body), 2)
        XCTAssertEqual(markedIndices(body), [0])
    }

    /// The API rejects a breakpoint on a thinking block and on an empty text block.
    func testThinkingAndEmptyTextBlocksAreNeverMarked() {
        let thinkingLast: [String: Any] = ["role": "assistant", "content": [
            ["type": "text", "text": "Answer."],
            ["type": "thinking", "thinking": "…", "signature": "sig"],
        ]]
        var body: [String: Any] = ["system": "S", "messages": [text("user", "q1"), thinkingLast, text("user", "q2")]]
        AnthropicPromptCaching.markBreakpoints(in: &body)
        let blocks = (body["messages"] as? [[String: Any]])?[1]["content"] as? [[String: Any]]
        XCTAssertNotNil(blocks?[0]["cache_control"], "the text block before the thinking block carries it")
        XCTAssertNil(blocks?[1]["cache_control"])

        var empty: [String: Any] = ["messages": [text("assistant", ""), text("user", "q")]]
        XCTAssertEqual(AnthropicPromptCaching.markBreakpoints(in: &empty), 0)
        XCTAssertEqual((empty["messages"] as? [[String: Any]])?[0]["content"] as? String, "", "an unmarkable message is left as it was")
    }

    func testNeverMoreThanTheAPILimit() {
        var body: [String: Any] = ["system": "S", "tools": [["name": "t"]], "messages": [
            text("user", "a"), text("assistant", "b"), text("user", "c"), toolUse, toolResult,
        ]]
        XCTAssertLessThanOrEqual(AnthropicPromptCaching.markBreakpoints(in: &body), AnthropicPromptCaching.maxBreakpoints)
    }

    // MARK: - Through the shipped builders

    private func provider() -> ClaudeLLMProvider {
        ClaudeLLMProvider(config: LLMProviderConfig(apiKey: "test-key", baseURL: URL(string: "https://api.anthropic.com/v1")!,
                                                    modelName: "claude-sonnet-4-5"))
    }

    func testTheAgentBuilderSendsBreakpoints() {
        let body = provider().debugRequestBody(
            messages: [["role": "system", "content": "S"], ["role": "user", "content": "earlier"],
                       ["role": "assistant", "content": "answer"], ["role": "user", "content": "kickoff"]],
            tools: [["name": "read_file", "input_schema": ["type": "object"]]])
        XCTAssertTrue(systemIsMarked(body))
        XCTAssertEqual(markedIndices(body), [1, 2])
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body), "the marked body must still serialize")
    }

    func testTheBotStreamingBuilderSendsBreakpoints() {
        let body = provider().debugStreamingRequestBody(
            messages: [["role": "system", "content": "S"], ["role": "user", "content": "earlier"],
                       ["role": "assistant", "content": "answer"], ["role": "user", "content": "question"]])
        XCTAssertTrue(systemIsMarked(body))
        XCTAssertEqual(markedIndices(body), [1])
    }

    /// The native agent path used to build its body inline; it must go through the shared builder,
    /// or it sends no breakpoints (and escapes every shape test). A live call needs a server, so
    /// this pins the call.
    func testTheNativeAgentPathUsesTheSharedBuilder() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let source = try? String(contentsOf: root.appendingPathComponent("Devgentic/Core/Backends/ClaudeLLMProvider.swift"), encoding: .utf8) else {
            throw XCTSkip("ClaudeLLMProvider.swift not reachable — running outside a checkout")
        }
        let native = try XCTUnwrap(source.range(of: "func generateCognitiveStep(nativeMessages:"))
        let rest = source[native.upperBound...]
        let end = rest.range(of: "\n    func ")?.lowerBound ?? rest.endIndex
        XCTAssertTrue(rest[..<end].contains("cognitiveStepBody(anthropicMessages:"),
                      "the native agent path builds its own body again — it sends no cache breakpoints")
    }
}

// MARK: - Usage and cost

/// Counts only — no price lookup, so these never depend on the bundled list.
private let unpriced = PricingKey(provider: .unpriced, model: "count-only")

/// Fixed rates for the pricing maths, so it never drifts with the bundled list.
private let sonnetRates = ModelPrice(input: 3e-6, output: 15e-6, cacheRead: 0.3e-6, cacheWrite: 3.75e-6,
                                     inputAbove200k: nil, outputAbove200k: nil, cacheReadAbove200k: nil, cacheWriteAbove200k: nil)
private let gpt4oRates = ModelPrice(input: 2.5e-6, output: 10e-6, cacheRead: 1.25e-6, cacheWrite: nil,
                                    inputAbove200k: nil, outputAbove200k: nil, cacheReadAbove200k: nil, cacheWriteAbove200k: nil)
private let geminiFlashRates = ModelPrice(input: 0.1e-6, output: 0.4e-6, cacheRead: 0.025e-6, cacheWrite: nil,
                                          inputAbove200k: nil, outputAbove200k: nil, cacheReadAbove200k: nil, cacheWriteAbove200k: nil)

final class AnthropicCacheUsageTests: XCTestCase {

    /// `input_tokens` is only the part after the last breakpoint; the prompt is all three.
    func testTheWholePromptIsCountedNotJustTheUncachedTail() {
        let usage = TokenUsage.fromAnthropic(["usage": [
            "input_tokens": 120, "cache_read_input_tokens": 18_000, "cache_creation_input_tokens": 900, "output_tokens": 50,
        ]], pricing: unpriced)
        XCTAssertEqual(usage?.inputTokens, 19_020)
        XCTAssertEqual(usage?.cacheReadTokens, 18_000)
        XCTAssertEqual(usage?.cacheWriteTokens, 900)
        XCTAssertEqual(usage?.outputTokens, 50)
    }

    func testAResponseWithoutCacheFieldsReadsAsBefore() {
        let usage = TokenUsage.fromAnthropic(["usage": ["input_tokens": 300, "output_tokens": 20]], pricing: unpriced)
        XCTAssertEqual(usage, TokenUsage(inputTokens: 300, outputTokens: 20))
    }

    func testAccumulatingARunKeepsTheCacheSplit() {
        var total = TokenUsage(inputTokens: 1_000, outputTokens: 10, cacheReadTokens: 0, cacheWriteTokens: 900)
        total.accumulate(TokenUsage(inputTokens: 1_100, outputTokens: 10, cacheReadTokens: 900, cacheWriteTokens: 150))
        XCTAssertEqual(total.cacheReadTokens, 900)
        XCTAssertEqual(total.cacheWriteTokens, 1_050)
        XCTAssertEqual(total.inputTokens, 2_100)
    }

    /// claude-sonnet: $3/M input. A million tokens read from the cache cost a tenth; written, 1.25×.
    func testCachedTokensArePricedAtTheirOwnRates() {
        XCTAssertEqual(sonnetRates.cost(of: TokenUsage(inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 1_000_000)), 0.30, accuracy: 1e-9)
        XCTAssertEqual(sonnetRates.cost(of: TokenUsage(inputTokens: 1_000_000, outputTokens: 0, cacheWriteTokens: 1_000_000)), 3.75, accuracy: 1e-9)
        XCTAssertEqual(gpt4oRates.cost(of: TokenUsage(inputTokens: 1_000_000, outputTokens: 0)), 2.50, accuracy: 1e-9,
                       "a call with no cache split prices at the input rate")
    }

    // MARK: - Stored usage

    /// Usage is stored on every chat message; blobs written before these fields existed must load.
    func testUsageStoredBeforeTheCacheFieldsStillDecodes() throws {
        let old = Data(#"{"inputTokens": 40, "outputTokens": 7, "isEstimated": false}"#.utf8)
        let usage = try JSONDecoder().decode(TokenUsage.self, from: old)
        XCTAssertEqual(usage, TokenUsage(inputTokens: 40, outputTokens: 7))
    }

    func testEveryFieldRoundTrips() throws {
        let usage = TokenUsage(inputTokens: 5, outputTokens: 6, isEstimated: true, cacheReadTokens: 3, cacheWriteTokens: 1)
        XCTAssertEqual(try JSONDecoder().decode(TokenUsage.self, from: JSONEncoder().encode(usage)), usage)
    }
}

// MARK: - OpenAI and Gemini

/// OpenAI and Gemini cache a repeated prefix on their own; layout B is what makes the prefix repeat.
/// Unlike Anthropic, both report the cached part INSIDE the prompt total.
final class ImplicitCacheUsageTests: XCTestCase {

    func testOpenAICachedTokensAreReadAndStayInsideThePromptTotal() {
        let usage = TokenUsage.fromOpenAI(["usage": [
            "prompt_tokens": 12_000, "completion_tokens": 80, "prompt_tokens_details": ["cached_tokens": 10_240],
        ]], pricing: unpriced)
        XCTAssertEqual(usage?.inputTokens, 12_000, "prompt_tokens already includes the cached part")
        XCTAssertEqual(usage?.cacheReadTokens, 10_240)
        XCTAssertEqual(usage?.cacheWriteTokens, 0, "OpenAI charges no cache write")
    }

    func testGeminiCachedTokensAreReadAndStayInsideThePromptTotal() {
        let usage = TokenUsage.fromGemini(["usageMetadata": [
            "promptTokenCount": 9_000, "candidatesTokenCount": 40, "cachedContentTokenCount": 8_192,
        ]], pricing: unpriced)
        XCTAssertEqual(usage?.inputTokens, 9_000)
        XCTAssertEqual(usage?.cacheReadTokens, 8_192)
        XCTAssertEqual(usage?.cacheWriteTokens, 0)
    }

    func testResponsesWithoutTheFieldsReadAsBefore() {
        XCTAssertEqual(TokenUsage.fromOpenAI(["usage": ["prompt_tokens": 100, "completion_tokens": 5]], pricing: unpriced),
                       TokenUsage(inputTokens: 100, outputTokens: 5))
        XCTAssertEqual(TokenUsage.fromGemini(["usageMetadata": ["promptTokenCount": 100, "candidatesTokenCount": 5]], pricing: unpriced),
                       TokenUsage(inputTokens: 100, outputTokens: 5))
    }

    /// A server that reports more cached than prompt tokens must not make the uncached part negative.
    func testACachedCountAboveThePromptIsCapped() {
        let usage = TokenUsage.fromOpenAI(["usage": [
            "prompt_tokens": 100, "completion_tokens": 5, "prompt_tokens_details": ["cached_tokens": 500],
        ]], pricing: unpriced)
        XCTAssertEqual(usage?.cacheReadTokens, 100)
    }

    /// gpt-4o: $2.50/M input, cached at half. gemini-2.0-flash: $0.10/M, cached at a quarter.
    func testEachProviderPricesItsCachedTokensAtItsOwnRate() {
        let cached = TokenUsage(inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 1_000_000)
        XCTAssertEqual(gpt4oRates.cost(of: cached), 1.25, accuracy: 1e-9)
        XCTAssertEqual(geminiFlashRates.cost(of: cached), 0.025, accuracy: 1e-9)
        XCTAssertEqual(gpt4oRates.cost(of: TokenUsage(inputTokens: 2_000_000, outputTokens: 0, cacheReadTokens: 1_000_000)),
                       2.50 + 1.25, accuracy: 1e-9, "the uncached part stays at the full rate")
    }

    /// Thinking tokens are billed as output and reported outside the candidates.
    func testGeminiThinkingTokensCountAsOutput() {
        let usage = TokenUsage.fromGemini(["usageMetadata": [
            "promptTokenCount": 500, "candidatesTokenCount": 40, "thoughtsTokenCount": 900,
        ]], pricing: unpriced)
        XCTAssertEqual(usage?.outputTokens, 940)
    }
}
