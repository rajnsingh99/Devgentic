//
//  TimelineClusterFixTests.swift
//  DevgenticTests
//
//  Regression cover for the timeline/capability-card fixes of 2026-08-10
//  (Chat_Production_Readiness.md rows CH25, CH26, CH50; audit rows AD5/AD6 + timeline-2).
//

import XCTest
@testable import devgentic

@MainActor
final class TimelineClusterFixTests: XCTestCase {

    private func makeMessage() -> ChatMessage {
        ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText(""))
    }

    private func executingRow(_ name: String = "write_file") -> TimelineEvent {
        .toolExecution(ToolExecutionData(id: UUID(), name: name, params: "{}",
                                         output: nil, isSuccess: nil, isExecuting: true))
    }

    private func isExecuting(_ event: TimelineEvent) -> Bool {
        if case .toolExecution(let d) = event { return d.isExecuting }
        return false
    }

    // MARK: - CH25

    /// With Plan & Execute on — most agent runs — tool rows live NESTED inside a plan card's
    /// step, not in the top-level array. `closeDanglingToolRows` only walked the top level, so
    /// a stop mid-tool closed nothing, logged nothing (the caller logs only when the count is
    /// > 0), and persisted a row that renders an animating spinner forever.
    func testDanglingRowInsidePlanStepIsClosed() {
        let message = makeMessage()
        var plan = PlanRunData(phase: .executing, steps: [
            PlanStepData(id: "step_1", title: "Write the file", status: .running)
        ])
        plan.steps[0].events = [executingRow()]
        message.timelineEvents = [.planExecution(plan)]

        let closed = message.closeDanglingToolRows(outcome: .cancelled)

        XCTAssertEqual(closed, 1, "the nested row must be counted, so the finalize log fires")
        guard case .planExecution(let after) = message.timelineEvents[0],
              case .toolExecution(let row) = after.steps[0].events[0] else {
            return XCTFail("plan/step/tool shape not preserved")
        }
        XCTAssertFalse(row.isExecuting, "a persisted row must never claim to still be executing")
        // [CF-51] `isSuccess` stays nil on a CANCELLED close — a user Stop is not a tool
        // failure. It was `false` here until CF-51; the pinned behaviour is now "no verdict".
        XCTAssertNil(row.isSuccess)
        XCTAssertEqual(row.failureCategory, .cancelled)
        XCTAssertEqual(row.output, "Cancelled before the tool finished.")
    }

    /// The stacked shape ExecutorFactory actually builds: Reflexion(Planning(ReAct)), so a plan
    /// card lives inside a reflection attempt and its tool rows are two levels down.
    func testDanglingRowInsideReflectionAttemptAndNestedPlanIsClosed() {
        let message = makeMessage()

        var nestedPlan = PlanRunData(phase: .executing, steps: [
            PlanStepData(id: "step_1", title: "Deep step", status: .running)
        ])
        nestedPlan.steps[0].events = [executingRow("execute_shell")]

        var attempt = ReflectionAttemptData(trial: 1)
        attempt.events = [executingRow("fs_read"), .planExecution(nestedPlan)]

        var run = ReflectionRunData(maxTrials: 3)
        run.attempts = [attempt]
        message.timelineEvents = [.reflectionRun(run)]

        let closed = message.closeDanglingToolRows(outcome: .failed)

        XCTAssertEqual(closed, 2, "both the attempt-level row and the row inside its nested plan")
        guard case .reflectionRun(let after) = message.timelineEvents[0] else { return XCTFail() }
        XCTAssertFalse(isExecuting(after.attempts[0].events[0]), "attempt-level row still spinning")
        guard case .planExecution(let deepPlan) = after.attempts[0].events[1] else { return XCTFail() }
        XCTAssertFalse(isExecuting(deepPlan.steps[0].events[0]), "row inside the nested plan still spinning")
    }

    /// Control: the top-level behaviour the original fix covered must be unchanged, and rows
    /// that already finished must not be touched or re-counted.
    func testTopLevelStillClosedAndFinishedRowsUntouched() {
        let message = makeMessage()
        let done = ToolExecutionData(id: UUID(), name: "fs_read", params: "{}",
                                     output: "42 lines", isSuccess: true, isExecuting: false)
        message.timelineEvents = [executingRow(), .toolExecution(done)]

        let closed = message.closeDanglingToolRows(outcome: .cancelled)

        XCTAssertEqual(closed, 1, "only the dangling row counts")
        guard case .toolExecution(let untouched) = message.timelineEvents[1] else { return XCTFail() }
        XCTAssertEqual(untouched.output, "42 lines", "a finished row must be left exactly as it was")
        XCTAssertEqual(untouched.isSuccess, true)
    }

    // MARK: - CH26

    /// A step still `.running` when a trial's nested plan card closes never reported
    /// completion — the plan aborted early. It used to be marked `.completed`, which renders a
    /// green checkmark and counts toward "N steps · M done", claiming success for work that was
    /// discarded when the trial was rejected.
    func testRejectedTrialDoesNotMarkRunningStepCompleted() {
        let message = makeMessage()
        let router = CapabilityCardRouter(message: message)

        router.handleTrialStarted(trial: 1, maxTrials: 3)
        router.handlePlanGenerated([
            SubTask(id: "step_1", description: "First"),
            SubTask(id: "step_2", description: "Second")
        ])
        router.handleSubtaskCompleted(id: "step_1", summary: "done", outcome: .completed, durationMs: 5)
        router.handleSubtaskStarted(id: "step_2", description: "Second")

        router.handleTrialRejected(trial: 1, critique: "not good enough")

        guard let plan = nestedPlan(in: message) else { return XCTFail("no nested plan card") }
        XCTAssertEqual(plan.steps[1].status, .cancelled,
                       "a step cut short by a rejected trial must not be recorded as completed")
        XCTAssertEqual(plan.completedCount, 1, "only the step that genuinely finished counts as done")
        XCTAssertEqual(plan.outcome, .cancelled, "the card must carry a verdict, not nil")
        XCTAssertEqual(plan.phase, .finished)
    }

    /// Accepted trials get the same treatment — the verdict is about the ANSWER, not about a
    /// step that never reported completion.
    func testAcceptedTrialDoesNotMarkRunningStepCompleted() {
        let message = makeMessage()
        let router = CapabilityCardRouter(message: message)

        router.handleTrialStarted(trial: 1, maxTrials: 3)
        router.handlePlanGenerated([SubTask(id: "step_1", description: "Only")])
        router.handleSubtaskStarted(id: "step_1", description: "Only")

        router.handleTrialAccepted(trial: 1)

        guard let plan = nestedPlan(in: message) else { return XCTFail("no nested plan card") }
        XCTAssertEqual(plan.steps[0].status, .cancelled)
        XCTAssertEqual(plan.completedCount, 0)
    }

    /// Control: a plan whose steps all reported completion must still close as completed.
    func testFullyCompletedPlanClosesAsCompleted() {
        let message = makeMessage()
        let router = CapabilityCardRouter(message: message)

        router.handleTrialStarted(trial: 1, maxTrials: 3)
        router.handlePlanGenerated([SubTask(id: "step_1", description: "Only")])
        router.handleSubtaskStarted(id: "step_1", description: "Only")
        router.handleSubtaskCompleted(id: "step_1", summary: "done", outcome: .completed, durationMs: 3)

        router.handleTrialAccepted(trial: 1)

        guard let plan = nestedPlan(in: message) else { return XCTFail("no nested plan card") }
        XCTAssertEqual(plan.steps[0].status, .completed, "a genuinely completed step is untouched")
        XCTAssertEqual(plan.completedCount, 1)
        // NB: `outcome` is deliberately NOT asserted here. It was nil before the fix and is
        // written only by the new line, so asserting it would make this a second targeted test
        // rather than a control that holds either way. The targeted test above pins it.
    }

    /// The plan card is nested inside the reflection attempt when capabilities are stacked.
    private func nestedPlan(in message: ChatMessage) -> PlanRunData? {
        for event in message.timelineEvents {
            if case .reflectionRun(let run) = event {
                for attempt in run.attempts {
                    for e in attempt.events {
                        if case .planExecution(let plan) = e { return plan }
                    }
                }
            }
            if case .planExecution(let plan) = event { return plan }
        }
        return nil
    }
}

