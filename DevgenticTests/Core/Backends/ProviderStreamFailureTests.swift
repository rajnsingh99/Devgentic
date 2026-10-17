// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProviderStreamFailureTests.swift
//  devgenticTests
//
//  Readiness CR-14, CR-15, CR-16 — three ways a provider failure on an HTTP-200 stream was lost.
//
//  CR-14: an Anthropic in-stream `overloaded_error` became `.invalidResponse`, which nothing retries,
//         while the identical failure sent as HTTP 529 got three retries.
//  CR-15: an Ollama `{"error": …}` line mid-stream was skipped; the stream then ended cleanly and a
//         cut-off answer was saved as a success.
//  CR-16: Anthropic `stop_reason: "refusal"` and Gemini blocks were never checked — an empty or
//         partial answer with no explanation.
//
//  These drive the providers' REAL decoders, which each stream passes as `handleLine:` directly.
//

import XCTest
@testable import devgentic

final class ProviderStreamFailureTests: XCTestCase {

    private func failure(_ directive: SSELineDirective, file: StaticString = #filePath, line: UInt = #line) -> Error? {
        if case .fail(let error) = directive { return error }
        XCTFail("expected .fail, got \(directive)", file: file, line: line)
        return nil
    }

    private func verdict(_ error: Error?) -> ProviderErrorVerdict? {
        error.flatMap { ProviderErrorClassifier.classifyTransport($0, connectionRefusedIsFatal: false, endpointHint: nil) }
    }

    // MARK: - CR-14: Anthropic in-stream errors are classified like their HTTP status

