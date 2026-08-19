//
//  WorkflowPortRenameTests.swift
//  DevgenticTests
//
//  Regression cover for Workflow_Production_Readiness.md row WF10.
//
//  Edges address their source port by LABEL. Renaming a Condition rule or a Gate option used to
//  strand every edge wired to it: the run skipped the whole downstream branch, while the canvas
//  kept drawing the edge connected (the port-position lookup falls back to index 0 for an unknown
//  label) and validation reported nothing.
//

import XCTest
import SwiftUI
@testable import devgentic

@MainActor
final class WorkflowPortRenameTests: XCTestCase {

    private func conditionNode(rules: [ConditionRule], fallback: String = "False") -> WorkflowNode {
        var config = ConditionNodeConfig()
        config.rules = rules
        config.fallbackLabel = fallback
        return WorkflowNode(kind: .condition(config), position: .zero, displayName: "Router")
    }

    private func rename(_ node: WorkflowNode, rules: [ConditionRule], fallback: String = "False") -> WorkflowNode {
        var renamed = node
        var config = ConditionNodeConfig()
        config.rules = rules
        config.fallbackLabel = fallback
        renamed.kind = .condition(config)
        return renamed
    }

    // MARK: - WF10: renaming re-points edges

    func testRenamingAConditionRuleRepointsItsEdges() {
        let ruleA = ConditionRule(label: "True", field: .upstreamOutput, op: .contains, value: "yes")
        let ruleB = ConditionRule(label: "False", field: .upstreamOutput, op: .isEmpty, value: "")
        let condition = conditionNode(rules: [ruleA, ruleB])
        let downstream = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Next")

        let state = WorkflowCanvasState(profileID: UUID())
        state.load(from: WorkflowLayout(
            nodes: [condition, downstream],
            edges: [WorkflowEdge(sourceNodeID: condition.id, targetNodeID: downstream.id, sourcePortLabel: "True")],
            annotations: []
        ))

        // The user renames "True" → "Urgent". Rule IDENTITY is unchanged.
        var renamedRuleA = ruleA
        renamedRuleA.label = "Urgent"
        state.replaceNode(id: condition.id, with: rename(condition, rules: [renamedRuleA, ruleB]))

        XCTAssertEqual(state.edges.first?.sourcePortLabel, "Urgent",
                       "The edge must follow the rename, or its branch silently stops running")
    }

    /// Rules carry a stable `id`, so a rename PLUS a reorder in one edit must still track.
    func testRenamingAndReorderingRulesTogetherStillRepoints() {
        let ruleA = ConditionRule(label: "True", field: .upstreamOutput, op: .contains, value: "yes")
        let ruleB = ConditionRule(label: "False", field: .upstreamOutput, op: .isEmpty, value: "")
        let condition = conditionNode(rules: [ruleA, ruleB])
        let downstream = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Next")

        let state = WorkflowCanvasState(profileID: UUID())
        state.load(from: WorkflowLayout(
            nodes: [condition, downstream],
            edges: [WorkflowEdge(sourceNodeID: condition.id, targetNodeID: downstream.id, sourcePortLabel: "True")],
            annotations: []
        ))

        var renamedRuleA = ruleA
        renamedRuleA.label = "Urgent"
        state.replaceNode(id: condition.id, with: rename(condition, rules: [ruleB, renamedRuleA]))

        XCTAssertEqual(state.edges.first?.sourcePortLabel, "Urgent")
    }

    /// A rename into a label that still exists elsewhere must NOT re-point — that would move the
    /// edge onto a different branch, which is worse than leaving it dangling for the validator.
    func testRenameIntoAStillExistingLabelDoesNotRepoint() {
        let ruleA = ConditionRule(label: "A", field: .upstreamOutput, op: .contains, value: "a")
        let ruleB = ConditionRule(label: "B", field: .upstreamOutput, op: .contains, value: "b")
        let condition = conditionNode(rules: [ruleA, ruleB], fallback: "Fallback")
        let downstream = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Next")

        let state = WorkflowCanvasState(profileID: UUID())
        state.load(from: WorkflowLayout(
            nodes: [condition, downstream],
            edges: [WorkflowEdge(sourceNodeID: condition.id, targetNodeID: downstream.id, sourcePortLabel: "A")],
            annotations: []
        ))

        // Rule B is renamed to "A" — the label "A" still exists (rule A keeps it).
        var renamedB = ruleB
        renamedB.label = "A"
        state.replaceNode(id: condition.id, with: rename(condition, rules: [ruleA, renamedB], fallback: "Fallback"))

        XCTAssertEqual(state.edges.first?.sourcePortLabel, "A",
                       "The edge must stay on the port it was wired to, not be moved by a colliding rename")
    }

