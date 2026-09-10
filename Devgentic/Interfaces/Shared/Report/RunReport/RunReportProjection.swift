// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  RunReportProjection.swift
//  Devgentic
//
//  The Run Report's entire display logic as a PURE projection: persisted rows in,
//  display values out. No store access, no SwiftUI, no clocks — the view paints what
//  this returns and adds nothing, so every claim the report makes is unit-testable
//  truth-table style (the WorkflowRunDisplayData pattern).
//
//  Design contract (approved 2026-08-22, "Run Report Redesign" canvas):
//    • ONE flat chronological stream is the primitive; steps/nodes are groupings over it.
//    • The verdict leads, as a sentence — derived from rows, never invented.
//    • A lane or number with no data on this path is a LABELLED gap, not a blank.
//

import Foundation

// MARK: - Row model

/// What kind of thing a stream row is — plain-language vocabulary, not enum spelling.
enum RunReportRowKind: String, Sendable {
    case setup = "SETUP"
    case context = "CONTEXT"
    case think = "THINK"
    case tool = "TOOL"
    case llm = "MODEL"
    case issue = "ISSUE"
    case approval = "APPROVAL"
    case skipped = "SKIPPED"
    case answer = "ANSWER"
    case state = "STATE"
}

/// One row of the stream. `id` is stable across rebuilds (event id / span id derived)
/// so selection survives a live refresh.
struct RunReportRow: Identifiable, Equatable, Sendable {
    let id: String
    let kind: RunReportRowKind
    let timestamp: Date
    let title: String
    /// Secondary mono line (tool params preview, error category, wait duration). Empty = hidden.
    let meta: String
    /// Right-aligned duration label ("340ms"). Empty = hidden.
    let duration: String
    /// True for rows the "Problems" filter keeps.
    let isProblem: Bool
    /// True for rows the "Notable" filter keeps (problems are always notable).
    let isNotable: Bool
    /// Nested one level (sub-workflow children, sub-tool activity).
    let isIndented: Bool
    /// Payload for the inspector pane.
    let detail: RunReportDetail
}

/// Inspector payload — sections the pane renders top to bottom.
struct RunReportDetail: Equatable, Sendable {
    struct Section: Equatable, Sendable {
        enum Body: Equatable, Sendable {
            case prose(String)
            case code(String)
            case pairs([(String, String)].KeyValueList)
        }
        let label: String
        let body: Body
    }
    let title: String
    let subtitle: String
    let sections: [Section]

    static let empty = RunReportDetail(title: "", subtitle: "", sections: [])
}

/// Equatable wrapper for ordered key-value pairs (tuples aren't Equatable in arrays).
extension Array where Element == (String, String) {
    struct KeyValueList: Equatable, Sendable {
        let pairs: [Pair]
        struct Pair: Equatable, Sendable, Identifiable {
            let key: String
            let value: String
            var id: String { key + "|" + value }
        }
        init(_ tuples: [(String, String)]) {
            pairs = tuples.map { Pair(key: $0.0, value: $0.1) }
        }
    }
}

/// A group of rows under one sticky header (a step, a node, or the pre-run setup).
struct RunReportGroup: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    /// "" for turn groups; the node KIND for workflow node groups ("ACTION", "GATE", …).
    let kindTag: String
    let durationLabel: String
    var rows: [RunReportRow]
}

// MARK: - Verdict

struct RunReportVerdict: Equatable, Sendable {
    enum Tone: Sendable { case success, warning, failure, running, neutral }
    let label: String
    let tone: Tone
    /// The one-sentence explanation under the pill. Derived, never invented.
    let sentence: String
}

// MARK: - Ribbon

/// One segment of the where-the-time-went ribbon. Fractions sum to ≤ 1; the builder
/// appends an explicit "unattributed" remainder so gaps are labelled, never implied.
struct RunReportLaneSegment: Identifiable, Equatable, Sendable {
    enum Category: Sendable { case input, tools, waiting, model, unattributed }
    let id: String
    let category: Category
    let label: String
    let fraction: Double
    let durationMs: Int
}

// MARK: - Empty / error states

/// The four distinct reasons the report can have nothing to show — each gets its own
/// sentence in the UI instead of the old undifferentiated blank panel.
enum RunReportUnavailability: Equatable, Sendable {
    /// message.traceID == nil — the run predates trace recording.
    case neverRecorded
    /// traceID present but the row is gone — the 30-day purge took it.
    case purged
    /// TraceStore.shared == nil — the diagnostics database could not be opened.
    case storeUnavailable
    /// The run is older than this build's instrumentation on some axis — partial banner, not a blank.
    case none
}

// MARK: - Inputs

/// Everything the projection reads, as plain values. The view model fetches these;
/// tests construct them directly.
struct RunReportInput: Sendable {
    let trace: TraceRecord?
    let spans: [Span]              // flat, hydration not required (tree derived here)
    let events: [SpanEvent]        // all events of the trace
    let hitl: [HITLAuditRecord]    // conversation-scoped; filtered to the run window here
    let configJSON: String?        // trace_configs.snapshotJSON (sanitized at capture)
    let configToolCount: Int?
    let answerPreview: String?     // the assistant message's prose (SwiftData side)
    let userQueryPreview: String?  // the user message's text when available
    let traceIDOnMessage: String?  // ChatMessageSD.traceID — nil ⇒ neverRecorded
    let storeAvailable: Bool
    /// This build's CFBundleVersion, supplied by the caller so the projection stays pure
    /// (no `Bundle`, no clocks — see the file header). Lets the unattributed caveat tell
    /// "recorded by an older build" apart from "this build doesn't measure that path yet"
    /// instead of asserting the first as though it were known.
    var currentBuildNumber: String? = nil
}