    private func anthropicError(_ type: String) -> SSELineDirective {
        ClaudeLLMProvider.anthropicStreamLine(
            #"data: {"type":"error","error":{"type":"\#(type)","message":"busy"}}"#, "error")
    }

    /// ⚠️⚠️ THE CR-14 DEFECT: zero retries for an overload the HTTP path retries three times.
    func testAnInStreamOverloadIsRetriedLikeA529() {
        guard case .transient = verdict(failure(anthropicError("overloaded_error"))) else {
            return XCTFail("an in-stream overload must be transient (retried), as an HTTP 529 is")
        }
    }

    func testAnInStreamRateLimitIsAThrottle() {
        guard case .throttle = verdict(failure(anthropicError("rate_limit_error"))) else { return XCTFail() }
    }

    /// The control: a deterministic in-stream error is still NOT retried.
    func testAnInStreamInvalidRequestIsFatal() {
        guard case .fatal = verdict(failure(anthropicError("invalid_request_error"))) else { return XCTFail() }
    }

    /// An error type this table has never seen is reported, never swallowed.
    func testAnUnknownInStreamErrorStillFailsTheStream() {
        let error = failure(anthropicError("brand_new_error"))
        XCTAssertTrue(error?.localizedDescription.contains("busy") == true, "\(String(describing: error))")
    }

    // MARK: - CR-15: an Ollama error line fails the stream

    /// ⚠️⚠️ THE CR-15 DEFECT: skipped, so a truncated answer was saved as a success.
    func testAnOllamaErrorLineFailsTheStream() {
        let error = failure(OllamaLLMProvider.ollamaStreamLine(#"{"error":"llama runner process has terminated"}"#, ""))
        XCTAssertTrue(error?.localizedDescription.contains("llama runner process has terminated") == true,
                      "the server's own message must reach the user: \(String(describing: error))")
    }

    /// The controls: ordinary content and the final line are unchanged.
    func testOrdinaryOllamaLinesAreUnchanged() {
        guard case .emit("Hi") = OllamaLLMProvider.ollamaStreamLine(#"{"message":{"content":"Hi"},"done":false}"#, "")
        else { return XCTFail() }
        guard case .finish = OllamaLLMProvider.ollamaStreamLine(#"{"message":{"content":""},"done":true}"#, "")
        else { return XCTFail() }
    }

    // MARK: - CR-16: refusals and blocks are reported, never silent

    /// ⚠️⚠️ A refusal on the streaming path arrives as a `message_delta` stop reason.
    func testAClaudeStreamRefusalFailsWithItsReason() {
        let line = #"data: {"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber","explanation":"Declined."}},"usage":{"output_tokens":3}}"#
        let error = failure(ClaudeLLMProvider.anthropicStreamLine(line, "message_delta"))
        let text = error?.localizedDescription ?? ""
        XCTAssertTrue(text.contains("cyber") && text.contains("Declined."), text)
        guard case .fatal = verdict(error) else { return XCTFail("a refusal must never be retried") }
    }

    /// The control: an ordinary stop reason does not fail anything.
    func testAnOrdinaryClaudeStopIsNotARefusal() {
        guard case .skip = ClaudeLLMProvider.anthropicStreamLine(
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#, "message_delta") else { return XCTFail() }
        XCTAssertNil(ClaudeLLMProvider.refusalError(in: ["stop_reason": "end_turn"]))
    }

    /// The non-streaming shape, which all four request paths check.
    func testAClaudeResponseRefusalCarriesItsCategory() {
        let error = ClaudeLLMProvider.refusalError(in: ["stop_reason": "refusal", "stop_details": ["category": "bio"]])
        XCTAssertTrue(error?.localizedDescription.contains("category: bio") == true)
        XCTAssertNotNil(ClaudeLLMProvider.refusalError(in: ["stop_reason": "refusal"]), "no details is still a refusal")
    }

    /// A blocked PROMPT has no candidates at all — it used to be skipped as an empty chunk.
    func testAGeminiPromptBlockFailsTheStream() {
        let error = failure(GeminiLLMProvider.geminiStreamLine(#"data: {"promptFeedback":{"blockReason":"PROHIBITED_CONTENT"}}"#, ""))
        XCTAssertTrue(error?.localizedDescription.contains("PROHIBITED_CONTENT") == true)
        guard case .fatal = verdict(error) else { return XCTFail() }
    }

    func testAGeminiSafetyStopMidStreamFailsTheStream() {
        for reason in ["SAFETY", "RECITATION", "BLOCKLIST", "SPII"] {
            let line = #"data: {"candidates":[{"content":{"parts":[{"text":"partial"}]},"finishReason":"\#(reason)"}]}"#
            XCTAssertNotNil(failure(GeminiLLMProvider.geminiStreamLine(line, "")), reason)
        }
    }

    /// The control, plus CR-30: a normal chunk emits EVERY text part, and thought parts are not the answer.
    func testAnOrdinaryGeminiChunkEmitsAllItsTextParts() {
        let line = #"data: {"candidates":[{"content":{"parts":[{"text":"thinking…","thought":true},{"text":"Hello, "},{"text":"world"}]},"finishReason":"STOP"}]}"#
        guard case .emit("Hello, world") = GeminiLLMProvider.geminiStreamLine(line, "") else {
            return XCTFail("\(GeminiLLMProvider.geminiStreamLine(line, ""))")
        }
    }

    // MARK: - The wiring

    /// Each stream passes the decoder ITSELF, and every non-streaming response path runs the check —
    /// a correct decoder with no caller is the state these guard against.
    func testEveryPathRunsTheChecks() throws {
        let claude = try Self.read("Devgentic/Core/Backends/ClaudeLLMProvider.swift")
        XCTAssertTrue(claude.contains("handleLine: Self.anthropicStreamLine"))
        XCTAssertEqual(claude.components(separatedBy: "if let refusal = Self.refusalError(in: json) { throw refusal }").count - 1, 4,
                       "all four non-streaming Claude paths must check for a refusal")

        let gemini = try Self.read("Devgentic/Core/Backends/GeminiLLMProvider.swift")
        XCTAssertTrue(gemini.contains("handleLine: Self.geminiStreamLine"))
        XCTAssertEqual(gemini.components(separatedBy: "if let blocked = Self.blockError(in: json) { throw blocked }").count - 1,
                       gemini.components(separatedBy: #"guard let candidates = json?["candidates"]"#).count - 1,
                       "every Gemini response guard must be preceded by the block check")

        let ollama = try Self.read("Devgentic/Core/Backends/OllamaLLMProvider.swift")
        XCTAssertTrue(ollama.contains("handleLine: Self.ollamaStreamLine"))
    }

    private static func read(_ relativePath: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return try String(contentsOf: candidate, encoding: .utf8) }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("Could not locate \(relativePath)")
    }
}