    func testRenamingAGateOptionRepointsItsEdges() {
        var gateConfig = GateNodeConfig()
        gateConfig.options = ["Approve", "Reject"]
        let gate = WorkflowNode(kind: .gate(gateConfig), position: .zero, displayName: "Sign-off")
        let downstream = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Ship")

        let state = WorkflowCanvasState(profileID: UUID())
        state.load(from: WorkflowLayout(
            nodes: [gate, downstream],
            edges: [WorkflowEdge(sourceNodeID: gate.id, targetNodeID: downstream.id, sourcePortLabel: "Approve")],
            annotations: []
        ))

        var renamed = gate
        var newConfig = GateNodeConfig()
        newConfig.options = ["Ship it", "Reject"]
        renamed.kind = .gate(newConfig)
        state.replaceNode(id: gate.id, with: renamed)

        XCTAssertEqual(state.edges.first?.sourcePortLabel, "Ship it")
    }

    // MARK: - Workflow Settings removal

    /// ⚠️ New workflows are BOUNDED. They used to be created with `nodeTimeoutEnabled: false` — fine
    /// while the Settings sheet let you turn it back on, but that sheet is gone (2026-08-13), so a
    /// profile created unbounded could never be bounded through any UI.
    func testNewWorkflowConfig_IsBoundedByDefault() {
        // ⚠️ Tests the FACTORY the profile-creation path uses, not a hand-built config. An earlier
        // version constructed `WorkflowConfig` directly, so a mutation reinstating
        // `nodeTimeoutEnabled: false` at the creation site passed every test.
        let config = WorkflowConfig.forNewProfile()
        XCTAssertNotNil(config.effectiveNodeTimeout,
                        "a new workflow must have a node timeout — there is no UI to add one")
        XCTAssertEqual(config.effectiveNodeTimeout, 120)
    }

    /// ⚠️ A workflow that deliberately ran unbounded keeps doing so — the stored value is still
    /// honoured, and the run logs that it is, since no UI reveals it any more.
    func testStoredTimeoutSettings_AreStillHonoured() {
        var off = WorkflowConfig(agentProfileIDs: [])
        off.nodeTimeoutEnabled = false
        XCTAssertNil(off.effectiveNodeTimeout, "an explicit OFF must survive the control's removal")

        var custom = WorkflowConfig(agentProfileIDs: [])
        custom.defaultNodeTimeout = 45
        XCTAssertEqual(custom.effectiveNodeTimeout, 45, "a stored number must survive too")

        // …and both round-trip, so an existing layout keeps them.
        let data = try? JSONEncoder().encode(off)
        let decoded = data.flatMap { try? JSONDecoder().decode(WorkflowConfig.self, from: $0) }
        XCTAssertNil(decoded?.effectiveNodeTimeout)
    }

    // MARK: - Sub-workflow nesting: cycles and depth (design-time)

    /// Builds a layout containing one sub-workflow node pointing at `target`.
    private func layoutReferencing(_ target: UUID, named: String) -> WorkflowLayout {
        WorkflowLayout(
            nodes: [WorkflowNode(kind: .profile(profileID: target, profileType: .workflow),
                                 position: .zero, displayName: named)],
            edges: [], annotations: [])
    }

    /// ⚠️ The case that used to be discoverable only by running it: A contains B, B contains A.
    /// Infinite by construction, and a pure graph property — so it belongs in the issues panel.
    func testSubWorkflowCycle_IsReportedAsAnError() {
        let rootID = UUID(), bID = UUID()
        let root = layoutReferencing(bID, named: "Sub B")
        let subs = [bID: layoutReferencing(rootID, named: "Back to root")]

        let issues = WorkflowValidator.validate(
            layout: root, profileMap: [:], subWorkflowLayouts: subs, rootProfileID: rootID)
        let cycles = issues.filter { $0.message.contains("Sub-workflow loop") }

        XCTAssertEqual(cycles.count, 1, "got: \(issues.map(\.message))")
        XCTAssertEqual(cycles.first?.severity, .error, "a loop can never run — it must block")
        XCTAssertTrue(cycles.first?.message.contains("Back to root") == true, "the loop must be named")
    }

    /// A workflow that contains ITSELF — only detectable because `rootProfileID` is supplied.
    func testSelfReferencingWorkflow_IsReportedAsAnError() {
        let rootID = UUID()
        let root = layoutReferencing(rootID, named: "Itself")

        let issues = WorkflowValidator.validate(
            layout: root, profileMap: [:],
            subWorkflowLayouts: [rootID: root], rootProfileID: rootID)

        XCTAssertTrue(issues.contains { $0.message.contains("Sub-workflow loop") && $0.severity == .error },
                      "got: \(issues.map(\.message))")
    }