// MARK: - CH50

@MainActor
final class TimelineSummaryStatusTests: XCTestCase {

    private func row(success: Bool?, cancelled: Bool = false) -> TimelineEvent {
        var data = ToolExecutionData(id: UUID(), name: "write_file", params: "{}",
                                     output: "done", isSuccess: success, isExecuting: false)
        if cancelled { data.failureCategory = .cancelled }
        return .toolExecution(data)
    }

    /// The collapsed header is the ONLY thing visible after a run ends, and it used to
    /// hardcode a green checkmark plus "Executed N steps" regardless of what happened.
    func testAllSucceededReadsAsSuccess() {
        let s = AgentTimelineView.summarize(events: [row(success: true), row(success: true)])
        XCTAssertEqual(s.status, .succeeded)
        XCTAssertEqual(s.failedTools, 0)
        XCTAssertEqual(s.status.glyph, "checkmark.circle.fill")
    }

    func testFailedToolsDowngradeToDegradedAndAreCounted() {
        let s = AgentTimelineView.summarize(events: [
            row(success: true), row(success: false), row(success: false)
        ])
        XCTAssertEqual(s.status, .degraded, "a run with failed tools must not claim success")
        XCTAssertEqual(s.failedTools, 2)
        XCTAssertEqual(s.status.glyph, "exclamationmark.triangle.fill")
    }

