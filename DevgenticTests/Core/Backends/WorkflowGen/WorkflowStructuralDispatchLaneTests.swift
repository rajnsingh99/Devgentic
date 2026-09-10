// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh

import XCTest
@testable import devgentic

/// ⚠️ WF-CC5 — Router `.condition` AI-Classifier fallback calls and nested sub-workflow nodes can
/// each independently reach the single global MLX slot exactly like profile nodes do (WF-CC2), but
/// the structural task group was left entirely unpartitioned until this fix. Pure, synchronous
/// tests over `structuralDispatchLanes` — no executor, no async, no model — mirroring
/// `WorkflowMLXDispatchLaneTests.swift`'s structure for its profile-node sibling.
///
/// ⚠️ A nested sub-workflow gets a UNIQUE key per node — deliberately coarser than a Router's
/// precise per-model key. See `structuralDispatchLanes`'s own doc comment for why: its real MLX
/// demand lives in a child layout this dispatch loop cannot cheaply resolve, and even if it could,
/// a sub-workflow can use multiple models across its OWN levels over time, so no single static key
/// could represent it the way one Router's one pinned fallback model does. Two sub-workflows (or a
/// sub-workflow beside a Router) therefore ALWAYS split, even when neither would ever touch MLX —
/// see `testTwoSubWorkflows_AlwaysSplit`.
///
/// The state-visibility half of this fix (every lane must read the SAME level-wide `state`
/// snapshot, never one re-taken per lane) is not testable here — this function does not take
/// `state` at all, by design — see `WorkflowStructuralLaneStateIsolationTests` for the end-to-end
/// regression guard.
final class WorkflowStructuralDispatchLaneTests: XCTestCase {

    private func conditionNode(_ name: String, model: String?, fallbackEnabled: Bool = true) -> WorkflowNode {
        var config = ConditionNodeConfig()
        config.rules = [ConditionRule(label: "A", field: .upstreamOutput, op: .contains, value: "x")]
        config.llmFallbackEnabled = fallbackEnabled
        config.llmModelName = model
        return WorkflowNode(kind: .condition(config), position: .zero, displayName: name)
    }

    private func subWorkflowNode(_ name: String, profileID: UUID = UUID()) -> WorkflowNode {
        WorkflowNode(kind: .profile(profileID: profileID, profileType: .workflow), position: .zero, displayName: name)
    }

