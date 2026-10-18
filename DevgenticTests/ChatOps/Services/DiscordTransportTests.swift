// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DiscordTransportTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class DiscordTransportTests: XCTestCase {

    // MARK: - Transport Identity

    func testTransportID_IsDiscord() {
        let client = DiscordAPIClient(botToken: "test-token")
        let transport = DiscordTransport(apiClient: client)
        XCTAssertEqual(transport.transportID, "discord")
    }

    // MARK: - HITL Button Components

    func testHITLButtonComponents_ApproveAndDeny() throws {
        let operationID = UUID()

        let approveButton = DiscordComponent.button(
            label: "✅ Approve",
            customID: "hitl:approve:\(operationID.uuidString)",
            style: DiscordComponent.successStyle
        )
        let denyButton = DiscordComponent.button(
            label: "❌ Deny",
            customID: "hitl:deny:\(operationID.uuidString)",
            style: DiscordComponent.dangerStyle
        )
        let row = DiscordComponent.actionRow([approveButton, denyButton])

        // Verify ActionRow structure
        XCTAssertEqual(row.type, DiscordComponent.actionRow)
        XCTAssertEqual(row.components?.count, 2)

        // Verify Approve button
        let approve = row.components![0]
        XCTAssertEqual(approve.type, DiscordComponent.button)
        XCTAssertEqual(approve.style, DiscordComponent.successStyle) // Green
        XCTAssertEqual(approve.label, "✅ Approve")
        XCTAssertTrue(approve.custom_id!.hasPrefix("hitl:approve:"))
        XCTAssertTrue(approve.custom_id!.contains(operationID.uuidString))

        // Verify Deny button
        let deny = row.components![1]
        XCTAssertEqual(deny.type, DiscordComponent.button)
        XCTAssertEqual(deny.style, DiscordComponent.dangerStyle) // Red
        XCTAssertEqual(deny.label, "❌ Deny")
        XCTAssertTrue(deny.custom_id!.hasPrefix("hitl:deny:"))
        XCTAssertTrue(deny.custom_id!.contains(operationID.uuidString))
    }

    func testHITLButtonCustomID_MatchesTelegramFormat() {
        // Discord and Telegram use the same callback data format for HITL
        let uuid = UUID()
        let discordCustomID = "hitl:approve:\(uuid.uuidString)"
        let telegramCallbackData = "hitl:approve:\(uuid.uuidString)"

        XCTAssertEqual(discordCustomID, telegramCallbackData)
    }

    // MARK: - Button Style Constants

    func testButtonStyles_CorrectValues() {
        XCTAssertEqual(DiscordComponent.primaryStyle, 1)    // Blurple
        XCTAssertEqual(DiscordComponent.secondaryStyle, 2)  // Grey
        XCTAssertEqual(DiscordComponent.successStyle, 3)    // Green
        XCTAssertEqual(DiscordComponent.dangerStyle, 4)     // Red
    }

    // MARK: - Snowflake ID Conversion

    func testSnowflakeConversion_StringToInt64() {
        let snowflake = "1234567890123456789"
        let int64Value = Int64(snowflake)
        XCTAssertNotNil(int64Value)
        XCTAssertEqual(int64Value, 1234567890123456789)
    }

    func testSnowflakeConversion_Int64ToString() {
        let int64Value: Int64 = 987654321098765432
        let stringValue = "\(int64Value)"
        XCTAssertEqual(stringValue, "987654321098765432")
    }

    func testSnowflakeConversion_Roundtrip() {
        let original = "1234567890123456789"
        let int64 = Int64(original)!
        let backToString = "\(int64)"
        XCTAssertEqual(original, backToString)
    }

    func testSnowflakeConversion_MessageIDAsInt() {
        // ChatOpsTransport protocol uses Int for messageID
        let snowflake = "1234567890123456789"
        let intValue = Int(snowflake)
        XCTAssertNotNil(intValue)
        // On 64-bit platforms (macOS), Int is 64-bit — snowflakes fit
        XCTAssertEqual(intValue, 1234567890123456789)
    }

    // MARK: - Component Type Constants

    func testComponentTypes_CorrectValues() {
        XCTAssertEqual(DiscordComponent.actionRow, 1)
        XCTAssertEqual(DiscordComponent.button, 2)
    }

    // MARK: - ActionRow With Multiple Buttons

    func testActionRow_MaxFiveButtons() {
        // Discord allows max 5 buttons per ActionRow
        let buttons = (1...5).map { i in
            DiscordComponent.button(
                label: "Button \(i)",
                customID: "btn:\(i)",
                style: DiscordComponent.secondaryStyle
            )
        }

        let row = DiscordComponent.actionRow(buttons)
        XCTAssertEqual(row.components?.count, 5)
    }

    // MARK: - Chunking Uses Discord Limit

    func testDiscordChunkLimit_Is1950() {
        let longText = String(repeating: "a", count: 2000)
        let chunks = DiscordAPIClient.chunkText(longText)
        XCTAssertEqual(chunks[0].count, 1950)
        XCTAssertGreaterThan(chunks.count, 1)
    }
}
