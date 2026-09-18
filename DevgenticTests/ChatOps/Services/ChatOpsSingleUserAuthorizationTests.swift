// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsSingleUserAuthorizationTests.swift
//  devgenticTests
//
//  ChatOps authorizes ONE account. This is where that is enforced rather than assumed.
//
//  ⚠️⚠️ THE FAILURE THIS PINS. Authorization compared the CHAT — or on Discord and Slack the CHANNEL —
//  and nothing else. A Telegram chat id in a DM happens to identify a person, so the single-user
//  assumption held there by accident; a Telegram GROUP, a Discord channel and a Slack channel all
//  identify a ROOM. Every member of one could send commands, answer clarifications and, at `.full`,
//  tap Approve on a mirrored tool call. The sender was decoded on all three platforms
//  (`DiscordMessage.author`, Slack's `user`, Telegram's `from`) and read only to skip the bot's own
//  messages — a repo-wide grep for any per-sender authorization symbol returned zero hits.
//
//  ⚠️ THE POLICY IS "ENFORCE WHAT WAS INTENDED", NOT "ADD GROUP SUPPORT". ChatOps was always a
//  single-user remote control, so the fix records the account that completes pairing and refuses
//  every other — rather than growing an allowlist for the multi-user case that was never the design.
//

import XCTest
@testable import devgentic

final class ChatOpsSingleUserAuthorizationTests: XCTestCase {

    // MARK: - The comparison itself

    /// ⚠️ FAIL CLOSED WHEN NOTHING WAS RECORDED. A pairing made before this check existed has no
    /// stored account, and treating "unknown" as "anyone" is the original hole with extra steps.
    /// Re-pairing is the documented fix and the log line names it.
    func testAPairingWithNoRecordedAccountRefusesEveryone() async {
        let gate = ChatOpsSecurityGate()
        let allowed = await gate.senderIsAuthorized("U123", expected: nil, platform: "Slack")
        XCTAssertFalse(allowed, """
            A pairing that recorded no account must refuse every sender. Admitting one here would \
            re-open exactly the hole this check closes, and would do it silently.
            """)
    }

    /// ⚠️ An unattributable message cannot be checked, so it cannot be trusted.
    /// `PairingAttemptPolicy` refuses to count these for the same reason.
    func testAnUnattributableMessageIsRefused() async {
        let gate = ChatOpsSecurityGate()
        let allowed = await gate.senderIsAuthorized(nil, expected: "U123", platform: "Slack")
        XCTAssertFalse(allowed)
    }

    func testOnlyThePairedAccountIsAdmitted() async {
        let gate = ChatOpsSecurityGate()
        let mine = await gate.senderIsAuthorized("U123", expected: "U123", platform: "Discord")
        let theirs = await gate.senderIsAuthorized("U999", expected: "U123", platform: "Discord")

        XCTAssertTrue(mine, "the account that completed pairing must be admitted")
        XCTAssertFalse(theirs, """
            A different member of the paired room was admitted. ChatOps authorizes ONE account; \
            anyone else in a shared channel or group is a bystander, not an operator.
            """)
    }

    // MARK: - Wiring

    /// ⚠️ THE HALF THAT MATTERS. A correct comparison changes nothing if the entry points do not
    /// pass a sender — which none of them did. Reads the real gate source: drop a `senderID`
    /// parameter and this goes red.
    func testEveryGateEntryPointTakesASender() throws {
        let gate = try ChatOpsSecurityTierMatrixTests.readSource("Devgentic/ChatOps/Services/ChatOpsSecurityGate.swift")

        for signature in ["func authorizeDiscord(channelID: String, senderID: String?",
                          "func authorizeSlack(channelID: String, senderID: String?"] {
            XCTAssertTrue(gate.contains(signature), """
                `\(signature)…` is gone. Without a sender the gate can only compare the room, and \
                every member of that room is authorized again.
                """)
        }

        // Telegram takes the whole update, so it reads the sender itself.
        XCTAssertTrue(gate.contains("update.message?.from?.id.description"),
                      "the Telegram path no longer reads the message sender.")
        XCTAssertTrue(gate.contains("update.callback_query.map { $0.from.id.description }"),
                      "the Telegram path no longer attributes BUTTON TAPS; a tap is as much a command as a typed line.")

        // All three authorize* methods must consult the shared comparison.
        XCTAssertEqual(gate.components(separatedBy: "senderIsAuthorized(").count - 1, 4,
                       "expected three call sites plus the declaration — a platform has stopped checking its sender.")
    }

