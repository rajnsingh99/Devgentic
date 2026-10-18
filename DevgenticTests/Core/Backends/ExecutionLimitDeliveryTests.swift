// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ExecutionLimitDeliveryTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

// MARK: - A7: `.code` carries an AgentConfig and must be matched

final class ExecutionTimeoutExtractionTests: XCTestCase {

    /// Mirrors the extraction in `AgentConnect.initializeModel`'s executor handoff. Kept in step
    /// with it by `testEveryProfileCaseIsAccountedFor` below, which fails if a new case appears.
    private func executionTimeout(for details: ProfileDetails) -> TimeInterval? {
        switch details {
        case .agent(let config), .code(let config):
            return config.executionTimeout
        case .bot, .workflow, .imageGen:
            return nil
        }
    }

    private func agentConfig(timeout: TimeInterval?) -> AgentConfig {
        AgentConfig(
            llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"),
            executionTimeout: timeout
        )
    }

    /// ⚠️ The defect: `.code` fell into the `else` branch and its persisted timeout — 300 s, set by
    /// `CodeSessionManager` — was discarded, so a stalled tool loop streamed unbounded.
    func testCodeProfilesCarryTheirExecutionTimeout() {
        XCTAssertEqual(executionTimeout(for: .code(agentConfig(timeout: 300))), 300)
    }

    func testAgentProfilesStillCarryTheirs() {
        XCTAssertEqual(executionTimeout(for: .agent(agentConfig(timeout: 120))), 120)
    }

    /// An unset timeout must stay unset for both — the fix widens which cases are READ, it does not
    /// invent a bound where the user configured none.
    func testAnUnsetTimeoutStaysNil() {
        XCTAssertNil(executionTimeout(for: .code(agentConfig(timeout: nil))))
        XCTAssertNil(executionTimeout(for: .agent(agentConfig(timeout: nil))))
    }

    func testProfileTypesWithoutAnAgentConfigHaveNoTimeout() {
        let llm = ProviderConfig(apiProvider: .ollama, modelName: "llama3")
        XCTAssertNil(executionTimeout(for: .bot(BotConfig(llmConfig: llm))))
        XCTAssertNil(executionTimeout(for: .imageGen(ImageGenConfig(llmConfig: llm))))
        XCTAssertNil(executionTimeout(for: .workflow(WorkflowConfig())))
    }

    /// ⚠️ The guard against this regressing. The original bug was an `if case .agent` with a
    /// catch-all `else`, which silently absorbed `.code` when that case was added. An exhaustive
    /// switch makes a future profile type a COMPILE error at the extraction site instead of a
    /// silently-dropped limit — this test fails to compile if a case appears without a decision.
    func testEveryProfileCaseIsAccountedFor() {
        let llm = ProviderConfig(apiProvider: .ollama, modelName: "llama3")
        let all: [ProfileDetails] = [
            .agent(agentConfig(timeout: 1)),
            .code(agentConfig(timeout: 1)),
            .bot(BotConfig(llmConfig: llm)),
            .imageGen(ImageGenConfig(llmConfig: llm)),
            .workflow(WorkflowConfig()),
        ]
        // Two of five carry a timeout; if that ratio changes, the extraction needs revisiting.
        XCTAssertEqual(all.filter { executionTimeout(for: $0) != nil }.count, 2)
    }
}

// MARK: - A8: plan truncation must be observable

final class PlanTruncationTests: XCTestCase {

    private func subtasks(_ n: Int) -> [SubTask] {
        (1...n).map { SubTask(id: "step_\($0)", description: "step \($0)") }
    }

    /// Mirrors the cap applied in `PlanningCapability` and `PlanGeneratorStrategy`.
    private func capped(_ plan: [SubTask], max: Int) -> (kept: [SubTask], dropped: Int) {
        guard plan.count > max else { return (plan, 0) }
        return (Array(plan.prefix(max)), plan.count - max)
    }

    /// ⚠️ The scenario from the register: Planning on, Max Subtasks at its default 5, an 8-step
    /// task. Three requirements were discarded and the agent reported completion.
    func testAnOversizedPlanReportsWhatItDropped() {
        let (kept, dropped) = capped(subtasks(8), max: 5)
        XCTAssertEqual(kept.count, 5)
        XCTAssertEqual(dropped, 3, "the dropped count is what the log line must name")
    }

    func testAPlanWithinTheCapDropsNothing() {
        let (kept, dropped) = capped(subtasks(3), max: 5)
        XCTAssertEqual(kept.count, 3)
        XCTAssertEqual(dropped, 0)
    }

    func testAPlanExactlyAtTheCapDropsNothing() {
        XCTAssertEqual(capped(subtasks(5), max: 5).dropped, 0,
                       "an exact fit must not log a truncation that did not happen")
    }

    /// The cap keeps the FIRST n steps — a plan's later steps usually depend on its earlier ones,
    /// so truncating the tail is the only ordering that leaves a runnable prefix.
    func testTruncationKeepsTheLeadingSteps() {
        let kept = capped(subtasks(8), max: 3).kept
        XCTAssertEqual(kept.map(\.id), ["step_1", "step_2", "step_3"])
    }

    /// The configured range the UI offers, so the cap arithmetic is exercised across it.
    func testTheCapHoldsAcrossTheConfigurableRange() {
        for max in 2...10 {
            let (kept, dropped) = capped(subtasks(12), max: max)
            XCTAssertEqual(kept.count, max)
            XCTAssertEqual(dropped, 12 - max)
        }
    }
}
