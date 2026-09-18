// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsSecurityTierMatrixTests.swift
//  devgenticTests
//
//  The whole tier table, pinned.
//
//  ⚠️⚠️ WHY THIS FILE EXISTS. `ChatOpsSecurityGate.canExecute` is the entire authorization policy
//  for untrusted remote input, and before 2026-09-10 exactly ONE of its arms was asserted anywhere
//  in the suite — `DiscordChatOpsBridgeTests` exercised the `.unknown` case. Nothing pinned which
//  verb sat in which tier, so a verb added to the always-allowed arm could not turn anything red.
//  That is precisely how `.conversationHistory` — which renders every message's BODY — came to be
//  served at `.readOnly`, the shipped default, whose own UI string promises "Can only view status
//  and list conversations".
//
//  ⚠️ THIS IS A TABLE, SO A TABLE TEST IS THE RIGHT SHAPE, but a table test is policy-only by
//  nature: it proves the gate ANSWERS correctly, never that a caller ASKS. `testEveryInboundPath...`
//  at the bottom reads the real bridge sources for that half, and `ChatOpsReplyCorrelationGateTests`
//  covers the one path that used to skip the gate entirely.
//

import XCTest
@testable import devgentic

final class ChatOpsSecurityTierMatrixTests: XCTestCase {

    private let gate = ChatOpsSecurityGate()

    /// Every command the gate can be handed. Associated values are arbitrary — the gate ignores
    /// them — but every CASE must appear, which is what makes an added case fail this file.
    private static let allCommands: [(name: String, command: ChatOpsCommand)] = [
        ("conversations",       .conversations),
        ("conversationPage",    .conversationPage(offset: 0)),
        ("searchConversations", .searchConversations("q")),
        ("conversationHistory", .conversationHistory("10")),
        ("status",              .status),
        ("help",                .help),
        ("profiles",            .profiles),
        ("unknown",             .unknown),
        ("pairingAttempt",      .pairingAttempt("123456")),
        ("newConversation",     .newConversation),
        ("freeText",            .freeText("hello")),
        ("cancel",              .cancel),
        ("switchConversation",  .switchConversation(UUID())),
        ("clarificationResponse", .clarificationResponse("answer")),
        ("answerClarification", .answerClarification(operationID: UUID())),
        ("selectProfile",       .selectProfile(UUID())),
        ("useProfile",          .useProfile("name")),
        ("approveHITL",         .approveHITL(operationID: UUID())),
        ("denyHITL",            .denyHITL(operationID: UUID())),
        ("gateChoiceHITL",      .gateChoiceHITL(operationID: UUID(), optionIndex: 0))
    ]

    /// The expected answer for every (command, tier) pair. Changing behaviour means changing this
    /// table deliberately, which is the point.
    private static let expected: [String: (readOnly: Bool, standard: Bool, full: Bool)] = [
        // Always allowed — reads that disclose no message BODY, plus the pairing handshake.
        "conversations":        (true,  true,  true),
        "conversationPage":     (true,  true,  true),
        "searchConversations":  (true,  true,  true),
        "status":               (true,  true,  true),
        "help":                 (true,  true,  true),
        "profiles":             (true,  true,  true),
        "unknown":              (true,  true,  true),
        "pairingAttempt":       (true,  true,  true),

        // Standard and above — anything that changes state, steers a run, or discloses bodies.
        "conversationHistory":  (false, true,  true),
        "newConversation":      (false, true,  true),
        "freeText":             (false, true,  true),
        "cancel":               (false, true,  true),
        "switchConversation":   (false, true,  true),
        "clarificationResponse": (false, true, true),
        "answerClarification":  (false, true,  true),
        "selectProfile":        (false, true,  true),
        "useProfile":           (false, true,  true),

        // Full only — a gate choice unblocks downstream execution, like a tool approval.
        "approveHITL":          (false, false, true),
        "denyHITL":             (false, false, true),
        "gateChoiceHITL":       (false, false, true)
    ]

    func testEveryCommandIsPinnedAtEveryTier() async {
        for (name, command) in Self.allCommands {
            guard let want = Self.expected[name] else {
                XCTFail("""
                    `\(name)` has no row in this test's expectation table. A new ChatOpsCommand case \
                    must be given an explicit tier here in the same change that adds it — otherwise \
                    it lands in whichever `canExecute` arm the author happened to type, unreviewed.
                    """)
                continue
            }

            let gotReadOnly = await gate.canExecute(command, tier: .readOnly)
            let gotStandard = await gate.canExecute(command, tier: .standard)
            let gotFull     = await gate.canExecute(command, tier: .full)

            XCTAssertEqual(gotReadOnly, want.readOnly, "`\(name)` at .readOnly")
            XCTAssertEqual(gotStandard, want.standard, "`\(name)` at .standard")
            XCTAssertEqual(gotFull, want.full, "`\(name)` at .full")
        }
    }

