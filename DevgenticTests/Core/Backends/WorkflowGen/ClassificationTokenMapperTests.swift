// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ClassificationTokenMapperTests.swift
//  DevgenticTests
//
//  `ClassificationTokenMapper` had NO tests at all despite being pure, `Sendable` and
//  dependency-free — the easiest thing in the subsystem to test, and the one deciding which branch
//  a Router takes when the AI Classifier answers.
//
//  These pin the parse contract that WF-EX1 depends on: a reply carrying no recognisable token
//  returns **nil**. `evaluateConditionWithLLM` turns that nil into "no port resolved", which makes
//  the Router fail onto its `error` port. Before WF-EX1 the nil was converted to `""` and handed
//  onward as if it were a routing decision.
//
//  ⚠️ WF-OB2 IS NOW FIXED (2026-08-17) and IS covered — see the `parse(_:)` section at the bottom.
//  This header used to say the multi-token case was deliberately untested "because a test asserting
//  today's answer would pin nondeterminism", which was correct at the time: `parseResponse` scanned
//  an unordered Dictionary, so a two-token reply resolved to whichever key iteration reached first,
//  and Swift seeds hashing per process. `parse(_:)` now orders candidates by character position, so
//  the behaviour is deterministic and assertable.
//

import XCTest
@testable import devgentic

final class ClassificationTokenMapperTests: XCTestCase {

    // MARK: - Token generation

    /// Every label must get its OWN token, or two branches collapse onto one.
    func testEachLabelGetsAUniqueToken() {
        let mapper = ClassificationTokenMapper(labels: ["Essay", "Code", "Other"], fallbackLabel: "Other")
        let tokens = Set(["Essay", "Code", "Other"].compactMap { mapper.labelToToken[$0] })
        XCTAssertEqual(tokens.count, 3, "a shared token would make two labels indistinguishable in the reply")
    }

    /// The prompt shows the model one `<label>` line per branch, in a stable order.
    func testXmlLabelBlockIsDeterministicAndCoversEveryLabel() {
        let mapper = ClassificationTokenMapper(labels: ["Zebra", "Apple"], fallbackLabel: "Apple")
        let block = mapper.xmlLabelBlock

        XCTAssertTrue(block.contains("Zebra") && block.contains("Apple"))
        XCTAssertEqual(block, mapper.xmlLabelBlock, "the block must not vary between reads")
        // Sorted by label, so the prompt is byte-stable across processes.
        XCTAssertLessThan(block.range(of: "Apple")!.lowerBound, block.range(of: "Zebra")!.lowerBound)
    }

    // MARK: - Response parsing

    /// The well-behaved case: the model answers with the bare token.
    func testCleanTokenResponseResolvesToItsLabel() {
        let mapper = ClassificationTokenMapper(labels: ["Essay", "Code"], fallbackLabel: "Essay")
        let token = mapper.labelToToken["Code"]!

        XCTAssertEqual(mapper.parseResponse(token), "Code")
        XCTAssertEqual(mapper.parseResponse("  \(token)\n"), "Code", "surrounding whitespace must not matter")
        XCTAssertEqual(mapper.parseResponse(token.lowercased()), "Code", "the scan is case-insensitive")
    }

    /// Small models rarely answer with just the token.
    func testTokenWrappedInProseIsStillFound() {
        let mapper = ClassificationTokenMapper(labels: ["Essay", "Code"], fallbackLabel: "Essay")
        let token = mapper.labelToToken["Essay"]!

        XCTAssertEqual(mapper.parseResponse("I think \(token) fits best."), "Essay")
    }

    /// ⚠️ THE WF-EX1 PRECONDITION. No recognisable token ⇒ nil, NOT a label and NOT "".
    /// The caller relies on this to fail the node instead of activating a phantom port.
    func testResponseWithNoKnownTokenReturnsNil() {
        let mapper = ClassificationTokenMapper(labels: ["Essay", "Code"], fallbackLabel: "Essay")

        XCTAssertNil(mapper.parseResponse("I'm not sure what you want."))
        XCTAssertNil(mapper.parseResponse(""))
        XCTAssertNil(mapper.parseResponse("Essay"),
                     "the LABEL is not the token — the whole point of the opaque id is that the model must echo the id")
    }

