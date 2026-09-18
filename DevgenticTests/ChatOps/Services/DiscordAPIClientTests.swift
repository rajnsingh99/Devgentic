// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DiscordAPIClientTests.swift
//  DevgenticTests
//
//  Created by Raj Singh on 24/03/26.
//

import XCTest
@testable import devgentic

final class DiscordAPIClientTests: XCTestCase {

    // MARK: - Text Chunking

    func testChunkText_ShortText_ReturnsSingleChunk() {
        let text = "Hello, world!"
        let chunks = DiscordAPIClient.chunkText(text, maxLength: 1950)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0], text)
    }

    func testChunkText_ExactlyAtLimit_ReturnsSingleChunk() {
        let text = String(repeating: "a", count: 1950)
        let chunks = DiscordAPIClient.chunkText(text, maxLength: 1950)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].count, 1950)
    }

    func testChunkText_JustOverLimit_SplitsIntoTwo() {
        let text = String(repeating: "a", count: 1951)
        let chunks = DiscordAPIClient.chunkText(text, maxLength: 1950)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].count, 1950)
        XCTAssertEqual(chunks[1].count, 1)
    }

    func testChunkText_PrefersParagraphBreaks() {
        let paragraph1 = String(repeating: "a", count: 100)
        let paragraph2 = String(repeating: "b", count: 100)
        let text = "\(paragraph1)\n\n\(paragraph2)"

        let chunks = DiscordAPIClient.chunkText(text, maxLength: 150)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertTrue(chunks[0].hasSuffix("\n\n"))
        XCTAssertTrue(chunks[1].hasPrefix("b"))
    }

    func testChunkText_FallsBackToLineBreaks() {
        let line1 = String(repeating: "a", count: 100)
        let line2 = String(repeating: "b", count: 100)
        let text = "\(line1)\n\(line2)"

        let chunks = DiscordAPIClient.chunkText(text, maxLength: 150)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertTrue(chunks[0].hasSuffix("\n"))
    }

    func testChunkText_HardSplitWhenNoBreaks() {
        let text = String(repeating: "x", count: 4000)
        let chunks = DiscordAPIClient.chunkText(text, maxLength: 1950)
        XCTAssertEqual(chunks.count, 3) // 1950 + 1950 + 100
        XCTAssertEqual(chunks[0].count, 1950)
        XCTAssertEqual(chunks[1].count, 1950)
        XCTAssertEqual(chunks[2].count, 100)
    }

    func testChunkText_EmptyString() {
        let chunks = DiscordAPIClient.chunkText("", maxLength: 1950)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0], "")
    }

    func testChunkText_DefaultMaxLength() {
        // Default is 1950 (not Telegram's 4000)
        let text = String(repeating: "a", count: 2000)
        let chunks = DiscordAPIClient.chunkText(text)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].count, 1950)
    }

    // MARK: - Discord vs Telegram Chunk Limits

    func testChunkText_DiscordLimitIsSmallerThanTelegram() {
        // Discord: 1950 (2000 limit with margin)
        // Telegram: 4000 (4096 limit with margin)
        let discordChunks = DiscordAPIClient.chunkText(String(repeating: "a", count: 4000))
        let telegramChunks = TelegramAPIClient.chunkText(String(repeating: "a", count: 4000))

        // Discord needs more chunks than Telegram for the same text
        XCTAssertGreaterThan(discordChunks.count, telegramChunks.count)
    }
}
