// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ClassificationTokenMapperTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class ClassificationTokenMapperTests: XCTestCase {

    // MARK: - Token generation

    /// Every label must get its OWN token, or two branches collapse onto one.
    func testEachLabelGetsAUniqueToken() {
        let mapper = ClassificationTokenMapper(labels: ["Essay", "Code", "Other"])
        let tokens = Set(["Essay", "Code", "Other"].compactMap { mapper.labelToToken[$0] })
        XCTAssertEqual(tokens.count, 3, "a shared token would make two labels indistinguishable in the reply")
    }

    /// The prompt shows the model one `<label>` line per branch, in a stable order.
    func testXmlLabelBlockIsDeterministicAndCoversEveryLabel() {
        let mapper = ClassificationTokenMapper(labels: ["Zebra", "Apple"])
        let block = mapper.xmlLabelBlock

        XCTAssertTrue(block.contains("Zebra") && block.contains("Apple"))
        XCTAssertEqual(block, mapper.xmlLabelBlock, "the block must not vary between reads")
        // Sorted by label, so the prompt is byte-stable across processes.
        XCTAssertLessThan(block.range(of: "Apple")!.lowerBound, block.range(of: "Zebra")!.lowerBound)
    }

    // MARK: - Response parsing

    /// The well-behaved case: the model answers with the bare token.
    func testCleanTokenResponseResolvesToItsLabel() {
        let mapper = ClassificationTokenMapper(labels: ["Essay", "Code"])
        let token = mapper.labelToToken["Code"]!

        XCTAssertEqual(mapper.parseResponse(token), "Code")
        XCTAssertEqual(mapper.parseResponse("  \(token)\n"), "Code", "surrounding whitespace must not matter")
        XCTAssertEqual(mapper.parseResponse(token.lowercased()), "Code", "the scan is case-insensitive")
    }

    /// Small models rarely answer with just the token.
    func testTokenWrappedInProseIsStillFound() {
        let mapper = ClassificationTokenMapper(labels: ["Essay", "Code"])
        let token = mapper.labelToToken["Essay"]!

        XCTAssertEqual(mapper.parseResponse("I think \(token) fits best."), "Essay")
    }

    /// ⚠️ THE WF-EX1 PRECONDITION. No recognisable token ⇒ nil, NOT a label and NOT "".
    /// The caller relies on this to fail the node instead of activating a phantom port.
    func testResponseWithNoKnownTokenReturnsNil() {
        let mapper = ClassificationTokenMapper(labels: ["Essay", "Code"])

        XCTAssertNil(mapper.parseResponse("I'm not sure what you want."))
        XCTAssertNil(mapper.parseResponse(""))
        XCTAssertNil(mapper.parseResponse("Essay"),
                     "the LABEL is not the token — the whole point of the opaque id is that the model must echo the id")
    }

    // MARK: - WF-OB1: the "if unsure" token must not be a real branch

    /// ⚠️ THE DEFECT. `fallbackToken` was `l2t[fallbackLabel] ?? l2t.values.first`, so with no
    /// catch-all configured the prompt told the model "if unsure, answer with <token>" where that
    /// token was an arbitrary REAL branch
    /// drawn from an unordered Dictionary. Every ambiguous input was funnelled down it, and because
    /// Swift seeds hashing per process, WHICH branch could change between app launches.
    func testTheUnsureTokenIsNotAnyRealBranch() {
        let mapper = ClassificationTokenMapper(labels: ["Essay", "Code", "Other"])

        XCTAssertFalse(Set(mapper.labelToToken.values).contains(mapper.fallbackToken),
                       "the 'if unsure' token must not be any real branch's token")
        XCTAssertNil(mapper.tokenToLabel[mapper.fallbackToken],
                     "…and must map to no label, so parsing it yields nothing to route to")
        XCTAssertNil(mapper.parseResponse(mapper.fallbackToken),
                     "an unsure answer resolves to NO port, which fails the node onto `error`")
    }

    /// The sentinel must be distinguishable from a garbled reply, because the two have different
    /// remedies: "add a rule" versus "use a stronger model".
    func testExplicitNoMatchIsDistinguishedFromAnUnusableReply() {
        let mapper = ClassificationTokenMapper(labels: ["Essay", "Code"])

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
            let mapper = ClassificationTokenMapper(labels: ["A", "B", "C", "D", "E"])
            XCTAssertFalse(Set(mapper.labelToToken.values).contains(mapper.fallbackToken))
        }
    }

    // MARK: - parse(_:) — WF-OB2

    /// ⚠️ THE TEST WF-OB2 EXISTS FOR. A model answering "not X, it's Y" names TWO labels. The old
    /// scan returned whichever the Dictionary reached first — frequently the REJECTED one, and
    /// differently after an app restart. It is now ambiguity, reported as such.
    func testAReplyNamingTwoLabelsIsAmbiguousRatherThanAnArbitraryPick() {
        let mapper = ClassificationTokenMapper(labels: ["Bug", "Feature"])
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
        let mapper = ClassificationTokenMapper(labels: ["Bug", "Feature"])
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
        let mapper = ClassificationTokenMapper(labels: ["Bug", "Feature"])
        let feature = mapper.labelToToken["Feature"]!
        XCTAssertEqual(mapper.parse("I think \(feature) fits best"), .label("Feature"))
        XCTAssertEqual(mapper.parse(feature), .label("Feature"), "a bare token is still the common case")
    }

    /// ⚠️ Two rules may share a label — they share one output port. Without deduping BY LABEL that
    /// would manufacture a phantom ambiguity against itself.
    func testTwoRulesSharingALabelAreNotSelfAmbiguous() {
        let mapper = ClassificationTokenMapper(labels: ["Bug", "Bug", "Feature"])
        let bug = mapper.labelToToken["Bug"]!
        XCTAssertEqual(mapper.parse("clearly \(bug)"), .label("Bug"))
    }

    /// The sentinel is a verdict about the RULES and is consulted only when no real token appeared.
    func testTheSentinelIsOnlyConsultedWhenNoRealTokenIsPresent() {
        let mapper = ClassificationTokenMapper(labels: ["Bug", "Feature"])
        XCTAssertEqual(mapper.parse(mapper.fallbackToken), .explicitNoMatch)

        // A real token WITH the sentinel routes on the real token — today's semantics, preserved.
        let bug = mapper.labelToToken["Bug"]!
        XCTAssertEqual(mapper.parse("\(mapper.fallbackToken) but actually \(bug)"), .label("Bug"))
    }

    func testAnUnrecognisableReplyIsUnreadableNotNoMatch() {
        let mapper = ClassificationTokenMapper(labels: ["Bug", "Feature"])
        XCTAssertEqual(mapper.parse("I'm not sure what you want"), .unreadable,
                       "a verdict about the MODEL, distinct from the model saying none of the rules fit")
    }
}
