// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CloudProviderProtocolTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

/// Answers any request to `host` with `Self.response` and records the request body.
private final class CloudStubProtocol: URLProtocol {
    static let host = "cloud-protocol-stub.test"
    nonisolated(unsafe) static var response = Data()
    nonisolated(unsafe) static var contentType = "application/json"
    nonisolated(unsafe) static var lastBody: [String: Any]?

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastBody = Self.readBody(of: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": Self.contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// A URLProtocol sees the body as a stream, never as `httpBody`.
    private static func readBody(of request: URLRequest) -> [String: Any]? {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

final class CloudProviderProtocolTests: XCTestCase {

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(CloudStubProtocol.self)
        CloudStubProtocol.lastBody = nil
        CloudStubProtocol.contentType = "application/json"
    }

    override func tearDown() {
        URLProtocol.unregisterClass(CloudStubProtocol.self)
        super.tearDown()
    }

    private func openAI(model: String, options: [String: JSONValue] = [:]) -> OpenAILLMProvider {
        OpenAILLMProvider(
            config: LLMProviderConfig(apiKey: "k", baseURL: URL(string: "https://\(CloudStubProtocol.host)/v1/")!,
                                      modelName: model, options: options, rateLimitKey: "cr-batch1-\(UUID().uuidString)"),
            providerCategory: .openAI)
    }

    private func gemini(model: String) -> GeminiLLMProvider {
        GeminiLLMProvider(config: LLMProviderConfig(
            apiKey: "k", baseURL: URL(string: "https://\(CloudStubProtocol.host)/v1beta/models/\(model)")!,
            modelName: model, rateLimitKey: "cr-batch1-\(UUID().uuidString)"))
    }

    private static func json(_ object: Any) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data() }

    private static func sse(_ chunks: [[String: Any]], done: Bool = true) -> Data {
        var text = chunks.map { "data: " + String(decoding: json($0), as: UTF8.self) + "\n\n" }.joined()
        if done { text += "data: [DONE]\n\n" }
        return Data(text.utf8)
    }

    // MARK: - CR-27: GPT-5.x is a reasoning family

    func testEveryGPTFromFiveOnIsReasoning() {
        for id in ["gpt-5", "gpt-5-mini", "gpt-5.1", "gpt-5.2", "gpt-5.1-codex", "gpt-5.2-pro",
                   "openai/gpt-5.1", "openai/gpt-5.2-pro", "gpt-5.5", "gpt-6"] {
            XCTAssertEqual(OpenAIModelFamily.classify(modelName: id), .reasoning, id)
        }
    }

    func testOlderGPTsAndLookalikesStayStandard() {
        for id in ["gpt-4o", "gpt-4o-mini", "gpt-4.1", "gpt-4.1-mini", "gpt-3.5-turbo", "gpt-4-turbo",
                   "gpt-oss-20b", "gpt-5x-local", "gpt-120b-merge", "gpt-"] {
            XCTAssertEqual(OpenAIModelFamily.classify(modelName: id), .standard, id)
        }
    }

    /// THE CALL SITE: the request a `gpt-5.1` profile actually sends.
    /// Mutation that must turn this red: classify only `gpt-5` / `gpt-5-…` as before.
    func testAGPT51RequestCarriesTheReasoningShape() {
        let provider = openAI(model: "gpt-5.1", options: [
            "maxTokens": .number(2048), "temperature": .number(0.4), "reasoningEffort": .string("high"),
        ])
        var body: [String: Any] = [:]
        provider.applyGenerationParams(to: &body)
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 2048)
        XCTAssertNil(body["max_tokens"], "reasoning models reject max_tokens")
        XCTAssertNil(body["temperature"], "reasoning models reject a non-default temperature")
        XCTAssertEqual(body["reasoning_effort"] as? String, "high", "the user's effort must reach the request")
    }

    // MARK: - CR-28: Gemini thinking

    func testOnlyThinkingFamiliesAskForThoughts() {
        for id in ["gemini-2.5-flash", "gemini-2.5-pro", "models/gemini-2.5-flash-lite", "gemini-3-pro-preview",
                   "gemini-3.1-flash", "google/gemini-2.5-pro", "gemini-flash-latest"] {
            XCTAssertTrue(GeminiLLMProvider.modelThinks(id), id)
        }
        for id in ["gemini-2.0-flash", "gemini-1.5-pro", "gemini-pro", "gemma-3-27b", "learnlm-2.0"] {
            XCTAssertFalse(GeminiLLMProvider.modelThinks(id), id)
        }
    }

