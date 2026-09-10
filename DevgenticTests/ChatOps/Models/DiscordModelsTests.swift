// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  DiscordModelsTests.swift
//  DevgenticTests
//
//  Created by Raj Singh on 24/03/26.
//

import XCTest
@testable import devgentic

final class DiscordModelsTests: XCTestCase {

    // MARK: - DiscordMessage Decoding

    func testDiscordMessage_DecodesFromJSON() throws {
        let json = """
        {
            "id": "1234567890123456789",
            "channel_id": "9876543210987654321",
            "guild_id": "1111111111111111111",
            "author": {
                "id": "2222222222222222222",
                "username": "testuser",
                "discriminator": "0001",
                "bot": false
            },
            "content": "Hello from Discord",
            "timestamp": "2026-03-24T10:00:00.000Z"
        }
        """.data(using: .utf8)!

        let message = try JSONDecoder().decode(DiscordMessage.self, from: json)

        XCTAssertEqual(message.id, "1234567890123456789")
        XCTAssertEqual(message.channel_id, "9876543210987654321")
        XCTAssertEqual(message.guild_id, "1111111111111111111")
        XCTAssertEqual(message.author.username, "testuser")
        XCTAssertEqual(message.author.bot, false)
        XCTAssertEqual(message.content, "Hello from Discord")
    }

    func testDiscordMessage_ChannelIDInt64Conversion() throws {
        let json = """
        {
            "id": "1234567890123456789",
            "channel_id": "987654321098765432",
            "author": { "id": "1", "username": "bot", "discriminator": "0" },
            "content": "test",
            "timestamp": "2026-03-24T10:00:00.000Z"
        }
        """.data(using: .utf8)!

        let message = try JSONDecoder().decode(DiscordMessage.self, from: json)
        XCTAssertEqual(message.channelIDInt64, 987654321098765432)
        XCTAssertEqual(message.messageIDInt, 1234567890123456789)
    }

    func testDiscordMessage_BotAuthorDetected() throws {
        let json = """
        {
            "id": "1",
            "channel_id": "2",
            "author": { "id": "3", "username": "mybot", "discriminator": "0", "bot": true },
            "content": "bot message",
            "timestamp": "2026-03-24T10:00:00.000Z"
        }
        """.data(using: .utf8)!

        let message = try JSONDecoder().decode(DiscordMessage.self, from: json)
        XCTAssertEqual(message.author.bot, true)
    }

    // MARK: - DiscordInteraction Decoding