    // MARK: - Fallback token

    /// When the caller names a real fallback label, its token is the one the prompt advertises and
    /// answering it ROUTES there. Legacy behaviour, deliberately unchanged by WF-OB1.
    func testConfiguredCatchAllStillRoutesToItsBranch() {
        let mapper = ClassificationTokenMapper(labels: ["Essay", "Code"], fallbackLabel: "Code")

        XCTAssertEqual(mapper.fallbackToken, mapper.labelToToken["Code"])
        XCTAssertFalse(mapper.fallbackIsNoMatchSentinel)
        XCTAssertEqual(mapper.parseResponse(mapper.fallbackToken), "Code",
                       "a configured catch-all must still resolve to its label")
        XCTAssertFalse(mapper.isExplicitNoMatch(mapper.fallbackToken),
                       "answering a real catch-all is a ROUTE, not a no-match")
    }

    // MARK: - WF-OB1: the "if unsure" token must not be a real branch

    /// ⚠️ THE DEFECT. `fallbackToken` was `l2t[fallbackLabel] ?? l2t.values.first`, so with no
    /// catch-all configured — the state of every Router created since 2026-08-13 — the prompt told
    /// the model "if unsure, answer with <token>" where that token was an arbitrary REAL branch
    /// drawn from an unordered Dictionary. Every ambiguous input was funnelled down it, and because
    /// Swift seeds hashing per process, WHICH branch could change between app launches.
    func testWithNoCatchAllTheUnsureTokenIsNotAnyRealBranch() {
        let mapper = ClassificationTokenMapper(labels: ["Essay", "Code", "Other"], fallbackLabel: "")

        XCTAssertTrue(mapper.fallbackIsNoMatchSentinel)
        XCTAssertFalse(Set(mapper.labelToToken.values).contains(mapper.fallbackToken),
                       "the 'if unsure' token must not be any real branch's token")
        XCTAssertNil(mapper.tokenToLabel[mapper.fallbackToken],
                     "…and must map to no label, so parsing it yields nothing to route to")
        XCTAssertNil(mapper.parseResponse(mapper.fallbackToken),
                     "an unsure answer resolves to NO port, which fails the node onto `error`")
    }

    /// A `fallbackLabel` naming a rule that has since been renamed or deleted must NOT silently
    /// substitute some other branch — that is the same defect wearing a different hat.
    func testAStaleCatchAllLabelFallsBackToTheSentinelNotAnotherBranch() {
        let mapper = ClassificationTokenMapper(labels: ["Essay", "Code"], fallbackLabel: "DeletedRule")

        XCTAssertTrue(mapper.fallbackIsNoMatchSentinel)
        XCTAssertFalse(Set(mapper.labelToToken.values).contains(mapper.fallbackToken))
    }

    /// The sentinel must be distinguishable from a garbled reply, because the two have different
    /// remedies: "add a rule" versus "use a stronger model".
    func testExplicitNoMatchIsDistinguishedFromAnUnusableReply() {
        let mapper = ClassificationTokenMapper(labels: ["Essay", "Code"], fallbackLabel: "")

        XCTAssertTrue(mapper.isExplicitNoMatch(mapper.fallbackToken))
        XCTAssertTrue(mapper.isExplicitNoMatch("I think \(mapper.fallbackToken) is right"))
        XCTAssertFalse(mapper.isExplicitNoMatch("who knows"),
                       "a reply with no token at all is an unusable answer, not a considered 'none of these'")
        XCTAssertFalse(mapper.isExplicitNoMatch(mapper.labelToToken["Essay"]!),
                       "a real routing answer is never a no-match")
    }

    /// The sentinel is generated from the same pool as real tokens, so it must be excluded from
    /// them — a collision would make one branch unreachable and the no-match signal ambiguous.
    func testSentinelNeverCollidesWithARealToken() {
        for _ in 0..<200 {
            let mapper = ClassificationTokenMapper(labels: ["A", "B", "C", "D", "E"], fallbackLabel: "")
            XCTAssertFalse(Set(mapper.labelToToken.values).contains(mapper.fallbackToken))
        }
    }

    // MARK: - parse(_:) — WF-OB2