// MARK: - Output

struct RunReportProjection: Equatable, Sendable {
    let unavailability: RunReportUnavailability
    let verdict: RunReportVerdict
    let headerFacts: [String]      // "claude-sonnet-4 · Anthropic", "12.4s", "2 steps · 3 tools", …
    let lanes: [RunReportLaneSegment]
    /// Honest caveat under the ribbon when a lane has no data ("model time isn't measured …").
    let laneCaveat: String
    let groups: [RunReportGroup]
    let setupDetail: RunReportDetail

    // MARK: Build

    static func build(_ input: RunReportInput) -> RunReportProjection {
        // ---- Unavailability discrimination (the four blank-panel causes) ----
        if !input.storeAvailable {
            return unavailable(.storeUnavailable)
        }
        if input.traceIDOnMessage == nil {
            return unavailable(.neverRecorded)
        }
        guard let trace = input.trace else {
            return unavailable(.purged)
        }

        let spansByID = Dictionary(uniqueKeysWithValues: input.spans.map { ($0.spanID, $0) })
        let events = input.events.sorted { $0.timestamp < $1.timestamp }

        // ---- Verdict ----
        let verdict = makeVerdict(trace: trace, events: events, hitl: input.hitl)

        // ---- Rows ----
        var rows: [RunReportRow] = []
        rows.append(contentsOf: setupRows(trace: trace, input: input))
        if let query = input.userQueryPreview, !query.isEmpty {
            rows.append(RunReportRow(
                id: "you", kind: .think, timestamp: trace.startedAt,
                title: query, meta: "", duration: "", isProblem: false, isNotable: true,
                isIndented: false,
                detail: RunReportDetail(title: "Your message", subtitle: "What started this run",
                                        sections: [.init(label: "MESSAGE", body: .prose(query))])
            ))
        }
        rows.append(contentsOf: eventRows(events: events, spansByID: spansByID))
        rows.append(contentsOf: hitlRows(hitl: input.hitl, trace: trace))
        if let answer = input.answerPreview, !answer.isEmpty {
            rows.append(RunReportRow(
                id: "answer", kind: .answer, timestamp: trace.endedAt ?? .distantFuture,
                title: String(answer.prefix(160)), meta: "", duration: "",
                isProblem: false, isNotable: true, isIndented: false,
                detail: RunReportDetail(title: "The answer", subtitle: "What this run produced",
                                        sections: [.init(label: "RESPONSE", body: .prose(answer))])
            ))
        }
        rows.sort { $0.timestamp < $1.timestamp }

        // ---- Grouping: chat steps from iteration spans; workflow nodes from node spans ----
        let groups = makeGroups(rows: rows, spans: input.spans, trace: trace)

        // ---- Lanes ----
        let (lanes, caveat) = makeLanes(trace: trace, spans: input.spans, events: events, hitl: input.hitl,
                                        currentBuildNumber: input.currentBuildNumber)

        return RunReportProjection(
            unavailability: .none,
            verdict: verdict,
            headerFacts: makeHeaderFacts(trace: trace, spans: input.spans, events: events),
            lanes: lanes,
            laneCaveat: caveat,
            groups: groups,
            setupDetail: makeSetupDetail(trace: trace, input: input)
        )
    }

    // MARK: - Unavailable

    private static func unavailable(_ u: RunReportUnavailability) -> RunReportProjection {
        RunReportProjection(
            unavailability: u,
            verdict: RunReportVerdict(label: "", tone: .neutral, sentence: ""),
            headerFacts: [], lanes: [], laneCaveat: "", groups: [], setupDetail: .empty
        )
    }

    // MARK: - Verdict

    static func makeVerdict(trace: TraceRecord, events: [SpanEvent], hitl: [HITLAuditRecord]) -> RunReportVerdict {
        // ⚠️ Skips are excluded from BOTH buckets. A skip is persisted as `eventType: .error`
        // with `severity: .warning` (its `.informational` category maps to warning), so it
        // matched each filter and inflated "N problem(s) occurred on the way" — the verdict
        // sentence counting the user's own instruction as a problem, twice over. Same invariant
        // as the Problems filter, enforced in the one other place that counts trouble.
        let errorEvents = events.filter { ($0.severity == .error || $0.eventType == .error) && !isSkipEvent($0) }
        let warningEvents = events.filter { $0.severity == .warning && !isSkipEvent($0) }
        let waitedMs = hitlWaitMs(hitl: hitl, trace: trace)

        func waitedClause() -> String {
            waitedMs > 0 ? " The run paused \(DurationFormat.format(ms: waitedMs)) waiting for you." : ""
        }

        switch trace.status {
        case .completed:
            return RunReportVerdict(
                label: "Completed", tone: .success,
                sentence: "The run finished cleanly." + waitedClause())
        case .completedWithWarnings:
            let what = warningEvents.isEmpty && errorEvents.isEmpty
                ? "something went wrong on the way"
                : "\(max(warningEvents.count, errorEvents.count)) problem(s) occurred on the way"
            return RunReportVerdict(
                label: "Completed with warnings", tone: .warning,
                sentence: "You got an answer, but \(what)." + waitedClause())
        case .failed:
            return RunReportVerdict(
                label: "Failed", tone: .failure,
                sentence: (trace.errorSummary.map { "The run gave up: \($0)" } ?? "The run reached a failure outcome without an answer.") + waitedClause())
        case .error:
            return RunReportVerdict(
                label: "Error", tone: .failure,
                sentence: (trace.errorSummary.map { "The run stopped with an error: \($0)" } ?? "An error reached the stream boundary.") + waitedClause())
        case .cancelled:
            return RunReportVerdict(
                label: "Cancelled", tone: .neutral,
                sentence: "You stopped this run before it finished.")
        case .interrupted:
            return RunReportVerdict(
                label: "Interrupted", tone: .warning,
                sentence: "The app quit or crashed while this run was in flight — everything up to that moment was kept.")
        case .running:
            return RunReportVerdict(
                label: "Running", tone: .running,
                sentence: "This run is still in progress; rows land about a second behind it.")
        }
    }

