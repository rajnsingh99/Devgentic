//
//  WorkflowNodeInspectorTests.swift
//  DevgenticTests
//
//  Register `Workflow_Production_Readiness_Fresh.md`, inspector cluster — the rows fixed
//  2026-09-01: `INS-2` (Cancel kept orchestration edits), `INS-4` (panel min height below four
//  inspectors' own minimums), `INS-6` (duplicate-label de-dup no-opped at the cap), `INS-7` (router
//  policy silently downgraded), `INS-8` (retry stepper showed 0 while the engine would retry),
//  `INS-10` (unavailable operator rendered as a blank dropdown) and `INS-11` (a no-op Save dirtied
//  the layout).
//
//  Every one of these lived inside a SwiftUI view's `private` method or a `Binding` closure, where
//  no test could reach it. Each fix extracted its decision first (WF-UI5), and this file is what
//  makes that extraction worth having: the rules are truth-tabled, including the boundaries the
//  original defects hid in.
//
//  ⚠️ What is NOT covered here, stated so this file is not mistaken for full coverage: the panel
//  HOSTING (`NodeInspectorPanelManager` sizing an `NSWindow`), the SwiftUI `ForEach` identity change
//  in `INS-5`, and the `.onChange` that drives `INS-12` are all AppKit/SwiftUI runtime behaviour
//  with no headless seam. `INS-5`'s model-side contract IS covered — see the gate-rename tests at
//  the end, which are the half that can actually break edges.
//

import XCTest
@testable import devgentic

@MainActor
final class WorkflowNodeInspectorTests: XCTestCase {

    private func rule(_ label: String, id: UUID = UUID()) -> ConditionRule {
        ConditionRule(id: id, label: label, field: .upstreamOutput, op: .contains, value: "x")
    }

    // MARK: - INS-6 — the duplicate-label de-dup must terminate with a distinct label

    /// The filed defect: at exactly the cap, `"\(label)\(n)".prefix(10)` truncates back to the SAME
    /// ten characters, so all 98 candidates collide and the duplicate ships to the validator.
    func testATenCharacterDuplicateGetsADistinctLabel() {
        let taken: Set<String> = ["Escalation"]          // exactly maxLabelLength
        XCTAssertEqual("Escalation".count, ConditionNodeConfig.maxLabelLength)

        let deduped = ConditionNodeConfig.deduplicatedLabel("Escalation", taken: taken)

        XCTAssertNotEqual(deduped, "Escalation", "the whole point — this used to no-op")
        XCTAssertFalse(taken.contains(deduped))
        XCTAssertTrue(ConditionNodeConfig.isValidLabel(deduped),
                      "a repair that produces an INVALID label just moves the blocking error")
    }

    /// The suffix replaces the tail, so the result never exceeds the cap however long the base is.
    func testTheDedupedLabelNeverExceedsTheCap() {
        var taken: Set<String> = []
        for _ in 0..<12 {
            let deduped = ConditionNodeConfig.deduplicatedLabel("Escalation", taken: taken)
            XCTAssertLessThanOrEqual(deduped.count, ConditionNodeConfig.maxLabelLength)
            XCTAssertTrue(ConditionNodeConfig.isValidLabel(deduped), "produced '\(deduped)'")
            XCTAssertFalse(taken.contains(deduped), "must be distinct from every earlier one")
            taken.insert(deduped)
        }
    }

    /// ⚠️ NAMES the produced label. Every other de-dup test constrains only distinctness, validity
    /// and length, so a de-dup returning arbitrary valid strings would pass them all — and the user
    /// would get an unrecognisable port name for a rule they wrote.
    func testTheDedupedLabelKeepsAsMuchOfTheOriginalAsFits() {
        // Room for the suffix: the tail is replaced, not appended.
        XCTAssertEqual(ConditionNodeConfig.deduplicatedLabel("Escalation", taken: ["Escalation"]),
                       "Escalatio2")
        XCTAssertEqual(
            ConditionNodeConfig.deduplicatedLabel("Escalation", taken: ["Escalation", "Escalatio2"]),
            "Escalatio3"
        )
        // A short label has room, so nothing is trimmed.
        XCTAssertEqual(ConditionNodeConfig.deduplicatedLabel("Refund", taken: ["Refund"]), "Refund2")
    }