    /// ⚠️ A cycle that does NOT involve the root: root → B → C → B. Every other cycle test here
    /// loops back to the root, so they all still pass if the walk only ever tracks the root on its
    /// path — which is exactly what mutation-testing exposed.
    func testCycleAmongDescendantsOnly_IsReportedAsAnError() {
        let rootID = UUID(), b = UUID(), c = UUID()
        let root = layoutReferencing(b, named: "Sub B")
        let subs = [
            b: layoutReferencing(c, named: "Sub C"),
            c: layoutReferencing(b, named: "Back to B")   // loops B ↔ C, never touching the root
        ]

        let issues = WorkflowValidator.validate(
            layout: root, profileMap: [:], subWorkflowLayouts: subs, rootProfileID: rootID)
        let cycles = issues.filter { $0.message.contains("Sub-workflow loop") }

        XCTAssertEqual(cycles.count, 1, "got: \(issues.map(\.message))")
        XCTAssertTrue(cycles.first?.message.contains("Back to B") == true,
                      "the loop must be named — got: \(cycles.first?.message ?? "")")
    }

    /// ⚠️ Depth counts THIS workflow as level 1, matching the runtime counter (incremented before
    /// its guard). With the limit at 3, a chain of 4 is the first one refused.
    func testNestingDeeperThanTheLimit_IsReportedAsAnError() {
        let rootID = UUID(), b = UUID(), c = UUID(), d = UUID()
        let root = layoutReferencing(b, named: "Level 2")
        let subs = [
            b: layoutReferencing(c, named: "Level 3"),
            c: layoutReferencing(d, named: "Level 4"),
            d: WorkflowLayout(nodes: [], edges: [], annotations: [])
        ]

        let issues = WorkflowValidator.validate(
            layout: root, profileMap: [:], subWorkflowLayouts: subs, rootProfileID: rootID)
        let depth = issues.filter { $0.message.contains("levels deep") }

        XCTAssertEqual(depth.count, 1, "got: \(issues.map(\.message))")
        XCTAssertEqual(depth.first?.severity, .error)
        XCTAssertTrue(depth.first?.message.contains("Level 4") == true, "the chain must be named")
    }

    /// The control: a chain exactly at the limit is fine.
    func testNestingAtTheLimit_IsClean() {
        let rootID = UUID(), b = UUID(), c = UUID()
        let root = layoutReferencing(b, named: "Level 2")
        let subs = [
            b: layoutReferencing(c, named: "Level 3"),
            c: WorkflowLayout(nodes: [], edges: [], annotations: [])
        ]

        let issues = WorkflowValidator.validate(
            layout: root, profileMap: [:], subWorkflowLayouts: subs, rootProfileID: rootID)
        XCTAssertFalse(issues.contains { $0.message.contains("levels deep") },
                       "\(WorkflowDepth.maxDepth) levels is allowed — got: \(issues.map(\.message))")
    }

    /// ⚠️ The same workflow used TWICE side by side is not a cycle. Only a repeat on the CURRENT
    /// PATH is — otherwise every reused sub-workflow would be flagged.
    func testSameSubWorkflowUsedTwice_IsNotACycle() {
        let rootID = UUID(), shared = UUID()
        let root = WorkflowLayout(
            nodes: [
                WorkflowNode(kind: .profile(profileID: shared, profileType: .workflow), position: .zero, displayName: "Use A"),
                WorkflowNode(kind: .profile(profileID: shared, profileType: .workflow), position: .zero, displayName: "Use B")
            ], edges: [], annotations: [])

        let issues = WorkflowValidator.validate(
            layout: root, profileMap: [:],
            subWorkflowLayouts: [shared: WorkflowLayout(nodes: [], edges: [], annotations: [])],
            rootProfileID: rootID)

        XCTAssertFalse(issues.contains { $0.message.contains("Sub-workflow loop") },
                       "reuse is not recursion — got: \(issues.map(\.message))")
    }

    /// ⚠️ Silence means "not checked", never "checked and clean". With no resolved layouts the rule
    /// must report nothing rather than guess.
    func testNoResolvedLayouts_SkipsTheNestingRuleEntirely() {
        let rootID = UUID()
        let root = layoutReferencing(rootID, named: "Itself")   // a real cycle

        let issues = WorkflowValidator.validate(layout: root, profileMap: [:])
        XCTAssertFalse(issues.contains { $0.message.contains("Sub-workflow loop") },
                       "the caller resolved nothing, so there is nothing to walk")
    }