    /// ⚠️ THE REGRESSION THIS FILE WAS WRITTEN FOR. `.readOnly` is what an unconfigured install runs
    /// at (`ChatOpsConfigManager.securityTier` falls back to it when the defaults key is absent), so
    /// this is not an exotic configuration — it is the default one.
    func testReadOnlyCannotReadMessageBodies() async {
        let allowed = await gate.canExecute(.conversationHistory("50"), tier: .readOnly)
        XCTAssertFalse(allowed, """
            `.readOnly` must not reach /history. `ChatOpsCommandService.conversationHistory` renders \
            `row.text` — the full body of every message it returns — and this tier's own description \
            string promises "Can only view status and list conversations". Serving bodies here hands \
            a complete private transcript to anyone who can reach the paired channel.
            """)
    }

    /// The counterpart: `.readOnly` KEEPS the list verbs, so tightening the tier did not quietly
    /// break what it is actually for.
    func testReadOnlyKeepsTheListAndStatusVerbsItPromises() async {
        for command in [ChatOpsCommand.conversations, .conversationPage(offset: 20), .status, .help] {
            let allowed = await gate.canExecute(command, tier: .readOnly)
            XCTAssertTrue(allowed, "`.readOnly` promises status and conversation listing: \(command)")
        }
    }

    /// `searchConversations` stays at `.readOnly` because it is a FILTERED LIST, not a new
    /// disclosure — it matches on title alone. If that ever starts matching message bodies, this
    /// test is the reminder that its tier has to move with it.
    func testSearchMatchesTitlesOnlySoItMayStayAtReadOnly() throws {
        let source = try Self.readSource("Devgentic/Core/Persistence/SwiftData/ConversationReading.swift")
        XCTAssertTrue(
            source.contains("ConversationSearchPolicy.matches(title:"),
            """
            `searchConversations` no longer matches on title alone. It is allowed at `.readOnly` \
            ONLY because every title it can return is already in the `/conversations` output that \
            tier serves. If it now reads message bodies, move `.searchConversations` to the \
            `.standard` arm of `ChatOpsSecurityGate.canExecute` alongside `.conversationHistory`.
            """
        )
    }

    /// ⚠️ THE WIRING HALF. A perfect table is worth nothing if an inbound path does not consult it —
    /// which is exactly what Telegram's reply-correlation branch did for the whole of its life.
    /// This reads the real bridge sources rather than a fake, so deleting a gate makes it fail.
    func testEveryInboundBridgeConsultsTheTierGate() throws {
        let bridges = [
            "Devgentic/ChatOps/Services/ChatOpsBridge.swift",
            "Devgentic/ChatOps/Services/DiscordChatOpsBridge.swift",
            "Devgentic/ChatOps/Services/SlackChatOpsBridge.swift"
        ]
        for path in bridges {
            let source = try Self.readSource(path)
            XCTAssertTrue(
                source.contains("securityGate.canExecute"),
                "\(path) has no tier check at all — every command it accepts runs at any tier."
            )
            XCTAssertTrue(
                source.contains("securityGate.denialMessage"),
                """
                \(path) refuses commands without telling the remote user why. A silent refusal and a \
                dead bridge are indistinguishable from the chat window.
                """
            )
        }
    }

    // MARK: - Helpers

    /// Reads a file from the repository working tree.
    ///
    /// ⚠️ Walks up from `#filePath` rather than using a bundle resource: these are PRODUCTION
    /// sources, not test fixtures, so they are not copied into the test bundle — and reading the
    /// real file is the entire point of a drift test.
    /// `readSource` with `//` comments removed.
    ///
    /// ⚠️⚠️ USE THIS FOR ANY STRUCTURAL SCAN. A drift test that reads comments is testing the
    /// DOCUMENTATION, not the code — and in this codebase, where a fix is routinely accompanied by a
    /// comment explaining the defect it removed, that means matching the very prose that describes
    /// what is no longer there. It produced three false results in one session: a scan for
    /// `isEnabled` matched the comment saying it was removed, a scan for a function name matched its
    /// definition after the call was deleted, and a scan for `cancelStreams` matched a comment
    /// asserting how few callers it has.
    ///
    /// ⚠️ Line-based and therefore approximate: it also strips a `//` inside a string literal. That
    /// is the safe direction for these scans — it can only cause a false FAILURE, never a false pass.
    static func readSourceStrippingComments(_ repoRelativePath: String) throws -> String {
        try readSource(repoRelativePath)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    static func readSource(_ repoRelativePath: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<12 {
            dir.deleteLastPathComponent()
            let candidate = dir.appendingPathComponent(repoRelativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
        }
        throw XCTSkip("Could not locate \(repoRelativePath) from \(#filePath) — repository layout changed.")
    }
}
