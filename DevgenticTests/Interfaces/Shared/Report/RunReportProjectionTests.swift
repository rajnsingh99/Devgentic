// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RunReportProjectionTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class RunReportProjectionTests: XCTestCase {

    // MARK: - Fixtures

    private func trace(
        status: TraceStatus = .completed,
        startedAt: Date = Date(timeIntervalSince1970: 1000),
        endedAt: Date? = Date(timeIntervalSince1970: 1012),
        errorSummary: String? = nil,
        modelName: String? = "claude-sonnet-4",
        provider: String? = "Anthropic",
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        tokensEstimated: Bool? = nil,
        cost: Double? = nil,
        appVersion: String? = nil,
        buildNumber: String? = nil
    ) -> TraceRecord {
        TraceRecord(
            traceID: "t1", conversationID: "c1", messageID: "m1",
            profileID: "p1", profileName: "Research Assistant", profileType: "Agent",
            provider: provider, modelName: modelName,
            startedAt: startedAt, endedAt: endedAt,
            status: status, errorSummary: errorSummary,
            appVersion: appVersion, buildNumber: buildNumber,
            inputTokens: inputTokens, outputTokens: outputTokens,
            estimatedCostUSD: cost, tokensEstimated: tokensEstimated
        )
    }

    private func input(
        trace: TraceRecord?,
        spans: [Span] = [],
        events: [SpanEvent] = [],
        hitl: [HITLAuditRecord] = [],
        configJSON: String? = nil,
        toolCount: Int? = nil,
        answer: String? = nil,
        traceIDOnMessage: String? = "t1",
        storeAvailable: Bool = true
    ) -> RunReportInput {
        RunReportInput(
            trace: trace, spans: spans, events: events, hitl: hitl,
            configJSON: configJSON, configToolCount: toolCount,
            answerPreview: answer, userQueryPreview: nil,
            traceIDOnMessage: traceIDOnMessage, storeAvailable: storeAvailable)
    }

    private func span(_ id: String, kind: SpanKind, name: String, start: TimeInterval, end: TimeInterval?,
                      parent: String? = nil, declaredMs: Int? = nil) -> Span {
        Span(spanID: id, traceID: "t1", parentSpanID: parent, name: name, kind: kind,
             startedAt: Date(timeIntervalSince1970: start),
             endedAt: end.map(Date.init(timeIntervalSince1970:)),
             status: .completed,
             metadataJSON: declaredMs.map { "{\"duration_ms\":\"\($0)\"}" })
    }

    private func event(
        _ id: Int64, span: String, at: TimeInterval, type: SpanEventType,
        content: String? = nil, detail: [String: Any]? = nil,
        severity: SpanEventSeverity = .info, durationMs: Int? = nil,
        category: AgentErrorCategory? = nil
    ) -> SpanEvent {
        let json = detail.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
            .flatMap { String(data: $0, encoding: .utf8) }
        return SpanEvent(
            id: id, spanID: span, traceID: "t1",
            timestamp: Date(timeIntervalSince1970: at),
            eventType: type, content: content, detailJSON: json,
            severity: severity, errorCategory: category, durationMs: durationMs)
    }

    private func hitlRecord(raised: TimeInterval, resolved: TimeInterval?, outcome: String? = "approved") -> HITLAuditRecord {
        HITLAuditRecord(
            operationID: "op-\(raised)", conversationID: "c1", interface: "chat",
            type: "permission", toolName: "execute_shell", nodeName: nil,
            title: "Run xcodebuild?", raisedAt: Date(timeIntervalSince1970: raised),
            resolvedAt: resolved.map(Date.init(timeIntervalSince1970:)), outcome: outcome)
    }

    // MARK: - Unavailability discrimination (the four blank-panel causes)

    func testStoreUnavailableWinsOverEverything() {
        let p = RunReportProjection.build(input(trace: nil, traceIDOnMessage: nil, storeAvailable: false))
        XCTAssertEqual(p.unavailability, .storeUnavailable)
    }

    func testNilTraceIDMeansNeverRecorded() {
        let p = RunReportProjection.build(input(trace: nil, traceIDOnMessage: nil))
        XCTAssertEqual(p.unavailability, .neverRecorded)
    }

    func testMissingTraceRowMeansPurged() {
        let p = RunReportProjection.build(input(trace: nil, traceIDOnMessage: "t1"))
        XCTAssertEqual(p.unavailability, .purged)
    }

    func testPresentTraceMeansAvailable() {
        let p = RunReportProjection.build(input(trace: trace()))
        XCTAssertEqual(p.unavailability, RunReportUnavailability.none)
    }

    // MARK: - Verdict truth table (all 7 statuses)

    func testVerdictAllSevenStatuses() {
        let cases: [(TraceStatus, String, RunReportVerdict.Tone)] = [
            (.completed, "Completed", .success),
            (.completedWithWarnings, "Completed with warnings", .warning),
            (.failed, "Failed", .failure),
            (.error, "Error", .failure),
            (.cancelled, "Cancelled", .neutral),
            (.interrupted, "Interrupted", .warning),
            (.running, "Running", .running),
        ]
        for (status, label, tone) in cases {
            let v = RunReportProjection.makeVerdict(trace: trace(status: status), events: [], hitl: [])
            XCTAssertEqual(v.label, label, "status \(status)")
            XCTAssertEqual(v.tone, tone, "status \(status)")
            XCTAssertFalse(v.sentence.isEmpty, "every verdict carries a sentence — \(status)")
        }
    }

    func testVerdictSentenceCarriesErrorSummaryOnFailure() {
        let v = RunReportProjection.makeVerdict(
            trace: trace(status: .failed, errorSummary: "circuit breaker tripped"),
            events: [], hitl: [])
        XCTAssertTrue(v.sentence.contains("circuit breaker tripped"))
    }

    func testVerdictMentionsWaitTimeWhenHITLResolvedInWindow() {
        // Raised at t=1002, resolved at t=1006 → 4.0s inside the 1000–1012 run window.
        let v = RunReportProjection.makeVerdict(
            trace: trace(status: .completedWithWarnings),
            events: [], hitl: [hitlRecord(raised: 1002, resolved: 1006)])
        XCTAssertTrue(v.sentence.contains("4.0s"), "waited clause missing: \(v.sentence)")
    }

    func testHITLOutsideRunWindowDoesNotCountAsWaiting() {
        let ms = RunReportProjection.hitlWaitMs(
            hitl: [hitlRecord(raised: 500, resolved: 900)], // before the run started
            trace: trace())
        XCTAssertEqual(ms, 0)
    }

    // MARK: - Tool row merging

    func testToolCallAndResultMergeIntoOneRow() {
        let events = [
            event(1, span: "s1", at: 1001, type: .toolCall, content: "read_file",
                  detail: ["tool_name": "read_file", "tool_params": "{\"path\":\"README.md\"}"]),
            event(2, span: "s1", at: 1002, type: .toolResult, content: "read_file: success",
                  detail: ["tool_name": "read_file", "is_success": true, "output_preview": "# Devgentic"],
                  durationMs: 340),
        ]
        let p = RunReportProjection.build(input(trace: trace(), events: events))
        let rows = p.groups.flatMap(\.rows)
        let toolRows = rows.filter { $0.kind == .tool }
        XCTAssertEqual(toolRows.count, 1, "call + result must render as ONE row")
        let row = toolRows[0]
        XCTAssertTrue(row.title.contains("read_file"))
        XCTAssertEqual(row.duration, "340ms")
        XCTAssertFalse(row.isProblem)
        // Inspector carries both halves.
        let labels = row.detail.sections.map(\.label)
        XCTAssertTrue(labels.contains("ARGUMENTS"))
        XCTAssertTrue(labels.contains("RESULT"))
    }

    func testFailedToolIsAProblemRow() {
        let events = [
            event(1, span: "s1", at: 1002, type: .toolResult, content: "web_fetch: failed",
                  detail: ["tool_name": "web_fetch", "is_success": false, "output_preview": "timeout"],
                  severity: .warning, durationMs: 30_000),
        ]
        let p = RunReportProjection.build(input(trace: trace(), events: events))
        let row = p.groups.flatMap(\.rows).first { $0.kind == .tool }
        XCTAssertEqual(row?.isProblem, true)
    }

    func testToolCallWithoutResultSurfacesAsProblem() {
        let events = [
            event(1, span: "s1", at: 1001, type: .toolCall, content: "execute_shell",
                  detail: ["tool_name": "execute_shell", "tool_params": "{\"cmd\":\"xcodebuild\"}"]),
        ]
        let p = RunReportProjection.build(input(trace: trace(status: .interrupted), events: events))
        let row = p.groups.flatMap(\.rows).first { $0.kind == .tool }
        XCTAssertNotNil(row, "a call with no result must not vanish")
        XCTAssertEqual(row?.isProblem, true)
        XCTAssertTrue(row?.title.contains("no result recorded") ?? false)
    }

    /// The bridge writes tool OBSERVATIONS as `.thought` events carrying tool metadata —
    /// they must render as the tool's row, not as a THINK row.
    func testBridgedToolObservationRendersAsToolNotThink() {
        let events = [
            event(1, span: "s1", at: 1002, type: .thought, content: "Tool 'read_file' succeeded.",
                  detail: ["tool_name": "read_file", "is_success": "true", "tool_output": "full file contents here", "tool_params": "{\"path\":\"a\"}"]),
        ]
        let p = RunReportProjection.build(input(trace: trace(), events: events))
        let rows = p.groups.flatMap(\.rows)
        XCTAssertEqual(rows.filter { $0.kind == .think }.count, 0)
        let tool = rows.first { $0.kind == .tool }
        XCTAssertNotNil(tool)
        XCTAssertTrue(tool?.detail.sections.contains { $0.label == "RESULT" } ?? false,
                      "the uncapped tool_output must reach the inspector")
    }

    // MARK: - Issues

    func testErrorEventBecomesIssueRowWithCategory() {
        let events = [
            event(1, span: "s1", at: 1003, type: .error, content: "Network timeout",
                  severity: .error, category: .providerTimeout),
        ]
        let p = RunReportProjection.build(input(trace: trace(status: .completedWithWarnings), events: events))
        let row = p.groups.flatMap(\.rows).first { $0.kind == .issue }
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.isProblem, true)
        XCTAssertTrue(row?.meta.contains("providerTimeout") ?? false)
    }

    // MARK: - Grouping

    func testRowsGroupUnderStepSpansChronologically() {
        let spans = [
            span("root", kind: .workflow, name: "root", start: 1000, end: 1012),
            span("it1", kind: .iteration, name: "iteration_1", start: 1001, end: 1005, parent: "root"),
            span("it2", kind: .iteration, name: "iteration_2", start: 1005, end: 1010, parent: "root"),
        ]
        let events = [
            event(1, span: "it1", at: 1002, type: .thought, content: "step one thinking"),
            event(2, span: "it2", at: 1006, type: .thought, content: "step two thinking"),
        ]
        let p = RunReportProjection.build(input(trace: trace(), spans: spans, events: events))
        // A ReAct iteration is a TURN. "step" is reserved for the workflow NODE level, which
        // the timeline already owns ("failed at step 2 of 2") — see makeHeaderFacts.
        let turnGroups = p.groups.filter { $0.label.hasPrefix("TURN") }
        XCTAssertEqual(turnGroups.map(\.label), ["TURN 1", "TURN 2"])
        // ⚠️ Subscript only AFTER the count is pinned. This test previously did
        // `stepGroups[0]` straight after the filter, so renaming the label made it CRASH with
        // an index-out-of-range instead of failing — and a crashed case reports as neither
        // passed nor failed, so it silently vanished from the run while the summary still said
        // "0 failures" (2026-08-23).
        XCTAssertEqual(turnGroups.count, 2)
        XCTAssertTrue(turnGroups.first?.rows.contains { $0.title == "step one thinking" } ?? false)
        XCTAssertTrue(turnGroups.last?.rows.contains { $0.title == "step two thinking" } ?? false)
        // Setup lands before the first turn.
        XCTAssertEqual(p.groups.first?.label, "BEFORE THE RUN")
    }

    // MARK: - "step" means ONE thing (2026-08-23)

    /// ⚠️ The header used to emit BOTH span levels under two nouns: `.iteration` spans as
    /// "steps" and `.workflowNode` spans as "nodes". The timeline calls a NODE a step, so the
    /// same 2-node run read "1 step · 2 nodes" in the report and "2 steps" in the timeline
    /// three inches above. This is the exact observed shape: bot node (no iteration span) +
    /// agent node (one iteration).
    func testWorkflowHeaderCountsNodesAsStepsMatchingTheTimeline() {
        let spans = [
            span("n1", kind: .workflowNode, name: "node:MLX - Bot", start: 1001, end: 1003),
            span("n2", kind: .workflowNode, name: "node:Agent 3", start: 1003, end: 1011),
            span("it1", kind: .iteration, name: "iteration_1", start: 1003, end: 1011, parent: "n2"),
        ]
        let facts = RunReportProjection.makeHeaderFacts(trace: trace(), spans: spans, events: [])
        XCTAssertTrue(facts.contains("2 steps"), "must agree with the timeline's '2 steps': \(facts)")
        XCTAssertFalse(facts.contains { $0.contains("node") },
                       "'node' as a second noun is what created the collision: \(facts)")
        XCTAssertFalse(facts.contains("1 step"), "the iteration count must not be called a step")
    }

    /// A bot-only workflow opens NO iteration spans, so the old rule reported zero steps and
    /// the count vanished from the header entirely (`if steps > 0`). Node counting fixes that.
    func testBotOnlyWorkflowStillReportsItsSteps() {
        let spans = [
            span("n1", kind: .workflowNode, name: "node:Bot A", start: 1001, end: 1003),
            span("n2", kind: .workflowNode, name: "node:Bot B", start: 1003, end: 1005),
        ]
        let facts = RunReportProjection.makeHeaderFacts(trace: trace(), spans: spans, events: [])
        XCTAssertTrue(facts.contains("2 steps"), "a workflow with no ReAct nodes still has steps: \(facts)")
    }

    /// A chat run has no nodes, so its ReAct iterations are the structure — and they are turns.
    func testChatHeaderCountsIterationsAsTurns() {
        let spans = [
            span("it1", kind: .iteration, name: "iteration_1", start: 1001, end: 1005),
            span("it2", kind: .iteration, name: "iteration_2", start: 1005, end: 1009),
        ]
        let facts = RunReportProjection.makeHeaderFacts(trace: trace(), spans: spans, events: [])
        XCTAssertTrue(facts.contains("2 turns"), "got: \(facts)")
        XCTAssertFalse(facts.contains("2 steps"), "there are no nodes here, so nothing is a step")
    }

    /// ⚠️ THE GROUPING BUG. An inner `iteration_1` span starts microseconds AFTER its parent
    /// `node:Agent 3`, so the boundary rule ("last boundary at or before the row") gave it every
    /// row, the parent group was left empty, and `filter { !rows.isEmpty }` deleted it — the
    /// report showed "MLX - Bot NODE" but NEVER named "Agent 3", presenting its work under a
    /// bare "STEP 1". Two agent nodes produced two indistinguishable "STEP 1" headers.
    func testIterationGroupNamesTheNodeThatOwnsIt() {
        let spans = [
            span("n2", kind: .workflowNode, name: "node:Agent 3", start: 1003, end: 1011),
            span("it1", kind: .iteration, name: "iteration_1", start: 1003.001, end: 1011, parent: "n2"),
        ]
        let events = [event(1, span: "it1", at: 1004, type: .thought, content: "thinking")]
        let p = RunReportProjection.build(input(trace: trace(), spans: spans, events: events))
        let labels = p.groups.map(\.label)
        XCTAssertTrue(labels.contains("Agent 3 · TURN 1"),
                      "the owning node must survive the elision — got: \(labels)")
        XCTAssertFalse(labels.contains("TURN 1"), "an unqualified turn loses which node ran it")
    }

    /// The owner is found by walking UP the chain — an iteration is not always a DIRECT child
    /// of its node span, so matching only the immediate parent would miss it.
    func testIterationGroupFindsItsNodeThroughAnIntermediateSpan() {
        let spans = [
            span("n2", kind: .workflowNode, name: "node:Agent 3", start: 1003, end: 1011),
            span("mid", kind: .subtask, name: "agent_root", start: 1003, end: 1011, parent: "n2"),
            span("it1", kind: .iteration, name: "iteration_1", start: 1003.002, end: 1011, parent: "mid"),
        ]
        let events = [event(1, span: "it1", at: 1004, type: .thought, content: "thinking")]
        let p = RunReportProjection.build(input(trace: trace(), spans: spans, events: events))
        XCTAssertTrue(p.groups.map(\.label).contains("Agent 3 · TURN 1"),
                      "got: \(p.groups.map(\.label))")
    }

    func testWorkflowNodeGroupsCarryNameAndTag() {
        let spans = [
            span("n1", kind: .workflowNode, name: "node:Fetch Issues", start: 1001, end: 1004),
        ]
        let events = [event(1, span: "n1", at: 1002, type: .toolResult, content: "web_fetch: success",
                            detail: ["tool_name": "web_fetch", "is_success": true], durationMs: 100)]
        let p = RunReportProjection.build(input(trace: trace(), spans: spans, events: events))
        let node = p.groups.first { $0.kindTag == "NODE" }
        XCTAssertEqual(node?.label, "Fetch Issues", "the 'node:' prefix is UI clutter and must be stripped")
        XCTAssertEqual(node?.durationLabel, "3.0s")
    }

    // MARK: - Lanes

    func testLanesToolsWaitingAndLabelledRemainder() {
        // 12s run: 2s of tools, 4s waiting → 6s unattributed, labelled.
        let events = [
            event(1, span: "s1", at: 1002, type: .toolResult, content: "a: success",
                  detail: ["tool_name": "a", "is_success": true], durationMs: 2000),
        ]
        let (lanes, caveat) = RunReportProjection.makeLanes(
            trace: trace(), spans: [], events: events,
            hitl: [hitlRecord(raised: 1003, resolved: 1007)])
        XCTAssertEqual(lanes.map(\.label), ["Tools", "Waiting for you", "Unattributed"])
        XCTAssertEqual(lanes[0].durationMs, 2000)
        XCTAssertEqual(lanes[1].durationMs, 4000)
        XCTAssertEqual(lanes[2].durationMs, 6000)
        XCTAssertTrue(caveat.contains("Model time"), "no model lane ⇒ the gap must be named")
    }

    func testModelLaneAppearsWithLLMCallSpans() {
        let spans = [
            span("llm1", kind: .llmCall, name: "llm:claude-sonnet-4", start: 1001, end: 1009, declaredMs: 8000),
        ]
        let (lanes, caveat) = RunReportProjection.makeLanes(trace: trace(), spans: spans, events: [], hitl: [])
        XCTAssertEqual(lanes.first?.label, "Model")
        XCTAssertEqual(lanes.first?.durationMs, 8000)
        XCTAssertFalse(caveat.contains("Model time isn't measured"))
    }

    /// A span that declares NO measurement contributes nothing — its wall-clock is not a
    /// substitute. `chat_call` brackets message assembly and the whole retry loop, so counting
    /// its duration would over-read the Model lane.
    func testUndeclaredSpanDoesNotFeedModelLane() {
        let spans = [span("c1", kind: .llmCall, name: "chat_call", start: 1001, end: 1009)]
        let (lanes, _) = RunReportProjection.makeLanes(trace: trace(), spans: spans, events: [], hitl: [])
        XCTAssertFalse(lanes.contains { $0.label == "Model" })
    }

    /// THE FIX (on-device 2026-08-23): the bot path's model time reached the report's stream as
    /// a MODEL row but never reached the Model lane, because the lane matched the span NAME
    /// prefix "llm:" and only the agent path emits that. A bot node's 11,977ms call showed as
    /// 13.4s "Unattributed" out of a 14.0s run. The lane now counts the DECLARED duration, so
    /// any emitter that measures itself is counted regardless of what its span is called.
    func testDeclaredDurationOnANonLLMPrefixedSpanFeedsModelLane() {
        // Wall-clock 8s (assembly + retries), declared model time 5s — the honest number.
        let spans = [span("c1", kind: .llmCall, name: "chat_call", start: 1001, end: 1009, declaredMs: 5000)]
        let (lanes, _) = RunReportProjection.makeLanes(trace: trace(), spans: spans, events: [], hitl: [])
        let model = lanes.first { $0.label == "Model" }
        XCTAssertNotNil(model, "a bot/classifier/imageGen call that measured itself must be counted")
        XCTAssertEqual(model?.durationMs, 5000,
                       "the DECLARED duration wins — the span's 8s wall-clock would over-read")
    }

    /// Non-model spans stay out however they are named or annotated.
    func testDeclaredDurationOnANonLLMCallSpanIsIgnored() {
        let spans = [span("t1s", kind: .toolExecution, name: "llm:pretender", start: 1001, end: 1009, declaredMs: 5000)]
        let (lanes, _) = RunReportProjection.makeLanes(trace: trace(), spans: spans, events: [], hitl: [])
        XCTAssertFalse(lanes.contains { $0.label == "Model" })
    }

    // MARK: - The unattributed caveat must not invent a cause (2026-08-23)

    /// ⚠️ The caveat used to assert ONE hardcoded reason — "older runs predate parts of the
    /// instrumentation" — from a single input, the remainder fraction. A run recorded minutes
    /// earlier on the CURRENT build was told it was old. These pin the three honest branches.
    func testCaveatSaysUninstrumentedWhenThisBuildRecordedTheRun() {
        let (_, caveat) = RunReportProjection.makeLanes(
            trace: trace(buildNumber: "42"),
            spans: [span("m", kind: .llmCall, name: "llm:x", start: 1000, end: 1001, declaredMs: 1000)],
            events: [], hitl: [], currentBuildNumber: "42")
        XCTAssertTrue(caveat.contains("this build recorded it"), "got: \(caveat)")
        XCTAssertFalse(caveat.contains("earlier build"),
                       "a run this build wrote must never be described as old")
    }

    func testCaveatNamesTheOlderBuildWhenOneRecordedTheRun() {
        let (_, caveat) = RunReportProjection.makeLanes(
            trace: trace(appVersion: "0.9", buildNumber: "7"),
            spans: [span("m", kind: .llmCall, name: "llm:x", start: 1000, end: 1001, declaredMs: 1000)],
            events: [], hitl: [], currentBuildNumber: "42")
        XCTAssertTrue(caveat.contains("earlier build"), "got: \(caveat)")
        XCTAssertTrue(caveat.contains("0.9 (7)"), "the caveat must name the build it blames: \(caveat)")
    }

    func testCaveatAdmitsIgnoranceWhenTheRunPredatesBuildStamping() {
        let (_, caveat) = RunReportProjection.makeLanes(
            trace: trace(buildNumber: nil),
            spans: [span("m", kind: .llmCall, name: "llm:x", start: 1000, end: 1001, declaredMs: 1000)],
            events: [], hitl: [], currentBuildNumber: "42")
        XCTAssertTrue(caveat.contains("predates build stamping"), "got: \(caveat)")
        XCTAssertFalse(caveat.contains("earlier build"),
                       "unknown provenance must be stated, not guessed")
    }

    func testNoLanesForRunningTraceWithoutDuration() {
        let (lanes, _) = RunReportProjection.makeLanes(
            trace: trace(status: .running, endedAt: nil), spans: [], events: [], hitl: [])
        XCTAssertTrue(lanes.isEmpty)
    }

    // MARK: - Header facts

    func testHeaderFactsTokensAndCost() {
        let t = trace(inputTokens: 23_800, outputTokens: 96, tokensEstimated: true, cost: 0.0912)
        let facts = RunReportProjection.makeHeaderFacts(trace: t, spans: [], events: [])
        XCTAssertTrue(facts.contains { $0 == "~23.8K → 96 tok" }, "\(facts)")
        XCTAssertTrue(facts.contains { $0 == "~$0.09" }, "\(facts)")
    }

    func testHeaderFactsOmitWhatIsMissing() {
        let t = trace(modelName: nil, provider: nil, inputTokens: nil, outputTokens: nil)
        let facts = RunReportProjection.makeHeaderFacts(trace: t, spans: [], events: [])
        XCTAssertFalse(facts.contains { $0.contains("tok") })
        XCTAssertFalse(facts.contains { $0.contains("$") })
    }

    // MARK: - HITL rows

    func testHITLRowShowsOutcomeAndWait() {
        let p = RunReportProjection.build(input(
            trace: trace(), hitl: [hitlRecord(raised: 1002, resolved: 1006, outcome: "approved")]))
        let row = p.groups.flatMap(\.rows).first { $0.kind == .approval }
        XCTAssertNotNil(row)
        XCTAssertTrue(row?.meta.contains("approved") ?? false)
        XCTAssertEqual(row?.duration, "waited 4.0s")
    }

    // MARK: - CONTEXT rows (Phase 3)

    func testMemoryOpEventBecomesContextRowWithProvenance() {
        let events = [
            event(1, span: "s1", at: 1000.5, type: .memoryOp, content: "knowledge_base",
                  detail: ["source": "knowledge_base", "chars": 4100, "preview": "# Project docs…"]),
        ]
        let p = RunReportProjection.build(input(trace: trace(), events: events))
        let row = p.groups.flatMap(\.rows).first { $0.kind == .context }
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.title, "Knowledge base · 4.1K chars")
        XCTAssertEqual(row?.meta, "from: knowledge_base")
        XCTAssertTrue(row?.detail.sections.contains { $0.label == "PREVIEW" } ?? false)
        XCTAssertEqual(row?.isNotable, true)
    }

    func testUnknownContextSourceGetsReadableFallbackName() {
        XCTAssertEqual(RunReportProjection.contextSourceDisplayName("future_layer"), "Future Layer")
    }

    // MARK: - Input lane (Phase 3)

    func testInputLaneSumsAssemblyMetrics() {
        // 12s run: 1.5s input (two brackets), 2s tools → 8.5s unattributed.
        let events = [
            event(1, span: "root", at: 1000.2, type: .metric, content: "input_assembly: 1000ms",
                  detail: ["key": "input_assembly", "value_ms": 1000]),
            event(2, span: "it1", at: 1002.0, type: .metric, content: "input_assembly: 500ms",
                  detail: ["key": "input_assembly", "value_ms": 500]),
            event(3, span: "it1", at: 1003.0, type: .toolResult, content: "a: success",
                  detail: ["tool_name": "a", "is_success": true], durationMs: 2000),
        ]
        let (lanes, _) = RunReportProjection.makeLanes(trace: trace(), spans: [], events: events, hitl: [])
        XCTAssertEqual(lanes.map(\.label), ["Input", "Tools", "Unattributed"])
        XCTAssertEqual(lanes[0].durationMs, 1500)
        XCTAssertEqual(lanes[2].durationMs, 12_000 - 1500 - 2000)
    }

    func testOtherMetricsDoNotFeedTheInputLane() {
        let events = [
            event(1, span: "s1", at: 1002, type: .metric, content: "tool_latency: 900ms",
                  detail: ["key": "tool_latency", "value_ms": 900]),
        ]
        let (lanes, _) = RunReportProjection.makeLanes(trace: trace(), spans: [], events: events, hitl: [])
        XCTAssertFalse(lanes.contains { $0.label == "Input" })
    }

    // MARK: - Skips (Phase 5)

    /// A skip is an instruction, never a failure (invariant 73) — amber SKIPPED row,
    /// invisible to the Problems filter.
    func testSkipEventRendersAsSkippedRowNotIssue() {
        let events = [
            event(1, span: "s1", at: 1003, type: .error, content: "Skipped by you",
                  severity: .warning, category: .wfNodeSkipped),
        ]
        let p = RunReportProjection.build(input(trace: trace(), events: events))
        let rows = p.groups.flatMap(\.rows)
        XCTAssertNil(rows.first { $0.kind == .issue }, "a skip must NOT render as an ISSUE")
        let skip = rows.first { $0.kind == .skipped }
        XCTAssertNotNil(skip)
        XCTAssertEqual(skip?.isProblem, false, "the Problems filter must not surface skips")
    }

    /// ⚠️ The skip row used to carry ONE hardcoded sentence ending "nodes downstream received its
    /// input unchanged" — true only for `.byUser`, the single reason that keeps the edge below it
    /// live. For every cascade reason the report asserted the OPPOSITE of what the engine did.
    func testSkipExplanationIsPerReasonNotOneHardcodedClaim() {
        let byUserRan = RunReportProjection.skipExplanation(reason: "byUser", ranBeforeSkip: true)
        XCTAssertTrue(byUserRan.contains("while it was running"), byUserRan)
        XCTAssertTrue(byUserRan.contains("discarded"), "the work it did is not free: \(byUserRan)")

        let byUserNotRan = RunReportProjection.skipExplanation(reason: "byUser", ranBeforeSkip: false)
        XCTAssertTrue(byUserNotRan.contains("before it started"), byUserNotRan)

        for cascade in ["notChosen", "errorPortNotTaken", "upstreamFailed", "upstreamSkipped", "upstreamCancelled", "notReached"] {
            let text = RunReportProjection.skipExplanation(reason: cascade, ranBeforeSkip: false)
            XCTAssertFalse(text.contains("received this node's input"),
                           "\(cascade) kills the subtree below it — claiming pass-through is false: \(text)")
        }
    }

    /// An unknown or absent reason must state only what is true of EVERY skip, not default to the
    /// byUser-shaped claim (records written before the producer carried the reason).
    func testUnknownSkipReasonMakesNoPassThroughClaim() {
        for r in [nil, "somethingNewerBuildsKnow"] {
            let text = RunReportProjection.skipExplanation(reason: r, ranBeforeSkip: false)
            XCTAssertFalse(text.contains("received this node's input"), text)
            XCTAssertTrue(text.contains("did not run"), text)
        }
    }

    /// ⚠️ THE INERT-FIX GUARD. `TraceRecorder` nests a classified error's context under
    /// `detail["context"]`, so a producer that adds a context key and a consumer that reads it
    /// with `detailValue` (top-level only) silently never meet.
    func testSkipRowReadsTheNestedContextBag() {
        let events = [
            event(1, span: "s1", at: 1003, type: .error, content: "Skipped by you",
                  detail: ["context": ["skip_reason": "byUser", "ran_before_skip": "true"]],
                  severity: .warning, category: .wfNodeSkipped),
        ]
        let p = RunReportProjection.build(input(trace: trace(), events: events))
        let skip = p.groups.flatMap(\.rows).first { $0.kind == .skipped }
        XCTAssertEqual(skip?.detail.title, "Skipped mid-run",
                       "the nested context must actually reach the projection")
        let prose = skip?.detail.sections.first { $0.label == "WHAT HAPPENED" }
        if case .prose(let text)? = prose?.body {
            XCTAssertTrue(text.contains("while it was running"), text)
        } else { XCTFail("no WHAT HAPPENED prose") }
    }

    // MARK: - The skip classification must not depend on a privacy-gated column (2026-08-23)

    /// ⚠️ THE HOLE UNDER THE PHASE 5 FIX. `TraceRecorder` writes the indexed `errorCategory`
    /// column only when developer mode is on OR "diagnostics recording" is enabled — but it does
    /// NOT gate trace/span/event recording on that preference. So a user who opts out still gets a
    /// full Run Report in which every skip arrives with `errorCategory == nil`, falls into the
    /// generic ISSUE arm, and is painted RED as a problem. The classification is also written
    /// UNCONDITIONALLY into detailJSON one line above the gated column; this pins that fallback.
    func testSkipIsStillASkipWhenTheErrorCategoryColumnWasNotRecorded() {
        let events = [
            event(1, span: "s1", at: 1003, type: .error, content: "Skipped by you",
                  detail: ["category": AgentErrorCategory.wfNodeSkipped.rawValue],
                  severity: .warning, category: nil),   // diagnostics OFF → column is NULL
        ]
        let p = RunReportProjection.build(input(trace: trace(), events: events))
        let rows = p.groups.flatMap(\.rows)
        XCTAssertNil(rows.first { $0.kind == .issue },
                     "with diagnostics off the skip fell into the ISSUE arm and showed red")
        let skip = rows.first { $0.kind == .skipped }
        XCTAssertNotNil(skip, "the detailJSON fallback must carry the classification")
        XCTAssertEqual(skip?.isProblem, false, "the Problems filter must still not surface it")
    }

    /// A genuine error with no category recorded must STILL be a problem — the fallback must not
    /// swallow everything that lost its column.
    func testUncategorisedGenuineErrorIsStillAProblem() {
        let events = [
            event(1, span: "s1", at: 1003, type: .error, content: "Tool crashed",
                  detail: ["category": "toolFailure"], severity: .error, category: nil),
        ]
        let p = RunReportProjection.build(input(trace: trace(), events: events))
        let rows = p.groups.flatMap(\.rows)
        XCTAssertNotNil(rows.first { $0.kind == .issue && $0.isProblem },
                        "only wfNodeSkipped is exempt; a real error stays a problem")
    }

    /// A skip is persisted as `eventType: .error` with `severity: .warning`, so it matched BOTH
    /// verdict buckets and inflated "N problem(s) occurred on the way" — the sentence counting the
    /// user's own instruction as a problem, twice.
    func testSkipDoesNotInflateTheVerdictProblemCount() {
        let skip = event(1, span: "s1", at: 1003, type: .error, content: "Skipped by you",
                         severity: .warning, category: .wfNodeSkipped)
        let v = RunReportProjection.makeVerdict(
            trace: trace(status: .completedWithWarnings), events: [skip], hitl: [])
        XCTAssertFalse(v.sentence.contains("1 problem"),
                       "a skip is an instruction, not a problem: \(v.sentence)")
        XCTAssertTrue(v.sentence.contains("something went wrong"),
                      "with the skip exempt there are no counted problems left: \(v.sentence)")
    }

    /// The control: a real warning still counts.
    func testRealWarningStillCountsTowardTheVerdict() {
        let warn = event(1, span: "s1", at: 1003, type: .error, content: "Degraded",
                         severity: .warning, category: .providerRateLimit)
        let v = RunReportProjection.makeVerdict(
            trace: trace(status: .completedWithWarnings), events: [warn], hitl: [])
        XCTAssertTrue(v.sentence.contains("1 problem(s)"), v.sentence)
    }

    // MARK: - ask_user false alarm (fixed 2026-08-22)

    /// ask_user is INTERCEPTED by the HITL banner by design — a dangling ask_user call
    /// is a healthy clarification, not a "no result recorded" problem. Its outcome is
    /// the APPROVAL row.
    func testDanglingAskUserCallIsNotAProblem() {
        let events = [
            event(1, span: "s1", at: 1001, type: .toolCall, content: "ask_user",
                  detail: ["tool_name": "ask_user", "tool_params": "{\"question\":\"which folder?\"}"]),
        ]
        let p = RunReportProjection.build(input(
            trace: trace(), events: events,
            hitl: [hitlRecord(raised: 1001.5, resolved: 1006, outcome: "answered")]))
        let rows = p.groups.flatMap(\.rows)
        XCTAssertNil(rows.first { $0.kind == .tool && $0.isProblem },
                     "an intercepted ask_user must not paint a red dangling-call row")
        XCTAssertNotNil(rows.first { $0.kind == .approval }, "the APPROVAL row carries the outcome")
    }

    // MARK: - HITL exact join (Phase 5 v8 columns)

    func testHITLWithTraceIDMatchesExactlyIgnoringWindow() {
        // Row raised OUTSIDE the run window but carrying THIS trace's id → included.
        var inRun = hitlRecord(raised: 500, resolved: 900)
        inRun.traceID = "t1"
        // Row raised INSIDE the window but belonging to ANOTHER trace → excluded.
        var otherRun = hitlRecord(raised: 1002, resolved: 1006)
        otherRun.traceID = "other-trace"

        XCTAssertTrue(RunReportProjection.hitlBelongsToRun(inRun, trace: trace()))
        XCTAssertFalse(RunReportProjection.hitlBelongsToRun(otherRun, trace: trace()),
                       "a v8 row names its run — the window heuristic must not override it")
        // Pre-v8 rows (nil traceID) keep the window heuristic.
        XCTAssertTrue(RunReportProjection.hitlBelongsToRun(hitlRecord(raised: 1002, resolved: 1006), trace: trace()))
    }

    // MARK: - Setup

    func testSetupRowSaysWhenSnapshotIsMissing() {
        let p = RunReportProjection.build(input(trace: trace(), configJSON: nil))
        let setup = p.groups.flatMap(\.rows).first { $0.kind == .setup }
        XCTAssertTrue(setup?.title.contains("no configuration snapshot") ?? false,
                      "a missing snapshot is a labelled gap, not a silent omission")
    }
}
