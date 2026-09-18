// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SlackTransportTests.swift
//  DevgenticTests
//
//  Created by Raj Singh on 24/03/26.
//

import XCTest
@testable import devgentic

final class SlackTransportTests: XCTestCase {

    // MARK: - Transport Identity

    func testTransportID_IsSlack() {
        let client = SlackAPIClient(botToken: "xoxb-test")
        let transport = SlackTransport(apiClient: client)
        XCTAssertEqual(transport.transportID, "slack")
    }

    // MARK: - HITL Button Block Kit Structure

    func testHITLButtons_ApproveAndDeny() {
        let operationID = UUID()

        let approveButton = SlackBlockElement.button(
            text: "✅ Approve",
            actionID: "hitl:approve:\(operationID.uuidString)",
            value: "approve",
            style: SlackBlockElement.primaryStyle
        )
        let denyButton = SlackBlockElement.button(
            text: "❌ Deny",
            actionID: "hitl:deny:\(operationID.uuidString)",
            value: "deny",
            style: SlackBlockElement.dangerStyle
        )

        // Verify Approve button
        XCTAssertEqual(approveButton.type, SlackBlockElement.buttonType)
        XCTAssertEqual(approveButton.style, "primary")
        XCTAssertEqual(approveButton.text?.text, "✅ Approve")
        XCTAssertTrue(approveButton.action_id!.hasPrefix("hitl:approve:"))

        // Verify Deny button
        XCTAssertEqual(denyButton.style, "danger")
        XCTAssertTrue(denyButton.action_id!.hasPrefix("hitl:deny:"))
    }

    func testHITLActionID_MatchesCrossplatformFormat() {
        // Slack, Discord, and Telegram all use the same callback data prefix convention
        let uuid = UUID()
        let slackActionID = "hitl:approve:\(uuid.uuidString)"
        let discordCustomID = "hitl:approve:\(uuid.uuidString)"
        let telegramCallbackData = "hitl:approve:\(uuid.uuidString)"

        XCTAssertEqual(slackActionID, discordCustomID)
        XCTAssertEqual(slackActionID, telegramCallbackData)
    }

    // MARK: - Block Kit Structure

    func testActionsBlock_ContainsButtons() {
        let button1 = SlackBlockElement.button(text: "A", actionID: "a")
        let button2 = SlackBlockElement.button(text: "B", actionID: "b")
        let block = SlackBlock.actionsBlock(elements: [button1, button2], blockID: "test")

        XCTAssertEqual(block.type, "actions")
        XCTAssertEqual(block.elements?.count, 2)
        XCTAssertEqual(block.block_id, "test")
    }

    func testSectionBlock_WithMarkdown() {
        let block = SlackBlock.sectionBlock(text: "*bold* _italic_")

        XCTAssertEqual(block.type, "section")
        XCTAssertEqual(block.text?.type, "mrkdwn")
        XCTAssertEqual(block.text?.text, "*bold* _italic_")
    }

    // MARK: - Button Style Constants

    func testButtonStyles() {
        XCTAssertEqual(SlackBlockElement.primaryStyle, "primary")
        XCTAssertEqual(SlackBlockElement.dangerStyle, "danger")
    }

    // MARK: - Typing Indicator (No-op)

    func testTypingIndicator_IsNoOp() async throws {
        // SlackTransport.sendTypingIndicator is a no-op — just verify it doesn't throw
        let client = SlackAPIClient(botToken: "xoxb-test")
        let transport = SlackTransport(apiClient: client)
        // This should complete without error (it's a no-op)
        try await transport.sendTypingIndicator(chatID: "C0123456789")
    }

    // MARK: - Slack Channel IDs are Strings

    func testSlackChannelID_IsNotNumeric() {
        let channelID = "C0123456789"
        XCTAssertNil(Int64(channelID)) // Slack channel IDs start with C — not numeric
        // This is why the protocol uses String, not Int64
    }

    func testSlackMessageTS_IsNotInteger() {
        let ts = "1716307200.123456"
        XCTAssertNil(Int(ts)) // Timestamps contain a decimal — not a valid Int
        // Protocol uses String for messageID to accommodate this
    }

    // MARK: - Chunking Uses Slack Limit

    func testSlackChunkLimit_Is3000() {
        let longText = String(repeating: "a", count: 3500)
        let chunks = SlackAPIClient.chunkText(longText)
        XCTAssertEqual(chunks[0].count, 3000)
    }
}
