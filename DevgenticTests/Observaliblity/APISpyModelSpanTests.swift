// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  APISpyModelSpanTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

private final class ScriptedProvider: LLMProvider, @unchecked Sendable {
    let modelName = "spy-test-model"
    var shouldThrow = false

    func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String {
        if shouldThrow { throw URLError(.timedOut) }
        return "plain response"
    }

    func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func generateCognitiveStep(messages: [[String: String]], tools: [[String: Any]]?) async throws -> ModernCognitiveStep {
        if shouldThrow { throw URLError(.timedOut) }
        return ModernCognitiveStep(
            reasoning: "scripted step",
            thought: "thinking about it",
            tokenUsage: TokenUsage(inputTokens: 1200, outputTokens: 45, isEstimated: false))
    }
}

final class APISpyModelSpanTests: XCTestCase {

    private func freshTrace() async -> TraceContext {
        let ctx = TraceContext(subAgentName: "spy-span-test", provider: .anthropic)
        await TraceRecorder.shared.beginTrace(
            context: ctx, conversationID: UUID(), messageID: UUID(), modelName: nil)
        return ctx
    }

    private func fetchSpans(_ traceID: String) throws -> [Span] {
        try XCTUnwrap(TraceStore.shared).fetchSpans(forTraceID: traceID)
    }

    func testXCTestRedirectProtectsRealStore() throws {
        // The precondition every test in this file relies on: the shared store must
        // NOT be the real Application Support database inside a test host.
        let store = try XCTUnwrap(TraceStore.shared)
        XCTAssertFalse(store.storagePath.contains("Application Support"),
                       "test host must never open the real traces.sqlite — got \(store.storagePath)")
    }

    func testCognitiveStepCreatesLLMSpanWithTokensUnderScope() async throws {
        let ctx = await freshTrace()
        let step = ctx.newSpan()
        await TraceRecorder.shared.beginSpan(context: step, name: "iteration_1", kind: .iteration)

        let spy = APISpyModel(inner: ScriptedProvider(), spanScope: LLMSpanScope(step))
        _ = try await spy.generateCognitiveStep(messages: [["role": "user", "content": "hi"]], tools: nil)
        await TraceRecorder.shared.endTrace(traceID: ctx.traceID, status: .completed) // flush events

        let spans = try fetchSpans(ctx.traceID)
        let llm = try XCTUnwrap(spans.first { $0.name == "llm:spy-test-model" })
        XCTAssertEqual(llm.kind, .llmCall)
        XCTAssertEqual(llm.parentSpanID, step.spanID, "the call must parent under the CURRENT step")
        XCTAssertEqual(llm.status, .completed)
        XCTAssertNotNil(llm.endedAt)

        let meta = try XCTUnwrap(llm.metadataJSON?.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] })
        XCTAssertEqual(meta["input_tokens"], "1200")
        XCTAssertEqual(meta["output_tokens"], "45")
        XCTAssertEqual(meta["tokens_estimated"], "false")
        XCTAssertEqual(meta["model"], "spy-test-model")
        XCTAssertNotNil(meta["duration_ms"])

        // The request/response event pair landed on the call span.
        let events = try XCTUnwrap(TraceStore.shared).fetchEvents(forSpanID: llm.spanID)
        XCTAssertTrue(try events.contains { $0.eventType == .llmRequest })
        XCTAssertTrue(try events.contains { $0.eventType == .llmResponse })
    }

    func testScopeFollowsTheExecutorAcrossSteps() async throws {
        let ctx = await freshTrace()
        let scope = LLMSpanScope(ctx)
        let spy = APISpyModel(inner: ScriptedProvider(), spanScope: scope)

        let step1 = ctx.newSpan()
        await TraceRecorder.shared.beginSpan(context: step1, name: "iteration_1", kind: .iteration)
        scope.set(step1)
        _ = try await spy.generateCognitiveStep(messages: [], tools: nil)

        let step2 = ctx.newSpan()
        await TraceRecorder.shared.beginSpan(context: step2, name: "iteration_2", kind: .iteration)
        scope.set(step2)
        _ = try await spy.generateCognitiveStep(messages: [], tools: nil)
        await TraceRecorder.shared.endTrace(traceID: ctx.traceID, status: .completed)

        let llmSpans = try fetchSpans(ctx.traceID).filter { $0.kind == .llmCall }
        XCTAssertEqual(llmSpans.count, 2)
        XCTAssertEqual(Set(llmSpans.compactMap(\.parentSpanID)), [step1.spanID, step2.spanID],
                       "each call parents under the step that was current when it ran")
    }

    func testThrowingCallEndsSpanAsError() async throws {
        let ctx = await freshTrace()
        let provider = ScriptedProvider()
        provider.shouldThrow = true
        let spy = APISpyModel(inner: provider, spanScope: LLMSpanScope(ctx))

        await XCTAssertThrowsErrorAsync(try await spy.generateCognitiveStep(messages: [], tools: nil))
        await TraceRecorder.shared.endTrace(traceID: ctx.traceID, status: .error)

        let llm = try XCTUnwrap(fetchSpans(ctx.traceID).first { $0.kind == .llmCall })
        XCTAssertEqual(llm.status, .error)
        XCTAssertNotNil(llm.metadataJSON, "even a failed call records its duration")
    }

    func testNilScopeIsAStrictPassThrough() async throws {
        let ctx = await freshTrace()
        let spy = APISpyModel(inner: ScriptedProvider()) // no scope
        _ = try await spy.generateCognitiveStep(messages: [], tools: nil)
        await TraceRecorder.shared.endTrace(traceID: ctx.traceID, status: .completed)

        let llmSpans = try fetchSpans(ctx.traceID).filter { $0.kind == .llmCall }
        XCTAssertTrue(llmSpans.isEmpty, "no scope ⇒ no telemetry side effects")
    }

    func testGenerateWithUsageRecordsUsageFromTheTuple() async throws {
        final class UsageProvider: LLMProvider, @unchecked Sendable {
            let modelName = "usage-model"
            func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String { "x" }
            func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error> {
                AsyncThrowingStream { $0.finish() }
            }
            func generateCognitiveStep(messages: [[String: String]], tools: [[String: Any]]?) async throws -> ModernCognitiveStep {
                ModernCognitiveStep(reasoning: "x")
            }
            func generateWithUsage(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> (text: String, usage: TokenUsage?) {
                ("legacy text", TokenUsage(inputTokens: 800, outputTokens: 20, isEstimated: false))
            }
        }
        let ctx = await freshTrace()
        let spy = APISpyModel(inner: UsageProvider(), spanScope: LLMSpanScope(ctx))
        _ = try await spy.generateWithUsage(messages: [], tools: nil, responseSchema: nil)
        await TraceRecorder.shared.endTrace(traceID: ctx.traceID, status: .completed)

        let llm = try XCTUnwrap(fetchSpans(ctx.traceID).first { $0.kind == .llmCall })
        let meta = try XCTUnwrap(llm.metadataJSON?.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] })
        XCTAssertEqual(meta["input_tokens"], "800",
                       "the legacy-dialect path's usage must reach the span even though the strategy discards it")
    }
}

/// Async throw assertion helper (XCTAssertThrowsError has no async overload).
func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                  file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("expected an error to be thrown", file: file, line: line)
    } catch {
        // expected
    }
}
