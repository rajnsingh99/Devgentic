// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SemanticChunkerTests.swift
//  devgenticTests
//
//  Created by Raj Singh on 02/03/26.
//

import XCTest
@testable import devgentic

final class SemanticChunkerTests: XCTestCase {

    // MARK: - Initialization Tests

    func testInit_DefaultValues() {
        let chunker = SemanticChunker()
        XCTAssertEqual(chunker.maxChunkSize, 512)
        XCTAssertEqual(chunker.overlap, 50)
    }

    func testInit_CustomValues() {
        let chunker = SemanticChunker(maxChunkSize: 256, overlap: 30)
        XCTAssertEqual(chunker.maxChunkSize, 256)
        XCTAssertEqual(chunker.overlap, 30)
    }

    // MARK: - Text Chunking (Small Inputs)

    func testChunkText_SingleShortParagraph_ProducesOneChunk() {
        let chunker = SemanticChunker()
        let blocks = [ContentBlock(id: "b0", type: .paragraph("Hello, this is a short paragraph."))]
        let chunks = chunker.chunk(blocks: blocks)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first, "Hello, this is a short paragraph.")
    }

    func testChunkText_SingleHeading_ProducesOneChunk() {
        let chunker = SemanticChunker()
        let blocks = [ContentBlock(id: "b0", type: .heading(level: 1, text: "Introduction"))]
        let chunks = chunker.chunk(blocks: blocks)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first, "Introduction")
    }

    func testChunkText_EmptyParagraph_ProducesZeroChunks() {
        let chunker = SemanticChunker()
        let blocks = [ContentBlock(id: "b0", type: .paragraph("   \n  \t  "))]
        let chunks = chunker.chunk(blocks: blocks)

        XCTAssertTrue(chunks.isEmpty)
    }

    // MARK: - Text Chunking (Medium Inputs)

    func testChunkText_MultipleParagraphsUnderLimit_GroupedIntoOneChunk() {
        let chunker = SemanticChunker(maxChunkSize: 512, overlap: 50)
        let text = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."
        let blocks = [ContentBlock(id: "b0", type: .paragraph(text))]
        let chunks = chunker.chunk(blocks: blocks)

        // All three fit under 512 chars, so should be 1 chunk
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].contains("First paragraph."))
        XCTAssertTrue(chunks[0].contains("Third paragraph."))
    }

    func testChunkText_MultipleParagraphsExceedingLimit_SplitsIntoMultipleChunks() {
        let chunker = SemanticChunker(maxChunkSize: 100, overlap: 20)

        // Each paragraph is ~60 chars, so two won't fit in 100
        let para1 = "This is the first paragraph with enough words to take up space here."
        let para2 = "This is the second paragraph with similarly substantial content here."
        let para3 = "This is the third paragraph bringing even more text to the table."
        let text = "\(para1)\n\n\(para2)\n\n\(para3)"
        let blocks = [ContentBlock(id: "b0", type: .paragraph(text))]
        let chunks = chunker.chunk(blocks: blocks)

        XCTAssertGreaterThan(chunks.count, 1, "Should produce more than 1 chunk for text exceeding maxChunkSize")
    }

    func testChunkText_OverlapBetweenChunks_SecondChunkContainsOverlapText() {
        let chunker = SemanticChunker(maxChunkSize: 80, overlap: 20)

        let para1 = "Alpha bravo charlie delta echo foxtrot golf hotel india juliet."
        let para2 = "Kilo lima mike november oscar papa quebec romeo sierra tango."
        let text = "\(para1)\n\n\(para2)"
        let blocks = [ContentBlock(id: "b0", type: .paragraph(text))]
        let chunks = chunker.chunk(blocks: blocks)

        guard chunks.count >= 2 else {
            XCTFail("Expected at least 2 chunks, got \(chunks.count)")
            return
        }

        // The second chunk should contain some trailing text from the first chunk (overlap)
        let firstChunkTail = String(chunks[0].suffix(20))
        // At least part of the overlap should appear in the second chunk
        let overlapWords = firstChunkTail.split(separator: " ").last.map(String.init) ?? ""
        if !overlapWords.isEmpty {
            XCTAssertTrue(chunks[1].contains(overlapWords),
                          "Second chunk should contain overlap text from first chunk. Looking for '\(overlapWords)' in '\(chunks[1].prefix(50))...'")
        }
    }

    // MARK: - Text Chunking (Large Inputs)

    func testChunkText_SingleMassiveParagraph_10KChars_ProducesMultipleChunks() {
        let chunker = SemanticChunker(maxChunkSize: 512, overlap: 50)

        // Create a 10,000+ character paragraph with no double-newlines
        let sentence = "This is a moderately long sentence that represents typical prose content. "
        let massiveText = String(repeating: sentence, count: 150) // ~11,250 chars
        let blocks = [ContentBlock(id: "b0", type: .paragraph(massiveText))]
        let chunks = chunker.chunk(blocks: blocks)

        XCTAssertGreaterThan(chunks.count, 10, "10K+ text should produce many chunks")

        // Verify no chunk exceeds maxChunkSize (with some tolerance for overlap mechanics)
        for (i, chunk) in chunks.enumerated() {
            XCTAssertLessThanOrEqual(chunk.count, 600,
                                     "Chunk \(i) has \(chunk.count) chars, expected ≤ ~600 (maxChunkSize + overlap tolerance)")
        }
    }

    func testChunkText_LargeParagraph_ChunksAreNotEmpty() {
        let chunker = SemanticChunker(maxChunkSize: 200, overlap: 30)

        let longText = String(repeating: "word ", count: 500) // 2500 chars
        let blocks = [ContentBlock(id: "b0", type: .paragraph(longText))]
        let chunks = chunker.chunk(blocks: blocks)

        XCTAssertFalse(chunks.isEmpty)
        for chunk in chunks {
            XCTAssertFalse(chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "No chunk should be empty or whitespace-only")
        }
    }

    // MARK: - Code Block Chunking

    func testChunkCode_ShortCodeBlock_ProducesOneChunkWithLanguagePrefix() {
        let chunker = SemanticChunker()
        let code = "let x = 1\nlet y = 2\nlet z = x + y\nprint(z)"
        let blocks = [ContentBlock(id: "b0", type: .code(language: "swift", content: code, fileName: nil))]
        let chunks = chunker.chunk(blocks: blocks)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].hasPrefix("[swift Context]:\n"),
                      "Code chunk should start with language prefix")
        XCTAssertTrue(chunks[0].contains("let x = 1"))
        XCTAssertTrue(chunks[0].contains("print(z)"))
    }

    func testChunkCode_EmptyLanguage_UsesCodePrefix() {
        let chunker = SemanticChunker()
        let code = "x = 1"
        let blocks = [ContentBlock(id: "b0", type: .code(language: "", content: code, fileName: nil))]
        let chunks = chunker.chunk(blocks: blocks)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].hasPrefix("[Code Context]:\n"),
                      "Empty language should use 'Code' as fallback prefix")
    }

    func testChunkCode_NeverSeversALine() {
        let chunker = SemanticChunker(maxChunkSize: 100, overlap: 20)

        // Each line is ~40 chars; with the prefix (~18 chars), 2 lines barely fit
        var lines: [String] = []
        for i in 0..<10 {
            lines.append("let variable\(i) = \"some value for \(i)\"")
        }
        let code = lines.joined(separator: "\n")
        let blocks = [ContentBlock(id: "b0", type: .code(language: "swift", content: code, fileName: nil))]
        let chunks = chunker.chunk(blocks: blocks)

        // Verify that no chunk contains a partial line (each line from original should appear complete)
        for chunk in chunks {
            // Strip the prefix before checking
            let content = chunk.replacingOccurrences(of: "[swift Context]:\n", with: "")
            let chunkLines = content.components(separatedBy: "\n")
            for line in chunkLines where !line.isEmpty {
                XCTAssertTrue(lines.contains(line),
                              "Found partial line '\(line)' that doesn't match any original line")
            }
        }
    }

    func testChunkCode_LargeCodeBlock_100PlusLines_ProducesMultipleChunks() {
        let chunker = SemanticChunker(maxChunkSize: 200, overlap: 30)

        var lines: [String] = []
        for i in 0..<120 {
            lines.append("    print(\"Line \(i)\")")
        }
        let code = lines.joined(separator: "\n")
        let blocks = [ContentBlock(id: "b0", type: .code(language: "python", content: code, fileName: nil))]
        let chunks = chunker.chunk(blocks: blocks)

        XCTAssertGreaterThan(chunks.count, 5, "120 lines should produce many chunks at maxChunkSize=200")

        // Every chunk should have the language prefix
        for chunk in chunks {
            XCTAssertTrue(chunk.hasPrefix("[python Context]:\n"),
                          "Every code chunk should have the language prefix")
        }
    }

    func testChunkCode_OverlapRetainsLastTwoLines() {
        let chunker = SemanticChunker(maxChunkSize: 120, overlap: 20)

        // Create enough lines to force a split
        let lines = (0..<10).map { "line_\($0) = value" }
        let code = lines.joined(separator: "\n")
        let blocks = [ContentBlock(id: "b0", type: .code(language: "py", content: code, fileName: nil))]
        let chunks = chunker.chunk(blocks: blocks)

        guard chunks.count >= 2 else {
            // If the code fits in 1 chunk, we can't test overlap
            return
        }

        // Get the lines from the first chunk (strip prefix)
        let firstContent = chunks[0].replacingOccurrences(of: "[py Context]:\n", with: "")
        let firstLines = firstContent.components(separatedBy: "\n").filter { !$0.isEmpty }

        // Get the lines from the second chunk (strip prefix)
        let secondContent = chunks[1].replacingOccurrences(of: "[py Context]:\n", with: "")
        let secondLines = secondContent.components(separatedBy: "\n").filter { !$0.isEmpty }

        // The last 2 lines of chunk 1 should appear at the start of chunk 2
        guard firstLines.count >= 2 else { return }
        let overlapLines = Array(firstLines.suffix(2))

        for overlapLine in overlapLines {
            XCTAssertTrue(secondLines.contains(overlapLine),
                          "Overlap line '\(overlapLine)' should appear in the next chunk")
        }
    }

    // MARK: - Block Type Routing

    func testChunk_ParagraphBlock_ProducesChunks() {
        let chunker = SemanticChunker()
        let blocks = [ContentBlock(id: "b0", type: .paragraph("Some paragraph text."))]
        let chunks = chunker.chunk(blocks: blocks)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0], "Some paragraph text.")
    }

    func testChunk_CodeBlock_ProducesChunksWithLanguagePrefix() {
        let chunker = SemanticChunker()
        let blocks = [ContentBlock(id: "b0", type: .code(language: "rust", content: "fn main() {}", fileName: nil))]
        let chunks = chunker.chunk(blocks: blocks)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].contains("[rust Context]:"))
        XCTAssertTrue(chunks[0].contains("fn main() {}"))
    }

    func testChunk_HeadingBlock_ProducesChunks() {
        let chunker = SemanticChunker()
        let blocks = [ContentBlock(id: "b0", type: .heading(level: 2, text: "Section Title"))]
        let chunks = chunker.chunk(blocks: blocks)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0], "Section Title")
    }

    func testChunk_ListItemBlock_CombinesPrefixAndText() {
        let chunker = SemanticChunker()
        let blocks = [ContentBlock(id: "b0", type: .listItem(
            prefix: "•",
            blocks: [ContentBlock(id: "b0.0", type: .paragraph("Buy groceries"))],
            checkbox: nil
        ))]
        let chunks = chunker.chunk(blocks: blocks)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0], "• Buy groceries")
    }

    func testChunk_TableBlock_JoinsHeadersAndRows() {
        let chunker = SemanticChunker()
        let blocks = [ContentBlock(id: "b0", type: .table(
            headers: ["Name", "Age"],
            rows: [["Alice", "30"], ["Bob", "25"]],
            alignments: []
        ))]
        let chunks = chunker.chunk(blocks: blocks)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].contains("Name | Age"))
        XCTAssertTrue(chunks[0].contains("Alice | 30"))
        XCTAssertTrue(chunks[0].contains("Bob | 25"))
    }

    func testChunk_HorizontalRuleBlock_Skipped() {
        let chunker = SemanticChunker()
        let blocks = [ContentBlock(id: "b0", type: .horizontalRule)]
        let chunks = chunker.chunk(blocks: blocks)

        XCTAssertTrue(chunks.isEmpty)
    }

    /// [mc-3] Images are indexed as the markdown the author wrote. This used to assert the
    /// opposite ("not useful for embedding"), which was harmless only because an INLINE image's
    /// `![alt](path)` stayed inside its paragraph text and was embedded with it — once the
    /// parser split image-bearing paragraphs, the alt text and the file path of every agent-
    /// written chart silently left the index ("where did you save the histogram?" stopped
    /// retrieving). A standalone image is indexed the same way, for consistency.
    func testChunk_ImageBlock_IndexedAsItsMarkdown() {
        let chunker = SemanticChunker()
        let blocks = [ContentBlock(id: "b0", type: .image(url: "https://example.com/img.png", altText: "A photo"))]
        let chunks = chunker.chunk(blocks: blocks)

        XCTAssertEqual(chunks, ["![A photo](https://example.com/img.png)"])
    }

    // MARK: - Mixed Block Inputs

    func testChunk_MixedBlocks_ParagraphAndCode() {
        let chunker = SemanticChunker()
        let blocks = [
            ContentBlock(id: "b0", type: .paragraph("Here is some explanation.")),
            ContentBlock(id: "b1", type: .code(language: "swift", content: "let x = 42", fileName: nil))
        ]
        let chunks = chunker.chunk(blocks: blocks)

        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0], "Here is some explanation.")
        XCTAssertTrue(chunks[1].contains("[swift Context]:"))
        XCTAssertTrue(chunks[1].contains("let x = 42"))
    }

    /// [mc-3] The horizontal rule is the only block type with nothing to index; the image
    /// contributes its markdown (see `testChunk_ImageBlock_IndexedAsItsMarkdown`).
    func testChunk_AllBlockTypes_SkipsHorizontalRuleOnly() {
        let chunker = SemanticChunker()
        let blocks = [
            ContentBlock(id: "b0", type: .heading(level: 1, text: "Title")),
            ContentBlock(id: "b1", type: .paragraph("Body text.")),
            ContentBlock(id: "b2", type: .listItem(
                prefix: "-",
                blocks: [ContentBlock(id: "b2.0", type: .paragraph("Item one"))],
                checkbox: nil
            )),
            ContentBlock(id: "b3", type: .table(headers: ["Col"], rows: [["Val"]], alignments: [])),
            ContentBlock(id: "b4", type: .code(language: "js", content: "console.log(1)", fileName: nil)),
            ContentBlock(id: "b5", type: .horizontalRule),
            ContentBlock(id: "b6", type: .image(url: "img.png", altText: "alt"))
        ]
        let chunks = chunker.chunk(blocks: blocks)

        // 6 content-bearing blocks: only the horizontalRule is skipped; the image is indexed
        // as its markdown ([mc-3]).
        XCTAssertEqual(chunks.count, 6)
        XCTAssertEqual(chunks.last, "![alt](img.png)")
    }

    // MARK: - Edge Cases

    func testChunk_EmptyBlocksArray_ProducesEmptyResult() {
        let chunker = SemanticChunker()
        let chunks = chunker.chunk(blocks: [])
        XCTAssertTrue(chunks.isEmpty)
    }

    func testChunk_WhitespaceOnlyParagraph_ProducesZeroChunks() {
        let chunker = SemanticChunker()
        let blocks = [ContentBlock(id: "b0", type: .paragraph("     \n\n   \t   "))]
        let chunks = chunker.chunk(blocks: blocks)

        XCTAssertTrue(chunks.isEmpty)
    }

    func testChunk_UnicodeAndEmoji_ChunksCorrectly() {
        let chunker = SemanticChunker()
        let text = "こんにちは世界 🌍 This message contains Unicode and emoji characters 🎉"
        let blocks = [ContentBlock(id: "b0", type: .paragraph(text))]
        let chunks = chunker.chunk(blocks: blocks)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].contains("🌍"))
        XCTAssertTrue(chunks[0].contains("こんにちは"))
    }

    func testChunk_SpecialCharactersInCode_PreservedVerbatim() {
        let chunker = SemanticChunker()
        let code = "if (x < 10 && y > 5) { return \"hello \\\"world\\\"\"; }"
        let blocks = [ContentBlock(id: "b0", type: .code(language: "c", content: code, fileName: nil))]
        let chunks = chunker.chunk(blocks: blocks)

        XCTAssertEqual(chunks.count, 1)
        let content = chunks[0].replacingOccurrences(of: "[c Context]:\n", with: "")
        XCTAssertEqual(content, code)
    }

    func testChunk_EmptyCodeContent_Skipped() {
        let chunker = SemanticChunker()
        let blocks = [ContentBlock(id: "b0", type: .code(language: "swift", content: "   ", fileName: nil))]
        let chunks = chunker.chunk(blocks: blocks)

        XCTAssertTrue(chunks.isEmpty)
    }
}