    // MARK: - Header facts

    static func makeHeaderFacts(trace: TraceRecord, spans: [Span], events: [SpanEvent]) -> [String] {
        var facts: [String] = []
        let modelBits = [trace.modelName, trace.provider].compactMap { $0 }
        if !modelBits.isEmpty { facts.append(modelBits.joined(separator: " · ")) }
        if let d = trace.durationMs { facts.append(DurationFormat.format(ms: d)) }
        // ⚠️ ONE NOUN, ONE MEANING. "step" is the WORKFLOW NODE — the timeline already owns
        // that word ("failed at step 2 of 2", `WorkflowRunDisplayData.stepCounterDescription`)
        // and it is the level a user recognises. "turn" is one ReAct model iteration.
        //
        // This header used to emit BOTH dimensions of the span tree side by side under two
        // nouns the timeline had already assigned differently: `steps` counted `.iteration`
        // spans while the timeline's "step" counted nodes, so the same 2-node run read
        // "1 step · 2 nodes" here and "2 steps" three inches above (observed 2026-08-23).
        // Worse, `.iteration` spans exist only on the ReAct path, so a bot-only workflow of any
        // size reported ZERO steps and the fact vanished entirely — the count was never a
        // node undercount, it was a different entity that happened to land nearby.
        let turns = spans.filter { $0.kind == .iteration }.count
        let nodes = spans.filter { $0.kind == .workflowNode }.count
        let tools = events.filter { $0.eventType == .toolResult }.count
        var counts: [String] = []
        if nodes > 0 {
            // Workflow run. Turns are deliberately NOT aggregated here: how many times a model
            // looped is a property of a NODE, not of the run, so a run-level scalar ("1 turn"
            // across two nodes) summarises away the only thing that makes it useful — which
            // node looped. The stream carries it per node instead (see makeGroups).
            counts.append("\(nodes) step\(nodes == 1 ? "" : "s")")
        } else if turns > 0 {
            // Chat run — no nodes exist, so the model turns are the run's structure.
            counts.append("\(turns) turn\(turns == 1 ? "" : "s")")
        }
        if tools > 0 { counts.append("\(tools) tool\(tools == 1 ? "" : "s")") }
        if !counts.isEmpty { facts.append(counts.joined(separator: " · ")) }
        if let inTok = trace.inputTokens, let outTok = trace.outputTokens {
            let estimated = (trace.tokensEstimated ?? false) ? "~" : ""
            facts.append("\(estimated)\(compactTokens(inTok)) → \(compactTokens(outTok)) tok")
        }
        if let cost = trace.estimatedCostUSD {
            facts.append(String(format: "~$%.2f", cost))
        }
        return facts
    }

    static func compactTokens(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fK", Double(n) / 1000) : "\(n)"
    }

    // MARK: - Rows from events

    private static func setupRows(trace: TraceRecord, input: RunReportInput) -> [RunReportRow] {
        var title = "How this run was set up"
        var meta: [String] = []
        if let m = trace.modelName { meta.append(m) }
        if let c = input.configToolCount, c > 0 { meta.append("\(c) tools") }
        if let v = trace.appVersion { meta.append("build \(v)") }
        if input.configJSON == nil { title += " (no configuration snapshot for this run)" }
        return [RunReportRow(
            id: "setup", kind: .setup, timestamp: trace.startedAt.addingTimeInterval(-0.001),
            title: title, meta: meta.joined(separator: " · "), duration: "",
            isProblem: false, isNotable: true, isIndented: false,
            detail: makeSetupDetail(trace: trace, input: input)
        )]
    }

