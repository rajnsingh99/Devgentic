// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  StreamingMarkdownParserTests.swift
//  DevgenticTests
//
//  Pins the incremental streaming markdown parser (2026-07): settled regions
//  parse once, only the trailing block re-parses per flush, and the result must
//  converge to exactly what a full parseMarkdown() produces.
//

import XCTest
import Markdown
@testable import devgentic

final class StreamingMarkdownParserTests: XCTestCase {

    /// Splits a string into fixed-size character chunks to simulate token flushes.
    private func chunks(_ text: String, size: Int) -> [String] {
        var result: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[index..<end]))
            index = end
        }
        return result
    }

    private let document = """
    # Title

    First paragraph with **bold** and `inline code`.

    ```swift
    let x = 1

    let y = 2
    ```

    - item one
    - item two

    1. first
    2. second

    Final closing words.
    """

    /// Feeding a document in small append-only chunks must converge to the same
    /// blocks as one full parse — same types, same content, same positional ids.
    func testIncrementalMatchesFullParseForAppendOnlyStream() {
        let parser = StreamingMarkdownParser()
        var fed = ""
        var result: [ContentBlock] = []

        for chunk in chunks(document, size: 7) {
            fed += chunk
            result = parser.parse(fed)
        }

        XCTAssertEqual(result, parseMarkdown(document),
                       "Incremental result must equal the full parse of the final text")
    }

    /// The blank line INSIDE the fenced code block above must not become a settle
    /// boundary — the fence must survive as ONE code block.
    func testBlankLineInsideFenceDoesNotSplitCodeBlock() {
        let parser = StreamingMarkdownParser()
        var fed = ""
        var result: [ContentBlock] = []
        for chunk in chunks(document, size: 5) {
            fed += chunk
            result = parser.parse(fed)
        }

        let codeBlocks = result.filter {
            if case .code = $0.type { return true }
            return false
        }
        XCTAssertEqual(codeBlocks.count, 1, "The fenced block must remain a single code block")
        if case .code(_, let content, _) = codeBlocks[0].type {
            XCTAssertTrue(content.contains("let x = 1") && content.contains("let y = 2"),
                          "Both statements (across the internal blank line) belong to one block")
        }
    }

    /// A mid-stream unclosed fence must render as a code block (stream-resilient
    /// preprocessing applies to the active region).
    func testUnclosedFenceRendersAsCodeMidStream() {
        let parser = StreamingMarkdownParser()
        let blocks = parser.parse("Intro text.\n\n```swift\nlet x = 1")

        XCTAssertEqual(blocks.count, 2)
        if case .code(let lang, let content, _) = blocks[1].type {
            XCTAssertEqual(lang, "swift")
            XCTAssertTrue(content.contains("let x = 1"))
        } else {
            XCTFail("Expected the unclosed fence to render as a code block, got \(blocks[1].type)")
        }
    }

    /// Settled blocks must keep their identity (id AND content) as more text streams
    /// in — that's what lets ContentBlockView's .equatable() skip re-rendering them.
    func testSettledBlocksKeepStableIdentityAcrossFlushes() {
        let parser = StreamingMarkdownParser()

        let early = parser.parse("# Title\n\nFirst paragraph.\n\nSecond par")
        let later = parser.parse("# Title\n\nFirst paragraph.\n\nSecond paragraph now complete.\n\nAnd a third one begins")

        // The heading and first paragraph settled before the second flush — identical structs.
        XCTAssertTrue(later.count >= 2)
        XCTAssertEqual(early[0], later[0], "Settled heading must be byte-identical across flushes")
        XCTAssertEqual(early[1], later[1], "Settled paragraph must be byte-identical across flushes")
        XCTAssertEqual(later[0].id, "block-0")
        XCTAssertEqual(later[1].id, "block-1")
    }

    /// Non-append input (regeneration, error replacement) must reset the parser and
    /// produce the same result as a fresh full parse — never a stale prefix.
    func testContentReplacementResetsParser() {
        let parser = StreamingMarkdownParser()
        _ = parser.parse("Original response about apples.\n\nWith two paragraphs.")

        let replaced = "Completely different answer.\n\n- bullet\n- points"
        let blocks = parser.parse(replaced)

        XCTAssertEqual(blocks, parseMarkdown(replaced),
                       "Replacement text must fully reset the incremental state")
    }

    /// Full-parse regression: smart punctuation rewrites `---` to an em dash during
    /// parsing, which silently broke marker matching after the AST migration — the
    /// matcher must tolerate both forms.
    func testFileMarkerAttachesFilenameInFullParse() {
        let blocks = parseMarkdown("--- Start of file: main.swift ---\n\n```swift\nprint(1)\n```")
        guard case .code(_, _, let fileName) = blocks.first(where: {
            if case .code = $0.type { return true }
            return false
        })?.type else {
            return XCTFail("Expected a code block")
        }
        XCTAssertEqual(fileName, "main.swift")
    }

    /// The `--- Start of file: X ---` marker must still attach the filename to a code
    /// block even when the marker and the fence settle in different regions.
    func testFileMarkerCarriesAcrossSettledRegions() {
        let parser = StreamingMarkdownParser()
        var fed = ""
        var result: [ContentBlock] = []
        let text = "--- Start of file: main.swift ---\n\n```swift\nprint(1)\n```\n\nDone."
        for chunk in chunks(text, size: 6) {
            fed += chunk
            result = parser.parse(fed)
        }

        guard case .code(_, _, let fileName) = result.first(where: {
            if case .code = $0.type { return true }
            return false
        })?.type else {
            return XCTFail("Expected a code block")
        }
        XCTAssertEqual(fileName, "main.swift")
    }

    /// End-to-end through ChatMessage: incremental while streaming, then ONE
    /// authoritative full re-parse on the first non-streaming access.
    @MainActor
    func testChatMessageHealsToFullParseWhenStreamingEnds() {
        let msg = ChatMessage(
            conversationId: UUID(),
            sender: .agent,
            content: .markdownText(""),
            isStreaming: true,
            backendEntityId: UUID()
        )

        var fed = ""
        for chunk in chunks(document, size: 9) {
            fed += chunk
            msg.invalidateMarkdownCache()          // what ActiveStreamManager does per flush
            _ = msg.getOrCreateMarkdownBlocks(from: fed)
        }

        msg.isStreaming = false
        let final = msg.getOrCreateMarkdownBlocks(from: document)
        XCTAssertEqual(final, parseMarkdown(document),
                       "Post-stream blocks must be the authoritative full parse")
    }
}
