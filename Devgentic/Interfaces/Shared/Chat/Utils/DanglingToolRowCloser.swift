// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DanglingToolRowCloser.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Closes every tool row still claiming to execute; one shared implementation for chat and workflow timelines.
/// Such a row spins forever and is non-disclosable; Stop, a provider throw or a force-quit can leave one behind.
enum DanglingToolRowCloser {

    /// A row this closer settled, identified well enough for a caller to react to which tool was abandoned.
    /// Lets a caller post the missing `AgentLiveWriteEvent.completed`, which a Stop or provider throw never produces.
    struct ClosedRow: Sendable {
        let name: String
        let params: String
    }

    /// Closes every still-executing tool row in `events`, including rows nested inside capability cards; returns how many.
    /// Rows are closed with a synthetic output, not removed: removal belongs to `sanitizeCapabilityCardsForResume`.
    @discardableResult
    static func close(_ events: inout [TimelineEvent], outcome: ExecutionOutcome?) -> Int {
        closeReporting(&events, outcome: outcome).count
    }

    // Why: a cancelled close leaves `isSuccess` nil: writing `false` made a user Stop read as a tool failure.
    /// `close`, returning the rows it settled; the count-only form delegates here so coverage cannot diverge.
    /// `failureCategory` still records `.cancelled`; the synthetic output says what happened, so the row stays disclosable.
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
                // Persisted tool output: deliberately unlocalized so it stays stable.
                data.output = outcome == .cancelled
                    ? "Cancelled before the tool finished."
                    : "Interrupted before the tool finished."
            }
        }
    }

    // Why: `output` stays nil so the resume engine can still find the tool the run died inside; a synthetic one looks observed.
    /// Repairs a row persisted mid-tool by `flushInFlight` after process death: stops the spinner and changes nothing else.
    /// `isSuccess` stays nil (outcome unknown); `statusIcon` paints a neutral `circle.dotted` and no failure is counted.
    @discardableResult
    static func markInterruptedByProcessDeath(_ events: inout [TimelineEvent]) -> Int {
        walk(&events) { data in
            data.isExecuting = false
        }.count
    }

    // Why: closing as failed would paint a red failure inside a node whose row says it was skipped by the user.
    /// The user-skip close: the node was deliberately skipped mid-flight, so its abandoned tool rows are neither failures
    /// nor cancellations. `isSuccess` stays nil and the output says what happened; `statusIcon` paints `circle.dotted`.
    @discardableResult
    static func closeForUserSkip(_ events: inout [TimelineEvent]) -> Int {
        closeForUserSkipReporting(&events).count
    }

    // Why: node timelines live outside `message.timelineEvents`, so the chat-path terminal never sees these rows.
    /// `closeForUserSkip`, returning the rows it settled.
    /// Skipping or stopping a workflow node mid-write can leave its live Code Viewer tab `.active`; callers post completions.
    @discardableResult
    static func closeForUserSkipReporting(_ events: inout [TimelineEvent]) -> [ClosedRow] {
        walk(&events) { data in
            data.isExecuting = false
            if data.output == nil {
                // Persisted tool output: deliberately unlocalized so it stays stable.
                data.output = "Interrupted — the node was skipped by you."
            }
        }
    }

    /// The shared traversal: every still-executing tool row, including rows nested inside capability cards.
    /// Shared by both close bodies so their coverage cannot drift.
    private static func walk(
        _ events: inout [TimelineEvent],
        applying mutate: (inout ToolExecutionData) -> Void
    ) -> [ClosedRow] {
        var closed: [ClosedRow] = []

        func close(_ data: inout ToolExecutionData) {
            mutate(&data)
            // Captured after the mutation; `name` and `params` are not mutated by either close body and identify the abandoned call.
            closed.append(ClosedRow(name: data.name, params: data.params))
        }

        /// One step's or attempt's sub-timeline: its own tool rows plus those in a plan card nested one level deeper.
        /// Not mutually recursive: local functions cannot forward-reference, and `CapabilityCardRouter` builds two levels.
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