    private static func eventRows(events: [SpanEvent], spansByID: [String: Span]) -> [RunReportRow] {
        var rows: [RunReportRow] = []
        // Merge a toolCall with its following toolResult on the same span+tool: one thing
        // happened, one row — the call carries the args, the result the outcome/duration.
        var pendingToolCalls: [String: SpanEvent] = [:]  // key: spanID|toolName

        func toolKey(_ e: SpanEvent) -> String {
            (e.spanID) + "|" + (detailValue(e, "tool_name") ?? e.content ?? "")
        }

        for e in events {
            let eid = e.id.map(String.init) ?? "\(e.timestamp.timeIntervalSince1970)-\(e.eventType.rawValue)"
            let indented = spansByID[e.spanID]?.parentSpanID.flatMap { spansByID[$0]?.parentSpanID } != nil

            switch e.eventType {
            case .thought:
                // The bridge writes tool OBSERVATIONS as .thought with tool metadata —
                // those merge into the tool row below; genuine thoughts render here.
                if let name = detailValue(e, "tool_name"), detailValue(e, "tool_output") != nil {
                    if let call = pendingToolCalls.removeValue(forKey: e.spanID + "|" + name) {
                        rows.append(mergedToolRow(call: call, result: e, name: name, indented: indented))
                    } else {
                        rows.append(mergedToolRow(call: nil, result: e, name: name, indented: indented))
                    }
                    continue
                }
                rows.append(RunReportRow(
                    id: eid, kind: .think, timestamp: e.timestamp,
                    title: e.content ?? "—", meta: "", duration: "",
                    isProblem: false, isNotable: false, isIndented: indented,
                    detail: RunReportDetail(
                        title: "Thinking", subtitle: "The model's reasoning at this step",
                        sections: [.init(label: "THOUGHT", body: .prose(e.content ?? ""))])
                ))

            case .toolCall:
                pendingToolCalls[toolKey(e)] = e

            case .toolResult:
                let name = detailValue(e, "tool_name") ?? (e.content?.components(separatedBy: ":").first ?? "tool")
                let call = pendingToolCalls.removeValue(forKey: e.spanID + "|" + name)
                rows.append(mergedToolRow(call: call, result: e, name: name, indented: indented))

            case .llmRequest:
                continue // paired into the response row below; a lone request adds noise
            case .llmResponse:
                let ms = e.durationMs ?? detailValue(e, "duration_ms").flatMap(Int.init) ?? 0
                rows.append(RunReportRow(
                    id: eid, kind: .llm, timestamp: e.timestamp,
                    title: e.content ?? "Model call", meta: "", duration: ms > 0 ? DurationFormat.format(ms: ms) : "",
                    isProblem: false, isNotable: false, isIndented: indented,
                    detail: RunReportDetail(
                        title: "Model call", subtitle: "One request → response round trip",
                        sections: [
                            .init(label: "RESPONSE PREVIEW", body: .prose(detailValue(e, "response_preview") ?? e.content ?? "")),
                            .init(label: "TIMING", body: .pairs(.init([("Duration", ms > 0 ? DurationFormat.format(ms: ms) : "not measured")])))
                        ])
                ))

            case .error, .parseError:
                // A skip is an INSTRUCTION, never a failure (invariant 73) — it renders
                // as its own amber row, not as a red ISSUE, and the Problems filter
                // must not surface it.
                if isSkipEvent(e) {
                    let skipReason = contextValue(e, "skip_reason")
                    let ranBefore = contextValue(e, "ran_before_skip") == "true"
                    // Only `.byUser` keeps the edge below it live; every cascade reason kills the
                    // subtree, so "downstream carried on" cannot be said unconditionally.
                    let meta = skipReason == "byUser"
                        ? (ranBefore ? "skipped mid-run — downstream carried on" : "not a failure — downstream carried on")
                        : "not a failure — this node never ran"
                    rows.append(RunReportRow(
                        id: eid, kind: .skipped, timestamp: e.timestamp,
                        title: e.content ?? "Skipped",
                        meta: meta,
                        duration: "", isProblem: false, isNotable: true, isIndented: indented,
                        detail: RunReportDetail(
                            title: ranBefore ? "Skipped mid-run" : "Skipped", subtitle: e.content ?? "",
                            sections: [
                                .init(label: "WHAT HAPPENED", body: .prose(skipExplanation(reason: skipReason, ranBeforeSkip: ranBefore))),
                            ] + (e.detailJSON.map { [RunReportDetail.Section(label: "DETAIL", body: .code(prettyJSON($0)))] } ?? []))
                    ))
                    continue
                }
                let category = e.errorCategory?.rawValue
                var pairs: [(String, String)] = []
                if let c = category { pairs.append(("Category", c)) }
                if let p = e.phase?.rawValue { pairs.append(("Phase", p)) }
                pairs.append(("Severity", e.severity == .error ? "fatal for this step" : "recovered / degraded"))
                rows.append(RunReportRow(
                    id: eid, kind: .issue, timestamp: e.timestamp,
                    title: e.content ?? "Something went wrong",
                    meta: [category, e.phase.map { "phase: \($0.rawValue)" }].compactMap { $0 }.joined(separator: " · "),
                    duration: "", isProblem: true, isNotable: true, isIndented: indented,
                    detail: RunReportDetail(
                        title: "Issue", subtitle: category ?? "unclassified",
                        sections: [
                            .init(label: "WHAT WENT WRONG", body: .prose(e.content ?? "")),
                            .init(label: "CLASSIFICATION", body: .pairs(.init(pairs)))
                        ] + (e.detailJSON.map { [RunReportDetail.Section(label: "DETAIL", body: .code(prettyJSON($0)))] } ?? []))
                ))

            case .userInteraction:
                rows.append(RunReportRow(
                    id: eid, kind: .approval, timestamp: e.timestamp,
                    title: e.content ?? "You were asked", meta: "", duration: "",
                    isProblem: false, isNotable: true, isIndented: indented,
                    detail: RunReportDetail(
                        title: "You were asked", subtitle: "Human-in-the-loop decision",
                        sections: [.init(label: "DECISION", body: .prose(e.content ?? ""))])
                ))

            case .memoryOp:
                // CONTEXT injection (Run-Report Phase 3): one row per prompt layer that
                // shipped, with its provenance — the report's answer to "what did the
                // model read, and where did it come from".
                let source = detailValue(e, "source") ?? e.content ?? "context"
                let chars = detailValue(e, "chars").flatMap(Int.init) ?? 0
                let preview = detailValue(e, "preview") ?? ""
                rows.append(RunReportRow(
                    id: eid, kind: .context, timestamp: e.timestamp,
                    title: "\(contextSourceDisplayName(source)) · \(compactChars(chars))",
                    meta: "from: \(source)", duration: "",
                    isProblem: false, isNotable: true, isIndented: indented,
                    detail: RunReportDetail(
                        title: contextSourceDisplayName(source),
                        subtitle: "Context the model received · \(compactChars(chars))",
                        sections: [
                            .init(label: "SOURCE", body: .pairs(.init([
                                ("Layer", source),
                                ("Size", "\(chars) chars"),
                            ]))),
                            .init(label: "PREVIEW", body: .code(preview.isEmpty ? "—" : preview))
                        ])
                ))

            case .stateChange, .metric, .parseAttempt:
                continue // internal bookkeeping; visible via the Details density toggle later
            }
        }

        // Any toolCall that never saw a result: it's still running or was torn down —
        // surface it rather than dropping it. EXCEPT interception-style tools:
        // `ask_user` is intercepted by the HITL banner BY DESIGN and never produces a
        // tool-result event — its outcome is the APPROVAL row (hitl_audit) that carries
        // the question, the wait and the answer. Flagging it painted a red "no result
        // recorded" problem row onto every healthy clarification (user report,
        // 2026-08-22 manual test) — a false alarm right above the row that showed it
        // was answered.
        let interceptionTools: Set<String> = ["ask_user"]
        for (_, call) in pendingToolCalls {
            let name = detailValue(call, "tool_name") ?? call.content ?? "tool"
            if interceptionTools.contains(name) { continue }
            rows.append(RunReportRow(
                id: call.id.map(String.init) ?? "call-\(name)", kind: .tool, timestamp: call.timestamp,
                title: "\(name) — no result recorded", meta: "started but never reported back",
                duration: "", isProblem: true, isNotable: true, isIndented: false,
                detail: RunReportDetail(
                    title: name, subtitle: "Tool call without a recorded result",
                    sections: [
                        .init(label: "ARGUMENTS", body: .code(detailValue(call, "tool_params") ?? "—")),
                        .init(label: "WHAT THIS MEANS", body: .prose("The call started but no result event landed — the run was torn down mid-call, or the result was lost at process death."))
                    ])
            ))
        }
        return rows
    }

