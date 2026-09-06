//
//  JarvisApprovalGrammarWiringTests.swift
//  DevgenticTests
//
//  The spoken-approval grammar, now that it is actually reachable.
//
//  ⚠️ WHY THIS FILE EXISTS. `parseApprovalUtterance` shipped with eight tests and ZERO production
//  callers, so "approve one" — the natural phrasing right after hearing a tool named — was rejected
//  as a non-confirmation while the grammar that handles it sat unreachable beside it. Wiring it in
//  widens what a microphone can commit, so what is pinned here is that it widened along the ONE
//  axis intended (a target for the user's own keyword) and along no other.
//

import XCTest
@testable import devgentic

final class JarvisApprovalVocabularyTests: XCTestCase {

    /// The shipped defaults, spelled out — the parser takes no defaults of its own.
    private func parse(_ text: String, queueSize: Int) -> JarvisApprovalUtterance? {
        JarvisApprovalPolicy.parseApprovalUtterance(
            text, queueSize: queueSize, approveKeywords: ["approve"], denyKeywords: ["deny"])
    }

    // MARK: - The keyword is the vocabulary

    /// ⚠️⚠️ THE RULE WIRING THIS IN HAD TO ESTABLISH. The keyword setting exists so a user can pick
    /// a commit word that does NOT occur in their ordinary speech near the microphone. A hardcoded
    /// verb list beside it would mean "approve one" still commits after they changed the word —
    /// silently defeating the only reason the setting exists.
    func testACustomKeywordReplacesTheDefaultVerbEntirely() {
        let custom = JarvisApprovalPolicy.parseApprovalUtterance(
            "confirm one", queueSize: 1, approveKeywords: ["confirm"], denyKeywords: ["deny"])
        XCTAssertEqual(custom, .approve([1]), "The user's own keyword must work as a verb.")

        let stale = JarvisApprovalPolicy.parseApprovalUtterance(
            "approve one", queueSize: 1, approveKeywords: ["confirm"], denyKeywords: ["deny"])
        XCTAssertNil(stale, "The DEFAULT word must stop committing once the user has chosen another.")
    }

    /// Multi-word keywords are legal ("go ahead"), so the verb match must not assume one token.
    func testAMultiWordKeywordStillLeadsTheGrammar() {
        XCTAssertEqual(
            JarvisApprovalPolicy.parseApprovalUtterance(
                "go ahead one", queueSize: 1, approveKeywords: ["go ahead"], denyKeywords: ["deny"]),
            .approve([1]))
    }

    /// "Deny all" derives from the user's deny words too, for the same reason.
    func testDenyAllFollowsTheConfiguredDenyKeyword() {
        XCTAssertEqual(JarvisApprovalPolicy.denyAllPhrases(for: ["reject"]),
                       ["reject all", "reject everything"])
        XCTAssertEqual(
            JarvisApprovalPolicy.parseApprovalUtterance(
                "reject all", queueSize: 2, approveKeywords: ["approve"], denyKeywords: ["reject"]),
            .denyAll)
    }

    /// ⚠️ Denial is matched BEFORE approval at every level. If a word reaches both lists, the safe
    /// reading of an ambiguous instruction to run a tool is "don't".
    func testAWordInBothListsDenies() {
        XCTAssertEqual(
            JarvisApprovalPolicy.parseApprovalUtterance(
                "sure one", queueSize: 1, approveKeywords: ["sure"], denyKeywords: ["sure"]),
            .deny([1]))
    }

    // MARK: - What wiring it in must NOT widen

    /// A verb that leads but names no valid position must produce NOTHING — never a bare approval.
    /// A half-heard "approve the—" must not degrade into a commit.
    func testAVerbWithNoValidTargetCommitsNothing() {
        for utterance in ["approve", "approve the", "approve that", "approve it now"] {
            XCTAssertNil(
                parse(utterance, queueSize: 1),
                "\(utterance) must not parse as a targeted approval")
        }
    }

