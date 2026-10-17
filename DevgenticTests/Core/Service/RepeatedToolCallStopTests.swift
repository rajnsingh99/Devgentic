// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RepeatedToolCallStopTests.swift
//  devgenticTests
//
//  A model that repeats one tool call must not run on to its token limit. On 2026-10-06
//  Qwen2.5-3B wrote the same `read_file` 46 times and the same edit 17 times in single turns, each
//  ~50s of decode to the 2,048-token cap. The text-repetition breaker never saw them: calls the
//  framework already decoded arrive as events, not text.
//

import XCTest
import MLXLMCommon
@testable import devgentic

// MARK: - The breaker

final class RepeatedToolCallBreakerTests: XCTestCase {

    func testTheThirdCopyOfOneCallTrips() {
        var breaker = StreamingCircuitBreaker()
        guard case .healthy = breaker.feedToolCall("A", name: "read_file"),
              case .healthy = breaker.feedToolCall("A", name: "read_file") else {
            return XCTFail("one duplicate must pass: the executor collapses it, and a stop there could cut off a later, different call")
        }
        guard case .tripped(let reason) = breaker.feedToolCall("A", name: "read_file") else {
            return XCTFail("the third copy is a loop")
        }
        XCTAssertTrue(reason.contains("read_file"), reason)
        XCTAssertTrue(breaker.hasTripped)
    }

    func testManyDifferentCallsNeverTrip() {
        var breaker = StreamingCircuitBreaker()
        for index in 0..<40 {
            guard case .healthy = breaker.feedToolCall("call-\(index)", name: "read_file") else {
                return XCTFail("distinct call \(index) tripped the breaker")
            }
        }
    }

    /// Counted per turn, not only back to back.
    func testAnAlternatingLoopTrips() {
        var breaker = StreamingCircuitBreaker()
        let sequence = ["A", "B", "A", "B"]
        for signature in sequence {
            guard case .healthy = breaker.feedToolCall(signature, name: "x") else {
                return XCTFail("tripped early on \(signature)")
            }
        }
        guard case .tripped = breaker.feedToolCall("A", name: "x") else {
            return XCTFail("A, B, A, B, A is a loop")
        }
    }
}

// MARK: - The wiring: a real MLXLMCommon stream through MLXService

final class RepeatedToolCallStreamTests: XCTestCase {

    private func consume(_ events: [Generation]) async throws -> String {
        let stream = AsyncStream<Generation> { continuation in
            events.forEach { continuation.yield($0) }
            continuation.finish()
        }
        let text = AsyncThrowingStream<String, Error> { continuation in
            Task {
                await MLXService.shared.consumeGenerationStream(
                    stream, into: continuation, stopSequences: ["<|im_end|>"],
                    reportsDiscardedToolCalls: true)
                continuation.finish()
            }
        }
        var out = ""
        for try await chunk in text { out += chunk }
        return out
    }

    private func call(_ name: String, _ arguments: [String: any Sendable]) -> Generation {
        .toolCall(ToolCall(function: ToolCall.Function(name: name, arguments: arguments)))
    }

    private func envelopes(in text: String) -> Int {
        text.components(separatedBy: FrameworkToolCallEnvelope.openTag).count - 1
    }

    private let info = Generation.info(GenerateCompletionInfo(
        promptTokenCount: 100, generationTokenCount: 2048, promptTime: 1, generationTime: 49))

    /// The T5 shape: the same read 46 times. At most two copies come out, and a different call the
    /// model writes after the loop is not forwarded either, because generation stopped there.
    func testAReadRepeated46TimesStopsAtTheThirdCopy() async throws {
        let repeated = Array(repeating: call("read_file", ["path": "/p/a.py"]), count: 46)
        let text = try await consume(repeated + [call("glob_files", ["pattern": "**/*.py"]), info])
        XCTAssertEqual(envelopes(in: text), 2, "the loop ran on past its third copy:\n\(text)")
        XCTAssertFalse(text.contains("glob_files"), "generation must stop at the loop, not skip over it")
    }

    /// The point of the fix is to stop GENERATING, not only to stop forwarding: withholding the copies
    /// while reading on would still decode to the token limit. A stream that produces events on
    /// demand shows how far the consumer actually read.
    func testTheStreamStopsBeingReadAtTheLoop() async throws {
        final class Pulls: @unchecked Sendable { var count = 0 }
        let pulls = Pulls()
        let total = 47
        let read = call("read_file", ["path": "/p/a.py"])
        let stream = AsyncStream<Generation>(unfolding: {
            guard pulls.count < total else { return nil }
            pulls.count += 1
            return read
        })
        let text = AsyncThrowingStream<String, Error> { continuation in
            Task {
                await MLXService.shared.consumeGenerationStream(
                    stream, into: continuation, stopSequences: [], reportsDiscardedToolCalls: true)
                continuation.finish()
            }
        }
        for try await _ in text {}
        XCTAssertLessThanOrEqual(pulls.count, 4, "generation was read \(pulls.count) of \(total) events past the loop")
    }

    /// The T2 shape: several distinct calls, then one of them on repeat. Every distinct call reaches
    /// the turn.
    func testDistinctCallsBeforeALoopAllComeThrough() async throws {
        let distinct = [
            call("create_new_file", ["file_path": "/p/u.json", "content": "{}"]),
            call("edit_code_single", ["file_path": "/p/u.json", "old_string": "{}", "new_string": "{\"a\":1}"]),
            call("edit_code_single", ["file_path": "/p/u.json", "old_string": "{\"a\":1}", "new_string": "{\"a\":2}"]),
        ]
        let loop = Array(repeating: call("edit_code_single", ["file_path": "/p/u.json", "old_string": "x", "new_string": "y"]), count: 17)
        let text = try await consume(distinct + loop + [info])
        XCTAssertEqual(envelopes(in: text), 5, "3 distinct calls + 2 copies of the looped one:\n\(text)")
        for needle in ["create_new_file", "{\\\"a\\\":1}", "{\\\"a\\\":2}"] {
            XCTAssertTrue(text.contains(needle), "a distinct call was lost: \(needle)")
        }
    }

    /// No loop: nothing changes, including a single accidental duplicate.
    func testOrdinaryTurnsAreUntouched() async throws {
        let text = try await consume([
            .chunk("Reading both files.\n"),
            call("read_file", ["path": "/p/a.py"]),
            call("read_file", ["path": "/p/b.py"]),
            call("read_file", ["path": "/p/b.py"]),
            info,
        ])
        XCTAssertEqual(envelopes(in: text), 3)
        XCTAssertTrue(text.hasPrefix("Reading both files."))
    }

    /// A broken call repeated in a loop is still a loop.
    func testARepeatedRejectedCallAlsoStops() async throws {
        let raw = #"<tool_call>{"name": "read_file", "arguments": {"path": </tool_call>"#
        let rejected = Generation.rejectedToolCall(RejectedToolCall(reason: .malformedSyntax, format: .json, rawText: raw))
        let text = try await consume(Array(repeating: rejected, count: 20) + [info])
        XCTAssertEqual(text.components(separatedBy: raw).count - 1, 2, "a rejected call looped past its third copy")
    }
}
