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
}