    /// A free label is returned untouched — the repair must not rename what nobody duplicated.
    func testAFreeLabelIsUntouched() {
        XCTAssertEqual(ConditionNodeConfig.deduplicatedLabel("Refund", taken: ["Escalate"]), "Refund")
    }

    /// ⚠️ Two-digit suffixes must not collapse. For a 9-character base, appending 10…99 and then
    /// truncating to 10 produced only nine distinct candidates; replacing the tail gives 90.
    func testTwoDigitSuffixesDoNotCollapseForANineCharacterBase() {
        let base = "Escalatio"                            // 9 characters
        XCTAssertEqual(base.count, 9)
        var taken: Set<String> = [base]
        var produced: Set<String> = []

        for _ in 0..<30 {
            let deduped = ConditionNodeConfig.deduplicatedLabel(base, taken: taken)
            XCTAssertFalse(produced.contains(deduped), "repeated '\(deduped)'")
            produced.insert(deduped)
            taken.insert(deduped)
        }

        XCTAssertEqual(produced.count, 30)
    }

    /// The result always ends in a digit, so it can never collide with the reserved error port.
    func testADedupedLabelCanNeverBecomeTheReservedErrorPort() {
        let deduped = ConditionNodeConfig.deduplicatedLabel(
            WorkflowEdge.errorPortLabel, taken: [WorkflowEdge.errorPortLabel]
        )
        XCTAssertNotEqual(deduped, WorkflowEdge.errorPortLabel)
    }

    // MARK: - INS-7 — a dangling route target must be detected, not silently rewritten

    func testAPolicyPointingAtALiveRuleNeedsNoRepair() {
        let r = rule("Refund")
        XCTAssertEqual(
            ConditionNodeInspectorView.danglingRouteRepair(in: .route(ruleID: r.id), against: [r]),
            .none
        )
    }

    func testAPolicyPointingAtADeletedRuleIsRepaired() {
        let deleted = UUID()
        XCTAssertEqual(
            ConditionNodeInspectorView.danglingRouteRepair(
                in: .route(ruleID: deleted), against: [rule("Refund")]
            ),
            .policy(ruleID: deleted)
        )
    }

    /// The ask FALLBACK is a second, independently reachable target — it needs its own arm, and its
    /// repair writes a different value (`.ask(fallback: .failNode)`, not `.failNode`).
    func testAnAskFallbackPointingAtADeletedRuleIsRepairedSeparately() {
        let deleted = UUID()
        XCTAssertEqual(
            ConditionNodeInspectorView.danglingRouteRepair(
                in: .ask(fallback: .route(ruleID: deleted)), against: [rule("Refund")]
            ),
            .askFallback(ruleID: deleted)
        )
    }

    func testAnAskFallbackPointingAtALiveRuleNeedsNoRepair() {
        let r = rule("Refund")
        XCTAssertEqual(
            ConditionNodeInspectorView.danglingRouteRepair(
                in: .ask(fallback: .route(ruleID: r.id)), against: [r]
            ),
            .none
        )
    }

    /// Every policy that names no rule at all is left alone — a repair that fired here would
    /// rewrite a decision the user made deliberately.
    func testPoliciesThatNameNoRuleAreNeverRepaired() {
        let rules = [rule("Refund")]
        for policy: RouterDecisionPolicy in [.failNode, .endBranch,
                                             .ask(fallback: .failNode), .ask(fallback: .endBranch)] {
            XCTAssertEqual(
                ConditionNodeInspectorView.danglingRouteRepair(in: policy, against: rules),
                .none,
                "\(policy)"
            )
        }
    }

    // MARK: - INS-10 — a preserved-but-unevaluable operator must have a tag to bind to

