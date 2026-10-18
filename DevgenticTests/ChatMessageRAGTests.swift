// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatMessageRAGTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class ChatMessageRAGTests: XCTestCase {

    // MARK: - Test Helpers

    private func makeMessage(content: MessageContent, sender: SenderRole = .user) -> ChatMessage {
        return ChatMessage(
            conversationId: UUID(),
            sender: sender,
            content: content
        )
    }










    // MARK: - MessageContent.textContent

    func testTextContent_PlainText() {
        let content = MessageContent.plainText("hello")
        XCTAssertEqual(content.textContent, "hello")
    }

    func testTextContent_MarkdownText() {
        let content = MessageContent.markdownText("# Title")
        XCTAssertEqual(content.textContent, "# Title")
    }

    func testTextContent_CodeBlock() {
        let content = MessageContent.codeBlock(language: "py", code: "print(1)")
        XCTAssertEqual(content.textContent, "print(1)")
    }

    func testTextContent_Error_WithTitle() {
        let content = MessageContent.error(title: "E", details: "D")
        XCTAssertEqual(content.textContent, "E: D")
    }

    func testTextContent_Error_NilTitle() {
        let content = MessageContent.error(title: nil, details: "D")
        XCTAssertEqual(content.textContent, "Error: D")
    }

    func testTextContent_Image_ReturnsNil() {
        let content = MessageContent.mediaArtifact(MediaArtifact(kind: .image, reference: .ephemeralData(Data()), mimeType: "image/png"))
        XCTAssertNil(content.textContent)
    }

    // MARK: - getBlocksForIndexing

    func testGetBlocksForIndexing_PlainText_ProducesBlocks() {
        let msg = makeMessage(content: .plainText("Hello world, this is a test."))
        let blocks = msg.getBlocksForIndexing()

        XCTAssertFalse(blocks.isEmpty, "Plain text should produce at least 1 ContentBlock")
    }

    func testGetBlocksForIndexing_MarkdownText_ParsesContent() {
        let msg = makeMessage(content: .markdownText("# Title\n\nBody paragraph text."))
        let blocks = msg.getBlocksForIndexing()

        XCTAssertGreaterThanOrEqual(blocks.count, 1, "Markdown should produce at least 1 block")
    }

    func testGetBlocksForIndexing_CodeBlock_ProducesSingleCodeBlock() {
        let msg = makeMessage(content: .codeBlock(language: "swift", code: "let x = 1"))
        let blocks = msg.getBlocksForIndexing()

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].id, "block-0")

        if case .code(let lang, let content, _) = blocks[0].type {
            XCTAssertEqual(lang, "swift")
            XCTAssertTrue(content.contains("let x = 1"))
        } else {
            XCTFail("Expected .code block type, got \(blocks[0].type)")
        }
    }

    func testGetBlocksForIndexing_CodeBlock_NilLanguage_UsesFallback() {
        let msg = makeMessage(content: .codeBlock(language: nil, code: "x"))
        let blocks = msg.getBlocksForIndexing()

        XCTAssertEqual(blocks.count, 1)
        if case .code(let lang, _, _) = blocks[0].type {
            XCTAssertEqual(lang, "text", "Nil language should use 'text' as fallback")
        } else {
            XCTFail("Expected .code block type")
        }
    }

    func testGetBlocksForIndexing_Error_ReturnsEmpty() {
        let msg = makeMessage(content: .error(title: "E", details: "D"))
        let blocks = msg.getBlocksForIndexing()

        XCTAssertTrue(blocks.isEmpty, "Error messages should not be indexed")
    }

    func testGetBlocksForIndexing_Image_ReturnsEmpty() {
        let msg = makeMessage(content: .mediaArtifact(MediaArtifact(kind: .image, reference: .ephemeralData(Data()), mimeType: "image/png")))
        let blocks = msg.getBlocksForIndexing()

        XCTAssertTrue(blocks.isEmpty, "Image messages should not be indexed")
    }

    func testGetBlocksForIndexing_MarkdownWithCodeFence_ProducesCodeBlock() {
        let markdown = "```swift\nlet x = 1\n```"
        let msg = makeMessage(content: .markdownText(markdown))
        let blocks = msg.getBlocksForIndexing()

        // Should contain at least a code block
        let codeBlocks = blocks.filter {
            if case .code = $0.type { return true }
            return false
        }
        XCTAssertFalse(codeBlocks.isEmpty, "Markdown with code fence should produce a .code block")
    }
}
