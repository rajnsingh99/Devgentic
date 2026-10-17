// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  FrameworkToolCallEnvelopeTests.swift
//  devgenticTests
//
//  Calls that MLXLMCommon already decoded must reach the step intact. On 2026-10-06 the framework
//  reported `toolCalls=3` for one Qwen2.5-3B turn and the agent ran ONE (`b.py` was never read):
//  MLXService re-serialized each call as a bare JSON object and the dialect parser's bare-JSON
//  fallback keeps the first. The prose around the calls was dropped the same way. And when the
//  framework DISCARDED a call it could not decode, the run retried a byte-identical prompt and got
//  the same 76 discarded tokens three times.
//

import XCTest
import MLXLMCommon
@testable import devgentic

final class FrameworkToolCallEnvelopeTests: XCTestCase {

    private let prose = "I'll read both files and compare their line counts."

    private static func tool(_ name: String) -> AgentTool {
        AgentTool(
            name: name,
            description: "A test tool.",
            parameters: SchemaBuilder.object(
                properties: [("path", "string", "File path."), ("pattern", "string", "Pattern.")],
                required: ["path"]
            ),
            requiresConfirmation: false,
            textOnlyRun: { _ in "ok" }
        )
    }

    private let tools = [tool("read_file"), tool("code_search_text")]

    private func pipeline(_ dialect: ModelDialect = .qwenHermesToolCall) -> CognitiveParsePipeline {
        CognitiveParsePipeline(expectedDialect: dialect, modelId: "test", iteration: 4, registeredTools: tools)
    }

    private func threeCalls() -> String {
        [
            FrameworkToolCallEnvelope.encode(name: "read_file", arguments: ["path": "/p/a.py"])!,
            FrameworkToolCallEnvelope.encode(name: "code_search_text", arguments: ["path": "/p", "pattern": "def"])!,
            FrameworkToolCallEnvelope.encode(name: "read_file", arguments: ["path": "/p/b.py"])!,
        ].joined(separator: "\n")
    }

    // MARK: - Every call, every dialect

    func testEveryFrameworkCallAndTheProseReachTheStepOnEveryDialect() {
        for dialect in ModelDialect.allCases {
            let step = pipeline(dialect).parse(raw: prose + "\n" + threeCalls())
            XCTAssertEqual(step.toolCalls.map(\.name), ["read_file", "code_search_text", "read_file"], "\(dialect.rawValue)")
            XCTAssertEqual(step.toolCalls.last?.arguments["path"], .string("/p/b.py"), "\(dialect.rawValue): the third call lost its arguments")
            XCTAssertEqual(step.reasoning, prose, "\(dialect.rawValue): the text beside the calls was dropped")
            guard case .success = step.parseOutcome else {
                return XCTFail("\(dialect.rawValue): \(String(describing: step.parseOutcome))")
            }
        }
    }

    func testAFrameworkCallToAnUnknownToolIsStillValidated() {
        let raw = FrameworkToolCallEnvelope.encode(name: "delete_everything", arguments: [:])!
        guard case .failed(.unknownToolName) = pipeline().parse(raw: raw).parseOutcome else {
            return XCTFail("a framework-decoded call skipped name validation")
        }
    }

    // MARK: - The call site: a real MLXLMCommon stream through MLXService

    private func consume(_ events: [Generation], tools reportsDiscarded: Bool = true) async throws -> String {
        let stream = AsyncStream<Generation> { continuation in
            events.forEach { continuation.yield($0) }
            continuation.finish()
        }
        let text = AsyncThrowingStream<String, Error> { continuation in
            Task {
                await MLXService.shared.consumeGenerationStream(
                    stream, into: continuation, stopSequences: ["<|im_end|>"],
                    reportsDiscardedToolCalls: reportsDiscarded)
                continuation.finish()
            }
        }
        var out = ""
        for try await chunk in text { out += chunk }
        return out
    }

    private func info(generated: Int) -> Generation {
        .info(GenerateCompletionInfo(promptTokenCount: 100, generationTokenCount: generated, promptTime: 1, generationTime: 1))
    }

    private func call(_ name: String, _ arguments: [String: any Sendable]) -> Generation {
        .toolCall(ToolCall(function: ToolCall.Function(name: name, arguments: arguments)))
    }

    func testThreeFrameworkCallsFromTheStreamRunAsThree() async throws {
        let text = try await consume([
            .chunk(prose + "\n"),
            call("read_file", ["path": "/p/a.py"]),
            call("code_search_text", ["path": "/p", "pattern": "def"]),
            call("read_file", ["path": "/p/b.py"]),
            info(generated: 120),
        ])
        let step = pipeline().parse(raw: text)
        XCTAssertEqual(step.toolCalls.count, 3, "the stream carried 3 framework calls:\n\(text)")
        XCTAssertEqual(step.reasoning, prose)
    }