    /// ⚠️ THE TEST WF-OB2 EXISTS FOR. A model answering "not X, it's Y" names TWO labels. The old
    /// scan returned whichever the Dictionary reached first — frequently the REJECTED one, and
    /// differently after an app restart. It is now ambiguity, reported as such.
    func testAReplyNamingTwoLabelsIsAmbiguousRatherThanAnArbitraryPick() {
        let mapper = ClassificationTokenMapper(labels: ["Bug", "Feature"], fallbackLabel: "")
        let bug = mapper.labelToToken["Bug"]!
        let feature = mapper.labelToToken["Feature"]!

        guard case .ambiguous(let candidates) = mapper.parse("It is not \(bug), it is \(feature)") else {
            return XCTFail("two named labels must be ambiguous, not a silent pick")
        }
        XCTAssertEqual(candidates, ["Bug", "Feature"],
                       "candidates must be in FIRST-APPEARANCE order in the reply, so the result is a property of the text and not of Dictionary seeding")
        XCTAssertNil(mapper.parseResponse("It is not \(bug), it is \(feature)"),
                     "the legacy adapter must refuse to collapse an ambiguous reply into one label")
    }

    /// Determinism, stated as a property: the same reply parses identically every time, and the
    /// order tracks the TEXT rather than the label set.
    func testAmbiguousCandidateOrderFollowsTheTextNotTheLabelSet() {
        let mapper = ClassificationTokenMapper(labels: ["Bug", "Feature"], fallbackLabel: "")
        let bug = mapper.labelToToken["Bug"]!
        let feature = mapper.labelToToken["Feature"]!

        for _ in 0..<50 {
            guard case .ambiguous(let forward) = mapper.parse("\(bug) then \(feature)"),
                  case .ambiguous(let reverse) = mapper.parse("\(feature) then \(bug)") else {
                return XCTFail("both orderings must parse as ambiguous")
            }
            XCTAssertEqual(forward, ["Bug", "Feature"])
            XCTAssertEqual(reverse, ["Feature", "Bug"])
        }
    }

    func testASingleTokenStillRoutes() {
        let mapper = ClassificationTokenMapper(labels: ["Bug", "Feature"], fallbackLabel: "")
        let feature = mapper.labelToToken["Feature"]!
        XCTAssertEqual(mapper.parse("I think \(feature) fits best"), .label("Feature"))
        XCTAssertEqual(mapper.parse(feature), .label("Feature"), "a bare token is still the common case")
    }

    /// ⚠️ Two rules may share a label — they share one output port. Without deduping BY LABEL that
    /// would manufacture a phantom ambiguity against itself.
    func testTwoRulesSharingALabelAreNotSelfAmbiguous() {
        let mapper = ClassificationTokenMapper(labels: ["Bug", "Bug", "Feature"], fallbackLabel: "")
        let bug = mapper.labelToToken["Bug"]!
        XCTAssertEqual(mapper.parse("clearly \(bug)"), .label("Bug"))
    }

    /// The sentinel is a verdict about the RULES and is consulted only when no real token appeared.
    func testTheSentinelIsOnlyConsultedWhenNoRealTokenIsPresent() {
        let mapper = ClassificationTokenMapper(labels: ["Bug", "Feature"], fallbackLabel: "")
        XCTAssertTrue(mapper.fallbackIsNoMatchSentinel, "precondition: no catch-all configured")
        XCTAssertEqual(mapper.parse(mapper.fallbackToken), .explicitNoMatch)

        // A real token WITH the sentinel routes on the real token — today's semantics, preserved.
        let bug = mapper.labelToToken["Bug"]!
        XCTAssertEqual(mapper.parse("\(mapper.fallbackToken) but actually \(bug)"), .label("Bug"))
    }

    func testAnUnrecognisableReplyIsUnreadableNotNoMatch() {
        let mapper = ClassificationTokenMapper(labels: ["Bug", "Feature"], fallbackLabel: "")
        XCTAssertEqual(mapper.parse("I'm not sure what you want"), .unreadable,
                       "a verdict about the MODEL, distinct from the model saying none of the rules fit")
    }
}

// MARK: - WF-EX1: Router port resolution
//
// The AI Classifier itself reaches for `MLXModelService.shared`/`MLXService.shared` and cannot be
// driven from a test. The rule that turns its answer into a PORT is pure, and that rule is where the
// defect lived — so it was extracted to `WorkflowExecutor.resolveRouterPort` to be testable here.
final class RouterPortResolutionTests: XCTestCase {