    /// The reachable case: the retired `always` decodes to `.other("always")`, which is not in
    /// `allCases`, so the Picker had no matching tag and rendered blank.
    func testARetiredOperatorIsOfferedSoThePickerCanRenderIt() {
        let retired = ConditionOp(rawValue: "always")
        XCTAssertEqual(retired, .other("always"))
        XCTAssertFalse(ConditionOp.allCases.contains(retired!),
                       "if this ever becomes false the row is moot — check why")

        let options = ConditionNodeInspectorView.operatorOptions(including: retired!)

        XCTAssertTrue(options.contains(retired!), "the blank dropdown was exactly this")
        XCTAssertEqual(options.count, ConditionOp.allCases.count + 1)
        XCTAssertEqual(options.last, retired!, "unavailable sorts last — it is not something to pick")
    }

    /// An ordinary operator must not be duplicated into the menu.
    func testAKnownOperatorDoesNotGrowTheMenu() {
        XCTAssertEqual(
            ConditionNodeInspectorView.operatorOptions(including: .contains),
            ConditionOp.allCases
        )
    }

    /// The label the user sees must not claim the operator came from a NEWER build — `.other` also
    /// holds the retired `always`, which came from an older one.
    func testAnUnavailableOperatorIsLabelledUnavailableNotNewer() {
        XCTAssertEqual(ConditionOp.other("always").displayName, "always (unavailable)")
    }

    // MARK: - INS-8 — the editor must show the retry count the engine will actually use

    /// A node with no config of its own INHERITS the workflow default, because
    /// `maxNodeRetries` is non-optional and the executor's `?? resolvedMaxRetries` fallback is
    /// reachable only while `nodeConfig` is nil. Showing 0 there claimed "no retries" for a node
    /// the engine would retry.
    func testAnUneditedSaveOnALegacyWorkflowStillWritesNothing() {
        // The panel seeds the stepper with the inherited 2, so "unedited" means maxRetries == 2 —
        // NOT 0. Collapsing against the bare defaults would call that a change and write a config.
        XCTAssertNil(ActionNodeInspectorView.executionConfigToPersist(
            existing: nil, maxRetries: 2, retryDelay: 0, hardTimeout: nil,
            unattendedAutoApprove: false, inheritedRetryDefault: 2
        ))
    }

    /// …and a real edit away from the inherited value MUST be written, or the user cannot override it.
    func testEditingAwayFromTheInheritedDefaultIsPersisted() {
        let persisted = ActionNodeInspectorView.executionConfigToPersist(
            existing: nil, maxRetries: 0, retryDelay: 0, hardTimeout: nil,
            unattendedAutoApprove: false, inheritedRetryDefault: 2
        )
        XCTAssertEqual(persisted?.maxNodeRetries, 0,
                       "explicitly choosing 0 on a workflow that inherits 2 is a real change")
    }

    /// With no inherited default — the overwhelmingly common case — the collapse is unchanged.
    func testTheCollapseIsUnchangedWhenNothingIsInherited() {
        XCTAssertNil(ActionNodeInspectorView.executionConfigToPersist(
            existing: nil, maxRetries: 0, retryDelay: 0, hardTimeout: nil,
            unattendedAutoApprove: false, inheritedRetryDefault: 0
        ))
        XCTAssertNotNil(ActionNodeInspectorView.executionConfigToPersist(
            existing: nil, maxRetries: 2, retryDelay: 0, hardTimeout: nil,
            unattendedAutoApprove: false, inheritedRetryDefault: 0
        ))
    }

    /// ⚠️ THE REGRESSION THIS ROW'S FIRST FIX INTRODUCED. Applying `inheritedRetryDefault` to the
    /// editor's READ but not to the config it MATERIALISES meant that touching the timeout — a
    /// control the user does not associate with retries — created a bare config and silently pinned
    /// the node to 0 retries, while the stepper the user was looking at said 2.
    func testMaterialisingAConfigCarriesTheInheritedRetryCount() {
        XCTAssertEqual(WorkflowNodeConfig.materialised(inheritedRetryDefault: 2).maxNodeRetries, 2)
    }

    /// …and with nothing inherited it is exactly the defaults, so the common case is unchanged.
    func testMaterialisingWithNothingInheritedIsTheBareDefaults() {
        XCTAssertEqual(WorkflowNodeConfig.materialised(inheritedRetryDefault: 0), WorkflowNodeConfig())
    }

