// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsCommandDiscordTests.swift
//  DevgenticTests
//
//  Created by Raj Singh on 24/03/26.
//

import XCTest
@testable import devgentic

final class ChatOpsCommandDiscordTests: XCTestCase {

    // MARK: - Slash Command Parsing

    func testParseDiscord_SlashConversations() {
        let command = ChatOpsCommand.parseDiscord(slashCommandName: "conversations")
        if case .conversations = command { } else {
            XCTFail("Expected .conversations, got \(command)")
        }
    }

    func testParseDiscord_SlashNew() {
        let command = ChatOpsCommand.parseDiscord(slashCommandName: "new")
        if case .newConversation = command { } else {
            XCTFail("Expected .newConversation, got \(command)")
        }
    }

    func testParseDiscord_SlashStatus() {
        let command = ChatOpsCommand.parseDiscord(slashCommandName: "status")
        if case .status = command { } else {
            XCTFail("Expected .status, got \(command)")
        }
    }

    func testParseDiscord_SlashCancel() {
        let command = ChatOpsCommand.parseDiscord(slashCommandName: "cancel")
        if case .cancel = command { } else {
            XCTFail("Expected .cancel, got \(command)")
        }
    }

    func testParseDiscord_SlashHelp() {
        let command = ChatOpsCommand.parseDiscord(slashCommandName: "help")
        if case .help = command { } else {
            XCTFail("Expected .help, got \(command)")
        }
    }

    func testParseDiscord_UnknownSlashCommand() {
        let command = ChatOpsCommand.parseDiscord(slashCommandName: "nonexistent")
        // Unknown slash commands fall through to text parsing with nil text → .unknown
        if case .unknown = command { } else {
            XCTFail("Expected .unknown, got \(command)")
        }
    }

    // MARK: - Button Custom ID Parsing (HITL)

    func testParseDiscord_ApproveHITL() {
        let uuid = UUID()
        let command = ChatOpsCommand.parseDiscord(customID: "hitl:approve:\(uuid.uuidString)")
        if case .approveHITL(let opID) = command {
            XCTAssertEqual(opID, uuid)
        } else {
            XCTFail("Expected .approveHITL, got \(command)")
        }
    }

    func testParseDiscord_DenyHITL() {
        let uuid = UUID()
        let command = ChatOpsCommand.parseDiscord(customID: "hitl:deny:\(uuid.uuidString)")
        if case .denyHITL(let opID) = command {
            XCTAssertEqual(opID, uuid)
        } else {
            XCTFail("Expected .denyHITL, got \(command)")
        }
    }

    func testParseDiscord_SwitchConversation() {
        let uuid = UUID()
        let command = ChatOpsCommand.parseDiscord(customID: "switch:\(uuid.uuidString)")
        if case .switchConversation(let convID) = command {
            XCTAssertEqual(convID, uuid)
        } else {
            XCTFail("Expected .switchConversation, got \(command)")
        }
    }

    func testParseDiscord_InvalidCustomID() {
        let command = ChatOpsCommand.parseDiscord(customID: "hitl:approve:not-a-uuid")
        if case .unknown = command { } else {
            XCTFail("Expected .unknown for invalid UUID, got \(command)")
        }
    }

    // MARK: - Text Message Parsing

    func testParseDiscord_PairingAttempt() {
        let command = ChatOpsCommand.parseDiscord(text: "PAIR 123456")
        if case .pairingAttempt(let pin) = command {
            XCTAssertEqual(pin, "123456")
        } else {
            XCTFail("Expected .pairingAttempt, got \(command)")
        }
    }

    func testParseDiscord_PairingCaseInsensitive() {
        let command = ChatOpsCommand.parseDiscord(text: "pair 654321")
        if case .pairingAttempt(let pin) = command {
            XCTAssertEqual(pin, "654321")
        } else {
            XCTFail("Expected .pairingAttempt, got \(command)")
        }
    }

    func testParseDiscord_FreeText() {
        let command = ChatOpsCommand.parseDiscord(text: "Tell me about Swift concurrency")
        if case .freeText(let text) = command {
            XCTAssertEqual(text, "Tell me about Swift concurrency")
        } else {
            XCTFail("Expected .freeText, got \(command)")
        }
    }

    func testParseDiscord_EmptyText() {
        let command = ChatOpsCommand.parseDiscord(text: "")
        if case .unknown = command { } else {
            XCTFail("Expected .unknown for empty text, got \(command)")
        }
    }

    func testParseDiscord_NilText() {
        let command = ChatOpsCommand.parseDiscord(text: nil)
        if case .unknown = command { } else {
            XCTFail("Expected .unknown for nil text, got \(command)")
        }
    }

    // MARK: - Clarification Mode

    func testParseDiscord_ClarificationResponse() {
        let command = ChatOpsCommand.parseDiscord(text: "Yes, proceed with that", awaitingClarification: true)
        if case .clarificationResponse(let text) = command {
            XCTAssertEqual(text, "Yes, proceed with that")
        } else {
            XCTFail("Expected .clarificationResponse, got \(command)")
        }
    }

    func testParseDiscord_ClarificationSkip() {
        let command = ChatOpsCommand.parseDiscord(text: "/skip", awaitingClarification: true)
        if case .clarificationResponse(let text) = command {
            XCTAssertEqual(text, "")
        } else {
            XCTFail("Expected .clarificationResponse with empty text, got \(command)")
        }
    }

    // MARK: - Priority: CustomID > SlashCommand > Text

    func testParseDiscord_CustomIDTakesPriority() {
        let uuid = UUID()
        let command = ChatOpsCommand.parseDiscord(
            text: "some text",
            customID: "hitl:approve:\(uuid.uuidString)",
            slashCommandName: "help"
        )
        if case .approveHITL = command { } else {
            XCTFail("Expected customID to take priority, got \(command)")
        }
    }

    func testParseDiscord_SlashCommandOverText() {
        let command = ChatOpsCommand.parseDiscord(
            text: "some text",
            slashCommandName: "status"
        )
        if case .status = command { } else {
            XCTFail("Expected slash command to take priority over text, got \(command)")
        }
    }

    // MARK: - Text Slash Commands (typed in chat)

    func testParseDiscord_TextSlashConversations() {
        let command = ChatOpsCommand.parseDiscord(text: "/conversations")
        if case .conversations = command { } else {
            XCTFail("Expected .conversations from text, got \(command)")
        }
    }

    func testParseDiscord_TextSlashNew() {
        let command = ChatOpsCommand.parseDiscord(text: "/new")
        if case .newConversation = command { } else {
            XCTFail("Expected .newConversation from text, got \(command)")
        }
    }
}
