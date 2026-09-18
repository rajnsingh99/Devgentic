// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SlackAPIClientTests.swift
//  DevgenticTests
//
//  Created by Raj Singh on 24/03/26.
//

import XCTest
@testable import devgentic

final class SlackAPIClientTests: XCTestCase {

    // MARK: - Text Chunking

    func testChunkText_ShortText_ReturnsSingleChunk() {
        let text = "Hello, world!"
        let chunks = SlackAPIClient.chunkText(text, maxLength: 3000)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0], text)
    }

    func testChunkText_ExactlyAtLimit() {
        let text = String(repeating: "a", count: 3000)
        let chunks = SlackAPIClient.chunkText(text, maxLength: 3000)
        XCTAssertEqual(chunks.count, 1)
    }

    func testChunkText_JustOverLimit() {
        let text = String(repeating: "a", count: 3001)
        let chunks = SlackAPIClient.chunkText(text, maxLength: 3000)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].count, 3000)
        XCTAssertEqual(chunks[1].count, 1)
    }

    func testChunkText_PrefersParagraphBreaks() {
        let p1 = String(repeating: "a", count: 100)
        let p2 = String(repeating: "b", count: 100)
        let text = "\(p1)\n\n\(p2)"

        let chunks = SlackAPIClient.chunkText(text, maxLength: 150)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertTrue(chunks[0].hasSuffix("\n\n"))
    }

    func testChunkText_FallsBackToLineBreaks() {
        let l1 = String(repeating: "a", count: 100)
        let l2 = String(repeating: "b", count: 100)
        let text = "\(l1)\n\(l2)"

        let chunks = SlackAPIClient.chunkText(text, maxLength: 150)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertTrue(chunks[0].hasSuffix("\n"))
    }

    func testChunkText_DefaultMaxLength_Is3000() {
        let text = String(repeating: "a", count: 3500)
        let chunks = SlackAPIClient.chunkText(text)
        XCTAssertEqual(chunks[0].count, 3000)
        XCTAssertGreaterThan(chunks.count, 1)
    }

    func testChunkText_EmptyString() {
        let chunks = SlackAPIClient.chunkText("")
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0], "")
    }

    // MARK: - Slack vs Discord vs Telegram Chunk Limits

    func testChunkText_SlackLargerThanDiscord() {
        let text = String(repeating: "a", count: 6000)
        let slackChunks = SlackAPIClient.chunkText(text)       // 3000 default
        let discordChunks = DiscordAPIClient.chunkText(text)   // 1950 default

        XCTAssertLessThan(slackChunks.count, discordChunks.count)
    }
}
