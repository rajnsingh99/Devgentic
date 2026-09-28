// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  QuickAccessFloatingButtonTests.swift
//  DevgenticTests
//
//  Unit tests for the Quick Access floating handoff button visibility rules and transfer contract.
//

import XCTest
@testable import devgentic

final class QuickAccessFloatingButtonTests: XCTestCase {

    // MARK: - Visibility Rules

    func testHiddenWhenNotChatInterface() {
        XCTAssertFalse(QuickAccessFloatingButton.shouldShow(
            isChatInterfaceActive: false,
            hasSelectedConversation: true,
            isQuickAccessEnabled: true,
            isCoveredByOverlayPanel: false
        ), "Button must be hidden when outside the chat interface (e.g. Workflow, Code, Settings)")
    }

    func testHiddenWhenNoSelectedConversation() {
        XCTAssertFalse(QuickAccessFloatingButton.shouldShow(
            isChatInterfaceActive: true,
            hasSelectedConversation: false,
            isQuickAccessEnabled: true,
            isCoveredByOverlayPanel: false
        ), "Button must be hidden when no conversation is selected (Welcome screen)")
    }

    func testHiddenWhenQuickAccessDisabled() {
        XCTAssertFalse(QuickAccessFloatingButton.shouldShow(
            isChatInterfaceActive: true,
            hasSelectedConversation: true,
            isQuickAccessEnabled: false,
            isCoveredByOverlayPanel: false
        ), "Button must be hidden when Quick Access is globally disabled in configuration")
    }

    func testHiddenWhenCoveredByOverlayPanel() {
        XCTAssertFalse(QuickAccessFloatingButton.shouldShow(
            isChatInterfaceActive: true,
            hasSelectedConversation: true,
            isQuickAccessEnabled: true,
            isCoveredByOverlayPanel: true
        ), "Button must be hidden when an overlay or full-screen panel covers the chat")
    }

    func testVisibleWhenInChatWithActiveConversationAndEnabled() {
        XCTAssertTrue(QuickAccessFloatingButton.shouldShow(
            isChatInterfaceActive: true,
            hasSelectedConversation: true,
            isQuickAccessEnabled: true,
            isCoveredByOverlayPanel: false
        ), "Button must be visible in the chat interface when a conversation is active and Quick Access is enabled")
    }

    func testVisibleInSplitModeWhenPanelDoesNotCoverChat() {
        // In split mode, the side panel lays out beside the chat without covering it.
        // Therefore `isCoveredByOverlayPanel` is false.
        XCTAssertTrue(QuickAccessFloatingButton.shouldShow(
            isChatInterfaceActive: true,
            hasSelectedConversation: true,
            isQuickAccessEnabled: true,
            isCoveredByOverlayPanel: false
        ), "Button must remain visible in split mode beside the open panel")
    }

    // MARK: - Handoff Source Contract

    func testTransferToOverlaySetsConversationIdAndPostsNotification() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()

        guard let source = try? String(contentsOf: root.appendingPathComponent("Devgentic/Interfaces/Main/ConversationManagementCoordinator.swift"), encoding: .utf8) else {
            throw XCTSkip("ConversationManagementCoordinator.swift not reachable — running outside a checkout")
        }

        guard let start = source.range(of: "func transferSelectedConversationToOverlay()"),
              let end = source.range(of: "vm.selectedConversationID = nil", range: start.upperBound..<source.endIndex) else {
            XCTFail("could not find transferSelectedConversationToOverlay contract")
            return
        }

        let body = String(source[start.upperBound...end.upperBound])
        XCTAssertTrue(body.contains("GlobalConstants.quickAccessOverlayConversationId"),
                      "Transfer must persist the conversation ID under quickAccessOverlayConversationId")
        XCTAssertTrue(body.contains("GlobalConstants.showQuickAccessPanelNotification"),
                      "Transfer must dispatch showQuickAccessPanelNotification")
        XCTAssertTrue(body.contains("\"forceExpand\": true"),
                      "Transfer must pass forceExpand: true so Quick Access opens expanded")
        XCTAssertTrue(body.contains("vm.selectedConversationID = nil"),
                      "Transfer must clear selectedConversationID to avoid dual ownership")
    }
}
