// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  WorkflowPortRenameTests.swift
//  DevgenticTests
//
//  Regression cover for Workflow_Production_Readiness.md rows WF10, WF-CS1, WF-CS2, WF-CS12.
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

    // MARK: - WF-CS1 / WF-CS12: combined edits on a Router

    /// [WF-CS1] A shift-rename permutation in ONE Save: Low→High while High→Critical. The old
    /// filter dropped any entry whose OLD label survives on the new node, so only Low→High was
    /// applied — High's edge silently started firing on the renamed Low rule, and Critical's port
    /// lost its edge. The map is applied simultaneously, so both halves must track.
    func testShiftRenamePermutationRepointsBothEdges() {
        let ruleLow = ConditionRule(label: "Low", field: .upstreamOutput, op: .contains, value: "low")
        let ruleHigh = ConditionRule(label: "High", field: .upstreamOutput, op: .contains, value: "high")
        let condition = conditionNode(rules: [ruleLow, ruleHigh], fallback: "")
        let nodeA = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "A")
        let nodeB = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "B")

        let state = WorkflowCanvasState(profileID: UUID())
        state.load(from: WorkflowLayout(
            nodes: [condition, nodeA, nodeB],
            edges: [WorkflowEdge(sourceNodeID: condition.id, targetNodeID: nodeA.id, sourcePortLabel: "Low"),
                    WorkflowEdge(sourceNodeID: condition.id, targetNodeID: nodeB.id, sourcePortLabel: "High")],
            annotations: []
        ))

        var renamedLow = ruleLow; renamedLow.label = "High"
        var renamedHigh = ruleHigh; renamedHigh.label = "Critical"
        state.replaceNode(id: condition.id, with: rename(condition, rules: [renamedLow, renamedHigh], fallback: ""))

        let byTarget = Dictionary(uniqueKeysWithValues: state.edges.map { ($0.targetNodeID, $0.sourcePortLabel) })
        XCTAssertEqual(byTarget[nodeA.id], "High",
                       "the Low rule's edge must follow its rule to 'High'")
        XCTAssertEqual(byTarget[nodeB.id], "Critical",
                       "the High rule's edge must follow its rule to 'Critical' — leaving it on 'High' runs it on the WRONG rule")
    }

    /// [WF-CS1] The degenerate permutation: a straight swap A↔B. The old filter dropped BOTH
    /// entries, leaving both edges silently on the wrong branches.
    func testSwapRenameRepointsBothEdges() {
        let ruleA = ConditionRule(label: "A", field: .upstreamOutput, op: .contains, value: "a")
        let ruleB = ConditionRule(label: "B", field: .upstreamOutput, op: .contains, value: "b")
        let condition = conditionNode(rules: [ruleA, ruleB], fallback: "")
        let nodeA = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "A")
        let nodeB = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "B")

        let state = WorkflowCanvasState(profileID: UUID())
        state.load(from: WorkflowLayout(
            nodes: [condition, nodeA, nodeB],
            edges: [WorkflowEdge(sourceNodeID: condition.id, targetNodeID: nodeA.id, sourcePortLabel: "A"),
                    WorkflowEdge(sourceNodeID: condition.id, targetNodeID: nodeB.id, sourcePortLabel: "B")],
            annotations: []
        ))

        var swappedA = ruleA; swappedA.label = "B"
        var swappedB = ruleB; swappedB.label = "A"
        state.replaceNode(id: condition.id, with: rename(condition, rules: [swappedA, swappedB], fallback: ""))

        let byTarget = Dictionary(uniqueKeysWithValues: state.edges.map { ($0.targetNodeID, $0.sourcePortLabel) })
        XCTAssertEqual(byTarget[nodeA.id], "B")
        XCTAssertEqual(byTarget[nodeB.id], "A")
    }

    /// [WF-CS12] The Router inspector clears a legacy catch-all on EVERY Save. When the user also
    /// renames the rule the catch-all names — decode guarantees it names a real rule — the old
    /// fallback arm ran after the rules loop and clobbered that rule's rename entry with
    /// `map["B"] = ""`, re-pointing its edges to a nonexistent empty port.
    func testClearingLegacyCatchAllDoesNotClobberARuleRename() {
        let ruleA = ConditionRule(label: "A", field: .upstreamOutput, op: .contains, value: "a")
        let ruleB = ConditionRule(label: "B", field: .upstreamOutput, op: .contains, value: "b")
        let condition = conditionNode(rules: [ruleA, ruleB], fallback: "B")
        let downstream = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Next")

        let state = WorkflowCanvasState(profileID: UUID())
        state.load(from: WorkflowLayout(
            nodes: [condition, downstream],
            edges: [WorkflowEdge(sourceNodeID: condition.id, targetNodeID: downstream.id, sourcePortLabel: "B")],
            annotations: []
        ))

        // One Save: rule B renamed to "C", catch-all cleared (what the inspector always does now).
        var renamedB = ruleB; renamedB.label = "C"
        state.replaceNode(id: condition.id, with: rename(condition, rules: [ruleA, renamedB], fallback: ""))

        XCTAssertEqual(state.edges.first?.sourcePortLabel, "C",
                       "the renamed rule's edge must follow the rename — '' points at no port and kills the branch")
    }

    /// [WF-CS12] The control: clearing the catch-all WITHOUT renaming anything must leave edges
    /// alone — the port lives on under the rule's own label.
    func testClearingLegacyCatchAllAloneLeavesEdgesUntouched() {
        let ruleA = ConditionRule(label: "A", field: .upstreamOutput, op: .contains, value: "a")
        let ruleB = ConditionRule(label: "B", field: .upstreamOutput, op: .contains, value: "b")
        let condition = conditionNode(rules: [ruleA, ruleB], fallback: "B")
        let downstream = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Next")

        let state = WorkflowCanvasState(profileID: UUID())
        state.load(from: WorkflowLayout(
            nodes: [condition, downstream],
            edges: [WorkflowEdge(sourceNodeID: condition.id, targetNodeID: downstream.id, sourcePortLabel: "B")],
            annotations: []
        ))

        state.replaceNode(id: condition.id, with: rename(condition, rules: [ruleA, ruleB], fallback: ""))

        XCTAssertEqual(state.edges.first?.sourcePortLabel, "B")
    }

    /// A PHANTOM catch-all (names no rule — possible in memory pre-normalization) is its own port,
    /// so renaming it is still a tracked rename. Pins the one legitimate case the old fallback arm
    /// handled, so the CS12 fix cannot pass by simply never mapping the fallback.
    func testPhantomCatchAllRenameStillRepoints() {
        let ruleA = ConditionRule(label: "A", field: .upstreamOutput, op: .contains, value: "a")
        let condition = conditionNode(rules: [ruleA], fallback: "Legacy")
        let downstream = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Next")

        let state = WorkflowCanvasState(profileID: UUID())
        state.load(from: WorkflowLayout(
            nodes: [condition, downstream],
            edges: [WorkflowEdge(sourceNodeID: condition.id, targetNodeID: downstream.id, sourcePortLabel: "Legacy")],
            annotations: []
        ))

        state.replaceNode(id: condition.id, with: rename(condition, rules: [ruleA], fallback: "Default"))

        XCTAssertEqual(state.edges.first?.sourcePortLabel, "Default")
    }

    // MARK: - WF-CS2: Gate renames combined with count changes

    private func gateNode(options: [String]) -> WorkflowNode {
        var config = GateNodeConfig()
        config.options = options
        return WorkflowNode(kind: .gate(config), position: .zero, displayName: "Sign-off")
    }

    private func regated(_ node: WorkflowNode, options: [String]) -> WorkflowNode {
        var renamed = node
        var config = GateNodeConfig()
        config.options = options
        renamed.kind = .gate(config)
        return renamed
    }

    /// [WF-CS2] The canonical failure: rename "Approve"→"Ship it" AND click Add Option in one
    /// Save. The old `guard count == count` abandoned the whole map, stranding the edge on
    /// "Approve" — a port that no longer exists — while the canvas kept drawing it connected.
    func testGateRenameWithAddOptionRepointsTheEdge() {
        let gate = gateNode(options: ["Approve", "Reject"])
        let deploy = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Deploy")

        let state = WorkflowCanvasState(profileID: UUID())
        state.load(from: WorkflowLayout(
            nodes: [gate, deploy],
            edges: [WorkflowEdge(sourceNodeID: gate.id, targetNodeID: deploy.id, sourcePortLabel: "Approve")],
            annotations: []
        ))

        state.replaceNode(id: gate.id, with: regated(gate, options: ["Ship it", "Reject", "Hold"]))

        XCTAssertEqual(state.edges.first?.sourcePortLabel, "Ship it",
                       "the rename must track through the Add Option — or the deploy branch silently never runs")
    }

    /// A pure delete must NOT invent a rename: the removed option's edge dangles for the
    /// validator, and the survivors' edges stay put.
    func testGateDeleteAloneLeavesEdgesAlone() {
        let gate = gateNode(options: ["A", "B", "C"])
        let nodeB = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "B")
        let nodeC = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "C")

        let state = WorkflowCanvasState(profileID: UUID())
        state.load(from: WorkflowLayout(
            nodes: [gate, nodeB, nodeC],
            edges: [WorkflowEdge(sourceNodeID: gate.id, targetNodeID: nodeB.id, sourcePortLabel: "B"),
                    WorkflowEdge(sourceNodeID: gate.id, targetNodeID: nodeC.id, sourcePortLabel: "C")],
            annotations: []
        ))

        state.replaceNode(id: gate.id, with: regated(gate, options: ["A", "C"]))

        let byTarget = Dictionary(uniqueKeysWithValues: state.edges.map { ($0.targetNodeID, $0.sourcePortLabel) })
        XCTAssertEqual(byTarget[nodeB.id], "B", "a deleted option's edge dangles — it must not be re-pointed anywhere")
        XCTAssertEqual(byTarget[nodeC.id], "C", "a surviving option's edge must not move")
    }

    /// ⚠️ A Save whose count DECREASED is ambiguous by construction — deleting row B then renaming
    /// row C is byte-identical to renaming row B then deleting row C — and guessing wrong would
    /// re-point an edge onto a live WRONG branch. Conservative: no re-pointing, validator reports.
    func testGateCountDecreaseWithRenameStaysConservative() {
        let gate = gateNode(options: ["A", "B", "C"])
        let downstream = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Next")

        let state = WorkflowCanvasState(profileID: UUID())
        state.load(from: WorkflowLayout(
            nodes: [gate, downstream],
            edges: [WorkflowEdge(sourceNodeID: gate.id, targetNodeID: downstream.id, sourcePortLabel: "A")],
            annotations: []
        ))

        // Could be: rename A→X + delete B, or delete A + rename B→X. No way to tell.
        state.replaceNode(id: gate.id, with: regated(gate, options: ["X", "C"]))

        XCTAssertEqual(state.edges.first?.sourcePortLabel, "A",
                       "an ambiguous shrink must leave the edge dangling for the validator, never guess a live branch")
    }

    /// A rename candidate must be text that is genuinely NEW — a surviving option that merely
    /// shifted into the vanished option's index must not capture its edge.
    func testGateRenameDoesNotGrabAShiftedSurvivor() {
        let gate = gateNode(options: ["A", "B", "C"])
        let nodeB = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "B")

        let state = WorkflowCanvasState(profileID: UUID())
        state.load(from: WorkflowLayout(
            nodes: [gate, nodeB],
            edges: [WorkflowEdge(sourceNodeID: gate.id, targetNodeID: nodeB.id, sourcePortLabel: "B")],
            annotations: []
        ))

        // B deleted, C shifted into its index, two options added — count grew, but index 1 now
        // holding "C" (a survivor) must not read as B→C.
        state.replaceNode(id: gate.id, with: regated(gate, options: ["A", "C", "D", "E"]))

        XCTAssertEqual(state.edges.first?.sourcePortLabel, "B",
                       "'C' is a shifted survivor, not B's new name — re-pointing would fire B's branch on C's choice")
    }

    // MARK: - Adversarial-review hardening: masked deletes, collisions, the reserved label

    /// ⚠️ [Found on adversarial review] "Count didn't shrink" is NOT "nothing was deleted": deleting
    /// the LAST row and clicking Add Option grows the count while producing the byte-identical
    /// shape of a rename. Guessing rename re-points the deleted option's edge onto a brand-new
    /// option — silent wrong-branch routing where the old code left a validator-visible dangle.
    func testGateSuffixDeleteWithAddsDoesNotInventARename() {
        let gate = gateNode(options: ["A", "B", "C"])
        let cleanup = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Cleanup")

        let state = WorkflowCanvasState(profileID: UUID())
        state.load(from: WorkflowLayout(
            nodes: [gate, cleanup],
            edges: [WorkflowEdge(sourceNodeID: gate.id, targetNodeID: cleanup.id, sourcePortLabel: "C")],
            annotations: []
        ))

        // Delete row C, Add Option twice: count 3 → 4, "Option 3" lands at C's old index.
        state.replaceNode(id: gate.id, with: regated(gate, options: ["A", "B", "Option 3", "Option 4"]))

        XCTAssertEqual(state.edges.first?.sourcePortLabel, "C",
                       "a suffix delete masked by adds must dangle, not wire the deleted branch to a fresh option")
    }

    /// The compound form: delete an interior row AND rename the last row AND add, in one Save.
    /// The displaced survivor proves the delete, which must refuse the WHOLE map.
    func testGateCompoundDeleteRenameAddsRefusesTheWholeMap() {
        let gate = gateNode(options: ["Approve", "Reject", "Escalate"])
        let rollback = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Rollback")
        let page = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Page")

        let state = WorkflowCanvasState(profileID: UUID())
        state.load(from: WorkflowLayout(
            nodes: [gate, rollback, page],
            edges: [WorkflowEdge(sourceNodeID: gate.id, targetNodeID: rollback.id, sourcePortLabel: "Reject"),
                    WorkflowEdge(sourceNodeID: gate.id, targetNodeID: page.id, sourcePortLabel: "Escalate")],
            annotations: []
        ))

        // Delete "Reject", rename "Escalate"→"Defer", Add Option — nothing here is provable.
        state.replaceNode(id: gate.id, with: regated(gate, options: ["Approve", "Defer", "Option 3", "Option 4"]))

        let byTarget = Dictionary(uniqueKeysWithValues: state.edges.map { ($0.targetNodeID, $0.sourcePortLabel) })
        XCTAssertEqual(byTarget[rollback.id], "Reject",
                       "the deleted option's edge must not fire on the renamed row's choice")
        XCTAssertEqual(byTarget[page.id], "Escalate",
                       "the renamed row cannot be told apart from a delete here — dangle, don't guess")
    }

    /// A displaced survivor proves a delete even at EQUAL count (delete + rename + add): the
    /// vanished first row here was DELETED, not renamed — its old neighbour's shift is the tell.
    func testGateDisplacedSurvivorRefusesEvenAtEqualCount() {
        let gate = gateNode(options: ["A", "B", "C"])
        let nodeA = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "A")

        let state = WorkflowCanvasState(profileID: UUID())
        state.load(from: WorkflowLayout(
            nodes: [gate, nodeA],
            edges: [WorkflowEdge(sourceNodeID: gate.id, targetNodeID: nodeA.id, sourcePortLabel: "A")],
            annotations: []
        ))

        // Delete A, rename B→X, add Y: [A,B,C] → [X,C,Y]. Count is EQUAL, but survivor C moved
        // 3rd → 2nd — positional identity is broken for the whole edit.
        state.replaceNode(id: gate.id, with: regated(gate, options: ["X", "C", "Y"]))

        XCTAssertEqual(state.edges.first?.sourcePortLabel, "A",
                       "A was deleted — mapping it onto X (really B's rename) fires the deleted branch on B's choice")
    }

    /// The boundary being kept: at EQUAL count a suffix rename still tracks — that is the
    /// long-shipped zip semantics, ambiguity and all. Only count GROWTH refuses the suffix.
    func testGateLastRowRenameAtEqualCountStillTracks() {
        let gate = gateNode(options: ["A", "B"])
        let downstream = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Next")

        let state = WorkflowCanvasState(profileID: UUID())
        state.load(from: WorkflowLayout(
            nodes: [gate, downstream],
            edges: [WorkflowEdge(sourceNodeID: gate.id, targetNodeID: downstream.id, sourcePortLabel: "B")],
            annotations: []
        ))

        state.replaceNode(id: gate.id, with: regated(gate, options: ["A", "X"]))

        XCTAssertEqual(state.edges.first?.sourcePortLabel, "X")
    }

    /// ⚠️ [Found on adversarial review] The destination filter had ZERO discriminating coverage —
    /// deleting it left the whole suite green. This pins it: two rows renamed to the SAME text
    /// (the gate inspector never dedups) collapse onto one port, and re-pointing either edge
    /// would fire both branches on that single choice.
    func testGateDestinationCollisionRefusesBothRenames() {
        let gate = gateNode(options: ["A", "B"])
        let downstream = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Next")

        let state = WorkflowCanvasState(profileID: UUID())
        state.load(from: WorkflowLayout(
            nodes: [gate, downstream],
            edges: [WorkflowEdge(sourceNodeID: gate.id, targetNodeID: downstream.id, sourcePortLabel: "B")],
            annotations: []
        ))

        state.replaceNode(id: gate.id, with: regated(gate, options: ["X", "X"]))

        XCTAssertEqual(state.edges.first?.sourcePortLabel, "B",
                       "a rename onto a duplicated destination must dangle, not pick one of the collapsed ports")
    }

    /// [Found on adversarial review] A label shared with a rule that KEEPS it: the divergent-rename
    /// check can't see a keeper (it never enters the map), so the renamed twin used to steal the
    /// keeper's edges off a still-live port — silently, since nothing dangles.
    func testConditionSharedLabelKeeperRetainsItsEdge() {
        let keeper = ConditionRule(label: "Escalation", field: .upstreamOutput, op: .contains, value: "a")
        let renamed = ConditionRule(label: "Escalation", field: .upstreamOutput, op: .contains, value: "b")
        let condition = conditionNode(rules: [keeper, renamed], fallback: "")
        let downstream = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Next")

        let state = WorkflowCanvasState(profileID: UUID())
        state.load(from: WorkflowLayout(
            nodes: [condition, downstream],
            edges: [WorkflowEdge(sourceNodeID: condition.id, targetNodeID: downstream.id, sourcePortLabel: "Escalation")],
            annotations: []
        ))

        var urgent = renamed; urgent.label = "Urgent"
        state.replaceNode(id: condition.id, with: rename(condition, rules: [keeper, urgent], fallback: ""))

        XCTAssertEqual(state.edges.first?.sourcePortLabel, "Escalation",
                       "the keeper still owns this label — the edge must stay on the live port, not follow the twin")
    }

    /// Duplicated old labels renamed to DIFFERENT things have no single owner — refuse, don't
    /// let the last writer win. One test per arm, so neither ambiguity block can be refactored away.
    func testConditionDivergentDuplicateRenamesAreRefused() {
        let r1 = ConditionRule(label: "Pending", field: .upstreamOutput, op: .contains, value: "a")
        let r2 = ConditionRule(label: "Pending", field: .upstreamOutput, op: .contains, value: "b")
        let condition = conditionNode(rules: [r1, r2], fallback: "")
        let downstream = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Next")

        let state = WorkflowCanvasState(profileID: UUID())
        state.load(from: WorkflowLayout(
            nodes: [condition, downstream],
            edges: [WorkflowEdge(sourceNodeID: condition.id, targetNodeID: downstream.id, sourcePortLabel: "Pending")],
            annotations: []
        ))

        var retry = r1; retry.label = "Retry"
        var abort = r2; abort.label = "Abort"
        state.replaceNode(id: condition.id, with: rename(condition, rules: [retry, abort], fallback: ""))

        XCTAssertEqual(state.edges.first?.sourcePortLabel, "Pending")
    }

    func testGateDivergentDuplicateRenamesAreRefused() {
        let gate = gateNode(options: ["Pending", "Pending"])
        let downstream = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Next")

        let state = WorkflowCanvasState(profileID: UUID())
        state.load(from: WorkflowLayout(
            nodes: [gate, downstream],
            edges: [WorkflowEdge(sourceNodeID: gate.id, targetNodeID: downstream.id, sourcePortLabel: "Pending")],
            annotations: []
        ))

        state.replaceNode(id: gate.id, with: regated(gate, options: ["Retry", "Abort"]))

        XCTAssertEqual(state.edges.first?.sourcePortLabel, "Pending")
    }

    /// [Found on adversarial review] The reserved failure label is invisible to destination
    /// counting (`withErrorPort` dedups it). Renaming AWAY from a rule named "error" must not
    /// move the edge — the port survives, and the engine activates it on every failure.
    func testRuleNamedErrorKeepsFailureRoutingOnRename() {
        let ok = ConditionRule(label: "ok", field: .upstreamOutput, op: .isNotEmpty, value: "")
        let err = ConditionRule(label: "error", field: .upstreamOutput, op: .isEmpty, value: "")
        let condition = conditionNode(rules: [ok, err], fallback: "")
        let recovery = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Recovery")

        let state = WorkflowCanvasState(profileID: UUID())
        state.load(from: WorkflowLayout(
            nodes: [condition, recovery],
            edges: [WorkflowEdge(sourceNodeID: condition.id, targetNodeID: recovery.id, sourcePortLabel: WorkflowEdge.errorPortLabel)],
            annotations: []
        ))

        var bad = err; bad.label = "bad"
        state.replaceNode(id: condition.id, with: rename(condition, rules: [ok, bad], fallback: ""))

        XCTAssertEqual(state.edges.first?.sourcePortLabel, WorkflowEdge.errorPortLabel,
                       "the failure port outlives the rule that shared its name — moving the edge unwires failure recovery")
    }

    /// …and renaming INTO "error" must refuse too: the destination would also fire on every
    /// failure and cascade skip, which no rename asked for.
    func testRenamingIntoTheReservedErrorLabelIsRefused() {
        let gate = gateNode(options: ["Approve", "Hold"])
        let deploy = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Deploy")

        let state = WorkflowCanvasState(profileID: UUID())
        state.load(from: WorkflowLayout(
            nodes: [gate, deploy],
            edges: [WorkflowEdge(sourceNodeID: gate.id, targetNodeID: deploy.id, sourcePortLabel: "Hold")],
            annotations: []
        ))

        state.replaceNode(id: gate.id, with: regated(gate, options: ["Approve", WorkflowEdge.errorPortLabel]))

        XCTAssertEqual(state.edges.first?.sourcePortLabel, "Hold")
    }

    /// [Found on adversarial review] Pins the CS12 guard's rule-membership clause, which nothing
    /// else discriminates: a programmatic edit that changes the fallback to some OTHER non-empty
    /// value while renaming the rule the old fallback names must not clobber the rule's rename.
    func testFallbackChangeToAnotherLabelNeverClobbersARuleRename() {
        let ruleA = ConditionRule(label: "A", field: .upstreamOutput, op: .contains, value: "a")
        let ruleB = ConditionRule(label: "B", field: .upstreamOutput, op: .contains, value: "b")
        let condition = conditionNode(rules: [ruleA, ruleB], fallback: "B")
        let downstream = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Next")

        let state = WorkflowCanvasState(profileID: UUID())
        state.load(from: WorkflowLayout(
            nodes: [condition, downstream],
            edges: [WorkflowEdge(sourceNodeID: condition.id, targetNodeID: downstream.id, sourcePortLabel: "B")],
            annotations: []
        ))

        var renamedB = ruleB; renamedB.label = "C"
        state.replaceNode(id: condition.id, with: rename(condition, rules: [ruleA, renamedB], fallback: "X"))

        XCTAssertEqual(state.edges.first?.sourcePortLabel, "C",
                       "the old fallback names rule B — B's edges follow B's rename, never the fallback's new value")
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
