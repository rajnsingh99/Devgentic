// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbRunReportLoader.swift
//  Devgentic
//
//  [Phase 6 · F1] The impure half of spoken run narration: fetches a finished run's trace and
//  builds its projection, so `OrbRunNarration` can stay a pure text transform.
//
//  ⚠️ MIRRORS `RunReportView.loadData` DELIBERATELY. The report panel and the spoken answer must
//  never disagree about what happened in a run — "it says two failures on screen and told me it
//  went fine" destroys trust in both. Any change to the fetch there belongs here too.
//
//  Three details in that sequence are load-bearing and easy to drop:
//   • `flushNow()` FIRST. The recorder's periodic loop leaves up to 1s / 50 events unwritten at
//     any moment, and a run that just ended is exactly the case where the tail — including the
//     error the verdict is about — is still in the buffer.
//   • `CFBundleVersion` is read on THIS side. The projection is pure by contract (no Bundle, no
//     clocks); passing it in is what lets the report tell "recorded by an older build" apart from
//     "this build doesn't measure that path".
//   • The store reads run on a detached task. They are synchronous SQLite calls, and the orb is
//     mid-conversation on the main actor.
//

import Foundation

@MainActor
enum OrbRunReportLoader {

    private static let logger = DGLogger(category: "OrbRunReport")

    /// Builds the projection for `message`'s run, or nil when the message never had a run.
    ///
    /// Never throws: every failure the caller could hit is already modelled as a
    /// `RunReportUnavailability`, and `OrbRunNarration` turns each one into its own sentence.
    /// A thrown error here would just become silence at the end of a turn.
    static func projection(for message: ChatMessage) async -> RunReportProjection {
        let traceID = message.traceID
        let conversationID = message.conversationId.uuidString
        let answerPreview = message.currentAgentContent?.textContent
        let currentBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String

        // Drain the tail of the run before reading it back.
        await TraceRecorder.shared.flushNow()

        let input: RunReportInput = await Task.detached(priority: .userInitiated) {
            guard let store = TraceStore.shared else {
                return RunReportInput(
                    trace: nil, spans: [], events: [], hitl: [], configJSON: nil,
                    configToolCount: nil, answerPreview: answerPreview, userQueryPreview: nil,
                    traceIDOnMessage: traceID, storeAvailable: false,
                    currentBuildNumber: currentBuild)
            }
            guard let traceID else {
                return RunReportInput(
                    trace: nil, spans: [], events: [], hitl: [], configJSON: nil,
                    configToolCount: nil, answerPreview: answerPreview, userQueryPreview: nil,
                    traceIDOnMessage: nil, storeAvailable: true,
                    currentBuildNumber: currentBuild)
            }
            // ⚠️ A throwing store used to be indistinguishable from a run that genuinely had no
            // spans — and the projection reports that as an unavailability the narrator then
            // speaks as settled fact ("that run wasn't recorded"). Each failure is now named.
            func report(_ what: String, _ error: Error) {
                Task { @MainActor in
                    logger.error("[ORB_RUNREPORT] Could not read \(what) for trace \(traceID.prefix(8)): \(error.localizedDescription). CONSEQUENCE: the spoken summary will describe this run as unrecorded or incomplete, which is a STORE failure and not the truth about the run.")
                }
            }
            var trace: TraceRecord?
            var spans: [Span] = []
            var events: [SpanEvent] = []
            var hitl: [HITLAuditRecord] = []
            do { trace = try store.fetchTrace(traceID: traceID) } catch { report("the trace row", error) }
            do { spans = try store.fetchSpans(forTraceID: traceID) } catch { report("spans", error) }
            do { events = try store.fetchEvents(forTraceID: traceID) } catch { report("events", error) }
            do { hitl = try store.fetchHITLAudit(forConversationID: conversationID) } catch { report("the approval audit", error) }
            // ⚠️ The config snapshot is not optional garnish: `RunReportProjection.setupRows` keys
            // off `configJSON`/`configToolCount`, so hardcoding them nil made Orb build a
            // DIFFERENT projection than the panel for the identical run — "no configuration
            // snapshot for this run" and a missing tool count. This file's header promises the two
            // can never disagree.
            var config: TraceConfigRow?
            do { config = try store.fetchConfigSnapshot(traceID: traceID) } catch { report("the config snapshot", error) }

            return RunReportInput(
                trace: trace,
                spans: spans,
                events: events,
                hitl: hitl,
                configJSON: config?.snapshotJSON,
                configToolCount: config?.toolsCount,
                answerPreview: answerPreview, userQueryPreview: nil,
                traceIDOnMessage: traceID, storeAvailable: true,
                currentBuildNumber: currentBuild)
        }.value

        return RunReportProjection.build(input)
    }

    /// The file-level changes a run actually made.
    ///
    /// ⚠️ NOT from the projection. Report tool rows are built with `call: nil` because
    /// `TraceRecorder.emitToolCall` has no production callers, so they carry no arguments — and a
    /// successful tool's recorded result is the literal string "success". The message timeline is
    /// the only place the real change survives.
    static func changes(in message: ChatMessage) -> (effects: [ActionEffect], writeToolNames: [String]) {
        var effects: [ActionEffect] = []
        var writeToolNames: [String] = []
        // Flattened: Plan & Execute and Reflexion nest their per-step events, and a tool that ran
        // inside a sub-step changed the user's files just as much as a top-level one.
        for event in message.flattenedTimelineEvents {
            guard case .toolExecution(let data) = event else { continue }
            if let effect = ActionEffect.from(toolExecution: data) {
                effects.append(effect)
            } else if TimelineFileViewerAction.resolve(data: data, missingBaseline: .recordFragment)?.isWrite == true {
                // ⚠️ ASK WHETHER IT WROTE, NOT WHAT TIER IT IS. This used to test
                // `HITLRiskTier.classify(toolName:) != .safe` — but that `.safe` list names only
                // six tools out of the catalogue's seventy-two, and its default is `.moderate`.
                // Every other read-only tool (`code_search_text`, `find_definition`,
                // `diff_files`, every MCP tool …) therefore counted as a write, so a purely
                // read-only run answered "I ran code search text, but I can't tell what changed" —
                // asserting a change that never happened, which is the one thing this narration
                // must never do.
                writeToolNames.append(data.name)
            }
        }
        return (effects, writeToolNames)
    }
}