    private static func mergedToolRow(call: SpanEvent?, result: SpanEvent, name: String, indented: Bool) -> RunReportRow {
        let success = detailValue(result, "is_success").map { $0 == "true" || $0 == "1" } ?? !(result.severity == .warning || result.severity == .error)
        let ms = result.durationMs ?? detailValue(result, "duration_ms").flatMap(Int.init) ?? 0
        let params = detailValue(call ?? result, "tool_params") ?? detailValue(result, "arguments_preview") ?? ""
        let output = detailValue(result, "tool_output") ?? detailValue(result, "output_preview") ?? ""

        var sections: [RunReportDetail.Section] = []
        if !params.isEmpty { sections.append(.init(label: "ARGUMENTS", body: .code(prettyJSON(params)))) }
        if !output.isEmpty { sections.append(.init(label: "RESULT", body: .code(output))) }
        sections.append(.init(label: "TIMING", body: .pairs(.init([
            ("Started", timeString(result.timestamp)),
            ("Duration", ms > 0 ? DurationFormat.format(ms: ms) : "not measured"),
            ("Outcome", success ? "succeeded" : "failed")
        ]))))

        return RunReportRow(
            id: result.id.map(String.init) ?? "tool-\(name)-\(result.timestamp.timeIntervalSince1970)",
            kind: .tool, timestamp: (call ?? result).timestamp,
            title: params.isEmpty ? name : "\(name) · \(String(params.prefix(80)))",
            meta: success ? "" : "failed",
            duration: ms > 0 ? DurationFormat.format(ms: ms) : "",
            isProblem: !success, isNotable: true, isIndented: indented,
            detail: RunReportDetail(title: name, subtitle: success ? "Tool · succeeded" : "Tool · failed", sections: sections)
        )
    }

    /// Whether an audit record belongs to this run. v8 rows carry the traceID and match
    /// EXACTLY; pre-v8 rows (traceID nil) fall back to the conversation + time-window
    /// heuristic they were recorded under.
    static func hitlBelongsToRun(_ r: HITLAuditRecord, trace: TraceRecord) -> Bool {
        if let rowTrace = r.traceID { return rowTrace == trace.traceID }
        let end = trace.endedAt ?? .distantFuture
        return r.raisedAt >= trace.startedAt && r.raisedAt <= end
    }

    private static func hitlRows(hitl: [HITLAuditRecord], trace: TraceRecord) -> [RunReportRow] {
        return hitl.filter { hitlBelongsToRun($0, trace: trace) }.map { r in
            let waited = r.resolvedAt.map { Int($0.timeIntervalSince(r.raisedAt) * 1000) }
            let outcome = r.outcome ?? "pending"
            return RunReportRow(
                id: "hitl-\(r.operationID)", kind: .approval, timestamp: r.raisedAt,
                title: r.title, meta: "you answered: \(outcome)",
                duration: waited.map { "waited \(DurationFormat.format(ms: $0))" } ?? "",
                isProblem: false, isNotable: true, isIndented: false,
                detail: RunReportDetail(
                    title: r.title, subtitle: "Approval · \(r.type)",
                    sections: [.init(label: "DECISION", body: .pairs(.init([
                        ("Outcome", outcome),
                        ("Asked at", timeString(r.raisedAt)),
                        ("You answered", r.resolvedAt.map(timeString) ?? "—"),
                        ("Run was paused", waited.map { DurationFormat.format(ms: $0) } ?? "—"),
                        ("Where", r.toolName ?? r.nodeName ?? r.interface)
                    ])))])
            )
        }
    }

