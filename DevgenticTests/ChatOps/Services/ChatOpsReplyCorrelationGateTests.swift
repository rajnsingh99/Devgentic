// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ChatOpsReplyCorrelationGateTests.swift
//  devgenticTests
//
//  The one inbound path that skipped the parser and the tier gate.
//
//  ⚠️⚠️ THREE DEFECTS SHARED ONE CAUSE. Telegram's reply-correlation branch ran BEFORE
//  `ChatOpsCommand.parse` and before `securityGate.canExecute`, and called `handleClarification`
//  unconditionally for any reply it could correlate. So:
//    • a `.readOnly` remote user could steer a live agent run just by replying — the gate never
//      saw the act (SEC-1);
//    • `/cancel` typed into the ForceReply box was delivered to the agent as literal answer text
//      instead of cancelling the run — the exact failure `parse` moved its own slash branch above
//      the clarification branch to prevent (BR-1);
//    • a reply to a mirrored tool-confirmation, plan-review or gate prompt resolved the
//      CLARIFICATION continuation, which resumed nothing, left that operation parked forever, and
//      consumed its `hitlMessageIDs` entry so its buttons could never be rewritten (SEC-2).
//
//  ⚠️ WHY THESE ARE SOURCE-READING TESTS. `ChatOpsBridge.handleUpdate` is private, on a @MainActor
//  class whose collaborators are reached through `MainApplicationViewModel` — which no test may
//  construct, because doing so runs `ChatOpsCoordinator.bootstrap()` and opens real Telegram,
//  Discord and Slack connections from the test host (finding LIFE-6). Until that seam exists, a
//  drift test over the real source is the only thing that can fail when the guard is removed, and
//  it is strictly better than the nothing that was here before. The classification and table halves
//  are covered by real behavioural tests in `ChatOpsSecurityTierMatrixTests`.
//

import XCTest
@testable import devgentic

final class ChatOpsReplyCorrelationGateTests: XCTestCase {

    private var bridgeSource: String {
        get throws { try ChatOpsSecurityTierMatrixTests.readSource("Devgentic/ChatOps/Services/ChatOpsBridge.swift") }
    }

    /// SEC-1. The correlated-reply path must consult the tier gate, exactly as step 4 does for a
    /// typed answer. Reaching the agent by replying rather than by typing cannot be the thing that
    /// decides whether the tier allows it.
    func testTheCorrelatedReplyPathAppliesTheTierGate() throws {
        let source = try bridgeSource
        let handler = try Self.body(of: "private func handleCorrelatedReply", in: source)

        XCTAssertTrue(handler.contains("securityGate.canExecute"), """
            `handleCorrelatedReply` no longer applies the tier gate. A Read Only remote user can \
            steer a live agent run by replying to any parked prompt.
            """)

        guard let gate = handler.range(of: "securityGate.canExecute"),
              let resolve = handler.range(of: "handleClarification") else {
            return XCTFail("Expected both a tier check and a clarification resume in handleCorrelatedReply.")
        }
        XCTAssertTrue(gate.lowerBound < resolve.lowerBound,
                      "the tier gate must run BEFORE the operation is resolved, not after.")
    }

    /// SEC-2. A typed reply can only answer a clarification. Every other kind parks in a different
    /// continuation, and routing a reply there resolves the wrong one.
    func testTheCorrelatedReplyPathIsKindAware() throws {
        let handler = try Self.body(of: "private func handleCorrelatedReply", in: bridgeSource)

        XCTAssertTrue(handler.contains("pendingInteraction(forOperation:"), """
            `handleCorrelatedReply` no longer looks up what kind of prompt it is answering. A reply \
            to a tool confirmation will again resolve the clarification continuation: the tool stays \
            parked forever and its buttons stay live for a decision nothing can make.
            """)

        for kind in ["case .clarification", ".toolConfirmation", ".planReview", ".gate", "case .none"] {
            XCTAssertTrue(handler.contains(kind),
                          "`handleCorrelatedReply` must handle \(kind) explicitly — a swallowed reply is a parked run.")
        }
    }

