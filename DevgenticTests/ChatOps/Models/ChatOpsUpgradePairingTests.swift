// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsUpgradePairingTests.swift
//  devgenticTests
//
//  NEW-1 and NEW-2 — two defects introduced BY the per-sender authorization fix (invariant 38) and
//  found only by auditing that fix against current source.
//
//  NEW-1: `authorizedUserID` is written by a pairing service and by nothing else, so every pairing
//  made before invariant 38 restores with it nil and the gate refuses every inbound message. The
//  launch restore read credentials + ADDRESS only, so Settings painted `.connected` — a green dot —
//  over a bridge that could not answer anything, and all three gate call sites bare-return, so the
//  remote user got silence. The register called this an accepted cost whose "log line says so
//  explicitly"; a log line is not an affordance.
//
//  NEW-2: the Telegram pairing loop computed ONE `origin` — `from?.id ?? String(chatID)` — for the
//  lockout ledger and then reused it as the authorized IDENTITY. A PIN arriving on a message with no
//  `from` paired "successfully" against a chat id, and `ChatOpsSecurityGate` compares against
//  `from?.id` with no such fallback, so every later message was refused forever.
//

import XCTest
@testable import devgentic

final class ChatOpsUpgradePairingTests: XCTestCase {

    // MARK: - NEW-1: the restore must not claim a pairing works when nobody is authorized

    /// ⚠️ THE DEFECT. Credentials and an address are present — which is all the old restore asked —
    /// but no account was ever recorded, so every command will be refused.
    func testAPairingWithNoRecordedAccountDoesNotRestoreAsConnected() {
        let state = ChatOpsPairingRestore.state(
            credentials: .present, addressPresent: true, authorizedUserID: nil, chatID: 42)
        XCTAssertNotEqual(state, .connected(chatID: 42),
                          "a green dot over a bridge that refuses every message is worse than a red one")
        XCTAssertTrue(state.needsRepairing, "and it must be the state that OFFERS re-pairing")
    }

    /// A complete pairing is unaffected — the common path must not regress.
    func testACompletePairingStillRestoresAsConnected() {
        XCTAssertEqual(
            ChatOpsPairingRestore.state(credentials: .present, addressPresent: true,
                                        authorizedUserID: "12345", chatID: 42),
            .connected(chatID: 42))
    }

    /// Missing credentials or a missing address is "never paired", not "needs re-pairing" — the two
    /// must not be conflated, because only one of them is a surprise to the user.
    func testAnIncompletePairingRestoresAsDisconnected() {
        for (creds, addr) in [(ChatOpsCredentialState.absent, true), (.present, false), (.absent, false)] {
            let state = ChatOpsPairingRestore.state(
                credentials: creds, addressPresent: addr, authorizedUserID: nil, chatID: 42)
            XCTAssertEqual(state, .disconnected, "creds=\(creds) addr=\(addr)")
            XCTAssertFalse(state.needsRepairing)
        }
    }

    /// ⚠️ `needsRepairing` must NOT match every `.error`. A revoked bot token also lands in `.error`
    /// and re-pairing does not fix it; the Settings pane uses this to choose its button label.
    func testATerminalTokenFailureIsNotMistakenForAnUpgrade() {
        XCTAssertFalse(ChatOpsConnectionState.error("Telegram rejected the bot token (401 Unauthorized)").needsRepairing)
        XCTAssertFalse(ChatOpsConnectionState.connected(chatID: 1).needsRepairing)
        XCTAssertFalse(ChatOpsConnectionState.disconnected.needsRepairing)
    }

    // MARK: - NEW-1: the dead end

    /// ⚠️⚠️ THE ONE-WAY DOOR, which predates NEW-1 and is why NEW-1's state could not simply be
    /// `.error`. `.error` rendered a bare warning line with NO control, while `.disconnected` — one
    /// rung below it — held the only "Start Pairing" button in the pane, and the Enable toggle is
    /// separately `.disabled(!isConnected)`. So a pairing timeout set
    /// `.error("Pairing timed out — ... Start pairing again.")` and then offered the user nothing
    /// with which to start pairing again.
    func testEveryErrorStateOffersAWayOut() throws {
        let view = try ChatOpsSecurityTierMatrixTests
            .readSourceStrippingComments("Devgentic/ChatOps/Settings/ChatOpsSettingsView.swift")

        var armsWithoutAButton = 0
        var searched = view[view.startIndex...]
        var armsFound = 0
        while let arm = searched.range(of: "case .error(let message):") {
            armsFound += 1
            let body = searched[arm.upperBound...].prefix(900)
            if !body.contains("Button(") { armsWithoutAButton += 1 }
            searched = searched[arm.upperBound...]
        }

        XCTAssertEqual(armsFound, 3, "one .error arm per provider tab — if this changed, the scan is blind")
        XCTAssertEqual(armsWithoutAButton, 0,
                       "an .error state with no control is a dead end: a pairing timeout, a revoked "
                       + "token and an un-upgraded pairing all land there and the Enable toggle is "
                       + "greyed out by isConnected")
    }

