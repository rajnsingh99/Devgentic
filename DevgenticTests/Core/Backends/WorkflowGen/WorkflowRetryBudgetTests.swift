// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  WorkflowRetryBudgetTests.swift
//  DevgenticTests
//
//  Register WF-EX2: Action-node retries were silently defeated.
//
//  The node's OUTER backstop (`executeStructuralNodeBounded`) and the PER-ATTEMPT bound inside the
//  Action path were computed from the identical expression — `node.nodeConfig?.hardTimeout ??
//  workflowConfig.effectiveNodeTimeout`. So attempt 1 consumed the entire node budget and the outer
//  sentinel fired the instant attempt 2 began: a node configured "60s, 3 retries" got exactly ONE
//  attempt. Any Action node whose tool failed more slowly than `limit / attempts` had its configured
//  retries disabled, with nothing anywhere saying so — and slow failure (a hanging endpoint) is
//  precisely the case retries exist for.
//
//  Worse, because the OUTER clock was what killed the node, the final attempt's failure reporting
//  never ran: the tool's real error reached neither the timeline, nor the trace, nor per-tool
//  reliability stats. The user was shown a generic node timeout instead of "the HTTP request
//  failed".
//

import XCTest
@testable import devgentic

final class WorkflowRetryBudgetTests: XCTestCase {

    private func actionNode(timeout: TimeInterval?, retries: Int, delay: TimeInterval = 0) -> WorkflowNode {
        var node = WorkflowNode(
            id: UUID(), kind: .action(ActionNodeConfig()),
            position: .zero, displayName: "Call API"
        )
        node.nodeConfig = WorkflowNodeConfig(
            maxNodeRetries: retries, retryDelay: delay, hardTimeout: timeout
        )
        return node
    }

    private func codeNode(timeout: TimeInterval?, retries: Int) -> WorkflowNode {
        var node = WorkflowNode(
            id: UUID(), kind: .code(CodeNodeConfig()),
            position: .zero, displayName: "Transform"
        )
        node.nodeConfig = WorkflowNodeConfig(maxNodeRetries: retries, hardTimeout: timeout)
        return node
    }

    private func subWorkflowNode(timeout: TimeInterval?, retries: Int, delay: TimeInterval = 0) -> WorkflowNode {
        var node = WorkflowNode(
            id: UUID(), kind: .profile(profileID: UUID(), profileType: .workflow),
            position: .zero, displayName: "Nested"
        )
        node.nodeConfig = WorkflowNodeConfig(maxNodeRetries: retries, retryDelay: delay, hardTimeout: timeout)
        return node
    }

    private let config = WorkflowConfig(agentProfileIDs: [])

    // MARK: - The defect

    /// THE BUG, stated as an invariant: the outer backstop must never be smaller than one attempt
    /// times the number of attempts, or every retry after the first is unreachable.
    func testOuterBudgetCoversEveryPlannedAttempt() {
        let node = actionNode(timeout: 60, retries: 3)

        let attempts = WorkflowExecutor.plannedAttempts(for: node, workflowConfig: config)
        let budget = WorkflowExecutor.outerTimeoutBudget(for: node, workflowConfig: config)

        XCTAssertEqual(attempts, 4, "3 retries means 4 attempts")
        XCTAssertEqual(budget, 240, "each attempt must get its own full 60s")
        XCTAssertGreaterThanOrEqual(budget ?? 0, 60 * Double(attempts),
                                    "a budget below attempts × limit makes later retries unreachable")
    }

    /// The retry DELAY is spent inside the outer clock too — `Task.sleep` is compute time as far as
    /// the sentinel is concerned — so omitting it would eat into the last attempt's budget.
    func testRetryDelayIsIncludedInTheBudget() {
        let node = actionNode(timeout: 30, retries: 2, delay: 5)

        // 3 attempts × 30s + 2 gaps × 5s
        XCTAssertEqual(WorkflowExecutor.outerTimeoutBudget(for: node, workflowConfig: config), 100)
    }

    // MARK: - No behaviour change where none is wanted

    /// The default. With no retries the budget is exactly one attempt, as it always was — this fix
    /// must not quietly widen the bound for the overwhelmingly common node.
    func testNoRetriesLeavesTheBudgetUnchanged() {
        let node = actionNode(timeout: 60, retries: 0)

        XCTAssertEqual(WorkflowExecutor.plannedAttempts(for: node, workflowConfig: config), 1)
        XCTAssertEqual(WorkflowExecutor.outerTimeoutBudget(for: node, workflowConfig: config), 60)
    }

    /// ⚠️ Only Action nodes retry. A Code node carrying a stored retry count must NOT get a
    /// multiplied budget — that would weaken a real bound in exchange for nothing, since the retry
    /// count is never read on that path.
    func testNonActionKindsNeverGetAMultipliedBudget() {
        let node = codeNode(timeout: 60, retries: 5)

        XCTAssertEqual(WorkflowExecutor.plannedAttempts(for: node, workflowConfig: config), 1,
                       "a Code node does not retry, whatever its stored config says")
        XCTAssertEqual(WorkflowExecutor.outerTimeoutBudget(for: node, workflowConfig: config), 60,
                       "the bound on a non-retrying kind must not be widened")
    }

