// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ChatOpsCommandSlackTests.swift
//  DevgenticTests
//
//  Created by Raj Singh on 24/03/26.
//

import XCTest
@testable import devgentic

final class ChatOpsCommandSlackTests: XCTestCase {

    // MARK: - Slash Command Parsing

    func testParseSlack_SlashConversations() {
        let command = ChatOpsCommand.parseSlack(slashCommand: "/conversations")
        if case .conversations = command { } else {
            XCTFail("Expected .conversations, got \(command)")
        }
    }

    func testParseSlack_SlashNew() {
        let command = ChatOpsCommand.parseSlack(slashCommand: "/new")
        if case .newConversation = command { } else {
            XCTFail("Expected .newConversation, got \(command)")
        }
    }

    func testParseSlack_SlashStatus() {
        let command = ChatOpsCommand.parseSlack(slashCommand: "/status")
        if case .status = command { } else {
            XCTFail("Expected .status, got \(command)")
        }
    }

    func testParseSlack_SlashCancel() {
        let command = ChatOpsCommand.parseSlack(slashCommand: "/cancel")
        if case .cancel = command { } else {
            XCTFail("Expected .cancel, got \(command)")
        }
    }

    func testParseSlack_SlashHelp() {
        let command = ChatOpsCommand.parseSlack(slashCommand: "/help")
        if case .help = command { } else {
            XCTFail("Expected .help, got \(command)")
        }
    }

    func testParseSlack_SlashWithoutPrefix() {
        // parseSlack strips leading / if present
        let command = ChatOpsCommand.parseSlack(slashCommand: "conversations")
        if case .conversations = command { } else {
            XCTFail("Expected .conversations without slash prefix, got \(command)")
        }
    }

    // MARK: - Action ID Parsing (Button Clicks)

    func testParseSlack_ApproveHITL() {
        let uuid = UUID()
        let command = ChatOpsCommand.parseSlack(actionID: "hitl:approve:\(uuid.uuidString)")
        if case .approveHITL(let opID) = command {
            XCTAssertEqual(opID, uuid)
        } else {
            XCTFail("Expected .approveHITL, got \(command)")
        }
    }

    func testParseSlack_DenyHITL() {
        let uuid = UUID()
        let command = ChatOpsCommand.parseSlack(actionID: "hitl:deny:\(uuid.uuidString)")
        if case .denyHITL(let opID) = command {
            XCTAssertEqual(opID, uuid)
        } else {
            XCTFail("Expected .denyHITL, got \(command)")
        }
    }

    func testParseSlack_SwitchConversation() {
        let uuid = UUID()
        let command = ChatOpsCommand.parseSlack(actionID: "switch:\(uuid.uuidString)")
        if case .switchConversation(let convID) = command {
            XCTAssertEqual(convID, uuid)
        } else {
            XCTFail("Expected .switchConversation, got \(command)")
        }
    }

    func testParseSlack_NewConversationAction() {
        let command = ChatOpsCommand.parseSlack(actionID: "action:new")
        if case .newConversation = command { } else {
            XCTFail("Expected .newConversation, got \(command)")
        }
    }

    // MARK: - Text Message Parsing

    func testParseSlack_PairingAttempt() {
        let command = ChatOpsCommand.parseSlack(text: "PAIR 123456")
        if case .pairingAttempt(let pin) = command {
            XCTAssertEqual(pin, "123456")
        } else {
            XCTFail("Expected .pairingAttempt, got \(command)")
        }
    }

    func testParseSlack_FreeText() {
        let command = ChatOpsCommand.parseSlack(text: "Tell me about Swift concurrency")
        if case .freeText(let text) = command {
            XCTAssertEqual(text, "Tell me about Swift concurrency")
        } else {
            XCTFail("Expected .freeText, got \(command)")
        }
    }

    func testParseSlack_EmptyText() {
        let command = ChatOpsCommand.parseSlack(text: "")
        if case .unknown = command { } else {
            XCTFail("Expected .unknown for empty text, got \(command)")
        }
    }

    // MARK: - Clarification Mode

    func testParseSlack_ClarificationResponse() {
        let command = ChatOpsCommand.parseSlack(text: "Yes, proceed", awaitingClarification: true)
        if case .clarificationResponse(let text) = command {
            XCTAssertEqual(text, "Yes, proceed")
        } else {
            XCTFail("Expected .clarificationResponse, got \(command)")
        }
    }

    func testParseSlack_ClarificationSkip() {
        let command = ChatOpsCommand.parseSlack(text: "/skip", awaitingClarification: true)
        if case .clarificationResponse(let text) = command {
            XCTAssertEqual(text, "")
        } else {
            XCTFail("Expected .clarificationResponse with empty text, got \(command)")
        }
    }

    // MARK: - Priority: ActionID > SlashCommand > Text

    func testParseSlack_ActionIDTakesPriority() {
        let uuid = UUID()
        let command = ChatOpsCommand.parseSlack(
            text: "some text",
            actionID: "hitl:approve:\(uuid.uuidString)",
            slashCommand: "/help"
        )
        if case .approveHITL = command { } else {
            XCTFail("Expected actionID to take priority, got \(command)")
        }
    }

    // MARK: - Text Slash Commands (typed in chat)

    func testParseSlack_TextSlashConversations() {
        let command = ChatOpsCommand.parseSlack(text: "/conversations")
        if case .conversations = command { } else {
            XCTFail("Expected .conversations from text, got \(command)")
        }
    }
}