    func testADiscardedCallBecomesAFormatFailureTheModelIsToldAbout() async throws {
        let text = try await consume([info(generated: 76)])
        let step = pipeline().parse(raw: text)
        guard case .failed(.malformedJSON(let detail, _)) = step.parseOutcome else {
            return XCTFail("a discarded call must be a correctable format failure, got \(String(describing: step.parseOutcome)) from \(text)")
        }
        XCTAssertTrue(detail.contains("76"), detail)
        XCTAssertTrue(step.toolCalls.isEmpty)
    }

    // MARK: - Calls the framework rejected (mlx-swift-lm ≥ 3.32)

    private func rejected(_ raw: String, _ reason: RejectedToolCall.Reason = .malformedSyntax) -> Generation {
        .rejectedToolCall(RejectedToolCall(reason: reason, format: .json, rawText: raw))
    }

    /// The two shapes Qwen2.5-3B actually writes, both of which the framework rejects and the
    /// app's Qwen parser repairs. Before 3.32 they vanished; now they must RUN.
    func testCallsTheFrameworkRejectedButTheAppCanRepairRun() async throws {
        let parametersKey = #"<tool_call>{"name": "read_file", "parameters": {"path": "/p/a.py"}}</tool_call>"#
        let doubledBraces = #"<tool_call>{{"name": "read_file", "arguments": {"path": "/p/b.py"}}}</tool_call>"#
        for raw in [parametersKey, doubledBraces] {
            let text = try await consume([.chunk(prose + "\n"), rejected(raw), info(generated: 60)])
            let step = pipeline().parse(raw: text)
            XCTAssertEqual(step.toolCalls.map(\.name), ["read_file"], "the rejected call was lost:\n\(text)")
            XCTAssertFalse(text.contains(FrameworkToolCallEnvelope.discardedPrefix),
                           "a reported rejection must not also be reported as a discard")
        }
    }

    /// An undeclared tool is rejected by the framework's authorization; the model must hear which
    /// name was wrong, through the same unknown-tool correction every other route gets.
    func testARejectedUndeclaredToolGetsTheUnknownToolCorrection() async throws {
        let raw = #"<tool_call>{"name": "delete_everything", "arguments": {}}</tool_call>"#
        let text = try await consume([rejected(raw, .undeclaredTool), info(generated: 20)])
        guard case .failed(.unknownToolName) = pipeline().parse(raw: text).parseOutcome else {
            return XCTFail("an undeclared tool must reach name validation, got \(text)")
        }
    }

    /// A rejection the app can't repair either fails as malformed, quoting what the model wrote,
    /// not as the content-free "discarded N tokens" marker.
    func testAnUnrepairableRejectedCallIsAMalformedFailureNotADiscard() async throws {
        let raw = #"<tool_call>{"name": "read_file", "arguments": {"path": </tool_call>"#
        let text = try await consume([rejected(raw), info(generated: 30)])
        XCTAssertEqual(text, raw)
        let step = pipeline().parse(raw: text)
        XCTAssertTrue(step.toolCalls.isEmpty)
        guard case .failed(let failure) = step.parseOutcome else {
            return XCTFail("an unrepairable call must fail, got \(String(describing: step.parseOutcome))")
        }
        XCTAssertFalse(String(describing: failure).contains("runtime discarded"),
                       "the model must be told what it wrote, not that tokens vanished: \(failure)")
    }

    func testNoMarkerWhenNoToolsWereOffered() async throws {
        // Bot, synthesis and planning calls: they must never receive the marker as text.
        let text = try await consume([info(generated: 76)], tools: false)
        XCTAssertEqual(text, "")
    }

    func testNoMarkerForAZeroTokenStop() async throws {
        // The model really produced nothing: that stays an empty response, not a "discarded call".
        let text = try await consume([info(generated: 0)])
        XCTAssertEqual(text, "")
    }

    // MARK: - The envelope itself

    func testAnUndecodablePayloadIsCountedAndAnUnclosedOneIsKeptAsText() throws {
        let good = FrameworkToolCallEnvelope.encode(name: "read_file", arguments: ["path": "/p"])!
        let bad = FrameworkToolCallEnvelope.openTag + "not json" + FrameworkToolCallEnvelope.closeTag
        let unclosed = FrameworkToolCallEnvelope.openTag + "{\"name\":"
        let extraction = try XCTUnwrap(FrameworkToolCallEnvelope.extract(from: "a " + good + " b " + bad + " c " + unclosed))
        XCTAssertEqual(extraction.calls.map(\.name), ["read_file"])
        XCTAssertEqual(extraction.undecodable, 2)
        XCTAssertEqual(extraction.remainder, "a  b  c " + unclosed)
    }

    func testTextWithoutAnEnvelopeIsLeftToTheDialectParsers() {
        XCTAssertNil(FrameworkToolCallEnvelope.extract(from: "<tool_call>{\"name\":\"read_file\",\"arguments\":{}}</tool_call>"))
    }
}