    /// Timeout off stays off — unbounded is unbounded however many attempts are planned.
    func testTimeoutOffStaysOff() {
        var offConfig = WorkflowConfig(agentProfileIDs: [])
        offConfig.nodeTimeoutEnabled = false
        let node = actionNode(timeout: nil, retries: 3)

        XCTAssertNil(WorkflowExecutor.outerTimeoutBudget(for: node, workflowConfig: offConfig))
    }

    /// A per-node `hardTimeout` overrides the workflow default, and the multiplication applies to
    /// whichever one won.
    func testPerNodeTimeoutOverridesTheWorkflowDefaultBeforeMultiplying() {
        let node = actionNode(timeout: 10, retries: 1)

        XCTAssertEqual(WorkflowExecutor.outerTimeoutBudget(for: node, workflowConfig: config), 20,
                       "2 attempts × the node's own 10s, not the workflow default")
    }

    // MARK: - WF-EX3: a sub-workflow node's child canvas already bounds itself
    //
    // ⚠️ A sub-workflow node's child canvas is a fully independent `WorkflowExecutor` run — every
    // inner node on it is already bounded by ITS OWN `outerTimeoutBudget`, computed from the
    // CHILD's own config, recursively. The flat parent-level 120s default was an EXTRA,
    // uncoordinated ceiling on top of that already-correct inner bounding, sized from the parent
    // node's own guess with zero awareness of how much legitimate work the child canvas actually
    // contains — a totally healthy, individually-compliant child could still be killed mid-flight,
    // discarding everything it produced. `hardTimeout` remains the explicit opt-in escape hatch.

    /// ⚠️ THE FIX. No explicit `hardTimeout` ⇒ no outer ceiling at all for a sub-workflow node —
    /// unlike every other structural kind, which still gets the workflow's 120s default.
    func testSubWorkflowWithNoExplicitTimeout_IsUnbounded() {
        let node = subWorkflowNode(timeout: nil, retries: 0)
        XCTAssertNil(WorkflowExecutor.outerTimeoutBudget(for: node, workflowConfig: config),
                     "a sub-workflow node with no explicit hardTimeout must not inherit the workflow's 120s default")
    }

    /// The escape hatch keeps working exactly as before — an author who wants a ceiling on the
    /// whole nested run still gets one by setting `hardTimeout` deliberately, multiplied across
    /// attempts exactly like any other structural node.
    func testSubWorkflowWithExplicitHardTimeout_IsStillBounded() {
        let node = subWorkflowNode(timeout: 300, retries: 2)
        XCTAssertEqual(WorkflowExecutor.outerTimeoutBudget(for: node, workflowConfig: config), 900,
                       "3 attempts × the node's own 300s hardTimeout")
    }

    /// The workflow-level default must not leak into a sub-workflow node's fallback even when one
    /// is explicitly configured on the workflow — the exemption is unconditional, not "whichever
    /// default happens to be smaller."
    func testSubWorkflowIgnoresTheWorkflowDefault_EvenWhenOneIsSet() {
        var wideConfig = WorkflowConfig(agentProfileIDs: [])
        wideConfig.defaultNodeTimeout = 45
        let node = subWorkflowNode(timeout: nil, retries: 0)
        XCTAssertNil(WorkflowExecutor.outerTimeoutBudget(for: node, workflowConfig: wideConfig),
                     "the workflow-level default must never become a sub-workflow node's fallback")
    }

    /// ⚠️ Adversarial-review gap: every other "unbounded" test above uses `retries: 0`. The nil
    /// fallback (`outerTimeoutBudget:2277-2278`) short-circuits BEFORE `plannedAttempts`/the
    /// multiplication is ever evaluated, so `limit` is nil BY CONSTRUCTION regardless of
    /// `maxNodeRetries` — this pins that a configured retry count can't accidentally resurrect a
    /// finite budget out of a nil per-attempt value.
    func testSubWorkflowWithNoExplicitTimeout_StaysUnboundedWithRetriesConfigured() {
        let node = subWorkflowNode(timeout: nil, retries: 2)
        XCTAssertNil(WorkflowExecutor.outerTimeoutBudget(for: node, workflowConfig: config),
                     "an unbounded sub-workflow node must stay unbounded regardless of how many retries are configured")
    }

    /// ⚠️ THE TEST THAT PINS THE TERNARY'S DISCRIMINATION. Only `profileType == .workflow` gets
    /// the unbounded fallback — a `.bot`-typed profile node (which never actually reaches
    /// `outerTimeoutBudget` in production, since bot/agent nodes dispatch through `executeNode`'s
    /// own independent timeout instead — but exercises the ternary directly here, in isolation)
    /// must not be silently widened too by a careless generalization of the exemption.
    func testNonWorkflowProfileTypeStillGetsTheWorkflowDefault() {
        var node = WorkflowNode(
            id: UUID(), kind: .profile(profileID: UUID(), profileType: .bot),
            position: .zero, displayName: "Bot"
        )
        node.nodeConfig = WorkflowNodeConfig(maxNodeRetries: 0, hardTimeout: nil)
        XCTAssertEqual(WorkflowExecutor.outerTimeoutBudget(for: node, workflowConfig: config), 120,
                       "only .workflow-typed profile nodes get the unbounded fallback")
    }
}
