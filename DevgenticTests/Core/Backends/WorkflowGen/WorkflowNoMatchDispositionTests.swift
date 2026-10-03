// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh

import XCTest
@testable import devgentic

/// ⚠️ WF-CC10 — the crashed-vs-inconclusive distinction, tested where it is actually PROVABLE.
///
/// THE COVERAGE BOUNDARY, stated plainly so a green run is not over-read:
/// `evaluateConditionWithLLM` reaches `MLXModelService.shared` and `MLXService.shared` as concrete
/// singletons with no injection seam, and `executeStructuralNode` is private. So at the INTEGRATION
/// level only the CRASH half is reachable (the hermetic vehicle throws a guard before any MLX
/// contact); an INCONCLUSIVE classifier — one that ran and answered "none of these", or answered
/// unreadably — cannot be produced by any test in this repo.
///
/// WF-CC10's claim is that those two are treated DIFFERENTLY. A test suite that can only ever
/// produce one of the two terms cannot prove a difference between them. That is why `classify` and
/// `resolveUndecided` are pure: **the differential lives in this file or it does not exist.** The
/// integration tests cover the crash path's end-to-end wiring; these cover the rule.
final class WorkflowNoMatchDispositionTests: XCTestCase {

    // MARK: - Routable matches (WF-EX1)

    /// ⚠️ An EMPTY label is absent, never a port: `edgeIsLive` resolves an edge's port as
    /// `sourcePortLabel ?? ""`, so activating `""` would fire every UNLABELLED edge out of the
    /// Router and send the run down the default branch as though a rule had matched.
    func testABlankLabelIsNeverRoutable() {
        XCTAssertEqual(WorkflowExecutor.routableMatches([""]), [])
        XCTAssertEqual(WorkflowExecutor.routableMatches(["", "Urgent"]), ["Urgent"],
                       "a blank match must not turn a single real match into an ambiguity")
    }

    /// Two rules sharing a label share one port — one branch, not an ambiguity.
    func testSharedLabelsCountOnceInRuleOrder() {
        XCTAssertEqual(WorkflowExecutor.routableMatches(["Bug", "Bug", "Feature"]), ["Bug", "Feature"])
    }

    // MARK: - The UNIFIED policy (2026-08-17 redesign)
    //
    // ⚠️ One setting, both triggers: EMPTY (nothing matched) and AMBIGUOUS (several did). They are
    // mutually exclusive by construction, which is what makes one setting coherent rather than a
    // false merge. The AI Classifier inherits it — one token routes, zero is EMPTY, two or more is
    // AMBIGUOUS — which is what retires WF-OB2.
    //
    // ⚠️ EVERY POLICY CASE IS TOTAL: it means the same thing for EMPTY and AMBIGUOUS. The earlier
    // draft's `firstMatch` was the one option that was not (undefined when nothing matched) and was
    // dropped by user decision. These tests pin totality by asserting each policy across both.

    private func ruleSet() -> [ConditionRule] {
        [ConditionRule(label: "Urgent", field: .upstreamOutput, op: .contains, value: "urgent"),
         ConditionRule(label: "Billing", field: .upstreamOutput, op: .contains, value: "invoice"),
         ConditionRule(label: "General", field: .upstreamOutput, op: .contains, value: "zzz")]
    }

    private let empty = WorkflowExecutor.RouterUndecided.empty(.noRuleMatched)
    private func ambiguous(_ c: [String], _ o: WorkflowExecutor.RouterUndecidedOrigin = .pattern)
    -> WorkflowExecutor.RouterUndecided { .ambiguous(candidates: c, origin: o) }

    /// ⚠️ TOTALITY. The same policy, the same answer shape, for both triggers — the property that
    /// keeps the decision table free of per-situation footnotes.
    func testEveryPolicyMeansTheSameThingForEmptyAndForAmbiguous() {
        let r = ruleSet()
        let amb = ambiguous(["Urgent", "Billing"])

        for (name, policy) in [("fail", RouterDecisionPolicy.failNode),
                               ("end", .endBranch),
                               ("route", .route(ruleID: r[2].id))] {
            let e = WorkflowExecutor.resolveUndecided(policy: policy, situation: empty, rules: r)
            let a = WorkflowExecutor.resolveUndecided(policy: policy, situation: amb, rules: r)
            switch (e, a) {
            case (.fail, .fail), (.endBranch, .endBranch):
                break
            case (.route(let p1), .route(let p2)):
                XCTAssertEqual(p1, p2, "[\(name)] both triggers must route to the same port")
            default:
                XCTFail("[\(name)] policy is not total: empty gave \(e), ambiguous gave \(a)")
            }
        }
    }

