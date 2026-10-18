// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatScrollAnchoringTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class ChatScrollAnchoringTests: XCTestCase {

    /// At the bottom: growth is followed (streaming, a new turn, a row finishing measurement).
    func testGrowthIsFollowedAtTheBottom() {
        XCTAssertEqual(ChatHistoryView.sizeChangeAnchor(isAwayFromBottom: false), .bottom)
    }

    /// ⚠️ [bm-2] Scrolled away: growth at the bottom must not drag what the reader is reading.
    func testAReaderWhoScrolledAwayIsNotDragged() {
        XCTAssertEqual(ChatHistoryView.sizeChangeAnchor(isAwayFromBottom: true), .top)
    }

    // MARK: - Wiring

    private func source() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = "Devgentic/Interfaces/Shared/Chat/ChatHistoryView.swift"
        guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("\(path) not reachable — running outside a checkout")
        }
        return text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func testTheTranscriptAnchorsItself() throws {
        let code = try source()
        XCTAssertTrue(code.contains(".defaultScrollAnchor(.top, for: .alignment)"),
                      "a short conversation no longer starts at the top")
        XCTAssertTrue(code.contains(".defaultScrollAnchor(.bottom, for: .initialOffset)"),
                      "a conversation no longer opens at its bottom — it will be scrolled there by hand again")
        XCTAssertTrue(code.contains(".defaultScrollAnchor(Self.sizeChangeAnchor(isAwayFromBottom: showScrollToBottom), for: .sizeChanges)"),
                      "new content is not followed, or a reader who scrolled up is dragged")
        XCTAssertTrue(code.contains(".id(displayMessages.first?.conversationId)"),
                      "the scroll view is reused across conversations, so `.initialOffset` applies only to the first")
    }

    /// The hand-built mechanisms stay gone — each was a source of the reported behaviour.
    func testTheManualScrollingIsGone() throws {
        let code = try source()
        XCTAssertFalse(code.contains("geometry.size.height - 115"),
                       "the per-row tall frame is back — it hops rows on every append and strands the view mid-way")
        XCTAssertFalse(code.contains("proxy.scrollTo(newestMessageID, anchor: .bottom)"),
                       "scrolling to a lazily measured row lands short of the bottom")
        XCTAssertTrue(code.contains("proxy.scrollTo(Self.bottomSentinelID, anchor: .bottom)"),
                      "scroll-to-bottom must target the list's end")
        XCTAssertTrue(code.contains(".id(Self.bottomSentinelID)"), "the sentinel it targets is missing")
    }
}