    /// THE CALL SITE, end to end: the request asks for thoughts INSIDE `generationConfig`, and the
    /// reply's thought part becomes the trace — not part of the answer.
    /// Mutations that must turn this red: put `thinking_config` back at the top level; test `text`
    /// before the thought flag in the decoder.
    func testAGeminiStepRequestsThoughtsCorrectlyAndKeepsThemOutOfTheAnswer() async throws {
        CloudStubProtocol.response = Self.json(["candidates": [[
            "finishReason": "STOP",
            "content": ["role": "model", "parts": [
                ["text": "Let me weigh the two options.", "thought": true],
                ["text": "Option B is faster."],
            ]],
        ]]])
        let provider = gemini(model: "gemini-2.5-flash")
        let step = try await provider.generateCognitiveStep(
            nativeMessages: [["role": "user", "parts": [["text": "Which is faster?"]]]], tools: nil)

        let body = try XCTUnwrap(CloudStubProtocol.lastBody)
        XCTAssertNil(body["thinking_config"], "a top-level thinking_config is not a request field")
        let generationConfig = try XCTUnwrap(body["generationConfig"] as? [String: Any])
        let thinking = try XCTUnwrap(generationConfig["thinkingConfig"] as? [String: Any])
        XCTAssertEqual(thinking["includeThoughts"] as? Bool, true)

        XCTAssertEqual(step.reasoning, "Option B is faster.", "a thought was spliced into the answer")
        XCTAssertEqual(step.thought, "Let me weigh the two options.")
    }

    /// The prompt-message builder takes the same path.
    func testTheMessagesBuilderAsksForThoughtsTheSameWay() async throws {
        CloudStubProtocol.response = Self.json(["candidates": [[
            "finishReason": "STOP",
            "content": ["role": "model", "parts": [["text": "thinking…", "thought": true], ["text": "Done."]]],
        ]]])
        let step = try await gemini(model: "gemini-2.5-pro").generateCognitiveStep(
            messages: [["role": "user", "content": "go"]], tools: nil)
        let generationConfig = try XCTUnwrap(CloudStubProtocol.lastBody?["generationConfig"] as? [String: Any])
        XCTAssertNotNil(generationConfig["thinkingConfig"])
        XCTAssertNil(CloudStubProtocol.lastBody?["thinking_config"])
        XCTAssertEqual(step.reasoning, "Done.")
        XCTAssertEqual(step.thought, "thinking…")
    }

    func testANonThinkingGeminiModelGetsNoThinkingConfig() async throws {
        CloudStubProtocol.response = Self.json(["candidates": [[
            "finishReason": "STOP", "content": ["role": "model", "parts": [["text": "Hi."]]],
        ]]])
        _ = try await gemini(model: "gemini-2.0-flash").generateCognitiveStep(
            nativeMessages: [["role": "user", "parts": [["text": "hi"]]]], tools: nil)
        let body = try XCTUnwrap(CloudStubProtocol.lastBody)
        XCTAssertNil((body["generationConfig"] as? [String: Any])?["thinkingConfig"])
        XCTAssertNil(body["thinking_config"])
    }

    // MARK: - CR-26: OpenAI tool arguments + early stream end

    func testRepairableArgumentsAreRepairedNotDropped() {
        // A raw newline inside a string and a trailing comma: invalid JSON, obviously intended.
        let raw = "{\"path\": \"notes.md\", \"content\": \"line one\nline two\",}"
        let args = OpenAILLMProvider.toolArguments(raw, toolName: "write_file", callID: "call_1")
        XCTAssertEqual(args["path"], .string("notes.md"))
        XCTAssertEqual(args["content"], .string("line one\nline two"))
    }

    func testAnEmptyArgumentsStringIsANoArgumentCall() {
        XCTAssertEqual(OpenAILLMProvider.toolArguments("", toolName: "list_tools", callID: "c"), [:])
        XCTAssertEqual(OpenAILLMProvider.toolArguments(["a": 1], toolName: "t", callID: "c"), ["a": .number(1)])
    }