    // MARK: - INS-11 — a Save that changes nothing must write nothing

    /// The crux: `nil` must stay `nil`. Materialising `WorkflowNodeConfig()` defeats
    /// `replaceNode`'s equality guard AND pins an inherited retry budget to 0.
    func testAnUneditedSaveLeavesANilConfigNil() {
        XCTAssertNil(ActionNodeInspectorView.executionConfigToPersist(
            existing: nil, maxRetries: 0, retryDelay: 0, hardTimeout: nil, unattendedAutoApprove: false
        ))
    }

    func testARealEditMaterialisesTheConfig() {
        let persisted = ActionNodeInspectorView.executionConfigToPersist(
            existing: nil, maxRetries: 3, retryDelay: 0, hardTimeout: nil, unattendedAutoApprove: false
        )
        XCTAssertEqual(persisted?.maxNodeRetries, 3)
    }

    /// Each field on its own must be enough to make the config real — a per-field regression would
    /// otherwise silently drop that one setting on a node that had no config yet.
    func testEveryFieldIndependentlyMaterialisesTheConfig() {
        XCTAssertNotNil(ActionNodeInspectorView.executionConfigToPersist(
            existing: nil, maxRetries: 1, retryDelay: 0, hardTimeout: nil, unattendedAutoApprove: false))
        XCTAssertNotNil(ActionNodeInspectorView.executionConfigToPersist(
            existing: nil, maxRetries: 0, retryDelay: 5, hardTimeout: nil, unattendedAutoApprove: false))
        XCTAssertNotNil(ActionNodeInspectorView.executionConfigToPersist(
            existing: nil, maxRetries: 0, retryDelay: 0, hardTimeout: 120, unattendedAutoApprove: false))
        XCTAssertNotNil(ActionNodeInspectorView.executionConfigToPersist(
            existing: nil, maxRetries: 0, retryDelay: 0, hardTimeout: nil, unattendedAutoApprove: true))
    }

    /// An EXISTING config is preserved and updated in place — the nil-collapse must not throw away
    /// a config the node already had.
    func testAnExistingConfigIsUpdatedNotDiscarded() {
        var existing = WorkflowNodeConfig()
        existing.maxNodeRetries = 4

        let persisted = ActionNodeInspectorView.executionConfigToPersist(
            existing: existing, maxRetries: 0, retryDelay: 0, hardTimeout: nil, unattendedAutoApprove: false
        )

        XCTAssertNotNil(persisted, "an existing config stays materialised even at the defaults")
        XCTAssertEqual(persisted?.maxNodeRetries, 0, "…and the edit to 0 is honoured")
        XCTAssertEqual(persisted?.joinMode, existing.joinMode,
                       "a field this panel does not edit must survive the round trip — the helper "
                       + "starts from `existing`, and rebuilding from scratch would drop it")
    }

    /// End to end: an unedited Save must leave the canvas clean and burn no undo step.
    func testAnUneditedSaveDoesNotDirtyTheCanvas() {
        let s = WorkflowCanvasState(profileID: UUID())
        s.load(from: WorkflowLayout(nodes: [], edges: [], annotations: []))
        s.addStructuralNode(kind: .code(CodeNodeConfig(template: "{{ input }}")), displayName: "C")
        s.markSaved()
        let node = s.nodes[0]
        XCTAssertNil(node.nodeConfig, "precondition: creation leaves nodeConfig nil")

        // Exactly what CodeNodeInspectorView.saveAndDismiss now does for an unedited panel.
        var rewritten = node
        rewritten.kind = .code(CodeNodeConfig(template: "{{ input }}", outputVariable: nil))
        s.replaceNode(id: node.id, with: rewritten)

        XCTAssertFalse(s.hasUnsavedChanges,
                       "opening an inspector and pressing Save without editing must be a no-op")

        // ⚠️ Asserted by UNDOING, not by reading `canUndo`. The setup's own `addStructuralNode`
        // already pushed a snapshot and `markSaved()` does not clear the stack, so `canUndo` is
        // true either way — it cannot see the extra step. One undo must land past the ADD; if the
        // no-op Save had pushed its own snapshot, this first undo would restore an
        // identical-looking canvas and the node would still be there.
        s.undo()
        XCTAssertTrue(s.nodes.isEmpty,
                      "one ⌘Z must reach the add — a Save that changed nothing must not have "
                      + "inserted an undo step the user has to press through")
    }

