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
/// produce one of the two terms cannot prove a difference between them. That is why
/// `resolveNoMatch` was extracted pure: **the differential lives in this file or it does not
/// exist.** The integration tests cover the crash path's end-to-end wiring; these cover the rule.
final class WorkflowNoMatchDispositionTests: XCTestCase {

    private func rules() -> [ConditionRule] {
        [
            ConditionRule(label: "Urgent", field: .upstreamOutput, op: .contains, value: "urgent"),
            ConditionRule(label: "General", field: .upstreamOutput, op: .contains, value: "zzz")
        ]
    }

    private func routeToGeneral(_ rules: [ConditionRule]) -> RouterNoMatchBehavior {
        .route(ruleID: rules[1].id)
    }

    // MARK: - The finding itself

    /// ⚠️ THE TEST WF-CC10 EXISTS FOR. Same setting, same rules — the ONLY difference is whether
    /// the classifier produced a verdict. Before the fix both returned `.route(port: "General")`,
    /// which is how an MLX slot race silently became a routing decision on a run that then
    /// reported success.
    func testACrashedClassifierAndAnInconclusiveOneResolveToDifferentDispositions() {
        let r = rules()
        let behavior = routeToGeneral(r)

        let crashed = WorkflowExecutor.resolveNoMatch(
            behavior: behavior, outcome: .failed(reason: "model slot held by another run"), rules: r)
        let inconclusive = WorkflowExecutor.resolveNoMatch(
            behavior: behavior, outcome: .noMatch, rules: r)

        XCTAssertNotEqual(crashed, inconclusive,
                          "a classifier that NEVER RAN and one that ran and found nothing must not resolve identically — that equality IS WF-CC10")

        guard case .fail(let reason) = crashed else {
            return XCTFail("a classifier fault must fail the node, got \(crashed)")
        }
        XCTAssertTrue(reason.contains("could not be consulted"), reason)
        XCTAssertTrue(reason.contains("model slot held by another run"),
                      "the underlying cause must survive into the reason: \(reason)")
        XCTAssertEqual(inconclusive, .route(port: "General"),
                       "an explicit 'none of these' IS the case `When Nothing Matches` was written for")
    }

    /// The model ran and said "none of these". That is a verdict about the RULES — the author's
    /// setting applies exactly as designed.
    func testAnExplicitNoneOfTheseStillFollowsTheAuthorsDefaultRoute() {
        let r = rules()
        XCTAssertEqual(
            WorkflowExecutor.resolveNoMatch(behavior: routeToGeneral(r), outcome: .noMatch, rules: r),
            .route(port: "General"))
    }

    /// ⚠️ THE DEBATABLE BOUNDARY, pinned deliberately. An unreadable reply means the model RAN and
    /// could not decide — and "if it can't decide, When Nothing Matches applies" is what the Router
    /// inspector promises. A small local model producing mush is precisely the audience that picks
    /// `.route`. If this ever changes to `.fail`, this is the test that says so out loud.
    func testAnUnreadableReplyStillFollowsTheAuthorsDefaultRoute() {
        let r = rules()
        XCTAssertEqual(
            WorkflowExecutor.resolveNoMatch(
                behavior: routeToGeneral(r), outcome: .unreadable(preview: "It is not QP3N"), rules: r),
            .route(port: "General"))
    }

    // MARK: - Honest reasons

    /// ⚠️ Pins the second wrongness in the old `detail` string: it INFERRED "the classifier ran"
    /// from `config.llmFallbackEnabled`, so a Router whose classifier is switched OFF — and one
    /// where a rule matched with a BLANK label, skipping the classifier entirely — both reported
    /// "the AI Classifier did not return a label" about a classifier that was never consulted.
    func testAClassifierThatNeverRanIsNotDescribedAsHavingAnswered() {
        let r = rules()
        let disposition = WorkflowExecutor.resolveNoMatch(behavior: .failNode, outcome: nil, rules: r)

        guard case .fail(let reason) = disposition else {
            return XCTFail("expected .fail, got \(disposition)")
        }
        XCTAssertEqual(reason, "no rule matched")
        XCTAssertFalse(reason.localizedCaseInsensitiveContains("classifier"),
                       "no classifier was consulted, so the reason must not mention one: \(reason)")
    }

    func testAnExplicitNoMatchReasonNamesTheClassifierAndTheRuleCount() {
        let r = rules()
        guard case .fail(let reason) = WorkflowExecutor.resolveNoMatch(
            behavior: .failNode, outcome: .noMatch, rules: r) else {
            return XCTFail("expected .fail")
        }
        XCTAssertTrue(reason.contains("none of the 2 categories fit"),
                      "the reason must distinguish 'the model considered your rules and rejected them' from 'nothing ran': \(reason)")
    }

    func testAnUnreadableReasonQuotesWhatTheModelActuallySaid() {
        let r = rules()
        guard case .fail(let reason) = WorkflowExecutor.resolveNoMatch(
            behavior: .failNode, outcome: .unreadable(preview: "It is not QP3N"), rules: r) else {
            return XCTFail("expected .fail")
        }
        XCTAssertTrue(reason.contains("It is not QP3N"),
                      "quoting the reply is what lets a user tell a too-small model from a rules problem: \(reason)")
    }

    // MARK: - The other arms are unaffected

    func testEndWorkflowStillEndsTheBranchForAGenuineNoMatch() {
        let r = rules()
        XCTAssertEqual(
            WorkflowExecutor.resolveNoMatch(behavior: .endWorkflow, outcome: .noMatch, rules: r),
            .endBranch)
    }