    func testDiscordInteraction_ButtonClick() throws {
        let json = """
        {
            "id": "111",
            "type": 3,
            "channel_id": "222",
            "data": {
                "custom_id": "hitl:approve:AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                "component_type": 2
            },
            "token": "interaction-token-123"
        }
        """.data(using: .utf8)!

        let interaction = try JSONDecoder().decode(DiscordInteraction.self, from: json)

        XCTAssertEqual(interaction.type, DiscordInteraction.messageComponent)
        XCTAssertEqual(interaction.data?.custom_id, "hitl:approve:AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        XCTAssertEqual(interaction.data?.component_type, 2)
        XCTAssertEqual(interaction.token, "interaction-token-123")
    }

    func testDiscordInteraction_SlashCommand() throws {
        let json = """
        {
            "id": "333",
            "type": 2,
            "channel_id": "444",
            "data": {
                "name": "conversations"
            },
            "token": "slash-token-456"
        }
        """.data(using: .utf8)!

        let interaction = try JSONDecoder().decode(DiscordInteraction.self, from: json)

        XCTAssertEqual(interaction.type, DiscordInteraction.applicationCommand)
        XCTAssertEqual(interaction.data?.name, "conversations")
    }

    // MARK: - DiscordComponent Encoding

    func testDiscordComponent_ButtonEncoding() throws {
        let button = DiscordComponent.button(
            label: "Approve",
            customID: "hitl:approve:test-uuid",
            style: DiscordComponent.successStyle
        )

        let data = try JSONEncoder().encode(button)
        let decoded = try JSONDecoder().decode(DiscordComponent.self, from: data)

        XCTAssertEqual(decoded.type, DiscordComponent.button)
        XCTAssertEqual(decoded.label, "Approve")
        XCTAssertEqual(decoded.custom_id, "hitl:approve:test-uuid")
        XCTAssertEqual(decoded.style, DiscordComponent.successStyle)
    }

    func testDiscordComponent_ActionRowEncoding() throws {
        let approve = DiscordComponent.button(label: "Yes", customID: "yes", style: DiscordComponent.successStyle)
        let deny = DiscordComponent.button(label: "No", customID: "no", style: DiscordComponent.dangerStyle)
        let row = DiscordComponent.actionRow([approve, deny])

        let data = try JSONEncoder().encode(row)
        let decoded = try JSONDecoder().decode(DiscordComponent.self, from: data)

        XCTAssertEqual(decoded.type, DiscordComponent.actionRow)
        XCTAssertEqual(decoded.components?.count, 2)
        XCTAssertEqual(decoded.components?[0].label, "Yes")
        XCTAssertEqual(decoded.components?[1].label, "No")
    }

    // MARK: - DiscordHelloPayload

    func testHelloPayload_ExtractsHeartbeatInterval() throws {
        let json = """
        { "heartbeat_interval": 41250 }
        """.data(using: .utf8)!

        let hello = try JSONDecoder().decode(DiscordHelloPayload.self, from: json)
        XCTAssertEqual(hello.heartbeat_interval, 41250)
    }

    // MARK: - DiscordIdentifyPayload

    func testIdentifyPayload_DefaultIntents() {
        XCTAssertEqual(DiscordIdentifyPayload.defaultIntents, 33281)
        // Verify: GUILDS (1) | GUILD_MESSAGES (512) | MESSAGE_CONTENT (32768) = 33281
        XCTAssertEqual(0x1 | 0x200 | 0x8000, 33281)
    }

    func testIdentifyPayload_Encoding() throws {
        let payload = DiscordIdentifyPayload(
            token: "test-token",
            intents: DiscordIdentifyPayload.defaultIntents,
            properties: .default
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(DiscordIdentifyPayload.self, from: data)

        XCTAssertEqual(decoded.token, "test-token")
        XCTAssertEqual(decoded.intents, 33281)
        XCTAssertEqual(decoded.properties.os, "macos")
        XCTAssertEqual(decoded.properties.browser, "devgentic")
    }

    // MARK: - DiscordReadyPayload

    func testReadyPayload_ExtractsSessionInfo() throws {
        let json = """
        {
            "user": { "id": "123", "username": "devgentic-bot", "discriminator": "0" },
            "session_id": "session-abc-123",
            "resume_gateway_url": "wss://gateway.discord.gg/?v=10",
            "application": { "id": "app-456" }
        }
        """.data(using: .utf8)!

        let ready = try JSONDecoder().decode(DiscordReadyPayload.self, from: json)

        XCTAssertEqual(ready.user.username, "devgentic-bot")
        XCTAssertEqual(ready.session_id, "session-abc-123")
        XCTAssertEqual(ready.application.id, "app-456")
    }

    // MARK: - DiscordAPIError

    func testDiscordAPIError_Descriptions() {
        let apiError = DiscordAPIError.apiError(status: 403, message: "Forbidden")
        XCTAssertTrue(apiError.localizedDescription.contains("403"))

        let rateLimited = DiscordAPIError.rateLimited(retryAfter: 2.5)
        XCTAssertTrue(rateLimited.localizedDescription.contains("2.5"))

        let invalidToken = DiscordAPIError.invalidToken
        XCTAssertTrue(invalidToken.localizedDescription.contains("Invalid"))

        let disconnected = DiscordAPIError.gatewayDisconnected(reason: "Server restart")
        XCTAssertTrue(disconnected.localizedDescription.contains("Server restart"))
    }

    // MARK: - DiscordSlashCommand

    func testSlashCommand_Encoding() throws {
        let command = DiscordSlashCommand(name: "help", description: "Show help", type: DiscordSlashCommand.chatInput)

        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(DiscordSlashCommand.self, from: data)

        XCTAssertEqual(decoded.name, "help")
        XCTAssertEqual(decoded.description, "Show help")
        XCTAssertEqual(decoded.type, 1)
    }

    // MARK: - InteractionResponse

    func testInteractionResponsePayload_Types() {
        XCTAssertEqual(DiscordInteractionResponsePayload.deferredChannelMessage, 5)
        XCTAssertEqual(DiscordInteractionResponsePayload.deferredUpdateMessage, 6)
        XCTAssertEqual(DiscordInteractionResponsePayload.channelMessageWithSource, 4)
        XCTAssertEqual(DiscordInteractionResponsePayload.updateMessage, 7)
    }
}
