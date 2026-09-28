// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ZeroTimeLimitTests.swift
//  DevgenticTests
//
//  Timeout inventory D-05 (probe P9): a configured limit of 0 or less meant "time out instantly".
//  It now means "not set" — the next setting in the priority chain applies.
//

import XCTest
@testable import devgentic

final class ZeroTimeLimitTests: XCTestCase {

    func testZeroNegativeAndNonFiniteAreNotSet() {
        for bad in [0, -1, .infinity, .nan] as [TimeInterval] {
            XCTAssertNil(TimeLimit.usable(bad, "t"), "\(bad)")
        }
        XCTAssertNil(TimeLimit.usable(nil, "t"))
        XCTAssertEqual(TimeLimit.usable(30, "t"), 30)
    }

    /// Mutation that must turn this red: read `hardTimeout` raw in `outerTimeoutBudget` again.
    func testANodeWithAZeroHardTimeoutFallsBackToTheWorkflowDefault() {
        var node = WorkflowNode(id: UUID(), kind: .action(ActionNodeConfig()), position: .zero, displayName: "Call API")
        node.nodeConfig = WorkflowNodeConfig(maxNodeRetries: 0, hardTimeout: 0)
        let config = WorkflowConfig(agentProfileIDs: [])

        let budget = WorkflowExecutor.outerTimeoutBudget(for: node, workflowConfig: config)
        XCTAssertNotEqual(budget, 0, "a 0 hardTimeout used to fail the node the instant it started")
        XCTAssertEqual(budget, config.effectiveNodeTimeout)
    }

    /// Every other reader goes through the same rule.
    func testEveryConfiguredLimitIsReadThroughTheRule() throws {
        let workflow = try source("Devgentic/Core/Backends/WorkflowGen/WorkflowExecutor.swift")
        for reader in ["TimeLimit.usable(config.timeout, \"Gate",
                       "TimeLimit.usable(node.nodeConfig?.hardTimeout, \"Node '\\(displayName)' hardTimeout\")",
                       "TimeLimit.usable(profile.details.executionTimeout, \"Node",
                       "TimeLimit.usable(node.nodeConfig?.hardTimeout, \"Action node"] {
            XCTAssertTrue(workflow.contains(reader), "not read through TimeLimit.usable: \(reader)")
        }
        let agent = try source("Devgentic/Core/Backends/TextGen/AgentConnect.swift")
        XCTAssertTrue(agent.contains("TimeLimit.usable(profile.details.executionTimeout"),
                      "a profile with executionTimeout 0 would abort every turn instantly")
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("\(path) not reachable — running outside a checkout")
        }
        return text
    }
}