    // MARK: - INS-2 — Cancel must put back what the write-through controls committed

    func testCancelRestoresOrchestrationEditsAndTheNodeName() throws {
        var node = WorkflowNode(kind: .profile(profileID: UUID(), profileType: .agent), position: .zero, displayName: "Researcher")
        let snapshot = NodeInspectorOpenSnapshot(node)

        // What the write-through bindings do the moment the user touches the controls.
        var config = WorkflowNodeConfig()
        config.hardTimeout = 120
        config.maxNodeRetries = 3
        node.nodeConfig = config
        node.displayName = "Renamed"

        let restored = try XCTUnwrap(snapshot.restored(into: node))

        XCTAssertNil(restored.nodeConfig, "the timeout and retries the user cancelled must go")
        XCTAssertEqual(restored.displayName, "Researcher", "…and so must the rename")
    }

    /// ⚠️ The other direction, and the one every earlier test missed: the node ALREADY had a config
    /// when the panel opened, and the user changed its values rather than creating it. A `restored`
    /// that only handled nil→non-nil would pass all the surrounding tests and still leave the user's
    /// cancelled 300s timeout in place.
    func testCancelRestoresPreviousValuesOfAnExistingConfig() throws {
        var opening = WorkflowNodeConfig()
        opening.hardTimeout = 60
        opening.maxNodeRetries = 1
        opening.retryDelay = 5
        var node = WorkflowNode(kind: .profile(profileID: UUID(), profileType: .agent),
                                position: .zero, displayName: "R")
        node.nodeConfig = opening
        let snapshot = NodeInspectorOpenSnapshot(node)

        var edited = opening
        edited.hardTimeout = 300
        edited.maxNodeRetries = 5
        edited.retryDelay = 30
        node.nodeConfig = edited

        let restored = try XCTUnwrap(snapshot.restored(into: node))

        XCTAssertEqual(restored.nodeConfig?.hardTimeout, 60)
        XCTAssertEqual(restored.nodeConfig?.maxNodeRetries, 1)
        XCTAssertEqual(restored.nodeConfig?.retryDelay, 5)
    }

    /// A Cancel that changes nothing must produce NO write, or it would dirty the canvas and burn
    /// an undo step for a panel the user merely looked at.
    func testCancelWithNoEditsWritesNothing() {
        let node = WorkflowNode(kind: .profile(profileID: UUID(), profileType: .agent), position: .zero, displayName: "R")
        XCTAssertNil(NodeInspectorOpenSnapshot(node).restored(into: node))
    }

    /// ⚠️ The node vanished while the panel was open (deleted, or the canvas reverted/cleared). The
    /// binding fabricates a placeholder with a FRESH uuid, so restoring would resurrect a node the
    /// user removed — or stamp these settings onto whatever the binding now points at.
    func testCancelDoesNotWriteBackOntoADifferentNode() {
        let opened = WorkflowNode(kind: .profile(profileID: UUID(), profileType: .agent), position: .zero, displayName: "A")
        let snapshot = NodeInspectorOpenSnapshot(opened)
        let somethingElse = WorkflowNode(kind: .profile(profileID: UUID(), profileType: .agent), position: .zero, displayName: "B")

        XCTAssertNil(snapshot.restored(into: somethingElse))
    }

