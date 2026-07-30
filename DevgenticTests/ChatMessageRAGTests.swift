//
//  ChatMessageRAGTests.swift
//  devgenticTests
//
//  Created by Raj Singh on 02/03/26.
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

    // MARK: - tokenCountEstimate

    func testTokenCountEstimate_PlainText_ShortString() {
        // "Hello world" = 11 chars → max(1, 11/4) = max(1, 2) = 2
        let msg = makeMessage(content: .plainText("Hello world"))
        XCTAssertEqual(msg.tokenCountEstimate, 2)
    }

    func testTokenCountEstimate_PlainText_MinimumIsOne() {
        // "Hi" = 2 chars → max(1, 2/4) = max(1, 0) = 1
        let msg = makeMessage(content: .plainText("Hi"))
        XCTAssertEqual(msg.tokenCountEstimate, 1)
    }

    func testTokenCountEstimate_PlainText_LongString() {
        // 1000 chars → 1000/4 = 250
        let longText = String(repeating: "a", count: 1000)
        let msg = makeMessage(content: .plainText(longText))
        XCTAssertEqual(msg.tokenCountEstimate, 250)
    }

    func testTokenCountEstimate_MarkdownText() {
        let text = "# Title\n\nSome **bold** and *italic* text here."
        let msg = makeMessage(content: .markdownText(text))
        XCTAssertEqual(msg.tokenCountEstimate, max(1, text.count / 4))
    }

    /// Code is denser than prose — braces, operators and short identifiers each cost a
    /// token — so it is estimated at ~3 chars/token, not the ~4 used for English. This test
    /// asserted the old uniform /4 and had been red since the split landed. The same ~3
    /// figure is reached independently by `SemanticChunker` for WordPiece.
    func testTokenCountEstimate_CodeBlock() {
        let code = "let x = 1\nlet y = 2"
        let msg = makeMessage(content: .codeBlock(language: "swift", code: code))
        XCTAssertEqual(msg.tokenCountEstimate, max(1, code.count / 3))
        XCTAssertGreaterThan(msg.tokenCountEstimate, code.count / 4,
                             "code must be priced denser than prose, not the same")
    }

    func testTokenCountEstimate_Error() {
        let msg = makeMessage(content: .error(title: "Err", details: "Something failed"))
        // textContent returns "Err: Something failed" = 21 chars → 21/4 = 5
        XCTAssertEqual(msg.tokenCountEstimate, 5)
    }

    func testTokenCountEstimate_Image_ReturnsZero() {
        let msg = makeMessage(content: .mediaArtifact(MediaArtifact(kind: .image, reference: .ephemeralData(Data()), mimeType: "image/png")))
        XCTAssertEqual(msg.tokenCountEstimate, 0)
    }

    func testTokenCountEstimate_EmptyString() {
        // "" = 0 chars → max(1, 0/4) = 1
        let msg = makeMessage(content: .plainText(""))
        XCTAssertEqual(msg.tokenCountEstimate, 1)
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