    /// …but not after a fault: the fault check precedes the behaviour switch.
    func testEndWorkflowDoesNotSwallowAClassifierFault() {
        let r = rules()
        guard case .fail = WorkflowExecutor.resolveNoMatch(
            behavior: .endWorkflow, outcome: .failed(reason: "boom"), rules: r) else {
            return XCTFail("`.endWorkflow` must not turn a classifier fault into a graceful ending — that reports SUCCESS on a run where nothing was classified")
        }
    }

    /// A deleted default-route target still fails honestly — unchanged, and the in-file precedent
    /// this whole finding's policy was argued from.
    func testADeletedDefaultRouteTargetStillFailsHonestly() {
        let r = rules()
        guard case .fail(let reason) = WorkflowExecutor.resolveNoMatch(
            behavior: .route(ruleID: UUID()), outcome: .noMatch, rules: r) else {
            return XCTFail("expected .fail for a deleted route target")
        }
        XCTAssertTrue(reason.contains("no longer exists"), reason)
    }

    /// ⚠️ Proves the MAPPING only. That a real Stop actually produces `.cancelled` is NOT proven by
    /// any test in this repo — the hermetic vehicle throws before reaching a cancellable await, and
    /// nothing can make the classifier's `model.generate` throw `CancellationError`. Recorded as an
    /// explicit coverage gap rather than implied.
    func testACancelledClassifierIsNeverDescribedAsAClassifierVerdict() {
        let r = rules()
        guard case .fail(let reason) = WorkflowExecutor.resolveNoMatch(
            behavior: .failNode, outcome: .cancelled, rules: r) else {
            return XCTFail("expected .fail")
        }
        XCTAssertFalse(reason.localizedCaseInsensitiveContains("classifier"),
                       "a Stop is not a classifier verdict: \(reason)")
    }

    // MARK: - Outcome adapter

    func testOnlyALabelOutcomeExposesALabelToPortResolution() {
        XCTAssertEqual(WorkflowExecutor.ClassifierOutcome.label("Urgent").label, "Urgent")
        XCTAssertNil(WorkflowExecutor.ClassifierOutcome.noMatch.label)
        XCTAssertNil(WorkflowExecutor.ClassifierOutcome.unreadable(preview: "x").label)
        XCTAssertNil(WorkflowExecutor.ClassifierOutcome.failed(reason: "x").label)
        XCTAssertNil(WorkflowExecutor.ClassifierOutcome.cancelled.label,
                     "a cancelled classifier must never contribute a routing signal")
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
    // MARK: - Migration seeding (inspector) + the prompt template

    private func legacyConfig(ask: Bool, noMatch: RouterNoMatchBehavior,
                              fallbackLabel: String = "") -> ConditionNodeConfig {
        var c = ConditionNodeConfig()
        c.rules = ruleSet()
        c.askOnAmbiguity = ask
        c.noMatchBehavior = noMatch
        c.fallbackLabel = fallbackLabel
        return c
    }

    /// ⚠️ The migration happens on an explicit SAVE, never at decode — so a stored workflow keeps
    /// its exact behaviour until its author opens the node. This seeds what the merged control
    /// shows them.
    func testSeedingMapsTheLegacyPairOntoTheUnifiedPolicy() {
        // ask ON + fail  → the default mass. Ask, falling back to fail.
        XCTAssertEqual(ConditionNodeInspectorView.seedPolicy(from: legacyConfig(ask: true, noMatch: .failNode)),
                       .ask(fallback: .failNode))
        // ask OFF + fail → resolve silently, both triggers.
        XCTAssertEqual(ConditionNodeInspectorView.seedPolicy(from: legacyConfig(ask: false, noMatch: .failNode)),
                       .failNode)
        // ask ON + end   → Ask, falling back to ending the branch.
        XCTAssertEqual(ConditionNodeInspectorView.seedPolicy(from: legacyConfig(ask: true, noMatch: .endWorkflow)),
                       .ask(fallback: .endBranch))
        // ask OFF + route → that route, both triggers.
        var routed = legacyConfig(ask: false, noMatch: .failNode)
        let target = routed.rules[2].id
        routed.noMatchBehavior = .route(ruleID: target)
        XCTAssertEqual(ConditionNodeInspectorView.seedPolicy(from: routed), .route(ruleID: target))
    }

    /// ⚠️ A legacy catch-all OUTRANKS `noMatchBehavior` at runtime today, so it must seed the
    /// route — otherwise the first Save would silently move where unmatched input goes, which is
    /// exactly the failure the `fallbackLabel` retirement note warns about.
    func testSeedingHonoursALegacyCatchAllOverNoMatchBehavior() {
        // ⚠️ Read the id from the SAME config the seeder sees — `ruleSet()` mints fresh UUIDs on
        // every call, so comparing against a second instance's id compares two different rules.
        let config = legacyConfig(ask: false, noMatch: .failNode, fallbackLabel: "General")
        let generalID = config.rules.first { $0.label == "General" }!.id

        XCTAssertEqual(ConditionNodeInspectorView.seedPolicy(from: config), .route(ruleID: generalID),
                       "the catch-all is where unmatched input goes TODAY — seeding fail would change it")
    }

    /// An already-migrated node is returned untouched — seeding is not idempotent-by-luck, it
    /// short-circuits.
    func testSeedingLeavesAnExistingPolicyAlone() {
        var c = legacyConfig(ask: true, noMatch: .failNode)
        c.decisionPolicy = .endBranch
        XCTAssertEqual(ConditionNodeInspectorView.seedPolicy(from: c), .endBranch)
    }

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