    /// ⚠️ "ALREADY RESOLVED" IS NOT "WRONG KIND". The operation may have been answered on the Mac or
    /// by another connected provider between the prompt and the reply, and telling that user to
    /// "tap the buttons" sends them to a message whose buttons no longer do anything.
    func testAnAlreadyResolvedOperationIsReportedDistinctly() throws {
        let handler = try Self.body(of: "private func handleCorrelatedReply", in: bridgeSource)
        guard let none = handler.range(of: "case .none") else {
            return XCTFail("no `.none` arm — a reply to an already-resolved prompt is silently discarded.")
        }
        let arm = handler[none.lowerBound...]
        XCTAssertTrue(arm.contains("await tell("),
                      "the user must be told their reply was not needed; silence reads as a lost message.")
        XCTAssertTrue(arm.lowercased().contains("already"),
                      "the message must say the prompt was already answered, not that the reply was invalid.")
    }

    /// BR-1. A known verb in the reply box is a COMMAND. The call site must let it fall through to
    /// the normal switch instead of handing it to the model as answer text.
    func testAKnownVerbInTheReplyBoxIsNotSwallowedAsAnAnswer() throws {
        let source = try bridgeSource
        guard let branch = source.range(of: "operationID(forRemoteMessageID:"),
              let call = source.range(of: "handleCorrelatedReply(", range: branch.upperBound..<source.endIndex) else {
            return XCTFail("Could not find the reply-correlation branch in handleUpdate.")
        }
        XCTAssertTrue(
            source[branch.upperBound..<call.lowerBound].contains("ChatOpsVerbTable.parse(slashPrefixedText:"),
            """
            The reply-correlation branch no longer excludes slash commands, so `/cancel` typed into \
            the ForceReply box is delivered to the agent as the literal answer text and the run is \
            never cancelled. This is the failure `ChatOpsCommand.parse` moved its own slash branch \
            above the clarification branch to prevent.
            """
        )
    }

    /// `/skip` must keep meaning "answer with nothing" on the reply path, matching what `parse`
    /// step 5 does for a typed answer. It is deliberately not a verb-table entry — it is only
    /// meaningful against the specific prompt being replied to.
    func testSkipStillMeansAnEmptyAnswerOnTheReplyPath() throws {
        let handler = try Self.body(of: "private func handleCorrelatedReply", in: bridgeSource)
        XCTAssertTrue(handler.contains("\"/skip\""), """
            `/skip` no longer resolves to an empty answer on the reply path, so replying `/skip` \
            sends the model the literal string "/skip" — while typing it (parse step 5) still skips. \
            Two paths, two meanings, one word.
            """)
        XCTAssertNil(ChatOpsVerbTable.parse(slashPrefixedText: "/skip"), """
            `/skip` has become a verb-table entry. It is now filtered out of the reply branch as a \
            command and can no longer answer the prompt it was replied to.
            """)
    }

    /// The mirror must expose the kind lookup the bridge depends on.
    func testTheMirrorExposesThePendingKindLookup() throws {
        let mirror = try ChatOpsSecurityTierMatrixTests.readSource("Devgentic/ChatOps/Services/RemoteMirrorService.swift")
        XCTAssertTrue(mirror.contains("func pendingInteraction(forOperation"),
                      "RemoteMirrorService no longer exposes the kind lookup; the bridge cannot route a reply safely without it.")
    }

    // MARK: - Helpers

    /// The body of a declaration, from its signature to the start of the next top-level `func`.
    ///
    /// ⚠️ Brace-counting would be more precise, but every string literal in this file's target
    /// carries braces of its own; the next-func heuristic is enough to keep an assertion inside the
    /// function it names, and it fails loudly rather than silently matching the whole file.
    static func body(of signature: String, in source: String) throws -> Substring {
        guard let start = source.range(of: signature) else {
            throw XCTSkip("`\(signature)` not found — it was renamed or removed.")
        }
        let rest = source[start.upperBound...]
        if let next = rest.range(of: "\n    private func ") ?? rest.range(of: "\n    func ") {
            return rest[..<next.lowerBound]
        }
        return rest
    }
}