    // MARK: - NEW-2: a chat id is not an account

    /// ⚠️ THE FIX IS A SEPARATION, so the test asserts the separation rather than a value. The ledger
    /// legitimately falls back to the chat id; the identity must not.
    func testPairingRecordsTheSenderAndNeverTheChatID() throws {
        let source = try ChatOpsSecurityTierMatrixTests
            .readSourceStrippingComments("Devgentic/ChatOps/Services/ChatOpsPairingService.swift")

        XCTAssertTrue(source.contains("config.authorizedUserID = senderID"),
                      "the authorized identity must be the SENDER, never the ledger's `origin`, "
                      + "which falls back to the chat id for channel posts")
        XCTAssertFalse(source.contains("config.authorizedUserID = origin"),
                       "`origin` is the lockout ledger's value — its own comment says so — and a chat "
                       + "id stored there is refused forever by ChatOpsSecurityGate, which has no fallback")
        XCTAssertTrue(source.contains("guard let senderID else"),
                      "an unattributable PIN must be refused, not paired against something that is not an account")
    }

    /// The gate's read side has no chat-id fallback — which is exactly why the write side must not
    /// invent one. If this ever gains a fallback, NEW-2's fix needs revisiting rather than silently
    /// becoming redundant.
    func testTheGateResolvesASenderWithNoChatIDFallback() throws {
        let gate = try ChatOpsSecurityTierMatrixTests
            .readSourceStrippingComments("Devgentic/ChatOps/Services/ChatOpsSecurityGate.swift")
        guard let range = gate.range(of: "let sender = ") else {
            return XCTFail("ChatOpsSecurityGate no longer resolves a sender — this test is blind")
        }
        let expr = String(gate[range.lowerBound...].prefix(200))
        XCTAssertTrue(expr.contains("from?.id"), "the sender is the account, not the room")
        XCTAssertFalse(expr.contains("chatID"),
                       "if the gate ever falls back to the chat id, the pairing side's refusal to do "
                       + "so stops being the thing that keeps them in agreement")
    }

    // MARK: - NEW-5: a correct PIN must never vanish

    /// ⚠️⚠️ THE DROP SITS AFTER `classify` HAS ALREADY RULED THE MESSAGE A MATCH — the `.wrongPIN` arm
    /// returns above it — so a bare `continue` there discards the user's REAL PIN three lines before
    /// the assignments that would complete pairing, with no trace anywhere. Every neighbouring
    /// refusal in that loop names its consequence; this one said nothing, so a user whose pairing
    /// silently failed could not tell it apart from a bot that never got the message.
    func testACorrectSlackPINIsNeverDiscardedSilently() throws {
        let source = try ChatOpsSecurityTierMatrixTests
            .readSource("Devgentic/ChatOps/Services/SlackPairingService.swift")
        guard let range = source.range(of: "guard let channelID = slackEvent.channel else") else {
            return XCTFail("the channel guard has moved — this test is blind")
        }
        let arm = String(source[range.lowerBound...].prefix(700))
        XCTAssertFalse(arm.hasPrefix("guard let channelID = slackEvent.channel else { continue }"),
                       "a correct PIN is being dropped on a bare continue")
        XCTAssertTrue(arm.contains("logger.error"), "the drop must be logged")
        XCTAssertTrue(arm.contains("CONSEQUENCE:"),
                      "per the logging standard, every silent drop names what followed from it")
    }

