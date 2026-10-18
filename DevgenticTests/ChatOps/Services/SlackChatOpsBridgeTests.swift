// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SlackChatOpsBridgeTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class SlackChatOpsBridgeTests: XCTestCase {

    // MARK: - Bot Message Filtering

    func testBotMessage_ShouldBeIgnored() throws {
        let json = """
        {
            "type": "message",
            "channel": "C01",
            "text": "Bot response",
            "ts": "1716307200.000001",
            "bot_id": "B0123456789"
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(SlackEvent.self, from: json)
        XCTAssertNotNil(event.bot_id) // Bridge checks bot_id != nil to skip
    }

    func testHumanMessage_ShouldBeProcessed() throws {
        let json = """
        {
            "type": "message",
            "channel": "C01",
            "user": "U01",
            "text": "Hello agent",
            "ts": "1716307200.000002"
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(SlackEvent.self, from: json)
        XCTAssertNil(event.bot_id)
        XCTAssertNil(event.subtype)
    }

    func testSubtypeMessage_ShouldBeIgnored() throws {
        let json = """
        {
            "type": "message",
            "subtype": "message_changed",
            "channel": "C01",
            "ts": "1716307200.000003"
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(SlackEvent.self, from: json)
        XCTAssertNotNil(event.subtype) // Bridge checks subtype == nil
    }

    // MARK: - Slash Command Routing

    func testSlashCommand_ConversationsRoutes() {
        let command = ChatOpsCommand.parseSlack(slashCommand: "/conversations")
        if case .conversations = command { } else {
            XCTFail("Expected .conversations")
        }
    }

    func testSlashCommand_NewRoutes() {
        let command = ChatOpsCommand.parseSlack(slashCommand: "/new")
        if case .newConversation = command { } else {
            XCTFail("Expected .newConversation")
        }
    }

    func testSlashCommand_StatusRoutes() {
        let command = ChatOpsCommand.parseSlack(slashCommand: "/status")
        if case .status = command { } else {
            XCTFail("Expected .status")
        }
    }

    func testSlashCommand_CancelRoutes() {
        let command = ChatOpsCommand.parseSlack(slashCommand: "/cancel")
        if case .cancel = command { } else {
            XCTFail("Expected .cancel")
        }
    }

    func testSlashCommand_HelpRoutes() {
        let command = ChatOpsCommand.parseSlack(slashCommand: "/help")
        if case .help = command { } else {
            XCTFail("Expected .help")
        }
    }

    // MARK: - Interactive Payload → HITL Routing

    func testInteraction_ApproveButton() {
        let uuid = UUID()
        let command = ChatOpsCommand.parseSlack(actionID: "hitl:approve:\(uuid.uuidString)")
        if case .approveHITL(let opID) = command {
            XCTAssertEqual(opID, uuid)
        } else {
            XCTFail("Expected .approveHITL")
        }
    }

    func testInteraction_DenyButton() {
        let uuid = UUID()
        let command = ChatOpsCommand.parseSlack(actionID: "hitl:deny:\(uuid.uuidString)")
        if case .denyHITL(let opID) = command {
            XCTAssertEqual(opID, uuid)
        } else {
            XCTFail("Expected .denyHITL")
        }
    }

    func testInteraction_SwitchConversation() {
        let uuid = UUID()
        let command = ChatOpsCommand.parseSlack(actionID: "switch:\(uuid.uuidString)")
        if case .switchConversation(let convID) = command {
            XCTAssertEqual(convID, uuid)
        } else {
            XCTFail("Expected .switchConversation")
        }
    }

    // MARK: - Slack MessageSource

    func testMessageSource_SlackExists() {
        let source = MessageSource.slack
        XCTAssertEqual(source.rawValue, "slack")
    }

    func testAllMessageSources() {
        let sources: [MessageSource] = [.localUI, .telegram, .discord, .slack]
        XCTAssertEqual(sources.count, 4)
    }

    // MARK: - Channel Security

    func testChannelID_ExtractedFromEvent() throws {
        let json = """
        {
            "type": "message",
            "channel": "C0123456789",
            "user": "U01",
            "text": "test",
            "ts": "1716307200.000004"
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(SlackEvent.self, from: json)
        XCTAssertEqual(event.channel, "C0123456789")
    }

    func testChannelID_ExtractedFromInteraction() throws {
        let json = """
        {
            "type": "block_actions",
            "actions": [{ "action_id": "test", "type": "button" }],
            "channel": { "id": "C0123456789" }
        }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(SlackInteractivePayload.self, from: json)
        XCTAssertEqual(payload.channel?.id, "C0123456789")
    }

    // MARK: - The channel allowlist and its missing-evidence case

    /// ⚠️⚠️ THE SAME BYPASS DISCORD CARRIED, IN THE SAME SHAPE. `authorizeSlack` decides by
    /// comparing its argument against `slackAuthorizedChannelID`, and the caller passed
    /// `payload.channel?.id ?? config.slackAuthorizedChannelID` — so a payload with no channel was
    /// authorized by construction.
    ///
    /// ⚠️ VIEW SUBMISSIONS ARE THE ONE REAL NO-CHANNEL CASE and they never reach this gate: they are
    /// routed to `resolveClarificationModal` first, which documents its own exemption and still
    /// applies the tier gate. That is why refusing here is safe rather than a regression to the
    /// modal flow.
    ///
    /// Mutation that must turn this red: pass `replyChannelID` to `authorizeSlack`, or restore the
    /// single `let channelID = payload.channel?.id ?? config.slackAuthorizedChannelID`.
    func testTheChannelAllowlistIsNeverGivenTheFallbackValue() throws {
        let source = try Self.readBridgeSource()
        let start = try XCTUnwrap(source.range(of: "private func handleInteraction("),
                                  "handleInteraction was renamed — this test no longer guards anything")
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    /// Opens the free-text modal")?.lowerBound ?? rest.endIndex
        let body = String(rest[..<end])

        XCTAssertTrue(body.contains("authorizeSlack(channelID: originChannelID"),
                      "the allowlist must be given the payload's own channel, never a default")
        XCTAssertFalse(body.contains("authorizeSlack(channelID: replyChannelID"),
                       "feeding the reply address to the gate reintroduces the bypass")
        XCTAssertTrue(body.contains("let originChannelID = payload.channel?.id\n"),
                      "the evidence value must have no fallback at all")
    }

    /// ⚠️ THE ROUTING THAT MAKES THE REFUSAL SAFE. If a view submission ever reached the actions
    /// path it would now be refused for having no channel, and the user's typed answer would be
    /// dropped — so the order of these two branches is load-bearing for the fix above.
    func testViewSubmissionsAreRoutedBeforeTheChannelGate() throws {
        let source = try Self.readBridgeSource()
        let start = try XCTUnwrap(source.range(of: "private func handleInteraction("))
        let rest = String(source[start.upperBound...])

        let submissionBranch = try XCTUnwrap(rest.range(of: "SlackInteractivePayload.viewSubmission"))
        let channelGate = try XCTUnwrap(rest.range(of: "authorizeSlack(channelID:"))
        XCTAssertLessThan(submissionBranch.lowerBound, channelGate.lowerBound,
                          "a view submission reaching the channel gate would have its answer dropped")
    }

    private static func readBridgeSource() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent("Devgentic/ChatOps/Services/SlackChatOpsBridge.swift")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("SlackChatOpsBridge.swift not reachable — running outside a checkout")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