    // MARK: - Grouping

    static func makeGroups(rows: [RunReportRow], spans: [Span], trace: TraceRecord) -> [RunReportGroup] {
        // Group boundaries come from step/node spans ordered by start time; rows fall
        // into the last boundary that started before them. Rows before the first
        // boundary (setup, the user message) form the "Before the run" group.
        struct Boundary { let id: String; let label: String; let tag: String; let start: Date; let durationMs: Int? }

        let stepSpans = spans
            .filter { $0.kind == .iteration || $0.kind == .workflowNode || $0.kind == .subtask }
            .sorted { $0.startedAt < $1.startedAt }

        // Which workflow node each span sits under, so an iteration group can name its owner.
        //
        // ⚠️ The boundary rule below is "last boundary that started at or before this row", and
        // an inner `iteration_1` span starts MICROSECONDS after its parent `node:Agent 3`. The
        // inner boundary therefore absorbs every row and the parent group is left empty, then
        // dropped by the `filter { !$0.rows.isEmpty }` at the end — so the report showed
        // "MLX - Bot NODE" (a bot node, no iteration span, keeps its rows) but NEVER named
        // "Agent 3", presenting its whole run under a bare "STEP 1" (observed 2026-08-23).
        // With two agent nodes that produced two indistinguishable "STEP 1" headers, because
        // `ReActAgentExecutor` restarts the iteration counter for each node. Carrying the owner
        // into the label preserves the identity the elision destroys.
        let nodeNameBySpanID: [String: String] = Dictionary(
            uniqueKeysWithValues: spans
                .filter { $0.kind == .workflowNode }
                .map { ($0.spanID, $0.name.hasPrefix("node:") ? String($0.name.dropFirst(5)) : $0.name) })
        let parentBySpanID = Dictionary(uniqueKeysWithValues: spans.map { ($0.spanID, $0.parentSpanID) })
        /// Nearest enclosing workflow node, walking up the chain — an iteration is not always a
        /// DIRECT child of its node span, so matching only the immediate parent would miss it.
        func owningNodeName(of span: Span) -> String? {
            var hops = 0
            var current = span.parentSpanID
            while let id = current, hops < 16 {          // bounded: a cycle must not hang the report
                if let name = nodeNameBySpanID[id] { return name }
                current = parentBySpanID[id] ?? nil
                hops += 1
            }
            return nil
        }

        let boundaries: [Boundary] = stepSpans.map { s in
            let label: String
            let tag: String
            switch s.kind {
            case .iteration:
                let n = s.name.split(separator: "_").last.map(String.init) ?? s.name
                // "TURN", not "STEP" — see makeHeaderFacts: "step" is the node level.
                label = owningNodeName(of: s).map { "\($0) · TURN \(n)" } ?? "TURN \(n)"
                tag = ""
            case .workflowNode:
                label = s.name.hasPrefix("node:") ? String(s.name.dropFirst(5)) : s.name
                tag = "NODE"
            case .subtask:
                label = s.name.uppercased(); tag = "SUBTASK"
            default:
                label = s.name; tag = ""
            }
            return Boundary(id: s.spanID, label: label, tag: tag, start: s.startedAt, durationMs: s.durationMs)
        }

        var groups: [RunReportGroup] = [
            RunReportGroup(id: "pre", label: "BEFORE THE RUN", kindTag: "", durationLabel: "", rows: [])
        ]
        for b in boundaries {
            groups.append(RunReportGroup(
                id: b.id, label: b.label, kindTag: b.tag,
                durationLabel: b.durationMs.map { DurationFormat.format(ms: $0) } ?? "", rows: []))
        }

        for row in rows {
            // Find the last boundary that started at or before this row.
            var idx = 0
            for (i, b) in boundaries.enumerated() where b.start <= row.timestamp { idx = i + 1 }
            groups[idx].rows.append(row)
        }
        return groups.filter { !$0.rows.isEmpty }
    }

    // MARK: - Lanes

    /// Tools + waiting-for-you are measured; model time joins when llmCall spans exist
    /// (Phase 2 instrumentation); the remainder is a LABELLED unattributed segment.
    static func makeLanes(trace: TraceRecord, spans: [Span], events: [SpanEvent], hitl: [HITLAuditRecord],
                          currentBuildNumber: String? = nil) -> ([RunReportLaneSegment], String) {
        guard let total = trace.durationMs, total > 0 else { return ([], "") }

        let toolMs = events
            .filter { $0.eventType == .toolResult }
            .compactMap { $0.durationMs ?? detailValue($0, "duration_ms").flatMap(Int.init) }
            .reduce(0, +)

        let waitMs = hitlWaitMs(hitl: hitl, trace: trace)

        let modelMs = spans.compactMap(declaredModelMs).reduce(0, +)

        // Input lane (Phase 3): the `input_assembly` metrics bracket pre-flight work —
        // BOS's attachment/RAG/knowledge assembly plus each iteration's context build.
        let inputMs = events
            .filter { $0.eventType == .metric && detailValue($0, "key") == "input_assembly" }
            .compactMap { detailValue($0, "value_ms").flatMap(Int.init) }
            .reduce(0, +)

        var segments: [RunReportLaneSegment] = []
        func add(_ category: RunReportLaneSegment.Category, _ label: String, _ ms: Int) {
            guard ms > 0 else { return }
            segments.append(RunReportLaneSegment(
                id: label, category: category, label: label,
                fraction: min(1.0, Double(ms) / Double(total)), durationMs: ms))
        }
        add(.input, "Input", inputMs)
        add(.model, "Model", modelMs)
        add(.tools, "Tools", toolMs)
        add(.waiting, "Waiting for you", waitMs)

        let attributed = min(total, inputMs + modelMs + toolMs + waitMs)
        let remainder = total - attributed
        if remainder > 0 {
            add(.unattributed, "Unattributed", remainder)
        }

        let caveat: String
        if modelMs == 0 {
            caveat = "Model time isn't measured separately on this run — it sits inside \"unattributed\"."
        } else if Double(remainder) / Double(total) > 0.4 {
            caveat = unattributedCaveat(trace: trace, currentBuildNumber: currentBuildNumber)
        } else {
            caveat = ""
        }
        return (segments, caveat)
    }