    // MARK: - WF61: the reserved failure port

    /// ⚠️ Every kind that can FAIL must expose a wireable `error` port. The engine already
    /// activated `["error"]` on failure for structural nodes at five sites — before WF61 the canvas
    /// simply never rendered a port for it, so no edge could leave it and the whole subtree below a
    /// failed Code/Gate/Condition died silently with one info log. Pre-flight validation
    /// cannot catch that: it checks EDGES against this list, so a port that is activated but never
    /// declared is invisible to it.
    func testFailableKindsAllExposeAnErrorPort() {
        let cases: [(String, WorkflowNodeKind)] = [
            ("code", .code(CodeNodeConfig())),
            ("condition", .condition(ConditionNodeConfig())),
            ("gate", .gate({ var c = GateNodeConfig(); c.options = ["Approve", "Reject"]; return c }())),
            ("action", .action(ActionNodeConfig())),
            ("profile", .profile(profileID: UUID(), profileType: .bot))
        ]
        for (name, kind) in cases {
            let node = WorkflowNode(kind: kind, position: .zero, displayName: name)
            let ports = WorkflowCanvasState.outputPortLabels(for: node)
            XCTAssertTrue(ports.contains(WorkflowEdge.errorPortLabel),
                          "\(name) can fail but exposes no error port — got \(ports)")
        }
    }

    /// A Trigger is an entry marker that never executes, so it has nothing to route on failure.
    func testTriggerHasNoPorts() {
        let node = WorkflowNode(kind: .trigger(TriggerNodeConfig()), position: .zero, displayName: "Trigger")
        XCTAssertTrue(WorkflowCanvasState.outputPortLabels(for: node).isEmpty)
    }

    /// The rule labels still come first and in order — the error port is APPENDED, so every edge
    /// authored before WF61 keeps its port index and its position on the canvas.
    func testErrorPortIsAppended_ExistingPortOrderUnchanged() {
        var config = ConditionNodeConfig()
        config.rules = [
            ConditionRule(label: "Urgent", field: .upstreamOutput, op: .contains, value: "asap"),
            ConditionRule(label: "Routine", field: .upstreamOutput, op: .isNotEmpty, value: "")
        ]
        config.fallbackLabel = "Routine"
        let node = WorkflowNode(kind: .condition(config), position: .zero, displayName: "Router")

        XCTAssertEqual(WorkflowCanvasState.outputPortLabels(for: node),
                       ["Urgent", "Routine", WorkflowEdge.errorPortLabel])
    }

    /// ⚠️ A user may legitimately name a rule "error". Emitting it twice would render two ports that
    /// `firstIndex(of:)` collapses onto one, so an edge from the lower one would silently address
    /// the upper.
    func testUserLabelNamedErrorIsNotDuplicated() {
        var config = ConditionNodeConfig()
        config.rules = [
            ConditionRule(label: "ok", field: .upstreamOutput, op: .isNotEmpty, value: ""),
            ConditionRule(label: "error", field: .upstreamOutput, op: .isEmpty, value: "")
        ]
        config.fallbackLabel = "error"
        let node = WorkflowNode(kind: .condition(config), position: .zero, displayName: "Router")
        let ports = WorkflowCanvasState.outputPortLabels(for: node)

        XCTAssertEqual(ports.filter { $0 == WorkflowEdge.errorPortLabel }.count, 1, "got \(ports)")

        let issues = WorkflowValidator.validate(
            layout: WorkflowLayout(nodes: [node], edges: [], annotations: []), profileMap: [:])
        let collision = issues.filter { $0.message.contains("reserved failure port") }
        XCTAssertEqual(collision.count, 1, "the collision must be reported — got: \(issues.map(\.message))")
        XCTAssertEqual(collision.first?.severity, .warning,
                       "must NOT block: a workflow may already carry a rule named 'error'")
    }

    // MARK: - Disconnected pipelines ("islands")

    /// Two clusters with no path between them is two workflows sharing one canvas: both entry
    /// nodes get the prompt, both run, both terminals land in one answer. Warned, not blocked.
    func testDisconnectedPipelinesAreWarned() {
        let a1 = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "MLX Bot")
        let a2 = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Agent 1")
        let b1 = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Ollama Bot")
        let b2 = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Ollama Agent")