    /// Every inbound bridge call site must supply a real sender rather than nil.
    func testEveryBridgeCallSiteSuppliesASender() throws {
        let discord = try ChatOpsSecurityTierMatrixTests.readSource("Devgentic/ChatOps/Services/DiscordChatOpsBridge.swift")
        XCTAssertTrue(discord.contains("senderID: message.author.id"),
                      "the Discord message path no longer passes its author.")
        XCTAssertTrue(discord.contains("senderID: interaction.member?.user?.id"),
                      "the Discord interaction path no longer passes the tapping member.")

        let slack = try ChatOpsSecurityTierMatrixTests.readSource("Devgentic/ChatOps/Services/SlackChatOpsBridge.swift")
        for site in ["senderID: event.user", "senderID: payload.user?.id", "senderID: payload.user_id"] {
            XCTAssertTrue(slack.contains(site), "a Slack entry point stopped passing its sender: expected `\(site)`.")
        }
    }

    /// ⚠️ THE ACCOUNT IS RECORDED AT THE ONE MOMENT IT IS PROVEN — the PIN match. `origin` is the
    /// same value the lockout ledger already computes, so nothing new has to be derived.
    func testAllThreePairingServicesRecordThePairedAccount() throws {
        // ⚠️⚠️ TELEGRAM RECORDS `senderID`, NOT `origin`, AND THAT DIFFERENCE IS THE POINT. This
        //   test used to assert `config.authorizedUserID = origin` on all three — i.e. it pinned
        //   NEW-2 in place. `origin` is the LOCKOUT LEDGER's value and falls back to the chat id for
        //   a message with no sender; storing it as an identity paired against something that is not
        //   an account, after which `ChatOpsSecurityGate` — which has no such fallback — refused
        //   every later message forever. Discord's `origin` is `message.author.id` and Slack's is a
        //   guarded `slackEvent.user`, so both are already senders and keep their spelling.
        let cases = [
            ("Devgentic/ChatOps/Services/ChatOpsPairingService.swift", "config.authorizedUserID = senderID"),
            ("Devgentic/ChatOps/Services/DiscordPairingService.swift", "config.discordAuthorizedUserID = origin"),
            ("Devgentic/ChatOps/Services/SlackPairingService.swift", "config.slackAuthorizedUserID = origin")
        ]
        for (path, expected) in cases {
            let source = try ChatOpsSecurityTierMatrixTests.readSource(path)
            XCTAssertTrue(source.contains(expected), """
                \(path) no longer records the paired account. Pairing would then succeed while \
                leaving nothing to compare against, and — because the gate fails closed — the user \
                would be locked out of a bot that just told them pairing worked.
                """)
        }
    }

    /// Disconnecting must forget the account, or a later re-pair silently inherits the old one.
    func testDisconnectClearsThePairedAccount() throws {
        let source = try ChatOpsSecurityTierMatrixTests.readSource("Devgentic/ChatOps/Models/ChatOpsConfig.swift")
        for property in ["authorizedUserID = nil", "discordAuthorizedUserID = nil", "slackAuthorizedUserID = nil"] {
            XCTAssertTrue(source.contains(property),
                          "disconnect leaves `\(property.replacingOccurrences(of: " = nil", with: ""))` behind.")
        }
    }
}
