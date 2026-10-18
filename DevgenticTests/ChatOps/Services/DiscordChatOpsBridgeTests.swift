// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DiscordChatOpsBridgeTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
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

    // MARK: - The orphaned deferred ack

    /// ⚠️⚠️ A COMMAND NOBODY OWNS USED TO LEAVE A PERMANENT "THINKING…". `routeInteractionCommand`
    /// ran only AFTER the interaction had been acked with a deferred response, and Discord shows
    /// that placeholder until something edits it. The method discarded `routeThroughService`'s
    /// return with `_ =`, so an unowned command fell out of it having acked and posted nothing —
    /// and the spinner stayed in the channel forever, with no log line naming what happened.
    ///
    /// ⚠️ REACHABLE, NOT THEORETICAL — which is what the three assertions below stand for. An
    /// unregistered or renamed slash name parses to `.unknown`, `.unknown` is permitted at every
    /// tier, so it clears both gates, receives the deferred ack, and lands there. A guild command
    /// left behind by a rename is enough to produce it.
    ///
    /// ⚠️ A SOURCE ASSERTION, DELIBERATELY, AND ITS LIMIT IS STATED. The bridge holds a concrete
    /// `DiscordAPIClient` with no seam to inject a fake through, so this proves the WIRING is
    /// present, not that the edit reaches Discord. It is the same technique
    /// `RemoteEgressSanitizerTests` uses for the transport floor, and it is bounded to the one
    /// method so it cannot answer for code it was not asked about.
    func testAnUnownedInteractionCommandResolvesItsDeferredPlaceholder() throws {
        let source = try Self.readBridgeSource()
        let start = try XCTUnwrap(source.range(of: "private func routeInteractionCommand("),
                                  "routeInteractionCommand was renamed — this test no longer guards anything")
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    private func ")?.lowerBound ?? rest.endIndex
        let body = String(rest[..<end])

        XCTAssertFalse(body.contains("_ = await routeThroughService"),
                       "discarding the return is the defect: an unowned command acks and posts nothing")
        XCTAssertTrue(body.contains("await render("),
                      "the deferred placeholder must be resolved, or it stays in the channel forever")
        XCTAssertTrue(body.contains("logger.error"),
                      "a dropped command with no log is how this went unnoticed")
    }

    /// The premise the test above rests on: `.unknown` really does clear the tier gate, so it
    /// really does reach the ack. If this ever changes the reachability comment must change too.
    func testAnUnknownCommandClearsTheTierGateAndSoReachesTheAck() async {
        let gate = ChatOpsSecurityGate()
        for tier in [ChatOpsSecurityTier.readOnly, .standard, .full] {
            let allowed = await gate.canExecute(.unknown, tier: tier)
            XCTAssertTrue(allowed,
                          "\(tier) refusing .unknown would change how the orphaned-ack path is reached")
        }
    }

    private static func readBridgeSource() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent("Devgentic/ChatOps/Services/DiscordChatOpsBridge.swift")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("DiscordChatOpsBridge.swift not reachable — running outside a checkout")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - The channel allowlist and its missing-evidence case

    /// ⚠️⚠️ THE MECHANISM, SO THE ASSERTIONS BELOW ARE READABLE. `authorizeDiscord` decides by
    /// comparing its argument against `discordAuthorizedChannelID` — so passing that very value in
    /// makes the guard compare the authorized id with itself and pass unconditionally. That is what
    /// `interaction.channel_id ?? config.discordAuthorizedChannelID` did for every interaction whose
    /// payload carried no channel: the allowlist was satisfied by construction.
    ///
    /// ⚠️ THERE IS DELIBERATELY NO TEST DRIVING THE REAL GATE HERE. It reads the shared
    /// `ChatOpsConfigManager`, so proving the tautology at runtime means either depending on the
    /// developer's own Discord pairing (a test that SKIPS on most machines, which is a green tick
    /// over nothing) or writing to it (which moves their real pairing, and leaves it moved if the
    /// test crashes). The property is arithmetic — `x == x` — and the assertions below guard the
    /// thing that can actually regress: whether the fallback is allowed to reach the gate.
    ///
    /// ⚠️⚠️ THE FIX: THE FALLBACK MUST NOT REACH THE GATE. A missing `channel_id` is the ABSENCE of
    /// evidence, and the old expression turned it into proof. The reply ADDRESS may still fall back
    /// — posting into the user's own paired channel is always safe — so the two uses are separated
    /// and only the address keeps a default.
    ///
    /// Mutation that must turn this red: pass `replyChannelID` to `authorizeDiscord`, or restore
    /// the single `let channelID = interaction.channel_id ?? config.discordAuthorizedChannelID`.
    func testTheChannelAllowlistIsNeverGivenTheFallbackValue() throws {
        let body = try Self.methodBody("private func handleInteraction(")

        XCTAssertTrue(body.contains("authorizeDiscord(channelID: originChannelID"),
                      "the allowlist must be given the payload's own channel, never a default")
        XCTAssertFalse(body.contains("authorizeDiscord(channelID: replyChannelID"),
                       "feeding the reply address to the gate reintroduces the bypass")
        XCTAssertTrue(body.contains("let originChannelID = interaction.channel_id\n"),
                      "the evidence value must have no fallback at all")
        XCTAssertTrue(body.contains("modalSubmit"),
                      "the one legitimate no-channel case must be named, not swept in with the rest")
    }

    private static func methodBody(_ signature: String) throws -> String {
        let source = try readBridgeSource()
        let start = try XCTUnwrap(source.range(of: signature), "\(signature) was renamed")
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    // MARK:")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }
}
