// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  DanglingToolRowCloser.swift
//  Devgentic
//
//  [TL-1] One implementation of "close every tool row still claiming to execute".
//
//  A row persisted with `isExecuting == true` renders an animating ProgressView forever
//  (`ActionDetailView.statusIcon`), carries no output and no failure reason, and is permanently
//  non-disclosable (`isDisclosable` requires `!isExecuting`). It is produced by any path that
//  ends a run without the normal per-tool completion event: user Stop, a provider throw, a
//  force-quit.
//
//  This lived as a private walk inside `ChatMessage.closeDanglingToolRows`, which meant the
//  workflow side — whose node timelines hold the same `TimelineEvent` values and are rendered by
//  the same `AgentTimelineView` — had no repair at all. Shared here so the two cannot drift.
//

import Foundation

enum DanglingToolRowCloser {

    /// A row this closer settled, identified well enough for a caller to react to WHICH tool
    /// was abandoned rather than merely how many were.
    ///
    /// Exists for [CF-9]: a live-agent-write tab is opened from the `.toolCall` event and is
    /// settled only by an `AgentLiveWriteEvent.completed`, which is posted from `.toolSucceeded`
    /// / `.toolFailed`. A Stop or a provider throw yields NEITHER, so the tab stays `.active`
    /// forever. `close` already runs on every one of those paths and already knows exactly which
    /// rows were abandoned — reporting them lets the caller post the missing completion instead
    /// of duplicating the traversal.
    struct ClosedRow: Sendable {
        let name: String
        let params: String
    }

    /// Closes every still-executing tool row in `events`, including rows nested inside
    /// capability cards, and returns how many were closed so the caller can log the repair.
    ///
    /// Rows are CLOSED (settled with a synthetic output), not removed — removal is
    /// `sanitizeCapabilityCardsForResume`'s job on the resume path, where the run is about to
    /// stream fresh events. Here the run is over and the row is the record of what happened.
    @discardableResult
    static func close(_ events: inout [TimelineEvent], outcome: ExecutionOutcome?) -> Int {
        closeReporting(&events, outcome: outcome).count
    }

    /// `close`, returning the rows it settled. Same traversal and same mutation — the count-only
    /// form delegates here, so the two can never disagree about coverage.
    ///
    /// ⚠️ [CF-51] A CANCELLED close leaves `isSuccess` nil; every other outcome writes `false`.
    /// A user Stop is not a tool failure: the tool never reported, and the run ended because the
    /// user said so. Writing `false` made `ActionDetailView.statusIcon` paint a red "CANCELLED"
    /// capsule and made `AgentTimelineView.summarize` count the row, so a Stop mid-tool read
    /// "Stopped after 3 steps (3 tools · 1 failed)" — a failure claim about a run in which
    /// nothing failed. That is the same reasoning `closeForUserSkip` and
    /// `markInterruptedByProcessDeath` below were already built on; this is the third and last
    /// user-initiated stop to adopt it. `failureCategory` still records `.cancelled` — the
    /// structured cause is worth keeping even when nothing renders it as a failure — and the
    /// synthetic output still says what happened, so the row stays disclosable.
    @discardableResult
    static func closeReporting(_ events: inout [TimelineEvent], outcome: ExecutionOutcome?) -> [ClosedRow] {
        walk(&events) { data in
            data.isExecuting = false
            if outcome == .cancelled {
                data.failureCategory = .cancelled
            } else {
                data.isSuccess = false
            }
            if data.output == nil {
                // Persisted tool output — deliberately unlocalized (category-c, must stay stable).
                data.output = outcome == .cancelled
                    ? "Cancelled before the tool finished."
                    : "Interrupted before the tool finished."
            }
        }
    }

    /// The PROCESS-DEATH repair (CF-44): stops the spinner on a row persisted mid-tool by
    /// `flushInFlight`, and changes NOTHING else.
    ///
    /// ⚠️ `output` is deliberately left nil, and that is the whole design. `isExecuting || output
    /// == nil` is how the resume engine identifies the tool a run died inside —
    /// `TimelineTurnReconstructor.reconstruct` uses it to pick `dangling`
    /// (TimelineTurnReconstructor.swift:82), and `resumeRun` uses the same expression to strip the
    /// stale card (MessagingCoordinator.swift:529-532). Writing a synthetic output would make the
    /// row look OBSERVED to both: a streaming resume would stop dropping it and would instead
    /// replay it to the model as a completed step whose result was "Interrupted before the tool
    /// finished.", and the stale card would survive into the resumed run. Turning the spinner off
    /// is the entire user-visible defect; asserting an outcome we never saw is not part of it.
    ///
    /// `isSuccess` stays nil for the same reason — the tool's fate is genuinely unknown, so the
    /// ⚠️ As of [tc-10] `statusIcon` DOES paint this row — a neutral `circle.dotted` in
    /// `tertiaryText` ("Outcome unknown — the run ended first"), which states ignorance rather
    /// than fabricating a verdict. `summarize` still counts nothing for it. The claim that it
    /// "renders no badge" was true when this was written and is no longer.
    /// `AgentTimelineView.summarize` does not count it toward "N failed".
    @discardableResult
    static func markInterruptedByProcessDeath(_ events: inout [TimelineEvent]) -> Int {
        walk(&events) { data in
            data.isExecuting = false
        }.count
    }