    /// The model time a span's emitter DECLARED for its own call, in milliseconds.
    ///
    /// ⚠️ Deliberately NOT the span's wall-clock. `chat_call` (bot path) brackets message
    /// assembly and the whole retry loop, and `imageGen` brackets a feasibility check —
    /// counting either as model time over-reads. The previous rule dodged that by matching the
    /// span NAME prefix `"llm:"`, which meant only `APISpyModel` (the ReAct/agent path) ever
    /// counted: the bot, classifier and imageGen paths dropped their model time into
    /// "Unattributed" silently. Observed on-device 2026-08-23 — a bot node's 11,977ms model
    /// call rendered in the stream while the Model lane read 584ms and Unattributed read 13.4s
    /// of a 14.0s run.
    ///
    /// Keying off the DECLARED measurement means a path opts in by MEASURING rather than by
    /// matching a string, so a new emitter cannot be forgotten by failing to guess a name — it
    /// either states its own narrow duration or it honestly contributes nothing.
    static func declaredModelMs(_ span: Span) -> Int? {
        guard span.kind == .llmCall,
              let json = span.metadataJSON,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let s = obj["duration_ms"] as? String { return Int(s) }
        return obj["duration_ms"] as? Int
    }

    /// Why a large share of the run carries no lane.
    ///
    /// ⚠️ This used to assert ONE hardcoded cause — "older runs predate parts of the
    /// instrumentation" — derived from a single input, the remainder fraction. A run recorded
    /// minutes earlier on the current build was therefore told it was old (observed on-device
    /// 2026-08-23). That is precisely the invented explanation this file's contract forbids: an
    /// unmeasured lane is a LABELLED GAP, never a guess.
    ///
    /// `TraceRecorder.beginTrace` stamps the writing build on every trace, so the one
    /// distinction that CAN be drawn honestly is drawn here — and where it cannot be drawn, the
    /// sentence says so rather than picking the flattering answer. `currentBuildNumber` is
    /// passed in rather than read from `Bundle` to keep this projection pure and testable.
    static func unattributedCaveat(trace: TraceRecord, currentBuildNumber: String?) -> String {
        let lead = "A large share of this run isn't attributed to a lane"
        guard let recorded = trace.buildNumber else {
            return "\(lead) — and this run predates build stamping, so we can't tell whether an older build recorded it."
        }
        if let currentBuildNumber, recorded != currentBuildNumber {
            let version = trace.appVersion.map { "\($0) (\(recorded))" } ?? "build \(recorded)"
            return "\(lead) — it was recorded by an earlier build (\(version)), which measured less than this one does."
        }
        return "\(lead) — this build recorded it, so the gap is work that isn't instrumented yet, not an old run."
    }

    static func hitlWaitMs(hitl: [HITLAuditRecord], trace: TraceRecord) -> Int {
        hitl
            .filter { hitlBelongsToRun($0, trace: trace) }
            .compactMap { r in r.resolvedAt.map { Int($0.timeIntervalSince(r.raisedAt) * 1000) } }
            .reduce(0, +)
    }

    // MARK: - Setup detail

    static func makeSetupDetail(trace: TraceRecord, input: RunReportInput) -> RunReportDetail {
        var sections: [RunReportDetail.Section] = []
        var pairs: [(String, String)] = [
            ("Profile", "\(trace.profileName) (\(trace.profileType))")
        ]
        if let m = trace.modelName { pairs.append(("Model", m)) }
        if let p = trace.provider { pairs.append(("Provider", p)) }
        if let c = input.configToolCount { pairs.append(("Tools available", "\(c)")) }
        if let v = trace.appVersion { pairs.append(("App build", "\(v) (\(trace.buildNumber ?? "?"))")) }
        sections.append(.init(label: "RUN CONFIGURATION", body: .pairs(.init(pairs))))
        if let json = input.configJSON {
            sections.append(.init(label: "FULL SNAPSHOT", body: .code(prettyJSON(json))))
        } else {
            sections.append(.init(label: "SNAPSHOT", body: .prose("No configuration snapshot was captured for this run (headless and scheduled runs don't record one yet).")))
        }
        return RunReportDetail(
            title: "How this run was set up",
            subtitle: "Captured once, at the moment the run started",
            sections: sections)
    }

    // MARK: - Search (Phase 4)

    /// Whether a row matches the search box. Case-insensitive, and DEEP: it searches
    /// the inspector payload too (tool args, results, previews, pair values), because
    /// "which call touched README.md" is exactly the question a search box is for —
    /// the visible title alone often carries only a truncated preview.
    static func rowMatches(_ row: RunReportRow, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }

        func hit(_ s: String) -> Bool { s.range(of: q, options: .caseInsensitive) != nil }

        if hit(row.title) || hit(row.meta) || hit(row.kind.rawValue) { return true }
        if hit(row.detail.title) || hit(row.detail.subtitle) { return true }
        for section in row.detail.sections {
            switch section.body {
            case .prose(let text), .code(let text):
                if hit(text) { return true }
            case .pairs(let list):
                if list.pairs.contains(where: { hit($0.key) || hit($0.value) }) { return true }
            }
        }
        return false
    }

    // MARK: - Small helpers

    /// Human names for the prompt builder's layer sources (the raw ids stay in `meta`
    /// and in detailJSON so a log line and a report row can be joined by eye).
    static func contextSourceDisplayName(_ source: String) -> String {
        switch source {
        case "task": return "Your task"
        case "clarification": return "Your clarification"
        case "instructions": return "Profile instructions"
        case "environment": return "Environment facts"
        case "knowledge_base": return "Knowledge base"
        case "tool_guidance": return "Tool guidance (MCP)"
        case "retrieval": return "Retrieved context"
        case "episodic": return "Conversation memory"
        case "user_profile": return "Personal profile"
        case "attachments": return "Attached files"
        default: return source.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func compactChars(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fK chars", Double(n) / 1000) : "\(n) chars"
    }

    static func detailValue(_ e: SpanEvent, _ key: String) -> String? {
        guard let json = e.detailJSON, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let s = obj[key] as? String { return s }
        if let n = obj[key] as? NSNumber { return n.stringValue }
        if let b = obj[key] as? Bool { return b ? "true" : "false" }
        return nil
    }

    /// Is this event a workflow-node SKIP?
    ///
    /// ⚠️ Deliberately does NOT trust the indexed `errorCategory` column alone. `TraceRecorder`
    /// writes that column only when `recordV2` is true — developer mode on, OR the user has left
    /// "diagnostics recording" enabled — while trace/span/EVENT recording is not gated on that
    /// preference at all. So a user who opts out of diagnostics still gets a fully populated Run
    /// Report in which every skip arrives with `errorCategory == nil`, falls past the skip branch
    /// into the generic ISSUE arm, and is painted RED as a problem: invariant 73 ("a skip is an
    /// instruction, never a failure") was being enforced in the display layer while depending on a
    /// field the persistence layer treats as optional telemetry.
    ///
    /// The fallback costs nothing: `TraceRecorder` already writes `detail["category"]`
    /// UNCONDITIONALLY, one line above the gated column. Preferred over widening the gate — that
    /// gate is a deliberate privacy posture, and loosening it for one category would be the wrong
    /// seam.
    static func isSkipEvent(_ e: SpanEvent) -> Bool {
        if e.errorCategory == .wfNodeSkipped { return true }
        return detailValue(e, "category") == AgentErrorCategory.wfNodeSkipped.rawValue
    }

    /// Reads a key from the event's SANITIZED CONTEXT BAG.
    ///
    /// ⚠️ Separate from `detailValue`, which only sees TOP-LEVEL keys. `TraceRecorder` nests a
    /// classified error's context under `detail["context"]`, so a producer that adds a context key
    /// and a consumer that reads it with `detailValue` silently never meet — the fix compiles,
    /// ships, and does nothing.
    static func contextValue(_ e: SpanEvent, _ key: String) -> String? {
        guard let json = e.detailJSON, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ctx = obj["context"] as? [String: Any] else { return nil }
        if let s = ctx[key] as? String { return s }
        if let n = ctx[key] as? NSNumber { return n.stringValue }
        if let b = ctx[key] as? Bool { return b ? "true" : "false" }
        return nil
    }

    /// What actually happened to a skipped node, per reason.
    ///
    /// ⚠️ The old sentence was one hardcoded string ending "nodes downstream received its input
    /// unchanged" — TRUE only for `.byUser`, which is the single reason that keeps the default
    /// edge below it live. For every cascade reason the subtree below the node is dead, so the
    /// report asserted the opposite of what the engine did. It also hedged "by you, or by routing
    /// that never chose its branch", which is the report declining to say which — even though the
    /// producer knows.
    static func skipExplanation(reason: String?, ranBeforeSkip: Bool) -> String {
        switch reason {
        case "byUser":
            return ranBeforeSkip
                ? "You skipped this node while it was running. The work it had already done was discarded, and the node below it received this node's input unchanged."
                : "You skipped this node before it started. The node below it received this node's input unchanged."
        case "notChosen":
            return "The workflow branched a different way, so this node never ran. Nothing failed."
        case "errorPortNotTaken":
            return "This node sits on an error path that wasn't taken, so it never ran. Nothing failed."
        case "upstreamFailed":
            return "A node upstream of this one failed, so this node never ran."
        case "upstreamSkipped":
            return "A node upstream of this one was skipped, so this node never ran."
        case "upstreamCancelled":
            return "The run was stopped upstream, so this node never ran."
        case "notReached":
            return "The run ended before it reached this node."
        default:
            // Unknown or absent (records written before the producer carried the reason). Say only
            // what is true of EVERY skip rather than picking the byUser-shaped claim as a default.
            return "This node did not run, and nothing failed. Its own row shows what happened around it."
        }
    }

    static func prettyJSON(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: pretty, encoding: .utf8) else { return json }
        return s
    }

    static func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: date)
    }
}