    /// Cancel must not undo a change this panel does not own. `kind` carries port labels, and a
    /// rename made through some other surface must survive.
    func testCancelLeavesTheNodeKindAlone() {
        var node = WorkflowNode(kind: .gate(GateNodeConfig(options: ["Approve", "Reject"])),
                                position: .zero, displayName: "G")
        let snapshot = NodeInspectorOpenSnapshot(node)
        node.displayName = "Renamed"
        node.kind = .gate(GateNodeConfig(options: ["Yes", "No"]))

        let restored = snapshot.restored(into: node)

        XCTAssertEqual(restored?.displayName, "G")
        if case .gate(let config) = restored?.kind {
            XCTAssertEqual(config.options, ["Yes", "No"], "the kind must be left exactly as found")
        } else {
            XCTFail("kind should still be a gate")
        }
    }

    // MARK: - INS-4 — one per-kind inspector minimum, matching each view's own root frame

    /// The filed defect: one shared 800×520 for five inspectors whose own roots declare up to 680.
    func testEveryKindsInspectorMinimumMatchesItsViewsDeclaredMinimum() {
        // These are the `minHeight:` values on each inspector view's root `.frame(...)`. If one of
        // those changes, this table must change WITH it — that is the whole point of the table.
        let expected: [(WorkflowNodeKind, CGFloat)] = [
            (.condition(ConditionNodeConfig()), 680),
            (.action(ActionNodeConfig()), 620),
            (.gate(GateNodeConfig()), 560),
            (.profile(profileID: UUID(), profileType: .agent), 540),
            (.code(CodeNodeConfig()), 520),
        ]
        for (kind, height) in expected {
            XCTAssertEqual(kind.inspectorMinimumSize.height, height, "\(kind)")
            XCTAssertEqual(kind.inspectorMinimumSize.width, 800, "\(kind)")
        }
    }

    /// The kinds that never open an inspector still need an answer, and it must be sane.
    func testKindsWithNoInspectorStillReportAUsableMinimum() {
        for kind: WorkflowNodeKind in [.trigger(TriggerNodeConfig()), .unsupported(raw: .string("future"))] {
            XCTAssertGreaterThanOrEqual(kind.inspectorMinimumSize.height, 520, "\(kind)")
        }
    }

    // MARK: - INS-5 — the model-side contract the identity change must not disturb
    //
    // The SwiftUI identity fix itself is unreachable from a test. What IS reachable, and what
    // actually breaks edges if the flatten order is wrong, is the port-rename map's positional
    // precondition: the inspector edits text in place and appends adds at the end.

    func testRenamingAGateOptionInPlaceStillRepointsItsEdge() {
        let s = WorkflowCanvasState(profileID: UUID())
        s.load(from: WorkflowLayout(nodes: [], edges: [], annotations: []))
        s.addStructuralNode(kind: .gate(GateNodeConfig(options: ["Approve", "Reject"])), displayName: "G")
        s.addStructuralNode(kind: .code(CodeNodeConfig()), displayName: "C")
        let gate = s.nodes[0], target = s.nodes[1]
        XCTAssertTrue(s.addEdge(sourceNodeID: gate.id, targetNodeID: target.id, sourcePortLabel: "Approve"))

        var renamed = gate
        renamed.kind = .gate(GateNodeConfig(options: ["Accept", "Reject"]))
        s.replaceNode(id: gate.id, with: renamed)

        XCTAssertEqual(s.edges.first?.sourcePortLabel, "Accept",
                       "an in-place rename must carry its edge, or the branch silently stops firing")
    }

    func testAddingAGateOptionAtTheEndLeavesExistingEdgesAlone() {
        let s = WorkflowCanvasState(profileID: UUID())
        s.load(from: WorkflowLayout(nodes: [], edges: [], annotations: []))
        s.addStructuralNode(kind: .gate(GateNodeConfig(options: ["Approve", "Reject"])), displayName: "G")
        s.addStructuralNode(kind: .code(CodeNodeConfig()), displayName: "C")
        let gate = s.nodes[0], target = s.nodes[1]
        XCTAssertTrue(s.addEdge(sourceNodeID: gate.id, targetNodeID: target.id, sourcePortLabel: "Reject"))

        var added = gate
        added.kind = .gate(GateNodeConfig(options: ["Approve", "Reject", "Defer"]))
        s.replaceNode(id: gate.id, with: added)

        XCTAssertEqual(s.edges.first?.sourcePortLabel, "Reject")
    }
}
