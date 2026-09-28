// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackgroundPollFoldingTests.swift
//  DevgenticTests
//
//  Device test 2026-09-21: asked to "check on it periodically", the model produced NINE
//  `command_status` calls in ~40 seconds — one every few seconds, because nothing lets it wait.
//  ⚠️ That tool was withdrawn 2026-09-23; the folding now applies to `command_output`, which is
//  the only remaining read path and is polled the same way.
//  Each rendered as its own "Command bg_1" row, stacked above a card already showing the same
//  status live.
//

import XCTest
@testable import devgentic

@MainActor
final class BackgroundPollFoldingTests: XCTestCase {

    private func card(_ taskID: String) -> TimelineEvent {
        .backgroundTask(BackgroundTaskData(
            id: UUID(), taskID: taskID, command: "xcodebuild build-for-testing",
            workingDirectory: "/tmp", startedAt: Date(), finishedAt: nil,
            status: .running, exitCode: nil, logPath: "/tmp/\(taskID).log",
            outputTail: "", logCharacterCount: 0))
    }

    private func tool(_ name: String, params: String) -> TimelineEvent {
        .toolExecution(ToolExecutionData(
            id: UUID(), name: name, params: params, output: "ok",
            isSuccess: true, isExecuting: false))
    }

    private func names(_ events: [TimelineEvent]) -> [String] {
        events.map {
            switch $0 {
            case .toolExecution(let d): return d.name
            case .backgroundTask(let d): return "card:\(d.taskID)"
            default: return "other"
            }
        }
    }

    // MARK: - The regression