    private func codeNode(_ name: String) -> WorkflowNode {
        WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: name)
    }

    private func gateNode(_ name: String) -> WorkflowNode {
        WorkflowNode(kind: .gate(GateNodeConfig()), position: .zero, displayName: name)
    }

    private func names(_ lanes: [(slot: String?, members: [WorkflowNode])]) -> [[String]] {
        lanes.map { $0.members.map(\.displayName) }
    }

    // MARK: - Router (.condition) precise-model keying — same shape as profileDispatchLanes

    func testTwoRoutersDifferentModels_Split() {
        let lanes = WorkflowExecutor.structuralDispatchLanes([
            codeNode("Code"),
            conditionNode("R1", model: "qwen3-8b"),
            conditionNode("R2", model: "llama3-3b")
        ])
        XCTAssertEqual(lanes.count, 2, "two DIFFERENT MLX models must be dispatched in two lanes")
        XCTAssertEqual(names(lanes), [["Code", "R1"], ["R2"]],
                       "the unconstrained Code node rides with the FIRST lane, same as profileDispatchLanes")
    }

    /// ⚠️ THE TEST THAT FORBIDS OVER-PARTITIONING for Routers, mirroring
    /// `WorkflowMLXDispatchLaneTests.testOneMLXModel_SingleLane`.
    func testTwoRoutersSameModel_SingleLane() {
        let lanes = WorkflowExecutor.structuralDispatchLanes([
            conditionNode("R1", model: "qwen3-8b"),
            conditionNode("R2", model: "qwen3-8b")
        ])
        XCTAssertEqual(lanes.count, 1,
                       "same-model Routers share one container (MLXService early-return) — splitting them costs parallelism for zero benefit")
    }

    func testRouterWithFallbackDisabled_NeverContends() {
        let lanes = WorkflowExecutor.structuralDispatchLanes([
            conditionNode("R1", model: "qwen3-8b", fallbackEnabled: false),
            conditionNode("R2", model: "llama3-3b")
        ])
        XCTAssertEqual(lanes.count, 1, "a Router with its AI Classifier switched off never loads a model")
        XCTAssertEqual(names(lanes), [["R1", "R2"]],
                       "R1 rides along unconstrained beside R2's single MLX-relevant lane — nothing to split")
    }

    func testRouterWithBlankModelName_NeverContends() {
        let lanes = WorkflowExecutor.structuralDispatchLanes([
            conditionNode("R1", model: nil),
            conditionNode("R2", model: "llama3-3b")
        ])
        XCTAssertEqual(lanes.count, 1, "an unconfigured model name binds no slot")
    }

    // MARK: - Nested sub-workflow — always exclusive, never coalesced

    /// ⚠️ THE TEST THAT PINS THE CONSERVATIVE CHOICE. Two sub-workflows always serialize against
    /// each other, even though this test constructs neither with any visible MLX demand at all —
    /// see the class doc comment for why precise resolution isn't attempted.
    func testTwoSubWorkflows_AlwaysSplit() {
        let lanes = WorkflowExecutor.structuralDispatchLanes([
            subWorkflowNode("Nested A"),
            subWorkflowNode("Nested B")
        ])
        XCTAssertEqual(lanes.count, 2)
        XCTAssertEqual(names(lanes), [["Nested A"], ["Nested B"]])
    }

    /// ⚠️ Distinguishes the shipped implementation (key = the NODE's own identity,
    /// `"workflow:\(node.id.uuidString)"`) from the plausible alternative (key = the REFERENCED
    /// workflow profile's id) that every OTHER sub-workflow test in this file cannot rule out,
    /// because they always give each node a distinct, freshly-generated `profileID` — under which
    /// both implementations produce identical lane counts. Two DIFFERENT nodes pointing at the SAME
    /// referenced workflow profile is the one shape that tells them apart: keying by the referenced
    /// profile would coalesce them into ONE lane; keying by node identity — the shipped behavior,
    /// and the only one that's actually SAFE, since one sub-workflow node's own execution contends
    /// with a SECOND, independent invocation of the exact same child canvas exactly as much as it
    /// would with any other sub-workflow — keeps them in TWO.
    func testSubWorkflowKeyedByNodeIdentity_NotByReferencedWorkflowProfile() {
        let sharedProfileID = UUID()
        let lanes = WorkflowExecutor.structuralDispatchLanes([
            subWorkflowNode("Call A", profileID: sharedProfileID),
            subWorkflowNode("Call B", profileID: sharedProfileID)
        ])
        XCTAssertEqual(lanes.count, 2,
                       "two DIFFERENT nodes referencing the SAME sub-workflow profile must still get separate lanes — keying by profile instead of node identity would silently coalesce them into one")
    }

    /// Even the SAME model name as the Router: a sub-workflow's key is never a model name at all,
    /// so it can never coalesce with a Router's slot the way two same-model Routers do.
    func testSubWorkflowBesideRouter_AlwaysSplits_RegardlessOfModel() {
        let lanes = WorkflowExecutor.structuralDispatchLanes([
            conditionNode("R1", model: "qwen3-8b"),
            subWorkflowNode("Nested")
        ])
        XCTAssertEqual(lanes.count, 2)
    }

    func testSingleSubWorkflow_NoSplit() {
        let lanes = WorkflowExecutor.structuralDispatchLanes([
            codeNode("Code"),
            gateNode("Gate"),
            subWorkflowNode("Nested")
        ])
        XCTAssertEqual(lanes.count, 1,
                       "one sub-workflow with no other MLX-relevant sibling has nothing to contend with — full parallelism preserved")
        XCTAssertEqual(names(lanes), [["Code", "Gate", "Nested"]])
    }

    func testThreeSubWorkflows_ThreeExclusiveLanes() {
        let lanes = WorkflowExecutor.structuralDispatchLanes([
            subWorkflowNode("A"), subWorkflowNode("B"), subWorkflowNode("C")
        ])
        XCTAssertEqual(lanes.count, 3, "every sub-workflow gets its own exclusive lane relative to every other one")
        XCTAssertEqual(names(lanes), [["A"], ["B"], ["C"]])
    }

    /// ⚠️ Untested-at-scale gap from adversarial review: every other sub-workflow test tops out at
    /// N=3. This pins that the partition stays O(N) — no quadratic blow-up, no truncation, no
    /// crash — and that first-seen order is preserved at a wider fan-out, the shape a "parallel
    /// branches over different inputs" canvas produces. The wall-clock cost of this — N sub-workflow
    /// siblings now fully serialize even when none of them touch MLX — is the documented,
    /// deliberate conservative tradeoff (see the class header and `structuralDispatchLanes`'s own
    /// doc comment), not something this test tries to change.
    func testFiveSubWorkflows_FiveExclusiveLanesInDeclarationOrder() {
        let lanes = WorkflowExecutor.structuralDispatchLanes([
            subWorkflowNode("A"), subWorkflowNode("B"), subWorkflowNode("C"),
            subWorkflowNode("D"), subWorkflowNode("E")
        ])
        XCTAssertEqual(lanes.count, 5)
        XCTAssertEqual(names(lanes), [["A"], ["B"], ["C"], ["D"], ["E"]])
    }

    // MARK: - Provably MLX-inert kinds never contend, and never trigger a split by themselves

    func testCodeAndGateNeverContend() {
        let lanes = WorkflowExecutor.structuralDispatchLanes([
            codeNode("Code"), gateNode("Gate")
        ])
        XCTAssertEqual(lanes.count, 1)
        XCTAssertNil(lanes[0].slot)
    }

    func testEmptyLevel_ProducesNoLanes() {
        XCTAssertTrue(WorkflowExecutor.structuralDispatchLanes([]).isEmpty,
                      "an empty level must produce no lanes, not one empty lane that logs a split")
    }

    func testSingleNode_SingleLane() {
        let lanes = WorkflowExecutor.structuralDispatchLanes([codeNode("Code")])
        XCTAssertEqual(lanes.count, 1)
        XCTAssertEqual(names(lanes), [["Code"]])
    }
}