    /// ⚠️ THE DEFECT. `evaluateConditionWithLLM` returned `matched ?? config.fallbackLabel`, and
    /// `fallbackLabel` is empty on every Router created since 2026-08-13 — so an unreadable model
    /// reply yielded `""`. A `??` chain treats `""` as PRESENT, so the node activated a port named
    /// `""` and reported success. It must resolve to NOTHING, which fails the node onto `error`.
    func testEmptyClassifierAnswerResolvesToNothing() {
        let resolution = WorkflowExecutor.resolveRouterPort(
            arbitrated: nil, matched: [], classifier: "", legacyFallback: ""
        )
        XCTAssertEqual(resolution, .none(discardedEmptyLabel: true))
        XCTAssertNil(resolution.port, "an empty label must never become an active port")
    }

    /// The post-fix shape: the classifier returns nil rather than "".
    func testNilClassifierAnswerResolvesToNothingAndIsNotReportedAsABlankLabel() {
        let resolution = WorkflowExecutor.resolveRouterPort(
            arbitrated: nil, matched: [], classifier: nil, legacyFallback: ""
        )
        XCTAssertEqual(resolution, .none(discardedEmptyLabel: false),
                       "nothing was discarded — there was simply no answer, and the log must not claim a blank rule label")
    }

    /// ⚠️ An empty `legacyFallback` is the ORDINARY state of a modern Router, not a defect.
    /// It must not raise the blank-label diagnostic, or every no-match run logs a false alarm.
    func testAbsentLegacyFallbackIsNotReportedAsADiscardedEmptyLabel() {
        let resolution = WorkflowExecutor.resolveRouterPort(
            arbitrated: nil, matched: [], classifier: nil, legacyFallback: ""
        )
        guard case .none(let discarded) = resolution else { return XCTFail("expected no port") }
        XCTAssertFalse(discarded)
    }

    /// A rule saved with a blank label must be discarded rather than activated — activating `""`
    /// would make every UNLABELLED edge out of the Router fire (see
    /// `WorkflowSkipReasonTests.testAnEmptyActivePortWouldMakeUnlabelledEdgesLive`).
    func testBlankRuleLabelIsDiscardedRatherThanActivated() {
        let resolution = WorkflowExecutor.resolveRouterPort(
            arbitrated: nil, matched: [""], classifier: nil, legacyFallback: ""
        )
        XCTAssertEqual(resolution, .none(discardedEmptyLabel: true))
    }

    /// …and a blank candidate must not shadow a real one further down the chain.
    func testABlankCandidateDoesNotSuppressALaterRealOne() {
        XCTAssertEqual(
            WorkflowExecutor.resolveRouterPort(arbitrated: "", matched: ["Urgent"], classifier: nil, legacyFallback: ""),
            .port("Urgent")
        )
        XCTAssertEqual(
            WorkflowExecutor.resolveRouterPort(arbitrated: nil, matched: [], classifier: "", legacyFallback: "Billing"),
            .port("Billing")
        )
    }

    /// Priority is unchanged by the fix: arbitration → first pattern match → classifier → legacy.
    func testResolutionPriorityIsUnchanged() {
        XCTAssertEqual(
            WorkflowExecutor.resolveRouterPort(arbitrated: "Chosen", matched: ["Pattern"], classifier: "AI", legacyFallback: "Legacy"),
            .port("Chosen")
        )
        XCTAssertEqual(
            WorkflowExecutor.resolveRouterPort(arbitrated: nil, matched: ["Pattern"], classifier: "AI", legacyFallback: "Legacy"),
            .port("Pattern")
        )
        XCTAssertEqual(
            WorkflowExecutor.resolveRouterPort(arbitrated: nil, matched: [], classifier: "AI", legacyFallback: "Legacy"),
            .port("AI")
        )
        XCTAssertEqual(
            WorkflowExecutor.resolveRouterPort(arbitrated: nil, matched: [], classifier: nil, legacyFallback: "Legacy"),
            .port("Legacy")
        )
    }

    // classifierUserPrompt escaping tests moved to ClassifierPromptEscapingTests.swift.
}