    func testPollsForACardedTaskAreFolded() {
        let events: [TimelineEvent] = [
            tool("batch_command", params: #"{"command":"xcodebuild","background":true}"#),
            card("bg_1"),
        ] + (1...9).map { _ in tool("get_task_output", params: #"{"task_id":"bg_1"}"#) }

        let folded = AgentTimelineView.foldBackgroundTaskPolls(events)

        XCTAssertEqual(names(folded), ["batch_command", "card:bg_1"],
                       "nine identical poll rows survived above a card showing the same status")
    }

    func testGetTaskOutputIsFoldedToo() {
        let events = [card("bg_1"), tool("get_task_output", params: #"{"task_id":"bg_1"}"#)]
        XCTAssertEqual(names(AgentTimelineView.foldBackgroundTaskPolls(events)), ["card:bg_1"])
    }

    func testLegacyCommandOutputIsFoldedToo() {
        let events = [card("bg_1"), tool("command_output", params: #"{"task_id":"bg_1"}"#)]
        XCTAssertEqual(names(AgentTimelineView.foldBackgroundTaskPolls(events)), ["card:bg_1"])
    }

    /// ⚠️ Hide observations, keep actions. Stopping a task CHANGES state; the user should see
    /// that it happened even though the card also reports the outcome.
    func testStopBackgroundTaskKeepsItsRow() {
        let events = [card("bg_1"), tool("stop_background_task", params: #"{"task_id":"bg_1"}"#)]
        XCTAssertEqual(names(AgentTimelineView.foldBackgroundTaskPolls(events)),
                       ["card:bg_1", "stop_background_task"],
                       "an action the agent took was hidden, not just an observation")
    }

    /// ⚠️ Without a card there is nowhere else for the information to appear, so folding would
    /// leave the user with nothing at all.
    func testPollsSurviveWhenNoCardExists() {
        let events = [tool("get_task_output", params: #"{"task_id":"bg_1"}"#)]
        XCTAssertEqual(names(AgentTimelineView.foldBackgroundTaskPolls(events)), ["get_task_output"])
    }

    func testAPollForADifferentTaskIsKept() {
        let events = [card("bg_1"), tool("get_task_output", params: #"{"task_id":"bg_2"}"#)]
        XCTAssertEqual(names(AgentTimelineView.foldBackgroundTaskPolls(events)),
                       ["card:bg_1", "get_task_output"],
                       "bg_2 has no card, so its status row is the only place it shows")
    }

    /// The list-everything form. With a card on screen it is the same noise.
    func testAListAllPollIsFoldedWhenAnyCardExists() {
        let events = [card("bg_1"), tool("get_task_output", params: "{}")]
        XCTAssertEqual(names(AgentTimelineView.foldBackgroundTaskPolls(events)), ["card:bg_1"])
    }

    /// ⚠️ PARSED, not substring-matched. A `batch_command` whose command text mentions a task id
    /// is not a poll, and folding it would be the shape-matching defect this codebase has paid
    /// for repeatedly.
    func testACommandMentioningATaskIDIsNotMistakenForAPoll() {
        let events = [
            card("bg_1"),
            tool("batch_command", params: #"{"command":"echo bg_1 finished","background":false}"#),
        ]
        XCTAssertEqual(names(AgentTimelineView.foldBackgroundTaskPolls(events)),
                       ["card:bg_1", "batch_command"],
                       "a real command was folded because its text mentioned a task id")
    }

    // MARK: - The wiring

    /// ⚠️⚠️ THE ONE THAT MATTERS, and mutation is what found it missing.
    ///
    /// Every test above calls `foldBackgroundTaskPolls` DIRECTLY. Deleting the single line that
    /// invokes it from `buildGroupedNodes` left all of them green while the timeline rendered all
    /// nine rows exactly as before — the pass existed and nothing used it. This drives the real
    /// entry point instead.
    func testTheNodeBuilderActuallyAppliesTheFold() {
        let events: [TimelineEvent] = [card("bg_1")]
            + (1...9).map { _ in tool("get_task_output", params: #"{"task_id":"bg_1"}"#) }

        let nodes = AgentTimelineView.buildGroupedNodes(from: events, isStreaming: false)

        var polls = 0
        var cards = 0
        for node in nodes {
            switch node {
            case .action(let event):
                if case .toolExecution(let d) = event, d.name == "get_task_output" { polls += 1 }
            case .actionGroup(let group):
                polls += group.filter {
                    if case .toolExecution(let d) = $0 { return d.name == "get_task_output" }
                    return false
                }.count
            case .backgroundCard:
                cards += 1
            default:
                break
            }
        }

        XCTAssertEqual(cards, 1, "the task's card should be rendered")
        XCTAssertEqual(polls, 0,
                       "\(polls) poll row(s) reached the rendered timeline — the fold is not "
                       + "wired into buildGroupedNodes, so the nine 'Command bg_1' rows are back")
    }

    func testNonPollEventsAreUntouched() {
        let events = [card("bg_1"), tool("read_file", params: #"{"path":"/tmp/x"}"#)]
        XCTAssertEqual(names(AgentTimelineView.foldBackgroundTaskPolls(events)),
                       ["card:bg_1", "read_file"])
    }
}

// MARK: - Background default timeout

final class BackgroundDefaultTimeoutTests: XCTestCase {

    /// ⚠️ Device test 2026-09-21: the model backgrounded a real `xcodebuild` without naming a
    /// timeout, inherited the FOREGROUND default of 30s, and the build was killed having barely
    /// started. A 30s ceiling on the mode that exists for long work makes the common case
    /// "killed before it began".
    func testBackgroundDefaultsToTheCeilingNotTheForegroundDefault() {
        XCTAssertEqual(BatchCommandTool.effectiveTimeout(nil, background: true),
                       BatchCommandTool.maxTimeoutSeconds)
        XCTAssertNotEqual(BatchCommandTool.effectiveTimeout(nil, background: true), 30)
    }

    func testForegroundDefaultIsUnchanged() {
        XCTAssertEqual(BatchCommandTool.effectiveTimeout(nil), BatchCommandTool.defaultTimeoutSeconds)
        XCTAssertEqual(BatchCommandTool.effectiveTimeout(nil, background: false), BatchCommandTool.defaultTimeoutSeconds)
    }

    /// An explicit value still wins in both modes, and the ceiling still binds.
    func testAnExplicitTimeoutIsHonouredAndStillClamped() {
        XCTAssertEqual(BatchCommandTool.effectiveTimeout(60, background: true), 60)
        XCTAssertEqual(BatchCommandTool.effectiveTimeout(60, background: false), 60)
        XCTAssertEqual(BatchCommandTool.effectiveTimeout(9_999, background: true),
                       BatchCommandTool.maxTimeoutSeconds)
    }

    /// Non-positive means "unspecified", in both modes — not "unbounded".
    func testNonPositiveFallsBackToTheModesDefault() {
        XCTAssertEqual(BatchCommandTool.effectiveTimeout(0, background: true),
                       BatchCommandTool.maxTimeoutSeconds)
        XCTAssertEqual(BatchCommandTool.effectiveTimeout(-1, background: false), BatchCommandTool.defaultTimeoutSeconds)
    }
}