    /// THE CALL SITE: the non-streaming native decoder.
    /// Mutation that must turn this red: inline the old strict-JSON-or-[:] decode again.
    func testTheNativeDecoderRepairsArguments() async throws {
        CloudStubProtocol.response = Self.json(["choices": [[
            "finish_reason": "tool_calls",
            "message": ["role": "assistant", "content": "", "tool_calls": [[
                "id": "call_7", "type": "function",
                "function": ["name": "write_file", "arguments": "{\"path\": \"a.txt\", \"content\": \"one\ntwo\"}"],
            ]]],
        ]]])
        let step = try await openAI(model: "gpt-4o").generateCognitiveStep(
            nativeMessages: [["role": "user", "content": "write it"]], tools: nil)
        XCTAssertEqual(step.toolCalls.first?.arguments["path"], .string("a.txt"))
        XCTAssertEqual(step.toolCalls.first?.arguments["content"], .string("one\ntwo"))
    }

    /// THE CALL SITE: the prompt-messages decoder, a separate loop.
    /// Mutation that must turn this red: inline the strict-JSON-or-[:] decode there.
    func testTheMessagesDecoderRepairsArguments() async throws {
        CloudStubProtocol.response = Self.json(["choices": [[
            "finish_reason": "tool_calls",
            "message": ["role": "assistant", "content": "", "tool_calls": [[
                "id": "call_8", "type": "function",
                "function": ["name": "write_file", "arguments": "{\"path\": \"c.txt\", \"content\": \"a\nb\"}"],
            ]]],
        ]]])
        let step = try await openAI(model: "gpt-4o").generateCognitiveStep(
            messages: [["role": "user", "content": "write it"]], tools: nil)
        XCTAssertEqual(step.toolCalls.first?.arguments["path"], .string("c.txt"))
    }

    /// THE CALL SITE: the streamed decoder (it goes through `step(fromMessage:)`).
    func testTheStreamedDecoderRepairsArguments() async throws {
        CloudStubProtocol.contentType = "text/event-stream"
        CloudStubProtocol.response = Self.sse([
            ["choices": [["delta": ["tool_calls": [["index": 0, "id": "call_9", "type": "function",
                                                     "function": ["name": "write_file", "arguments": "{\"path\": \"b.txt\", \"content\": \"x"]]]]]]],
            ["choices": [["delta": ["tool_calls": [["index": 0, "function": ["arguments": "\ny\"}"]]]], "finish_reason": "tool_calls"]]],
        ])
        let step = try await openAI(model: "gpt-4o").generateCognitiveStepStreaming(
            nativeMessages: [["role": "user", "content": "go"]], tools: nil, onTextDelta: { _ in })
        XCTAssertEqual(step.toolCalls.first?.arguments["path"], .string("b.txt"))
    }

