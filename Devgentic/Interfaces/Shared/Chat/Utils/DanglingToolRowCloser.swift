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

    /// Closes every still-executing tool row in `events`, including rows nested inside
    /// capability cards, and returns how many were closed so the caller can log the repair.
    ///
    /// Rows are CLOSED (settled with a synthetic output), not removed — removal is
    /// `sanitizeCapabilityCardsForResume`'s job on the resume path, where the run is about to
    /// stream fresh events. Here the run is over and the row is the record of what happened.
    @discardableResult
    static func close(_ events: inout [TimelineEvent], outcome: ExecutionOutcome?) -> Int {
        walk(&events) { data in
            data.isExecuting = false
            data.isSuccess = false
            if outcome == .cancelled {
                data.failureCategory = .cancelled
            }
            if data.output == nil {
                // Persisted tool output — deliberately unlocalized (category-c, must stay stable).
                data.output = outcome == .cancelled
                    ? "Cancelled before the tool finished."
                    : "Interrupted before the tool finished."
            }
        }
    }

    /// The USER-SKIP close (Phase B increment 5): the node was deliberately skipped mid-flight,
    /// so its abandoned tool rows are neither failures nor cancellations — `isSuccess` stays nil
    /// (statusIcon renders no badge, `summarize` counts nothing failed) and the output says what
    /// actually happened. Without this, `WorkflowRunRecord.freeze`'s unconditional `.failed`
    /// close painted a RED "Interrupted before the tool finished." row inside a node whose row
    /// says "Skipped by you" — a failure claim about a run in which nothing failed.
    @discardableResult
    static func closeForUserSkip(_ events: inout [TimelineEvent]) -> Int {
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
    ) -> Int {
        var closed = 0

        func close(_ data: inout ToolExecutionData) {
            mutate(&data)
            closed += 1
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
