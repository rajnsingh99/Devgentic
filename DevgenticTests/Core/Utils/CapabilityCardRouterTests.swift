// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CapabilityCardRouterTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
final class CapabilityCardRouterTests: XCTestCase {

    private func makeMessage() -> ChatMessage {
        ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText(""))
    }

    private func planCard(in message: ChatMessage) -> PlanRunData? {
        for event in message.timelineEvents {
            if case .planExecution(let data) = event { return data }
        }
        return nil
    }

    private func reflectionCard(in message: ChatMessage) -> ReflectionRunData? {
        for event in message.timelineEvents {
            if case .reflectionRun(let data) = event { return data }
        }
        return nil
    }

    private func subtasks(_ descriptions: [String]) -> [SubTask] {
        descriptions.enumerated().map { SubTask(id: "step_\($0.offset + 1)", description: $0.element) }
    }

    // MARK: - Plan lifecycle

    func testPlanLifecycle_StepStatusesAndNestedRouting() {
        let message = makeMessage()
        let router = CapabilityCardRouter(message: message)

        router.handlePlanGenerated(subtasks(["Create folder", "Write file"]))

        var card = try! XCTUnwrap(planCard(in: message))
        XCTAssertEqual(card.phase, .executing)
        XCTAssertEqual(card.steps.map(\.status), [.pending, .pending])

        // Step 1 runs; forwarded events nest inside it.
        router.handleSubtaskStarted(id: "step_1", description: "Create folder")
        XCTAssertTrue(router.route(.thought(id: UUID(), text: "Creating the folder now.")),
                      "Events during an active step must route into the step")
        XCTAssertTrue(router.route(.toolExecution(ToolExecutionData(
            id: UUID(), name: "create_folder", params: "{}", output: nil, isSuccess: nil, isExecuting: true
        ))))
        XCTAssertTrue(router.completeTool(
            output: ToolOutput(toolName: "create_folder", params: "{}", output: "ok", isSuccess: true),
            failureCategory: nil, durationMs: 42
        ), "Nested executing tool row must be completable")

        card = try! XCTUnwrap(planCard(in: message))
        XCTAssertEqual(card.steps[0].status, .running)
        XCTAssertEqual(card.steps[0].events.count, 2)
        if case .toolExecution(let tool) = card.steps[0].events[1] {
            XCTAssertEqual(tool.isSuccess, true)
            XCTAssertFalse(tool.isExecuting)
            XCTAssertEqual(tool.durationMs, 42)
        } else {
            XCTFail("Expected nested tool execution event")
        }

        // Step 1 completes; nothing active → routing declines.
        router.handleSubtaskCompleted(id: "step_1", summary: "Folder created", outcome: .completed, durationMs: 1200)
        XCTAssertFalse(router.route(.thought(id: UUID(), text: "between steps")),
                       "No active segment → caller appends top-level")

        // Step 2 degrades (circuit-breaker style early stop).
        router.handleSubtaskStarted(id: "step_2", description: "Write file")
        router.handleSubtaskCompleted(id: "step_2", summary: "Ended early", outcome: .completedWithWarnings, durationMs: 300)

        router.handleExecutionFinished(outcome: .completedWithWarnings)

        card = try! XCTUnwrap(planCard(in: message))
        XCTAssertEqual(card.phase, .finished)
        XCTAssertEqual(card.outcome, .completedWithWarnings)
        XCTAssertNotNil(card.finishedAt)
        XCTAssertEqual(card.steps.map(\.status), [.completed, .warning])
        XCTAssertEqual(card.steps[0].durationMs, 1200)
        XCTAssertTrue(card.hasDegradedSteps)
    }

    func testPlanReview_ApprovedEditedPlanReplacesSteps() {
        let message = makeMessage()
        let router = CapabilityCardRouter(message: message)

        router.handlePlanGenerated(subtasks(["A", "B", "C"]))
        router.handlePlanReviewRequested()
        XCTAssertEqual(planCard(in: message)?.phase, .awaitingApproval)

        // User deleted one step and reworded another before approving.
        let edited = [SubTask(id: "step_1", description: "A edited"), SubTask(id: "step_3", description: "C")]
        router.handlePlanApproved(edited)

        let card = try! XCTUnwrap(planCard(in: message))
        XCTAssertEqual(card.phase, .executing)
        XCTAssertEqual(card.steps.map(\.id), ["step_1", "step_3"])
        XCTAssertEqual(card.steps[0].title, "A edited")
    }

    func testPlanRejected_FinishesCancelledWithAllStepsPending() {
        let message = makeMessage()
        let router = CapabilityCardRouter(message: message)

        router.handlePlanGenerated(subtasks(["A", "B"]))
        router.handlePlanReviewRequested()
        router.handleExecutionFinished(outcome: .cancelled)

        let card = try! XCTUnwrap(planCard(in: message))
        XCTAssertEqual(card.phase, .finished)
        XCTAssertEqual(card.outcome, .cancelled)
        XCTAssertEqual(card.steps.map(\.status), [.pending, .pending],
                       "A rejected plan honestly records that nothing ran")
    }

    // MARK: - Reflection lifecycle

    func testReflectionLifecycle_CritiqueAndAcceptance() {
        let message = makeMessage()
        let router = CapabilityCardRouter(message: message)

        router.handleTrialStarted(trial: 1, maxTrials: 3)
        XCTAssertTrue(router.route(.thought(id: UUID(), text: "trial 1 work")),
                      "Events during a trial must route into the attempt")
        router.handleTrialEvaluating(trial: 1)
        router.handleTrialRejected(trial: 1, critique: "Used a relative path — directory never found.")

        router.handleTrialStarted(trial: 2, maxTrials: 3)
        router.handleTrialEvaluating(trial: 2)
        router.handleTrialAccepted(trial: 2)
        router.handleExecutionFinished(outcome: .completed)

        let card = try! XCTUnwrap(reflectionCard(in: message))
        XCTAssertEqual(card.attempts.count, 2)
        XCTAssertEqual(card.attempts[0].status, .rejected)
        XCTAssertEqual(card.attempts[0].critique, "Used a relative path — directory never found.")
        XCTAssertEqual(card.attempts[0].events.count, 1)
        XCTAssertEqual(card.attempts[1].status, .accepted)
        XCTAssertEqual(card.acceptedTrial, 2)
        XCTAssertEqual(card.outcome, .completed)
    }

    func testReflection_FinalTrialWithoutVerdict_MarksCompletedNotAccepted() {
        let message = makeMessage()
        let router = CapabilityCardRouter(message: message)

        router.handleTrialStarted(trial: 1, maxTrials: 1)
        router.handleExecutionFinished(outcome: .completed)

        let card = try! XCTUnwrap(reflectionCard(in: message))
        XCTAssertEqual(card.attempts[0].status, .completed,
                       "The final trial is never evaluated — no accepted verdict may be claimed")
        XCTAssertNil(card.acceptedTrial)
    }

    // MARK: - Stacked capabilities (plan card nested in a reflection attempt)

    func testStacked_PlanCardNestsInsideAttempt_AndClosesOnTrialEnd() {
        let message = makeMessage()
        let router = CapabilityCardRouter(message: message)

        router.handleTrialStarted(trial: 1, maxTrials: 2)
        router.handlePlanGenerated(subtasks(["Inner step"]))
        router.handleSubtaskStarted(id: "step_1", description: "Inner step")
        XCTAssertTrue(router.route(.thought(id: UUID(), text: "nested work")))
        router.handleSubtaskCompleted(id: "step_1", summary: "done", outcome: .completed, durationMs: nil)
        router.handleTrialRejected(trial: 1, critique: "Not good enough.")

        // Top level holds ONLY the reflection card; the plan card lives inside attempt 1.
        XCTAssertNil(planCard(in: message), "Plan card must not appear at top level when stacked")
        let reflection = try! XCTUnwrap(reflectionCard(in: message))
        let nestedPlan: PlanRunData? = reflection.attempts[0].events.compactMap {
            if case .planExecution(let d) = $0 { return d }
            return nil
        }.first
        let plan = try! XCTUnwrap(nestedPlan)
        XCTAssertEqual(plan.phase, .finished, "Trial end must close the nested plan card")
        XCTAssertEqual(plan.steps[0].status, .completed)
        XCTAssertEqual(plan.steps[0].events.count, 1, "Nested step holds its routed events")

        // Next trial gets a FRESH plan card.
        router.handleTrialStarted(trial: 2, maxTrials: 2)
        router.handlePlanGenerated(subtasks(["Retry step"]))
        let reflection2 = try! XCTUnwrap(reflectionCard(in: message))
        let attempt2Plans = reflection2.attempts[1].events.filter {
            if case .planExecution = $0 { return true }
            return false
        }
        XCTAssertEqual(attempt2Plans.count, 1, "Trial 2 gets its own nested plan card")
    }

    // MARK: - Flattening + resume sanitation

    func testFlattenedTimelineEvents_IncludesNestedToolRows() {
        let message = makeMessage()
        let router = CapabilityCardRouter(message: message)

        router.handlePlanGenerated(subtasks(["A"]))
        router.handleSubtaskStarted(id: "step_1", description: "A")
        _ = router.route(.toolExecution(ToolExecutionData(
            id: UUID(), name: "read_file", params: "{}", output: "data", isSuccess: true, isExecuting: false
        )))

        let flattenedTools = message.flattenedTimelineEvents.filter {
            if case .toolExecution = $0 { return true }
            return false
        }
        XCTAssertEqual(flattenedTools.count, 1,
                       "Nested tool rows must surface through flattenedTimelineEvents (episodic memory / resume contract)")
        XCTAssertTrue(message.timelineEvents.allSatisfy { event in
            if case .toolExecution = event { return false }
            return true
        }, "The raw top-level timeline holds the card, not the nested tool")
    }

    func testSanitizeForResume_DropsDanglingNestedToolAndClosesCard() {
        let message = makeMessage()
        let router = CapabilityCardRouter(message: message)

        router.handlePlanGenerated(subtasks(["A"]))
        router.handleSubtaskStarted(id: "step_1", description: "A")
        _ = router.route(.toolExecution(ToolExecutionData(
            id: UUID(), name: "ask_user", params: "{}", output: nil, isSuccess: nil, isExecuting: true
        )))
        // Simulate force-quit: no executionFinished; card persists open with a dangling tool.

        message.sanitizeCapabilityCardsForResume()

        let card = try! XCTUnwrap(planCard(in: message))
        XCTAssertEqual(card.phase, .finished, "Resume sanitation must close an open card")
        XCTAssertEqual(card.steps[0].status, .cancelled)
        XCTAssertTrue(card.steps[0].events.isEmpty, "Dangling executing tool must be dropped")
    }
}
