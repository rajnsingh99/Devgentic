// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  NativeStepStreamingTests.swift
//  DevgenticTests
//
//  Item 6 of the 2026-09-27 OpenRouter review: agent steps on the native tool path were requested
//  with `stream: false`, so a 23–68s cloud step showed nothing until it finished. Steps now stream
//  their visible text as a provisional `.draftText` that the final `.content` replaces, and that is
//  withdrawn when the step turns out to be tool calls.
//

import XCTest
@testable import devgentic

// MARK: - Accumulator

final class OpenAIStreamAccumulatorTests: XCTestCase {

    private func chunk(_ json: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: json.data(using: .utf8)!) as! [String: Any]
    }

    func testTextDeltasAreReturnedAndAccumulated() {
        var acc = OpenAIStreamAccumulator()
        XCTAssertEqual(acc.consume(chunk(#"{"id":"gen-1","provider":"Nvidia","choices":[{"delta":{"role":"assistant","content":"Here "}}]}"#)), "Here ")
        XCTAssertEqual(acc.consume(chunk(#"{"choices":[{"delta":{"content":"are 4 files."},"finish_reason":"stop"}]}"#)), "are 4 files.")
        XCTAssertEqual(acc.message["content"] as? String, "Here are 4 files.")
        XCTAssertEqual(acc.finishReason, "stop")
    }

    /// Tool calls arrive as fragments keyed by `index`; `arguments` is a JSON string split mid-token.
    func testToolCallFragmentsReassembleIntoTheNonStreamingShape() {
        var acc = OpenAIStreamAccumulator()
        let lines = [
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"read_file","arguments":""}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_b","type":"function","function":{"name":"read_file","arguments":"{\"pa"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"path\":\"/a.txt\"}"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":"th\":\"/b.txt\"}"}}]}}],"usage":null}"#,
            #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
        ]
        for line in lines { XCTAssertNil(acc.consume(chunk(line)), "tool-call chunks carry no visible text") }

        let step = OpenAILLMProvider.step(fromMessage: acc.message, usage: nil)
        XCTAssertEqual(step.toolCalls.map(\.id), ["call_a", "call_b"])
        XCTAssertEqual(step.toolCalls.map(\.name), ["read_file", "read_file"])
        XCTAssertEqual(step.toolCalls[0].arguments["path"], .string("/a.txt"))
        XCTAssertEqual(step.toolCalls[1].arguments["path"], .string("/b.txt"))
        XCTAssertEqual(acc.finishReason, "tool_calls")
    }

    func testReasoningAndReasoningDetailsAreCollected() {
        var acc = OpenAIStreamAccumulator()
        _ = acc.consume(chunk(#"{"choices":[{"delta":{"reasoning":"Need to ","reasoning_details":[{"index":0,"type":"reasoning.text","text":"Need to ","format":"x"}]}}]}"#))
        _ = acc.consume(chunk(#"{"choices":[{"delta":{"reasoning":"list it.","reasoning_details":[{"index":0,"type":"reasoning.text","text":"list it.","signature":"sig"}]}}]}"#))

        let step = OpenAILLMProvider.step(fromMessage: acc.message, usage: nil)
        XCTAssertEqual(step.thought, "Need to list it.")
        guard case .array(let details)? = step.reasoningReplay, case .object(let first)? = details.first else {
            return XCTFail("reasoning_details must be kept for replay")
        }
        XCTAssertEqual(details.count, 1, "fragments with one index merge into one detail")
        XCTAssertEqual(first["text"], .string("Need to list it."))
        XCTAssertEqual(first["signature"], .string("sig"), "a field arriving later is kept")
        XCTAssertEqual(first["format"], .string("x"))
    }

    /// The usage chunk has empty `choices`; the id/provider from the first chunk are folded into it
    /// so `[OPENROUTER]` logging still names the generation and upstream.
    func testUsageChunkCarriesEarlierMetadata() throws {
        var acc = OpenAIStreamAccumulator()
        _ = acc.consume(chunk(#"{"id":"gen-9","provider":"Nvidia","model":"n/m:free","choices":[{"delta":{"content":"x"}}]}"#))
        _ = acc.consume(chunk(#"{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2,"cost":0}}"#))
        let usageChunk = try XCTUnwrap(acc.lastUsageChunk)
        XCTAssertEqual(usageChunk["id"] as? String, "gen-9")
        XCTAssertNotNil(OpenAILLMProvider.routerMetadataSummary(usageChunk)?.contains("upstream: Nvidia"))
        XCTAssertEqual(TokenUsage.fromOpenAI(usageChunk, pricing: PricingKey(provider: .openRouter, model: "n/m:free"))?.inputTokens, 10)
    }

    func testRawChunkDirective() {
        guard case .emit(let payload) = OpenAILLMProvider.rawChunkDirective(#"data: {"choices":[]}"#, provider: .openRouter) else { return XCTFail() }
        XCTAssertEqual(payload, #"{"choices":[]}"#)
        guard case .finish = OpenAILLMProvider.rawChunkDirective("data: [DONE]", provider: .openRouter) else { return XCTFail() }
        guard case .skip = OpenAILLMProvider.rawChunkDirective(": OPENROUTER PROCESSING", provider: .openRouter) else { return XCTFail() }
        guard case .fail(let error) = OpenAILLMProvider.rawChunkDirective(#"data: {"error":{"code":503,"message":"down"}}"#, provider: .openRouter) else {
            return XCTFail("an in-band error must fail the step")
        }
        XCTAssertEqual((error as? CloudProviderError)?.statusCode, 503)
    }
}

// MARK: - Relay

final class DraftTextRelayTests: XCTestCase {

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [String] = []
        var values: [String] { lock.lock(); defer { lock.unlock() }; return _values }
        func add(_ v: String) { lock.lock(); _values.append(v); lock.unlock() }
    }

    func testDisabledRelayHandsTheGeneratorNoCallback() {
        XCTAssertNil(DraftTextRelay(enabled: false) { _ in }.onTextDelta)
    }

    func testEmissionsAreCumulativeThrottledAndFlushedWhole() throws {
        let sink = Sink()
        let relay = DraftTextRelay(enabled: true, interval: 60) { sink.add($0) }
        let delta = try XCTUnwrap(relay.onTextDelta)
        delta("Here "); delta("are "); delta("files.")
        XCTAssertEqual(sink.values, ["Here "], "first delta shows at once; the rest wait for the interval")
        relay.flush()
        XCTAssertEqual(sink.values.last, "Here are files.", "the final answer is shown whole before .content replaces it")
    }

    func testWithdrawOnlyWhenSomethingWasShown() throws {
        let quiet = Sink()
        DraftTextRelay(enabled: true) { quiet.add($0) }.withdraw()
        XCTAssertEqual(quiet.values, [], "no draft, nothing to withdraw")

        let shown = Sink()
        let relay = DraftTextRelay(enabled: true) { shown.add($0) }
        try XCTUnwrap(relay.onTextDelta)("Checking the folder")
        relay.withdraw()
        XCTAssertEqual(shown.values, ["Checking the folder", ""])
    }

    func testDraftDisplayContent() {
        XCTAssertEqual(ChatMessage.draftDisplayContent(baseline: .markdownText(""), draft: "abc").textContent, "abc")
        XCTAssertEqual(ChatMessage.draftDisplayContent(baseline: .markdownText("Earlier. "), draft: "abc").textContent, "Earlier. abc")
    }
}

// MARK: - Executor, end to end

/// Streams each step's text in two halves before returning it.
private final class StreamingStepProvider: LLMProvider, @unchecked Sendable {
    let modelName = "streaming-mock"
    private var steps: [ModernCognitiveStep]
    private let failAfterFirstDelta: Bool

    init(steps: [ModernCognitiveStep], failAfterFirstDelta: Bool = false) {
        self.steps = steps
        self.failAfterFirstDelta = failAfterFirstDelta
    }

    func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String { "" }
    func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func generateCognitiveStep(messages: [[String: String]], tools: [[String: Any]]?) async throws -> ModernCognitiveStep {
        steps.isEmpty ? ModernCognitiveStep(reasoning: "No more steps.") : steps.removeFirst()
    }
    func generateCognitiveStepStreaming(nativeMessages: [[String: Any]], tools: [[String: Any]]?,
                                        onTextDelta: @escaping @Sendable (String) -> Void) async throws -> ModernCognitiveStep {
        let step = try await generateCognitiveStep(messages: [], tools: tools)
        let text = step.reasoning
        let mid = text.index(text.startIndex, offsetBy: text.count / 2)
        onTextDelta(String(text[..<mid]))
        if failAfterFirstDelta { throw CloudProviderError(statusCode: 400, retryAfterSeconds: nil, requestId: nil, rawBody: "bad", provider: .openRouter) }
        onTextDelta(String(text[mid...]))
        return step
    }
}

final class NativeStepStreamingExecutorTests: XCTestCase {

    private var savedSetting: Any?

    override func setUp() {
        super.setUp()
        savedSetting = UserDefaults.standard.object(forKey: AppSettings.useStreamingResponseKey)
        UserDefaults.standard.set(true, forKey: AppSettings.useStreamingResponseKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(savedSetting, forKey: AppSettings.useStreamingResponseKey)
        super.tearDown()
    }

    private func drafts(_ events: [AgentStreamEvent]) -> [String] {
        events.compactMap { if case .draftText(let t) = $0 { return t } else { return nil } }
    }

    private func run(_ provider: StreamingStepProvider, tools: [AgentTool] = []) async throws -> [AgentStreamEvent] {
        // The factory defaults to a mock generator; streaming lives on the native path.
        let input = TestAgentInputFactory.make(query: "q", tools: tools,
                                               generatorStrategy: NativeStructuredGenerator(toolTurnAdapter: OpenAIToolTurnAdapter()))
        return try await StreamCollector.collect(
            from: ReActAgentExecutor(maxIterations: 4).execute(model: provider, input: input) { _ in })
    }

    func testMonologueDraftIsWithdrawnAndTheAnswerDraftIsReplacedByContent() async throws {
        let tool = TestToolFactory.make(name: "list_directory", output: "a.txt")
        let events = try await run(StreamingStepProvider(steps: [
            ModernCognitiveStep(reasoning: "Checking the folder.",
                                toolCalls: [TestToolCallFactory.make(name: "list_directory", input: "/tmp")]),
            ModernCognitiveStep(reasoning: "It contains a.txt."),
        ]), tools: [tool])

        let d = drafts(events)
        XCTAssertTrue(d.contains(where: { $0.hasPrefix("Checking") }), "the monologue streamed live")
        let withdrawal = try XCTUnwrap(events.firstIndex { if case .draftText("") = $0 { return true }; return false })
        let toolCall = try XCTUnwrap(events.firstIndex { if case .toolCall = $0 { return true }; return false })
        XCTAssertLessThan(withdrawal, toolCall, "the draft is withdrawn before the tool runs")
        XCTAssertEqual(d.last, "It contains a.txt.", "the answer draft is left whole for .content to replace")

        let lastDraft = try XCTUnwrap(events.lastIndex { if case .draftText = $0 { return true }; return false })
        let content = try XCTUnwrap(events.lastIndex { if case .content = $0 { return true }; return false })
        XCTAssertLessThan(lastDraft, content)
    }

    func testFailedStepWithdrawsItsDraft() async throws {
        let events = try await run(StreamingStepProvider(steps: [ModernCognitiveStep(reasoning: "Partial answer")],
                                                         failAfterFirstDelta: true))
        XCTAssertEqual(drafts(events).last, "", "a step that threw must not leave its partial text in the bubble")
    }

    func testNoDraftsWhenStreamingIsOff() async throws {
        UserDefaults.standard.set(false, forKey: AppSettings.useStreamingResponseKey)
        let events = try await run(StreamingStepProvider(steps: [ModernCognitiveStep(reasoning: "Answer.")]))
        XCTAssertTrue(drafts(events).isEmpty)
    }
}
