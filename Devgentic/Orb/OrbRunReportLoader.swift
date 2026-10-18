// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbRunReportLoader.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// The impure half of spoken run narration: fetches a finished run's trace and builds its projection, leaving
/// `OrbRunNarration` a pure text transform. Mirrors `RunReportView.loadData` so the report panel and the spoken
/// answer never disagree about a run.
@MainActor
enum OrbRunReportLoader {

    private static let logger = DGLogger(category: "OrbRunReport")

    /// Builds the projection for `message`'s run, or nil when the message never had a run. Never throws: every failure
    /// is modelled as a `RunReportUnavailability` that the narration turns into its own sentence.
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
            // Name each store failure: a throwing store would otherwise look like a run with no spans, which the narrator
            // speaks as fact.
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
            // Fetch the config snapshot: `RunReportProjection.setupRows` keys off it, and omitting it would make Orb's
            // projection differ from the panel's.
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

    /// The file-level changes a run actually made, read from the message timeline. Not from the projection: its tool
    /// rows carry no arguments and a successful result is the literal "success".
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
                // Ask whether the tool wrote, not its risk tier: the `.safe` tier is short and defaults to `.moderate`, so
                // read-only tools would be reported as changes.
                writeToolNames.append(data.name)
            }
        }
        return (effects, writeToolNames)
    }
}
