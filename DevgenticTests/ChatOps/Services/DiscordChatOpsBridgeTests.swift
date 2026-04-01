//
//  DiscordChatOpsBridgeTests.swift
//  DevgenticTests
//
//  Created by Raj Singh on 24/03/26.
//

import XCTest
@testable import devgentic

final class DiscordChatOpsBridgeTests: XCTestCase {

    // MARK: - Bot Message Filtering

    func testBotMessage_ShouldBeIgnored() throws {
        let json = """
        {
            "id": "1",
            "channel_id": "2",
            "author": { "id": "3", "username": "devgentic-bot", "discriminator": "0", "bot": true },
            "content": "I am a bot",
            "timestamp": "2026-03-24T10:00:00.000Z"
        }
        """.data(using: .utf8)!

        let message = try JSONDecoder().decode(DiscordMessage.self, from: json)
        XCTAssertEqual(message.author.bot, true)
        // The bridge checks `message.author.bot != true` before processing
    }

    func testHumanMessage_ShouldBeProcessed() throws {
        let json = """
        {
            "id": "1",
            "channel_id": "2",
            "author": { "id": "3", "username": "human", "discriminator": "0" },
            "content": "Hello agent",
            "timestamp": "2026-03-24T10:00:00.000Z"
        }
        """.data(using: .utf8)!

        let message = try JSONDecoder().decode(DiscordMessage.self, from: json)
        XCTAssertNil(message.author.bot) // nil means not a bot
    }

    func testHumanMessage_BotExplicitlyFalse() throws {
        let json = """
        {
            "id": "1",
            "channel_id": "2",
            "author": { "id": "3", "username": "human", "discriminator": "0", "bot": false },
            "content": "Hello",
            "timestamp": "2026-03-24T10:00:00.000Z"
        }
        """.data(using: .utf8)!

        let message = try JSONDecoder().decode(DiscordMessage.self, from: json)
        XCTAssertEqual(message.author.bot, false)
    }

    // MARK: - Slash Command Routing

    func testSlashCommand_ConversationsRoutes() {
        let command = ChatOpsCommand.parseDiscord(slashCommandName: "conversations")
        if case .conversations = command { } else {
            XCTFail("Expected /conversations to route to .conversations")
        }
    }

    func testSlashCommand_NewRoutes() {
        let command = ChatOpsCommand.parseDiscord(slashCommandName: "new")
        if case .newConversation = command { } else {
            XCTFail("Expected /new to route to .newConversation")
        }
    }

    func testSlashCommand_StatusRoutes() {
        let command = ChatOpsCommand.parseDiscord(slashCommandName: "status")
        if case .status = command { } else {
            XCTFail("Expected /status to route to .status")
        }
    }

    func testSlashCommand_CancelRoutes() {
        let command = ChatOpsCommand.parseDiscord(slashCommandName: "cancel")
        if case .cancel = command { } else {
            XCTFail("Expected /cancel to route to .cancel")
        }
    }

    func testSlashCommand_HelpRoutes() {
        let command = ChatOpsCommand.parseDiscord(slashCommandName: "help")
        if case .help = command { } else {
            XCTFail("Expected /help to route to .help")
        }
    }

    // MARK: - Button Interaction Routing

    func testButtonInteraction_ApproveHITL() {
        let uuid = UUID()
        let command = ChatOpsCommand.parseDiscord(customID: "hitl:approve:\(uuid.uuidString)")
        if case .approveHITL(let opID) = command {
            XCTAssertEqual(opID, uuid)
        } else {
            XCTFail("Expected approve button to route to .approveHITL")
        }
    }

    func testButtonInteraction_DenyHITL() {
        let uuid = UUID()
        let command = ChatOpsCommand.parseDiscord(customID: "hitl:deny:\(uuid.uuidString)")
        if case .denyHITL(let opID) = command {
            XCTAssertEqual(opID, uuid)
        } else {
            XCTFail("Expected deny button to route to .denyHITL")
        }
    }

    func testButtonInteraction_SwitchConversation() {
        let uuid = UUID()
        let command = ChatOpsCommand.parseDiscord(customID: "switch:\(uuid.uuidString)")
        if case .switchConversation(let convID) = command {
            XCTAssertEqual(convID, uuid)
        } else {
            XCTFail("Expected switch button to route to .switchConversation")
        }
    }

    func testButtonInteraction_NewConversationAction() {
        let command = ChatOpsCommand.parseDiscord(customID: "action:new")
        if case .newConversation = command { } else {
            XCTFail("Expected action:new to route to .newConversation")
        }
    }

    // MARK: - Interaction Type Constants

    func testInteractionTypes_CorrectValues() {
        XCTAssertEqual(DiscordInteraction.applicationCommand, 2)
        XCTAssertEqual(DiscordInteraction.messageComponent, 3)
    }

    // MARK: - Deferred Response Types

    func testDeferredResponseTypes() {
        // Button clicks → type 6 (deferred update, no visible response)
        XCTAssertEqual(DiscordInteractionResponsePayload.deferredUpdateMessage, 6)
        // Slash commands → type 5 (deferred channel message, shows "thinking...")
        XCTAssertEqual(DiscordInteractionResponsePayload.deferredChannelMessage, 5)
    }

    // MARK: - Free Text → Discord Source

    func testFreeText_DiscordSource() {
        let source = MessageSource.discord
        XCTAssertEqual(source.rawValue, "discord")
    }

    func testMessageSource_DiscordExists() {
        // Verify .discord case exists in MessageSource enum
        let sources: [MessageSource] = [.localUI, .telegram, .discord]
        XCTAssertTrue(sources.contains(.discord))
    }

    // MARK: - Channel Security

    func testChannelID_ExtractedFromMessage() throws {
        let json = """
        {
            "id": "1",
            "channel_id": "9876543210987654321",
            "author": { "id": "2", "username": "user", "discriminator": "0" },
            "content": "test",
            "timestamp": "2026-03-24T10:00:00.000Z"
        }
        """.data(using: .utf8)!

        let message = try JSONDecoder().decode(DiscordMessage.self, from: json)
        XCTAssertEqual(message.channel_id, "9876543210987654321")
        // Security gate will check this against config.discordAuthorizedChannelID
    }

    func testChannelID_ExtractedFromInteraction() throws {
        let json = """
        {
            "id": "1",
            "type": 3,
            "channel_id": "9876543210987654321",
            "data": { "custom_id": "hitl:approve:AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE" },
            "token": "tok"
        }
        """.data(using: .utf8)!

        let interaction = try JSONDecoder().decode(DiscordInteraction.self, from: json)
        XCTAssertEqual(interaction.channel_id, "9876543210987654321")
    }
}