    /// The user's spec point 2: the chosen default route wins for BOTH triggers — and on ambiguity
    /// it deliberately OVERRIDES the rules that did match.
    func testRouteOverridesEvenTheRulesThatMatched() {
        let r = ruleSet()
        let d = WorkflowExecutor.resolveUndecided(
            policy: .route(ruleID: r[2].id), situation: ambiguous(["Urgent", "Billing"]), rules: r)
        XCTAssertEqual(d, .route(port: "General"),
                       "the author's explicit default beats the implicit rule-order tiebreak that used to win here")
    }

    // MARK: Ask

    /// Ambiguity offers only the branches actually named.
    func testAskOnAmbiguityOffersOnlyTheNamedBranches() {
        let r = ruleSet()
        guard case .ask(let options, let prompt, let fallback) = WorkflowExecutor.resolveUndecided(
            policy: .ask(fallback: .failNode), situation: ambiguous(["Urgent", "Billing"]), rules: r) else {
            return XCTFail("expected .ask")
        }
        XCTAssertEqual(options, ["Urgent", "Billing"], "must not offer General — it did not match")
        XCTAssertTrue(prompt.contains("2 rules"), prompt)
        XCTAssertEqual(fallback, .failNode)
    }

    /// ⚠️ EMPTY has no candidates, so Ask offers EVERY rule — the question becomes "none of these
    /// fit, which should it take anyway?". This is the case the old `askOnAmbiguity` Bool could not
    /// express at all: asking was wired only to the several-matched trigger.
    func testAskOnEmptyOffersEveryRule() {
        let r = ruleSet()
        guard case .ask(let options, let prompt, _) = WorkflowExecutor.resolveUndecided(
            policy: .ask(fallback: .failNode), situation: empty, rules: r) else {
            return XCTFail("expected .ask")
        }
        XCTAssertEqual(options, ["Urgent", "Billing", "General"])
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("nothing matched"), prompt)
    }

    /// Two rules may share a label — one output port. The banner must not offer it twice.
    func testAskDoesNotOfferADuplicatedLabelTwice() {
        let dup = [ConditionRule(label: "Same", field: .upstreamOutput, op: .contains, value: "a"),
                   ConditionRule(label: "Same", field: .upstreamOutput, op: .contains, value: "b")]
        guard case .ask(let options, _, _) = WorkflowExecutor.resolveUndecided(
            policy: .ask(fallback: .failNode), situation: empty, rules: dup) else {
            return XCTFail("expected .ask")
        }
        XCTAssertEqual(options, ["Same"])
    }

    /// ⚠️ A Router with nothing to offer must NOT park on an empty banner — it resolves straight to
    /// its fallback, through the SAME table, so the two can never drift.
    func testAskWithNoOfferableOptionsFallsThroughInsteadOfParking() {
        let d = WorkflowExecutor.resolveUndecided(
            policy: .ask(fallback: .endBranch), situation: empty, rules: [])
        XCTAssertEqual(d, .endBranch, "no options means no question to ask")
    }

    /// The fallback resolves through the same function, so a fallback route behaves identically to
    /// a top-level route.
    func testAskFallbackResolvesThroughTheSameTable() {
        let r = ruleSet()
        let viaFallback = WorkflowExecutor.resolveUndecided(
            policy: .ask(fallback: .route(ruleID: r[2].id)), situation: empty, rules: [])
        XCTAssertEqual(viaFallback, .fail(reason: WorkflowExecutor.resolveUndecided(
            policy: .route(ruleID: r[2].id), situation: empty, rules: []).failReasonForTest),
            "a dangling fallback route must fail exactly as a dangling top-level route does")
    }

    /// A deleted route target fails honestly rather than guessing — unchanged contract.
    func testADeletedRouteTargetFailsHonestly() {
        guard case .fail(let reason) = WorkflowExecutor.resolveUndecided(
            policy: .route(ruleID: UUID()), situation: empty, rules: ruleSet()) else {
            return XCTFail("expected .fail")
        }
        XCTAssertTrue(reason.contains("no longer exists"), reason)
    }

    // MARK: classify() — the boundary that policy must never see

    /// ⚠️ THE CC10/CC13 BOUNDARY, now type-enforced. A crash and a Stop are sorted out BEFORE a
    /// situation value exists, so no policy branch can route them.
    func testCrashAndCancelAreBoundariesNotSituations() {
        guard case .boundaryFail(let reason) = WorkflowExecutor.classify(outcome: .failed(reason: "model slot held")) else {
            return XCTFail("a classifier crash must be a boundary, never a routable situation")
        }
        XCTAssertTrue(reason.contains("could not be consulted"), reason)
        XCTAssertTrue(reason.contains("model slot held"), "the cause must survive into the reason: \(reason)")

        XCTAssertEqual(WorkflowExecutor.classify(outcome: .cancelled), .boundaryCancel)
    }

    /// The verdicts the model DID produce become situations, and feed the policy.
    func testClassifierVerdictsBecomeSituations() {
        XCTAssertEqual(WorkflowExecutor.classify(outcome: .label("Urgent")), .decided("Urgent"))
        XCTAssertEqual(WorkflowExecutor.classify(outcome: .noMatch),
                       .situation(.empty(.classifierNoMatch)))
        XCTAssertEqual(WorkflowExecutor.classify(outcome: .unreadable(preview: "hmm")),
                       .situation(.empty(.classifierUnreadable(preview: "hmm"))))
        XCTAssertEqual(WorkflowExecutor.classify(outcome: .ambiguous(candidates: ["Urgent", "Billing"])),
                       .situation(.ambiguous(candidates: ["Urgent", "Billing"], origin: .classifier)),
                       "WF-OB2: a two-token reply is ambiguity feeding the policy, not an arbitrary pick")
    }

    /// The reason text names WHICH kind of undecided it was — the user's remedy differs.
    func testReasonsDistinguishTheEvidence() {
        let r = ruleSet()
        func reason(_ s: WorkflowExecutor.RouterUndecided) -> String {
            guard case .fail(let x) = WorkflowExecutor.resolveUndecided(policy: .failNode, situation: s, rules: r) else { return "" }
            return x
        }
        XCTAssertEqual(reason(.empty(.noRuleMatched)), "no rule matched")
        XCTAssertTrue(reason(.empty(.classifierNoMatch)).contains("none of the 3 categories fit"))
        XCTAssertTrue(reason(.empty(.classifierUnreadable(preview: "It is not QP3N"))).contains("It is not QP3N"))
        let amb = reason(ambiguous(["Urgent", "Billing"], .classifier))
        XCTAssertTrue(amb.contains("AI Classifier named 2 categories"), amb)
        XCTAssertTrue(amb.contains("Urgent, Billing"), amb)
    }
    // MARK: - The prompt template

    /// ⚠️ The placeholder expands at RUN TIME, which is what makes rule edits non-clobbering and
    /// non-staling at once.
    func testTheRoutingPromptPlaceholderExpandsToTheCurrentRules() {
        var c = ConditionNodeConfig()
        c.rules = ruleSet()
        c.llmPrompt = ConditionNodeConfig.defaultRoutingPrompt

        let resolved = c.resolvedRoutingPrompt()
        XCTAssertFalse(resolved.contains(ConditionNodeConfig.rulesPlaceholder),
                       "the placeholder must never reach the model verbatim")
        for label in ["Urgent", "Billing", "General"] {
            XCTAssertTrue(resolved.contains(label), "\(label) missing from: \(resolved)")
        }

        // Rename a rule — the STORED prompt is untouched, the resolved one tracks it.
        c.rules[0].label = "Critical"
        XCTAssertEqual(c.llmPrompt, ConditionNodeConfig.defaultRoutingPrompt,
                       "editing rules must never rewrite the user's prompt text")
        XCTAssertTrue(c.resolvedRoutingPrompt().contains("Critical"),
                      "…and the resolved prompt must never go stale")
    }

    /// A user who deletes the placeholder gets their text sent verbatim — their choice, not an error.
    func testAPromptWithoutThePlaceholderIsSentAsWritten() {
        var c = ConditionNodeConfig()
        c.rules = ruleSet()
        c.llmPrompt = "Decide if this is urgent."
        XCTAssertEqual(c.resolvedRoutingPrompt(), "Decide if this is urgent.")
    }

    /// Duplicate labels collapse — the model must not be offered the same branch twice.
    func testTheExpandedRuleListDoesNotRepeatALabel() {
        var c = ConditionNodeConfig()
        c.rules = [ConditionRule(label: "Same", field: .upstreamOutput, op: .contains, value: "a"),
                   ConditionRule(label: "Same", field: .upstreamOutput, op: .contains, value: "b")]
        c.llmPrompt = ConditionNodeConfig.defaultRoutingPrompt
        let occurrences = c.resolvedRoutingPrompt().components(separatedBy: "- Same").count - 1
        XCTAssertEqual(occurrences, 1)
    }
}

private extension WorkflowExecutor.UndecidedDisposition {
    /// Test helper: the reason of a `.fail`, or "" — keeps the fallback-equivalence assertion legible.
    var failReasonForTest: String {
        if case .fail(let r) = self { return r }
        return ""
    }
}