        let layout = WorkflowLayout(
            nodes: [a1, a2, b1, b2],
            edges: [WorkflowEdge(sourceNodeID: a1.id, targetNodeID: a2.id),
                    WorkflowEdge(sourceNodeID: b1.id, targetNodeID: b2.id)],
            annotations: []
        )

        let issues = WorkflowValidator.validate(layout: layout, profileMap: [:])
        let islands = issues.filter { $0.message.contains("separate pipelines") }

        XCTAssertEqual(islands.count, 1, "got: \(issues.map(\.message))")
        XCTAssertEqual(islands.first?.severity, .warning, "it runs correctly — must not block")
        XCTAssertTrue(islands.first?.message.contains("MLX Bot") == true, "the split must be named")
    }

    /// ⚠️ The control that matters: MULTIPLE ENTRY NODES in ONE connected graph is a legitimate
    /// pattern (two sources feeding one synthesizer) and must NOT be flagged.
    func testMultipleEntryNodesInOneGraphAreNotFlagged() {
        let src1 = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Research Web")
        let src2 = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Research Docs")
        let sink = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Synthesizer")

        let layout = WorkflowLayout(
            nodes: [src1, src2, sink],
            edges: [WorkflowEdge(sourceNodeID: src1.id, targetNodeID: sink.id),
                    WorkflowEdge(sourceNodeID: src2.id, targetNodeID: sink.id)],
            annotations: []
        )

        let issues = WorkflowValidator.validate(layout: layout, profileMap: [:])
        XCTAssertFalse(issues.contains { $0.message.contains("separate pipelines") },
                       "two starts feeding one node is ONE pipeline — got: \(issues.map(\.message))")
    }

    // MARK: - WF10: the validator backstop

    /// A DELETED port cannot be re-pointed, and neither can a layout broken before the fix. The
    /// validator has to report it, because nothing else in the app does.
    func testEdgeOnANonExistentPortIsAValidationError() {
        let ruleA = ConditionRule(label: "True", field: .upstreamOutput, op: .contains, value: "yes")
        let ruleB = ConditionRule(label: "False", field: .upstreamOutput, op: .isEmpty, value: "")
        let condition = conditionNode(rules: [ruleA, ruleB])
        let downstream = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Next")

        let layout = WorkflowLayout(
            nodes: [condition, downstream],
            edges: [WorkflowEdge(sourceNodeID: condition.id, targetNodeID: downstream.id, sourcePortLabel: "Deleted")],
            annotations: []
        )

        let issues = WorkflowValidator.validate(layout: layout, profileMap: [:])

        // A WARNING, not an error: the branch is genuinely dead, but blocking the whole run would
        // stop workflows that have been living with a dangling edge while the rest of them worked.
        // The complaint was that the failure was invisible, not that it was tolerated.
        let dangling = issues.filter { $0.message.contains("no longer exists") }
        XCTAssertEqual(dangling.count, 1, "A dangling port must be reported — got: \(issues.map(\.message))")
        XCTAssertEqual(dangling.first?.severity, .warning,
                       "It must not block the run — that would trade a dead branch for a dead workflow")
    }

    /// The control: a correctly wired multi-port node produces no dangling-port error, so the new
    /// rule cannot be passing merely by flagging everything.
    func testCorrectlyWiredPortsProduceNoDanglingPortError() {
        let ruleA = ConditionRule(label: "True", field: .upstreamOutput, op: .contains, value: "yes")
        let ruleB = ConditionRule(label: "False", field: .upstreamOutput, op: .isEmpty, value: "")
        let condition = conditionNode(rules: [ruleA, ruleB])
        let downstream = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Next")

        let layout = WorkflowLayout(
            nodes: [condition, downstream],
            edges: [WorkflowEdge(sourceNodeID: condition.id, targetNodeID: downstream.id, sourcePortLabel: "True")],
            annotations: []
        )

        let issues = WorkflowValidator.validate(layout: layout, profileMap: [:])

        XCTAssertFalse(issues.contains { $0.message.contains("no longer exists") },
                       "A correctly wired port must not be flagged — got: \(issues.map(\.message))")
    }

    /// Single-port kinds (profile default, code) must not be swept up by the new rule.
    func testSinglePortNodesAreNotFlagged() {
        let code = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Transform")
        let next = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Next")

        let layout = WorkflowLayout(
            nodes: [code, next],
            edges: [WorkflowEdge(sourceNodeID: code.id, targetNodeID: next.id, sourcePortLabel: nil)],
            annotations: []
        )

        let flagged = WorkflowValidator.validate(layout: layout, profileMap: [:])
            .filter { $0.message.contains("no longer exists") }

        XCTAssertTrue(flagged.isEmpty)
    }
}