    /// Cancellation comes from the RUN's outcome, never from a tool row. (AD-row `timeline-2`:
    /// `ToolExecutionLoop` also stamps `failureCategory == .cancelled` when the user merely SKIPS
    /// an `ask_user` prompt, after which the run continues and finishes normally.)
    func testCancelledComesFromTheRunOutcome() {
        let s = AgentTimelineView.summarize(events: [row(success: false), row(success: false)],
                                            outcome: .cancelled)
        XCTAssertEqual(s.status, .cancelled)
        XCTAssertEqual(s.failedTools, 2, "the failed count is still reported alongside the cancel")
        XCTAssertEqual(s.status.glyph, "slash.circle")
    }

    /// The false-cancel this replaced: a skipped `ask_user` leaves a `.cancelled` tool row on a
    /// run that COMPLETED. The header must not call that "Stopped".
    func testSkippedAskUserDoesNotMakeACompletedRunLookCancelled() {
        let s = AgentTimelineView.summarize(events: [row(success: true),
                                                     row(success: false, cancelled: true)],
                                            outcome: .completed)
        XCTAssertNotEqual(s.status, .cancelled,
                          "a per-tool cancelled category is not proof the RUN was stopped")
        XCTAssertEqual(s.status, .degraded)
    }

    // MARK: - AD5/AD6 — nested rows

    private func planCard(with events: [TimelineEvent]) -> TimelineEvent {
        var plan = PlanRunData(phase: .finished, steps: [
            PlanStepData(id: "step_1", title: "Do it", status: .completed)
        ])
        plan.steps[0].events = events
        return .planExecution(plan)
    }

    private func reflectionCard(with events: [TimelineEvent]) -> TimelineEvent {
        var attempt = ReflectionAttemptData(trial: 1)
        attempt.events = events
        var run = ReflectionRunData(maxTrials: 3)
        run.attempts = [attempt]
        return .reflectionRun(run)
    }

    /// With Plan & Execute on — most agent runs — `CapabilityCardRouter` puts every tool row
    /// INSIDE the card, so the top-level array holds no tool rows at all. Reading it flat made
    /// the header render a green checkmark and "Thought for N steps" for a run whose tools failed.
    func testFailedToolNestedInAPlanStepIsSeen() {
        let s = AgentTimelineView.summarize(events: [planCard(with: [row(success: false)])])
        XCTAssertEqual(s.status, .degraded, "a nested failure must downgrade the header")
        XCTAssertEqual(s.failedTools, 1)
    }

    /// The stacked shape ExecutorFactory builds: Reflexion(Planning(ReAct)) — two levels down.
    func testFailedToolNestedInsideAPlanInsideAnAttemptIsSeen() {
        let deep = reflectionCard(with: [row(success: true),
                                         planCard(with: [row(success: false), row(success: false)])])
        let s = AgentTimelineView.summarize(events: [deep])
        XCTAssertEqual(s.status, .degraded)
        XCTAssertEqual(s.failedTools, 2, "both rows two levels down must be counted")
    }

    /// Control: a nested run where everything succeeded still reads as success, so the flattening
    /// did not simply make every capability run look degraded.
    func testAllSucceededNestedStillReadsAsSuccess() {
        let s = AgentTimelineView.summarize(events: [planCard(with: [row(success: true),
                                                                     row(success: true)])])
        XCTAssertEqual(s.status, .succeeded)
        XCTAssertEqual(s.failedTools, 0)
    }

    /// `isSuccess == nil` is "not reported", not "failed" — a reasoning-only timeline with no
    /// tool rows must not be downgraded.
    func testUnreportedAndNonToolEventsDoNotDowngrade() {
        let s = AgentTimelineView.summarize(events: [row(success: nil), .thought(id: UUID(), text: "thinking")])
        XCTAssertEqual(s.status, .succeeded)
        XCTAssertEqual(s.failedTools, 0)
    }
}