    /// A stream that closes cleanly but never sent a finish_reason was cut off upstream.
    /// Mutation that must turn this red: drop the `incompleteStreamError` check.
    func testAStreamWithNoFinishReasonIsNotAFinishedStep() async {
        CloudStubProtocol.contentType = "text/event-stream"
        CloudStubProtocol.response = Self.sse([
            ["choices": [["delta": ["content": "The answer is"]]]],
        ])
        do {
            _ = try await openAI(model: "gpt-4o").generateCognitiveStepStreaming(
                nativeMessages: [["role": "user", "content": "go"]], tools: nil, onTextDelta: { _ in })
            XCTFail("a cut-off stream was returned as a finished step")
        } catch let error as LLMProviderError {
            guard case .streamEndedEarly = error else { return XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testACompleteStreamIsStillAccepted() async throws {
        CloudStubProtocol.contentType = "text/event-stream"
        CloudStubProtocol.response = Self.sse([
            ["choices": [["delta": ["content": "Hello."], "finish_reason": "stop"]]],
        ])
        let step = try await openAI(model: "gpt-4o").generateCognitiveStepStreaming(
            nativeMessages: [["role": "user", "content": "hi"]], tools: nil, onTextDelta: { _ in })
        XCTAssertEqual(step.reasoning, "Hello.")
    }

    /// The cut-off stream is a transport failure: retried, not charged to the parse budget, not fatal.
    func testAStreamThatEndedEarlyIsRetriedAsTransient() {
        var strategy = LLMRetryStrategy()
        guard case .networkRetry = strategy.handleError(LLMProviderError.streamEndedEarly(provider: "OpenAI-compatible")) else {
            return XCTFail("an early stream end must be retried as a transport failure")
        }
        XCTAssertEqual(strategy.consecutiveParseFailures, 0)
    }

    // MARK: - CR-42: an empty native reply is not a finished answer

    /// THE CALL SITE: `generateNativeStep` over a real provider returning nothing.
    /// Mutation that must turn this red: drop `refuseEmptyReply` from `generateNativeStep`.
    func testAnEmptyNativeReplyIsAnEmptyResponseNotACompletion() async {
        CloudStubProtocol.response = Self.json(["choices": [[
            "finish_reason": "length",
            "message": ["role": "assistant", "content": "", "reasoning": "Thinking about it at length…"],
        ]]])
        do {
            let step = try await NativeStructuredGenerator().generateNativeStep(
                model: openAI(model: "o3-mini"), nativeMessages: [["role": "user", "content": "hi"]],
                availableTools: [], iteration: 1)
            XCTFail("an empty reply was accepted as \(String(describing: step.parseOutcome))")
        } catch {
            XCTAssertEqual(error as? GenerationError, .emptyResponse(generator: "Native"))
        }
    }

    func testANativeReplyWithTextOrACallIsKept() throws {
        XCTAssertNoThrow(try NativeStructuredGenerator.refuseEmptyReply(
            ModernCognitiveStep(reasoning: "Done.", thought: nil, toolCalls: [], tokenUsage: nil), model: "m", reqId: "r"))
        XCTAssertNoThrow(try NativeStructuredGenerator.refuseEmptyReply(
            ModernCognitiveStep(reasoning: "", thought: nil,
                                toolCalls: [PendingToolCall(id: "1", name: "final_answer", arguments: [:])], tokenUsage: nil),
            model: "m", reqId: "r"))
        XCTAssertThrowsError(try NativeStructuredGenerator.refuseEmptyReply(
            ModernCognitiveStep(reasoning: "  \n", thought: "x", toolCalls: [], tokenUsage: nil), model: "m", reqId: "r"))
    }

    /// The bounded retry ends with advice that fits a native reasoning model, not the MLX sampling advice.
    func testTheNativeEmptyReplyStopPointsAtTheOutputLimit() {
        var strategy = LLMRetryStrategy()
        var last: RetryAction?
        for _ in 0..<3 { last = strategy.handleError(GenerationError.emptyResponse(generator: "Native")) }
        guard case .abort(let reason)? = last else { return XCTFail("expected a stop, got \(String(describing: last))") }
        XCTAssertTrue(reason.contains("Max Tokens"), reason)
        XCTAssertFalse(reason.contains("Repetition Penalty"), reason)
    }
}

// MARK: - CR-25: opening the request is not a stall

/// Holds the response back for `delay`, as an Ollama cold-load or a slow gateway does before headers.
private final class SlowHeadersProtocol: URLProtocol {
    nonisolated(unsafe) static var delay: TimeInterval = 1.2
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let client = self.client
        let url = request.url!
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay) { [self] in
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("hello\n".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

final class SSEStreamOpenIsNotAStallTests: XCTestCase {

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _text = ""
        private var _error: Error?
        var text: String { lock.withLock { _text } }
        var error: Error? { lock.withLock { _error } }
        func append(_ s: String) { lock.withLock { _text += s } }
        func fail(_ e: Error) { lock.withLock { _error = e } }
    }

    /// Headers arrive after four stall timeouts. The stream must still deliver its line.
    /// Mutation that must turn this red: start the watchdog before `openBytes` again.
    func testSlowHeadersDoNotTripTheStallWatchdog() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SlowHeadersProtocol.self]
        let session = URLSession(configuration: config)
        let box = Box()
        let done = expectation(description: "stream ended")
        let stream = SSEStreamParser.stream(
            stallTimeout: 0.3,
            openBytes: {
                let (bytes, _) = try await session.bytes(for: URLRequest(url: URL(string: "https://slow.invalid/api/chat")!))
                return bytes
            },
            handleLine: { line, _ in line.isEmpty ? .skip : .emit(line) })
        let task = Task {
            do { for try await chunk in stream { box.append(chunk) } } catch { box.fail(error) }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 10)
        task.cancel()
        XCTAssertNil(box.error, "waiting for headers is not a stalled stream: \(String(describing: box.error))")
        XCTAssertEqual(box.text, "hello")
    }
}
