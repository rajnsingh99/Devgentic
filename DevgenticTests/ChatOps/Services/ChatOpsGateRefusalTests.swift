// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsGateRefusalTests.swift
//  devgenticTests
//
//  B4 — TG-5(B), OBS-4 and SEC-6, which are one edit because they rewrite the same three `authorize*`
//  return types. OBS-4's filing was that the authorization boundary for untrusted remote input had ONE
//  behavioural assertion in the whole suite; this file is the answer to that half of it.
//
//  ⚠️⚠️ THE SECURITY PROPERTY UNDER TEST IS AN ASYMMETRY, NOT A RULE. Most refusals must stay SILENT —
//  replying confirms to an unpaired room that a Devgentic Mac is listening, and hands an attacker free
//  amplification. Exactly one may answer: a throttled sender has already passed the channel AND sender
//  checks, so they have proved they are the paired operator and telling them leaks nothing. Before
//  this, they saw precisely what an intruder saw.
//

import XCTest
@testable import devgentic

final class ChatOpsGateRefusalTests: XCTestCase {

    // MARK: - Who may be answered

    /// ⚠️ THE BOUNDARY. If this ever flips, the bot becomes a liveness oracle for any room it is in.
    func testOnlyAThrottledSenderMayEverBeAnswered() {
        let answerable = RemoteRefusal(reason: .rateLimited(retryIn: 3), consequence: "c")
        XCTAssertTrue(answerable.mayReply)

        for reason in [RemoteRefusal.Reason.unauthorizedChannel,
                       .unauthorizedSender,
                       .unattributable,
                       .pairingPredatesAuthorization] {
            XCTAssertFalse(RemoteRefusal(reason: reason, consequence: "c").mayReply,
                           "\(reason) happens BEFORE identity is established — answering it confirms "
                           + "to an unpaired sender that this Mac is listening")
        }
    }

    /// Every refusal carries its consequence: the field is a stored `let`, so a new reason cannot be
    /// added without writing one.
    func testEveryRefusalStatesItsConsequence() {
        let refusal = RemoteRefusal(reason: .unauthorizedChannel, consequence: "dropped in silence")
        XCTAssertFalse(refusal.consequence.isEmpty)
    }

    // MARK: - SEC-6: the bucket

    /// ⚠️⚠️ THE CASE THAT WAS UNTESTABLE UNTIL THE CLOCK WAS INJECTED, and the reason the row was
    /// filed. Wall-clock time moves BACKWARDS — NTP correction, a timezone change, the user setting
    /// their clock — and `timeIntervalSince` then returns a negative elapsed, which under the old
    /// arithmetic REMOVED tokens from the bucket. A monotonic source cannot go backwards, and the
    /// `max(0,…)` clamp is kept as the belt.
    func testTheBucketNeverLosesTokensWhenTheClockGoesBackwards() async {
        var now: TimeInterval = 1_000
        let gate = ChatOpsSecurityGate(now: { now })

        // Spend one token so the bucket is not sitting at its ceiling.
        _ = await gate.consumeTokenForTesting()
        let afterSpend = await gate.availableTokensForTesting()

        now -= 600   // the clock jumps back ten minutes
        _ = await gate.refillForTesting()

        let afterJump = await gate.availableTokensForTesting()
        XCTAssertGreaterThanOrEqual(afterJump, afterSpend,
                                    "a backward clock drained the bucket: \(afterSpend) → \(afterJump)")
    }

    /// Forward time refills at the documented rate — 1 token per second, burst 30. ⚠️ The three
    /// comments this replaced claimed three DIFFERENT rates, none matching the code.
    func testTheBucketRefillsAtOneTokenPerSecondAndBurstsAtThirty() async {
        var now: TimeInterval = 1_000
        let gate = ChatOpsSecurityGate(now: { now })

        for _ in 0..<30 { _ = await gate.consumeTokenForTesting() }
        let spent = await gate.availableTokensForTesting()
        XCTAssertLessThan(spent, 1, "the burst should be spent")

        now += 5
        _ = await gate.refillForTesting()
        let refilled = await gate.availableTokensForTesting()
        XCTAssertEqual(refilled, 5, accuracy: 0.01, "five seconds must return five tokens")

        now += 10_000
        _ = await gate.refillForTesting()
        let capped = await gate.availableTokensForTesting()
        XCTAssertEqual(capped, 30, accuracy: 0.01,
                       "the bucket must cap at its burst rather than growing without bound")
    }

    // MARK: - The throttle notice

    /// ⚠️ ONCE PER WINDOW. Answering every dropped message turns one refusal into a flood — itself the
    /// amplification the silent arms exist to avoid.
    @MainActor
    func testAThrottledOperatorIsToldOncePerWindow() {
        ChatOpsThrottleNotice.resetForTesting()
        XCTAssertTrue(ChatOpsThrottleNotice.claim(for: .telegram, now: 100))
        XCTAssertFalse(ChatOpsThrottleNotice.claim(for: .telegram, now: 110), "still inside the window")
        XCTAssertTrue(ChatOpsThrottleNotice.claim(for: .telegram, now: 100 + ChatOpsThrottleNotice.window + 1),
                      "a new window earns a new notice")
        XCTAssertTrue(ChatOpsThrottleNotice.claim(for: .slack, now: 110), "providers are independent")
        ChatOpsThrottleNotice.resetForTesting()
    }

    // MARK: - Wiring

    /// ⚠️ The asymmetry is worthless if no bridge consults it. All three must, and all three must go
    /// through `mayReply` rather than re-deriving the rule.
    func testAllThreeBridgesAnswerOnlyThroughMayReply() throws {
        for bridge in ["ChatOpsBridge", "DiscordChatOpsBridge", "SlackChatOpsBridge"] {
            let source = try ChatOpsSecurityTierMatrixTests
                .readSourceStrippingComments("Devgentic/ChatOps/Services/\(bridge).swift")
            XCTAssertTrue(source.contains("refusal.mayReply"),
                          "\(bridge) does not consult mayReply, so it either answers everyone or no one")
            XCTAssertTrue(source.contains("ChatOpsThrottleNotice.claim"),
                          "\(bridge) would answer every throttled message rather than once per window")
        }
    }

    /// ⚠️ [OBS-4] Every drop path in the gate names its consequence — the half of that row that was
    /// still live after the tier-matrix work closed the rest.
    func testEveryGateRefusalPathIsTaggedAndNamesItsConsequence() throws {
        let source = try ChatOpsSecurityTierMatrixTests
            .readSourceStrippingComments("Devgentic/ChatOps/Services/ChatOpsSecurityGate.swift")
        for line in source.components(separatedBy: "\n") where line.contains("logger.warning(") || line.contains("logger.error(") {
            XCTAssertTrue(line.contains("[CHATOPS]"), "untagged gate log: \(line.trimmingCharacters(in: .whitespaces))")
            XCTAssertTrue(line.contains("CONSEQUENCE:"), "gate log with no consequence: \(line.trimmingCharacters(in: .whitespaces))")
        }
    }
}
