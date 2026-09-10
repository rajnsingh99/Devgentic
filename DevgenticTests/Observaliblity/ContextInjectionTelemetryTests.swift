// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ContextInjectionTelemetryTests.swift
//  devgenticTests
//
//  Run-Report Phase 3: every prompt layer that ships becomes one `.memoryOp` CONTEXT
//  event with a provenance. Emission is tested THROUGH the real prompt builder
//  (`PromptBuilder.buildStandardMessages`) against the real recorder — safe because
//  the Phase-1 XCTest redirect points the shared store at a throwaway file.
//
//  ⚠️ These tests also stand guard on a byte-level invariant: adding telemetry to the
//  prompt builder must NOT change the rendered prompt (KV-cache prefix stability).
//

import XCTest
@testable import devgentic

final class ContextInjectionTelemetryTests: XCTestCase {

    private func makeContext(
        traceContext: TraceContext?,
        iteration: Int = 1,
        knowledge: String? = nil,
        rag: String = "",
        layerConfig: PromptLayerConfig = .agent
    ) -> SemanticContext {
        var ctx = SemanticContext(
            instructions: "You are a careful test assistant.",
            environmentFacts: EnvironmentFacts(
                osVersion: "macOS 26", shellType: "Zsh", userName: "tester",
                homeDirectory: "/Users/tester", currentDate: "01/01/2026"),
            longTermMemory: StaticGroundingMemory(ragContext: rag),
            recentHistory: nil,
            nativeHistoryTurns: nil,
            originalQuery: "What does this code do?",
            currentIteration: iteration,
            compiledScratchpad: "",
            latestClarification: nil,
            negativeConstraints: [],
            hallucinatedTools: [],
            availableTools: [],
            userProfile: nil,
            skillManifests: nil,
            promptLayerConfig: layerConfig,
            workflowContext: nil,
            attachmentContext: nil,
            knowledgeBaseContext: knowledge
        )
        ctx.traceContext = traceContext
        return ctx
    }

    private func beginTrace() async -> TraceContext {
        let ctx = TraceContext(subAgentName: "ctx-injection-test", provider: .anthropic)
        await TraceRecorder.shared.beginTrace(
            context: ctx, conversationID: UUID(), messageID: UUID(), modelName: nil)
        return ctx
    }

    /// Emission hops through an unstructured Task — flush by ending the trace, then read.
    private func contextEvents(_ traceID: String) async throws -> [SpanEvent] {
        // Give the fire-and-forget Task a beat to reach the actor before the flush.
        try await Task.sleep(for: .milliseconds(80))
        await TraceRecorder.shared.endTrace(traceID: traceID, status: .completed)
        return try XCTUnwrap(TraceStore.shared)
            .fetchEvents(forTraceID: traceID)
            .filter { $0.eventType == .memoryOp }
    }

    // MARK: - Emission

    func testFirstIterationEmitsOneEventPerShippedLayer() async throws {
        let trace = await beginTrace()
        let semantic = makeContext(traceContext: trace, iteration: 1,
                                   knowledge: "KB payload", rag: "retrieved snippet")
        _ = PromptBuilder.buildStandardMessages(context: semantic, layerConfig: .agent)

        let events = try await contextEvents(trace.traceID)
        let sources = Set(events.compactMap { RunReportProjection.detailValue($0, "source") })
        // Non-empty layers for this fixture: task, instructions, environment,
        // knowledge_base, retrieval. Empty ones must NOT produce rows.
        XCTAssertEqual(sources, ["task", "instructions", "environment", "knowledge_base", "retrieval"])

        let kb = try XCTUnwrap(events.first { RunReportProjection.detailValue($0, "source") == "knowledge_base" })
        XCTAssertEqual(RunReportProjection.detailValue(kb, "chars"), "\("KB payload".count)")
        XCTAssertEqual(RunReportProjection.detailValue(kb, "preview"), "KB payload")
    }

    func testLaterIterationsEmitNothing() async throws {
        let trace = await beginTrace()
        let semantic = makeContext(traceContext: trace, iteration: 2, knowledge: "KB payload")
        _ = PromptBuilder.buildStandardMessages(context: semantic, layerConfig: .agent)

        let events = try await contextEvents(trace.traceID)
        XCTAssertTrue(events.isEmpty,
                      "the legacy path rebuilds the prompt every iteration — re-emission would multiply storage by iteration count")
    }

    func testNilTraceContextEmitsNothing() async throws {
        let trace = await beginTrace() // only used as a read scope
        let semantic = makeContext(traceContext: nil, iteration: 1, knowledge: "KB payload")
        _ = PromptBuilder.buildStandardMessages(context: semantic, layerConfig: .agent)

        let events = try await contextEvents(trace.traceID)
        XCTAssertTrue(events.isEmpty, "fixtures and planning contexts carry no trace — they must stay silent")
    }

    func testEmissionOrderFollowsLayerOrder() async throws {
        let trace = await beginTrace()
        let semantic = makeContext(traceContext: trace, iteration: 1,
                                   knowledge: "KB", rag: "RAG")
        _ = PromptBuilder.buildStandardMessages(context: semantic, layerConfig: .agent)

        let events = try await contextEvents(trace.traceID).sorted { $0.timestamp < $1.timestamp }
        let ordered = events.compactMap { RunReportProjection.detailValue($0, "source") }
        XCTAssertEqual(ordered, ["task", "instructions", "environment", "knowledge_base", "retrieval"],
                       "the 1ms stagger must preserve prompt-layer order under a time sort")
    }

    // MARK: - Byte stability (the KV-cache invariant)

    func testTelemetryDoesNotChangeThePromptBytes() {
        let silent = makeContext(traceContext: nil, iteration: 1, knowledge: "KB", rag: "RAG")
        var traced = makeContext(traceContext: nil, iteration: 1, knowledge: "KB", rag: "RAG")
        traced.traceContext = TraceContext(subAgentName: "bytes", provider: .anthropic)

        let a = PromptBuilder.buildStandardMessages(context: silent, layerConfig: .agent)
        let b = PromptBuilder.buildStandardMessages(context: traced, layerConfig: .agent)
        XCTAssertEqual(a, b, "emitting telemetry must be byte-invisible to the rendered prompt")
    }
}