    /// ⚠️ THE COUNTERPART, so this does not become "log every non-match". `PairingAttemptPolicy`'s
    /// whole design is that ordinary chatter during a 5-minute window must NOT be logged — a line per
    /// message buries the one event that matters. `.unrelated` staying silent is correct, and a
    /// future reader tempted to "fix" it should fail this test instead.
    func testUnrelatedChatterDuringAPairingWindowStaysUnlogged() throws {
        for service in ["ChatOpsPairingService", "DiscordPairingService", "SlackPairingService"] {
            let source = try ChatOpsSecurityTierMatrixTests
                .readSourceStrippingComments("Devgentic/ChatOps/Services/\(service).swift")
            XCTAssertTrue(source.contains("guard attempt != .unrelated else { continue }"),
                          "\(service) must drop unrelated chatter WITHOUT logging — see PairingAttemptPolicy's "
                          + "header for why logging every non-match is worse than logging nothing")
        }
    }

    // MARK: - NEW-1: the remote user is told, once

    func testTheUpgradeConditionIsAnAddressWithNoAccount() {
        XCTAssertTrue(ChatOpsUpgradeNotice.needsRepairing(addressPresent: true, authorizedUserID: nil))
        XCTAssertFalse(ChatOpsUpgradeNotice.needsRepairing(addressPresent: true, authorizedUserID: "u1"),
                       "a complete pairing must never be told to re-pair")
        XCTAssertFalse(ChatOpsUpgradeNotice.needsRepairing(addressPresent: false, authorizedUserID: nil),
                       "never paired is not the same as needs re-pairing — there is nowhere to post it")
    }

    /// ⚠️ `start()` runs on every launch AND every toggle. A bot that repeats itself gets muted.
    @MainActor
    func testTheNoticeIsClaimedOncePerProvider() {
        ChatOpsUpgradeNotice.resetForTesting()
        XCTAssertTrue(ChatOpsUpgradeNotice.claimAnnouncement(for: .telegram))
        XCTAssertFalse(ChatOpsUpgradeNotice.claimAnnouncement(for: .telegram), "second start must stay quiet")
        XCTAssertTrue(ChatOpsUpgradeNotice.claimAnnouncement(for: .discord), "providers are independent")
        ChatOpsUpgradeNotice.resetForTesting()
    }

    /// The copy has to name the fix and where to do it — "something went wrong" leaves the user as
    /// stuck as the silence did.
    @MainActor
    func testTheNoticeNamesTheFixAndWhereToPerformIt() {
        let m = ChatOpsUpgradeNotice.message
        XCTAssertTrue(m.contains("Settings"))
        XCTAssertTrue(m.localizedCaseInsensitiveContains("re-pair"))
        XCTAssertTrue(m.localizedCaseInsensitiveContains("refused"),
                      "it must explain the silence they have already experienced")
    }

    /// ⚠️ THE WIRING. The condition and the dedup are worthless if no bridge consults them — and all
    /// three must, because a user on one platform is as stranded as a user on another.
    func testAllThreeBridgesAnnounceTheUpgrade() throws {
        for bridge in ["ChatOpsBridge", "DiscordChatOpsBridge", "SlackChatOpsBridge"] {
            let source = try ChatOpsSecurityTierMatrixTests
                .readSourceStrippingComments("Devgentic/ChatOps/Services/\(bridge).swift")
            XCTAssertTrue(source.contains("ChatOpsUpgradeNotice.needsRepairing"),
                          "\(bridge) must detect the upgrade case")
            XCTAssertTrue(source.contains("ChatOpsUpgradeNotice.claimAnnouncement"),
                          "\(bridge) must dedup the notice")
        }
    }

    /// ⚠️ THE SAFETY BOUNDARY. The notice goes only to the ALREADY-PAIRED address. A bystander in a
    /// shared room hits `sender != expected`, a different branch, which must stay silent so the bot
    /// cannot be used to probe.
    func testTheNoticeIsPostedOnlyToThePairedAddress() throws {
        for (bridge, addr) in [("ChatOpsBridge", "authorizedChatID"),
                               ("DiscordChatOpsBridge", "discordAuthorizedChannelID"),
                               ("SlackChatOpsBridge", "slackAuthorizedChannelID")] {
            let source = try ChatOpsSecurityTierMatrixTests
                .readSourceStrippingComments("Devgentic/ChatOps/Services/\(bridge).swift")
            guard let range = source.range(of: "ChatOpsUpgradeNotice.claimAnnouncement") else {
                return XCTFail("\(bridge) does not announce — covered by the wiring test")
            }
            let block = String(source[range.lowerBound...].prefix(700))
            XCTAssertTrue(block.contains(addr),
                          "\(bridge) must post to the paired address it already holds, never to an "
                          + "address taken from the inbound message")
        }
    }
}
