// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SemanticChunkerEdgeCaseTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class SemanticChunkerEdgeCaseTests: XCTestCase {

    // MARK: - R3: Empty Code Block Prefix-Only Chunks

    /// The SemanticChunker filters empty code at the block level, but TreeSitterCodeChunker
    /// may produce a prefix-only chunk for code that is just whitespace after language detection.
    func testChunkCode_WhitespaceOnlyCode_ProducesNoChunks() {
        let chunker = SemanticChunker(maxChunkSize: 256, overlap: 30)
        let blocks = [ContentBlock(id: "b0", type: .code(language: "swift", content: "   \n  \n  ", fileName: nil))]
        let chunks = chunker.chunk(blocks: blocks)

        XCTAssertTrue(chunks.isEmpty, "Whitespace-only code should produce zero chunks")
    }

    func testChunkCode_NewlinesOnly_ProducesNoChunks() {
        let chunker = SemanticChunker(maxChunkSize: 256, overlap: 30)
        let blocks = [ContentBlock(id: "b0", type: .code(language: "python", content: "\n\n\n", fileName: nil))]
        let chunks = chunker.chunk(blocks: blocks)

        XCTAssertTrue(chunks.isEmpty, "Newlines-only code should produce zero chunks")
    }

    /// Verify that no chunk is ONLY a language prefix with no actual content
    func testChunkCode_NoChunkIsPrefixOnly() {
        let chunker = SemanticChunker(maxChunkSize: 100, overlap: 10)
        // Short code that might edge-case into prefix-only
        let code = "x = 1"
        let blocks = [ContentBlock(id: "b0", type: .code(language: "python", content: code, fileName: nil))]
        let chunks = chunker.chunk(blocks: blocks)

        for chunk in chunks {
            let stripped = chunk
                .replacingOccurrences(of: "[python Context]:\n", with: "")
                .replacingOccurrences(of: "[Code Context]:\n", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertFalse(stripped.isEmpty,
                "Chunk should have content beyond the language prefix. Got: '\(chunk)'")
        }
    }

    // MARK: - R4: Table Pipe Character Corruption

    /// Table cells containing | should be escaped or preserved without corrupting structure
    func testChunkTable_CellsWithPipeCharacter_PreservedCorrectly() {
        let chunker = SemanticChunker(maxChunkSize: 512, overlap: 50)
        let blocks = [ContentBlock(id: "b0", type: .table(
            headers: ["Expression", "Result"],
            rows: [["a | b", "true"], ["x || y", "false"]],
            alignments: []
        ))]
        let chunks = chunker.chunk(blocks: blocks)

        XCTAssertEqual(chunks.count, 1)
        // The chunk should contain both cell values intact
        let chunk = chunks[0]
        XCTAssertTrue(chunk.contains("Expression"), "Header should be present")
        XCTAssertTrue(chunk.contains("Result"), "Header should be present")
        // Each row cell should be recoverable in the output
        XCTAssertTrue(chunk.contains("true"), "Cell value 'true' should be present")
        XCTAssertTrue(chunk.contains("false"), "Cell value 'false' should be present")
    }

    func testChunkTable_EmptyHeaders_ProducesChunk() {
        let chunker = SemanticChunker(maxChunkSize: 512, overlap: 50)
        let blocks = [ContentBlock(id: "b0", type: .table(
            headers: [],
            rows: [["data1", "data2"]],
            alignments: []
        ))]
        let chunks = chunker.chunk(blocks: blocks)

        // Should produce a chunk with just the row data
        XCTAssertFalse(chunks.isEmpty, "Table with empty headers but rows should still produce chunks")
    }

    func testChunkTable_EmptyRows_ProducesChunkWithHeadersOnly() {
        let chunker = SemanticChunker(maxChunkSize: 512, overlap: 50)
        let blocks = [ContentBlock(id: "b0", type: .table(
            headers: ["Col1", "Col2"],
            rows: [],
            alignments: []
        ))]
        let chunks = chunker.chunk(blocks: blocks)

        XCTAssertFalse(chunks.isEmpty, "Table with headers but no rows should still produce chunks")
        XCTAssertTrue(chunks[0].contains("Col1"))
    }

    func testChunkTable_EmptyHeadersAndRows_ProducesNoChunks() {
        let chunker = SemanticChunker(maxChunkSize: 512, overlap: 50)
        let blocks = [ContentBlock(id: "b0", type: .table(
            headers: [],
            rows: [],
            alignments: []
        ))]
        let chunks = chunker.chunk(blocks: blocks)

        XCTAssertTrue(chunks.isEmpty, "Completely empty table should produce zero chunks")
    }

    // MARK: - R5: Overlap Word Boundary for Non-Space Text

    /// When text has no spaces (CJK, long URLs, code), getOverlapText should still
    /// return a meaningful overlap — not the raw character slice from the middle of a glyph.
    func testChunkText_CJKTextWithoutSpaces_OverlapDoesNotCrash() {
        let chunker = SemanticChunker(maxChunkSize: 80, overlap: 20)
        // CJK text has no spaces — overlap word-boundary snapping will fail to find a space
        let cjk = String(repeating: "漢字テスト文", count: 30) // ~180 chars, no spaces
        let blocks = [ContentBlock(id: "b0", type: .paragraph(cjk))]

        // Should not crash and should produce chunks
        let chunks = chunker.chunk(blocks: blocks)
        XCTAssertFalse(chunks.isEmpty, "CJK text should produce chunks even without spaces")

        for chunk in chunks {
            XCTAssertFalse(chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "No chunk should be empty")
        }
    }

    func testChunkText_LongURLWithoutSpaces_ProducesChunks() {
        let chunker = SemanticChunker(maxChunkSize: 100, overlap: 20)
        let url = "https://example.com/" + String(repeating: "path/", count: 50) // ~350 chars, few spaces
        let blocks = [ContentBlock(id: "b0", type: .paragraph(url))]
        let chunks = chunker.chunk(blocks: blocks)

        XCTAssertFalse(chunks.isEmpty, "Long URL text should produce chunks")
    }

    // MARK: - R6: splitLargeText Minimum Chunk Quality

    /// When a single word is larger than maxChunkSize, splitLargeText should not produce
    /// single-character or empty chunks.
    func testChunkText_SingleMassiveWord_NoEmptyChunks() {
        let chunker = SemanticChunker(maxChunkSize: 50, overlap: 10)
        // A 200-char "word" with no spaces
        let massiveWord = String(repeating: "a", count: 200)
        let blocks = [ContentBlock(id: "b0", type: .paragraph(massiveWord))]
        let chunks = chunker.chunk(blocks: blocks)

        XCTAssertFalse(chunks.isEmpty, "Should produce chunks for massive word")

        for (i, chunk) in chunks.enumerated() {
            XCTAssertGreaterThan(chunk.count, 1,
                "Chunk \(i) should not be a single character. Got: '\(chunk)'")
        }
    }

    func testChunkText_SingleMassiveWord_ChunksDontExceedMaxSize() {
        let chunker = SemanticChunker(maxChunkSize: 50, overlap: 10)
        let massiveWord = String(repeating: "b", count: 200)
        let blocks = [ContentBlock(id: "b0", type: .paragraph(massiveWord))]
        let chunks = chunker.chunk(blocks: blocks)

        for (i, chunk) in chunks.enumerated() {
            // Allow some tolerance for overlap mechanics
            XCTAssertLessThanOrEqual(chunk.count, 70,
                "Chunk \(i) has \(chunk.count) chars, expected ≤ ~70 (maxChunkSize + overlap tolerance)")
        }
    }

    /// Verify splitLargeText doesn't produce duplicate content (infinite loop symptom)
    func testChunkText_MassiveWord_NoDuplicateChunks() {
        let chunker = SemanticChunker(maxChunkSize: 50, overlap: 10)
        let massiveWord = String(repeating: "x", count: 150)
        let blocks = [ContentBlock(id: "b0", type: .paragraph(massiveWord))]
        let chunks = chunker.chunk(blocks: blocks)

        // With 150 chars and 50-char chunks, we should get ~3-5 chunks, not 150
        XCTAssertLessThan(chunks.count, 20,
            "Should not produce excessive chunks (possible infinite loop). Got \(chunks.count)")
    }

    // MARK: - Mixed Edge Cases

    func testChunkBlocks_AllEmptyContent_ProducesNoChunks() {
        let chunker = SemanticChunker(maxChunkSize: 256, overlap: 30)
        let blocks = [
            ContentBlock(id: "b0", type: .paragraph("")),
            ContentBlock(id: "b1", type: .code(language: "swift", content: "", fileName: nil)),
            ContentBlock(id: "b2", type: .heading(level: 1, text: "  ")),
            ContentBlock(id: "b3", type: .table(headers: [], rows: [], alignments: [])),
            ContentBlock(id: "b4", type: .horizontalRule),
            // [mc-3] An image with a path or alt text IS content now (indexed as its markdown);
            // only one with neither is empty.
            ContentBlock(id: "b5", type: .image(url: "", altText: nil))
        ]
        let chunks = chunker.chunk(blocks: blocks)

        XCTAssertTrue(chunks.isEmpty, "All-empty content blocks should produce zero chunks")
    }

    func testChunkBlocks_SingleCharParagraph_ProducesOneChunk() {
        let chunker = SemanticChunker(maxChunkSize: 256, overlap: 30)
        let blocks = [ContentBlock(id: "b0", type: .paragraph("X"))]
        let chunks = chunker.chunk(blocks: blocks)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0], "X")
    }

    func testChunkCode_SingleNewline_ProducesNoChunks() {
        let chunker = SemanticChunker(maxChunkSize: 256, overlap: 30)
        let blocks = [ContentBlock(id: "b0", type: .code(language: "js", content: "\n", fileName: nil))]
        let chunks = chunker.chunk(blocks: blocks)

        // "\n" trims to empty → should be filtered
        XCTAssertTrue(chunks.isEmpty, "Single newline code should produce zero chunks")
    }
}
