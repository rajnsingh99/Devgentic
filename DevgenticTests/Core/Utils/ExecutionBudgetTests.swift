// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ExecutionBudgetTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class ExecutionBudgetTests: XCTestCase {

    /// A frame whose clock started `elapsed` seconds ago — simulates being late in a turn/run.
    private func frame(limit: TimeInterval, elapsed: TimeInterval, owner: String = "the turn's 10 min limit") -> ExecutionBudget.Frame {
        ExecutionBudget.Frame(owner: owner, limit: limit, scope: UUID(),
                              start: SuspendingClock().now.advanced(by: .seconds(-elapsed)), parkedAtStart: 0)
    }

    // MARK: - The rule

    func testTheReserveIsKeptBackAndAShortRemainderIsHalved() {
        XCTAssertEqual(ExecutionBudget.reserve, 60)
        XCTAssertEqual(ExecutionBudget.available(outerRemaining: 600), 540)
        XCTAssertEqual(ExecutionBudget.available(outerRemaining: 100), 50, "under 2× the reserve: half")
        XCTAssertEqual(ExecutionBudget.available(outerRemaining: -5), 0)
    }

    /// A short outer limit keeps a tenth, not 60 s — a flat 60 s left a 30 s node no retries at all
    /// and a 120 s node's tools at most 60 s. Mutation: return `reserve` unconditionally.
    func testAShortLimitKeepsATenthAsItsReserve() async {
        XCTAssertEqual(ExecutionBudget.reserve(forLimit: 1800), 60)
        XCTAssertEqual(ExecutionBudget.reserve(forLimit: 120), 12)
        let retries = await ExecutionBudget.withFrame(frame(limit: 30, elapsed: 5)) {
            await ExecutionBudget.retryFits(what: "t")
        }
        XCTAssertTrue(retries, "25 s left of a 30 s limit is room for a retry")
    }

    func testOutsideAnyLimitNothingIsShortened() async {
        let clamp = await ExecutionBudget.clamp(1800, what: "t")
        XCTAssertEqual(clamp, ExecutionBudget.Clamp(limit: 1800, shortenedBy: nil))
    }

    func testAnInnerLimitIsShortenedToFitTheTightestOuterOne() async {
        let run = frame(limit: 1800, elapsed: 0, owner: "the scheduled run's 30 min limit")
        let turn = frame(limit: 600, elapsed: 540)            // 60 s left → 30 s available
        let clamp = await ExecutionBudget.withFrame(run) {
            await ExecutionBudget.withFrame(turn) { await ExecutionBudget.clamp(1800, what: "t") }
        }
        XCTAssertEqual(clamp.limit, 30, accuracy: 1)
        XCTAssertEqual(clamp.shortenedBy, "the turn's 10 min limit")
    }

    func testANodeWithNoLimitOfItsOwnInheritsTheFittedOuterOne() async {
        let clamp = await ExecutionBudget.withFrame(frame(limit: 1800, elapsed: 0)) {
            await ExecutionBudget.clamp(nil, what: "sub-workflow")
        }
        XCTAssertEqual(clamp.limit, 1740, accuracy: 1)
    }

    func testARetryIsNotStartedOnceOnlyTheReserveRemains() async {
        let late = await ExecutionBudget.withFrame(frame(limit: 600, elapsed: 560)) {
            await ExecutionBudget.retryFits(what: "t")
        }
        XCTAssertFalse(late)
        let early = await ExecutionBudget.withFrame(frame(limit: 600, elapsed: 10)) {
            await ExecutionBudget.retryFits(what: "t")
        }
        XCTAssertTrue(early)
    }

    // MARK: - Seams, driven through the real code

    /// Tool dispatch: a 30-min command started late in a turn is stopped first, and the model is told
    /// why and that it still has time to answer. Mutation: remove the clamp in the mediator.
    func testAToolLateInATurnIsStoppedFirstAndTheModelIsToldWhy() async {
        let tool = TestToolFactory.makeSlow(name: "build", delay: 10)
        let start = Date()
        let result = await ExecutionBudget.withFrame(frame(limit: 600, elapsed: 598.5)) {   // 1.5 s left
            await ToolExecutionMediator().executePreparedTool(
                toolName: "build", arguments: ["input": .string("x")],
                availableTools: [tool], parentContext: TestTraceContext.make())
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "the tool must be stopped at the fitted limit")
        guard case .timedOut(_, _, let message?) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(message.contains("shortened to fit the turn's 10 min limit"), message)
    }

    /// Workflow wrapper: a node with no limit of its own, inside a nearly spent outer limit, now times
    /// out instead of running until the outer one cuts everything off. Mutation: drop the clamp.
    func testAnUnlimitedNodeInsideAnOuterLimitTimesOut() async {
        do {
            _ = try await ExecutionBudget.withFrame(frame(limit: 600, elapsed: 598.5)) {
                try await WorkflowExecutor.withComputeTimeout(nil, conversationID: UUID(), nodeName: "child") {
                    try await Task.sleep(for: .seconds(10)); return 1
                }
            }
            XCTFail("expected a timeout")
        } catch let error as AgentExecutionError {
            guard case .executionTimeout = error.reason else { return XCTFail("\(error)") }
        } catch {
            XCTFail("\(error)")
        }
    }

    /// Wiring the pure seams cannot reach: the turn and the scheduled run open frames.
    func testTheTurnAndTheScheduledRunOpenBudgets() throws {
        let agent = try source("Devgentic/Core/Backends/TextGen/AgentConnect.swift")
        XCTAssertTrue(agent.contains("ExecutionBudget.bind(turnFrame)"), "a limited turn no longer nests its tools")
        let scheduler = try source("Devgentic/Interfaces/Main/SchedulerCoordinator.swift")
        XCTAssertTrue(scheduler.contains("ExecutionBudget.bind(runFrame)"), "a scheduled run no longer nests its nodes")
        let workflow = try source("Devgentic/Core/Backends/WorkflowGen/WorkflowExecutor.swift")
        XCTAssertEqual(workflow.components(separatedBy: "ExecutionBudget.retryFits(").count - 1, 3,
                       "profile-node, sub-workflow and Action retries must all check the remaining time")
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("\(path) not reachable — running outside a checkout")
        }
        return text
    }
}
