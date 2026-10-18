// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SlackModelsTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class SlackModelsTests: XCTestCase {

    // MARK: - SlackEvent Decoding

    func testSlackEvent_DecodesMessageEvent() throws {
        let json = """
        {
            "type": "message",
            "channel": "C0123456789",
            "user": "U0123456789",
            "text": "Hello from Slack",
            "ts": "1716307200.123456"
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(SlackEvent.self, from: json)

        XCTAssertEqual(event.type, "message")
        XCTAssertEqual(event.channel, "C0123456789")
        XCTAssertEqual(event.user, "U0123456789")
        XCTAssertEqual(event.text, "Hello from Slack")
        XCTAssertEqual(event.ts, "1716307200.123456")
        XCTAssertNil(event.bot_id)
    }

    func testSlackEvent_BotMessageDetected() throws {
        let json = """
        {
            "type": "message",
            "channel": "C0123456789",
            "text": "Bot response",
            "ts": "1716307200.789012",
            "bot_id": "B0123456789"
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(SlackEvent.self, from: json)
        XCTAssertEqual(event.bot_id, "B0123456789")
    }

    func testSlackEvent_SubtypeDetected() throws {
        let json = """
        {
            "type": "message",
            "subtype": "bot_message",
            "channel": "C01",
            "text": "edited",
            "ts": "1716307200.000001"
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(SlackEvent.self, from: json)
        XCTAssertEqual(event.subtype, "bot_message")
    }

    // MARK: - SlackInteractivePayload Decoding

    func testInteractivePayload_BlockActions() throws {
        let json = """
        {
            "type": "block_actions",
            "actions": [
                {
                    "action_id": "hitl:approve:AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                    "block_id": "hitl_block",
                    "value": "approve",
                    "type": "button"
                }
            ],
            "channel": { "id": "C0123456789", "name": "general" },
            "user": { "id": "U0123456789", "username": "testuser", "name": "Test User" }
        }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(SlackInteractivePayload.self, from: json)

        XCTAssertEqual(payload.type, "block_actions")
        XCTAssertEqual(payload.actions?.count, 1)
        XCTAssertEqual(payload.actions?[0].action_id, "hitl:approve:AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        XCTAssertEqual(payload.actions?[0].type, "button")
        XCTAssertEqual(payload.channel?.id, "C0123456789")
    }

    // MARK: - SlackSlashCommandPayload

    func testSlashCommandPayload_Decoding() throws {
        let json = """
        {
            "command": "/conversations",
            "text": "",
            "channel_id": "C0123456789",
            "channel_name": "general",
            "user_id": "U0123456789",
            "user_name": "testuser"
        }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(SlackSlashCommandPayload.self, from: json)

        XCTAssertEqual(payload.command, "/conversations")
        XCTAssertEqual(payload.channel_id, "C0123456789")
        XCTAssertEqual(payload.user_name, "testuser")
    }

    // MARK: - Block Kit Button Encoding

    func testBlockElement_ButtonEncoding() throws {
        let button = SlackBlockElement.button(
            text: "Approve",
            actionID: "hitl:approve:test-uuid",
            value: "approve",
            style: SlackBlockElement.primaryStyle
        )

        let data = try JSONEncoder().encode(button)
        let decoded = try JSONDecoder().decode(SlackBlockElement.self, from: data)

        XCTAssertEqual(decoded.type, SlackBlockElement.buttonType)
        XCTAssertEqual(decoded.action_id, "hitl:approve:test-uuid")
        XCTAssertEqual(decoded.value, "approve")
        XCTAssertEqual(decoded.style, "primary")
        XCTAssertEqual(decoded.text?.text, "Approve")
    }

    func testBlockElement_DangerButton() throws {
        let button = SlackBlockElement.button(
            text: "Deny",
            actionID: "hitl:deny:test-uuid",
            value: "deny",
            style: SlackBlockElement.dangerStyle
        )

        XCTAssertEqual(button.style, "danger")
    }

    // MARK: - Block Kit Block Factories

    func testSectionBlock_Creation() throws {
        let block = SlackBlock.sectionBlock(text: "Hello *world*", blockID: "test_block")

        XCTAssertEqual(block.type, SlackBlock.section)
        XCTAssertEqual(block.block_id, "test_block")
        XCTAssertEqual(block.text?.type, "mrkdwn")
        XCTAssertEqual(block.text?.text, "Hello *world*")
    }

    func testActionsBlock_WithButtons() throws {
        let approve = SlackBlockElement.button(text: "Yes", actionID: "yes", style: "primary")
        let deny = SlackBlockElement.button(text: "No", actionID: "no", style: "danger")
        let block = SlackBlock.actionsBlock(elements: [approve, deny], blockID: "actions_1")

        XCTAssertEqual(block.type, SlackBlock.actions)
        XCTAssertEqual(block.elements?.count, 2)
        XCTAssertEqual(block.block_id, "actions_1")
    }

    // MARK: - SlackAuthTestResponse

    func testAuthTestResponse_Success() throws {
        let json = """
        {
            "ok": true,
            "user_id": "U0123",
            "user": "devgentic-bot",
            "team": "My Team",
            "team_id": "T0123",
            "bot_id": "B0123"
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(SlackAuthTestResponse.self, from: json)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.user, "devgentic-bot")
        XCTAssertEqual(response.team, "My Team")
        XCTAssertEqual(response.bot_id, "B0123")
    }

    func testAuthTestResponse_Failure() throws {
        let json = """
        { "ok": false, "error": "invalid_auth" }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(SlackAuthTestResponse.self, from: json)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "invalid_auth")
    }

    // MARK: - SlackSocketPayload Envelope

    func testSocketPayload_HelloType() throws {
        let json = """
        { "type": "hello" }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(SlackSocketPayload.self, from: json)
        XCTAssertEqual(payload.type, "hello")
        XCTAssertNil(payload.envelope_id)
    }

    func testSocketPayload_WithEnvelopeID() throws {
        let json = """
        {
            "type": "events_api",
            "envelope_id": "env-123-abc"
        }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(SlackSocketPayload.self, from: json)
        XCTAssertEqual(payload.type, "events_api")
        XCTAssertEqual(payload.envelope_id, "env-123-abc")
    }

    // MARK: - Socket Acknowledgment

    func testSocketAck_Encoding() throws {
        let ack = SlackSocketAck(envelope_id: "env-456-def")
        let data = try JSONEncoder().encode(ack)
        let json = String(data: data, encoding: .utf8)!

        XCTAssertTrue(json.contains("env-456-def"))
        XCTAssertTrue(json.contains("envelope_id"))
    }

    // MARK: - SlackAPIError

    func testSlackAPIError_Descriptions() {
        let apiError = SlackAPIError.apiError(method: "chat.postMessage", error: "channel_not_found")
        XCTAssertTrue(apiError.localizedDescription.contains("chat.postMessage"))
        XCTAssertTrue(apiError.localizedDescription.contains("channel_not_found"))

        let rateLimited = SlackAPIError.rateLimited(retryAfter: 3.0)
        XCTAssertTrue(rateLimited.localizedDescription.contains("3.0"))

        let invalidToken = SlackAPIError.invalidToken
        XCTAssertTrue(invalidToken.localizedDescription.contains("Invalid"))

        let disconnected = SlackAPIError.socketDisconnected(reason: "Server restart")
        XCTAssertTrue(disconnected.localizedDescription.contains("Server restart"))
    }

    // MARK: - Connection Open Response

    func testConnectionOpenResponse_Success() throws {
        let json = """
        { "ok": true, "url": "wss://wss-primary.slack.com/link/?ticket=abc123" }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(SlackConnectionOpenResponse.self, from: json)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.url, "wss://wss-primary.slack.com/link/?ticket=abc123")
    }

    func testConnectionOpenResponse_Failure() throws {
        let json = """
        { "ok": false, "error": "invalid_auth" }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(SlackConnectionOpenResponse.self, from: json)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "invalid_auth")
    }
}