    /// ⚠️ Out of range is DROPPED, never clamped — with one request pending, "approve three" must
    /// not quietly become "approve the only one".
    func testAnOutOfRangePositionDoesNotBecomeTheOnlyPendingRequest() {
        XCTAssertNil(parse("approve three", queueSize: 1))
        XCTAssertEqual(parse("approve one", queueSize: 1),
                       .approve([1]))
    }

    /// Still no "approve all", now that the grammar is live. "All" is the word a television
    /// supplies and its blast radius is everything pending.
    func testThereIsStillNoApproveAll() {
        for utterance in ["approve all", "approve everything", "accept all"] {
            XCTAssertNil(parse(utterance, queueSize: 3),
                         "\(utterance) must never approve")
        }
    }

    /// The swallowing rule survives wiring: a sentence ABOUT approving is not an approval.
    func testASentenceAboutApprovingIsStillNotAnApproval() {
        for utterance in ["can you approve one of these later",
                          "I was going to deny one of them",
                          "tell me what approve one means"] {
            XCTAssertNil(parse(utterance, queueSize: 3),
                         "\(utterance) must not be treated as a command")
        }
    }

    /// Asking to see it authorizes nothing — it is a request to move to the surface that can show
    /// arguments and let them be edited.
    func testAskingToSeeItIsNotADecision() {
        XCTAssertEqual(parse("show me", queueSize: 1),
                       .openOnScreen)
    }

    /// A re-read request must be recognised, because the branch it drives is the one that must not
    /// fail closed: someone who did not catch the arguments is least able to decide.
    func testAskingWhatItIsRequestsAReRead() {
        XCTAssertEqual(parse("what is one", queueSize: 1),
                       .describe(1))
        XCTAssertEqual(parse("what\u{2019}s number one", queueSize: 1),
                       .describe(1))
    }
}

// MARK: - The read-back

@MainActor
final class JarvisApprovalReadBackWordingTests: XCTestCase {

    private func readBack(approve: [String], deny: [String]) -> String {
        // The token is only constructible through the policy, so go through a real decision.
        guard let token = JarvisApprovalPolicy.token(for: Self.pendingReadFile()) else {
            XCTFail("a safe read-only tool with readable arguments should be voice-approvable")
            return ""
        }
        return JarvisSessionController.approvalReadBack(
            token: token, keywords: (approve: approve, deny: deny, problems: []))
    }

    /// ⚠️ The sentence must name the user's REAL keywords. Telling someone to say "yes" while the
    /// commit word is "approve" looks like the microphone failing, not like a wrong word — and it
    /// is now doubly load-bearing, because the same words lead the targeted grammar.
    func testTheReadBackNamesTheConfiguredKeywords() {
        let sentence = readBack(approve: ["confirm"], deny: ["scrap"])
        XCTAssertTrue(sentence.contains("Say confirm to go ahead"), sentence)
        XCTAssertTrue(sentence.contains("or scrap to skip it"), sentence)
        XCTAssertFalse(sentence.lowercased().contains("say yes"), sentence)
    }

    /// It must also still say WHAT would run — the read-back is the entire mitigation.
    func testTheReadBackStillNamesTheToolAndItsArguments() {
        let sentence = readBack(approve: ["approve"], deny: ["deny"])
        XCTAssertTrue(sentence.contains("read file"), "tool name missing: \(sentence)")
        XCTAssertTrue(sentence.contains("Config"), "arguments missing: \(sentence)")
    }

    private static func pendingReadFile() -> PendingHITL {
        PendingHITL(
            id: UUID(),
            origin: HITLOrigin(interface: .chat, conversationID: UUID(), title: "Permission required"),
            kind: .toolConfirmation(PendingToolConfirmation(
                toolName: "read_file", params: "{}", risk: .safe,
                arguments: .object(["path": .string("/tmp/Config.swift")]), riskIsServerDeclared: nil))
        )
    }
}