    /// The USER-SKIP close (Phase B increment 5): the node was deliberately skipped mid-flight,
    /// so its abandoned tool rows are neither failures nor cancellations — `isSuccess` stays nil
    /// (`summarize` counts nothing failed) and the output says what actually happened.
    /// ⚠️ As of [tc-10] `statusIcon` DOES paint these rows, with a neutral `circle.dotted` in
    /// `tertiaryText` — "the run ended before this reported", not a failure. The claim that it
    /// "renders no badge" was true when this was written and is no longer. Without this, `WorkflowRunRecord.freeze`'s unconditional `.failed`
    /// close painted a RED "Interrupted before the tool finished." row inside a node whose row
    /// says "Skipped by you" — a failure claim about a run in which nothing failed.
    @discardableResult
    static func closeForUserSkip(_ events: inout [TimelineEvent]) -> Int {
        closeForUserSkipReporting(&events).count
    }

    /// `closeForUserSkip`, returning the rows it settled.
    ///
    /// ⚠️ This exists because the count-only form's old comment — "a skipped workflow node has no
    /// live tab" — was FALSE. `AgentLiveWriteEvent.began` is posted from `.toolCall`
    /// unconditionally, BEFORE the row is routed by `sourceNodeID`, so a workflow node's
    /// `write_file` opens a live Code Viewer tab exactly like a chat-path write. Meanwhile CF-9's
    /// terminal (`finalizeMessage` → `closeDanglingToolRowsReporting`) walks only
    /// `message.timelineEvents`, and a node's rows live in `WorkflowExecutionState.nodeTimelines`
    /// — a separate array it never sees. So skipping or stopping a node mid-write left its tab
    /// `.active` for the rest of the session: orange "Agent is writing this file" banner up,
    /// minimized pill pulsing, and `lastSavedDisk` never set, so ⌘S was refused as on-disk drift
    /// on a claim that is false. The caller needs the ROWS to post the completions itself.
    @discardableResult
    static func closeForUserSkipReporting(_ events: inout [TimelineEvent]) -> [ClosedRow] {
        walk(&events) { data in
            data.isExecuting = false
            if data.output == nil {
                // Persisted tool output — deliberately unlocalized (category-c, must stay stable).
                data.output = "Interrupted — the node was skipped by you."
            }
        }
    }

    /// The shared traversal: every still-executing tool row, including rows nested inside
    /// capability cards. Split from the two close bodies so they cannot drift in COVERAGE —
    /// a row shape one close reaches and the other misses would be this file's founding defect
    /// reborn one level down.
    private static func walk(
        _ events: inout [TimelineEvent],
        applying mutate: (inout ToolExecutionData) -> Void
    ) -> [ClosedRow] {
        var closed: [ClosedRow] = []

        func close(_ data: inout ToolExecutionData) {
            mutate(&data)
            // Captured AFTER the mutation, but `name`/`params` are not mutated by either close
            // body — they identify the abandoned call, which is exactly what CF-9's caller needs.
            closed.append(ClosedRow(name: data.name, params: data.params))
        }

        /// One step's / attempt's sub-timeline: its own tool rows, plus those inside a plan
        /// card nested one level deeper (stacked Reflexion(Planning(…))). Deliberately not
        /// mutually recursive — Swift local functions cannot reference one another before
        /// declaration, and two levels is the deepest shape `CapabilityCardRouter` can build.
        func closeNested(_ events: inout [TimelineEvent]) {
            for i in events.indices {
                switch events[i] {
                case .toolExecution(var data) where data.isExecuting:
                    close(&data)
                    events[i] = .toolExecution(data)
                case .planExecution(var plan):
                    for s in plan.steps.indices {
                        for e in plan.steps[s].events.indices {
                            guard case .toolExecution(var data) = plan.steps[s].events[e],
                                  data.isExecuting else { continue }
                            close(&data)
                            plan.steps[s].events[e] = .toolExecution(data)
                        }
                    }
                    events[i] = .planExecution(plan)
                default:
                    break
                }
            }
        }

        for i in events.indices {
            switch events[i] {
            case .toolExecution(var data) where data.isExecuting:
                close(&data)
                events[i] = .toolExecution(data)
            case .planExecution(var plan):
                for s in plan.steps.indices { closeNested(&plan.steps[s].events) }
                events[i] = .planExecution(plan)
            case .reflectionRun(var run):
                for a in run.attempts.indices { closeNested(&run.attempts[a].events) }
                events[i] = .reflectionRun(run)
            default:
                break
            }
        }
        return closed
    }
}
