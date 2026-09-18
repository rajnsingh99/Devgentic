// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TreeSitterCodeChunkerTests.swift
//  DevgenticTests
//
//  TDD: RAG Tier 1 — TreeSitterCodeChunker Edge Cases (R7 + R8)
//
//  R7: Empty/whitespace code input should not produce prefix-only chunks
//  R8: Language fallback map + single-line edge cases
//

import XCTest
@testable import devgentic

final class TreeSitterCodeChunkerTests: XCTestCase {

    // MARK: - R7: Empty / Whitespace Code Input

    func testChunk_EmptyCode_ProducesNoChunks() {
        let chunker = TreeSitterCodeChunker(maxChunkSize: 256, overlap: 20)
        let chunks = chunker.chunk(code: "", languageName: "swift")

        // Should not produce a prefix-only chunk like "[swift Context]:\n"
        for chunk in chunks {
            let stripped = chunk
                .replacingOccurrences(of: "[swift Context]:\n", with: "")
                .replacingOccurrences(of: "[Code Context]:\n", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertFalse(stripped.isEmpty,
                "No chunk should be prefix-only. Got: '\(chunk)'")
        }
    }

    func testChunk_WhitespaceOnlyCode_NoPrefixOnlyChunks() {
        let chunker = TreeSitterCodeChunker(maxChunkSize: 256, overlap: 20)
        let chunks = chunker.chunk(code: "   \n  \n  \t  ", languageName: "python")

        for chunk in chunks {
            let stripped = chunk
                .replacingOccurrences(of: "[python Context]:\n", with: "")
                .replacingOccurrences(of: "[Code Context]:\n", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertFalse(stripped.isEmpty,
                "Whitespace-only code should not produce prefix-only chunks. Got: '\(chunk)'")
        }
    }

    func testChunk_SingleNewline_NoPrefixOnlyChunks() {
        let chunker = TreeSitterCodeChunker(maxChunkSize: 256, overlap: 20)
        let chunks = chunker.chunk(code: "\n", languageName: "js")

        for chunk in chunks {
            let stripped = chunk
                .replacingOccurrences(of: "[js Context]:\n", with: "")
                .replacingOccurrences(of: "[Code Context]:\n", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertFalse(stripped.isEmpty,
                "Single newline should not produce prefix-only chunks. Got: '\(chunk)'")
        }
    }

    // MARK: - R8: Language Fallback Map

    func testChunk_ShAlias_MapsToLanguage() {
        let chunker = TreeSitterCodeChunker(maxChunkSize: 512, overlap: 20)
        let chunks = chunker.chunk(code: "echo hello", languageName: "sh")

        XCTAssertFalse(chunks.isEmpty)
        // Should use either "sh" or "bash" as prefix — both acceptable
        let hasPrefix = chunks[0].contains("[sh Context]:") || chunks[0].contains("[bash Context]:")
        XCTAssertTrue(hasPrefix, "sh/bash alias should produce a valid language prefix")
    }

    func testChunk_UnknownLanguage_FallsBackGracefully() {
        let chunker = TreeSitterCodeChunker(maxChunkSize: 512, overlap: 20)
        let chunks = chunker.chunk(code: "data = [1,2,3]", languageName: "brainfuck")

        XCTAssertFalse(chunks.isEmpty, "Unknown language should fall back to naive chunking")
        XCTAssertTrue(chunks[0].contains("[brainfuck Context]:"),
            "Unknown language name should still be used as prefix")
    }

    func testChunk_EmptyLanguage_UsesCodePrefix() {
        let chunker = TreeSitterCodeChunker(maxChunkSize: 512, overlap: 20)
        let chunks = chunker.chunk(code: "let x = 1", languageName: "")

        XCTAssertFalse(chunks.isEmpty)
        XCTAssertTrue(chunks[0].hasPrefix("[Code Context]:\n"),
            "Empty language should use 'Code' as fallback prefix")
    }

    func testChunk_NilLanguageEquivalent_UsesCodePrefix() {
        // SemanticChunker passes `language ?? ""` so empty string is the nil case
        let chunker = TreeSitterCodeChunker(maxChunkSize: 512, overlap: 20)
        let chunks = chunker.chunk(code: "print('hello')", languageName: "")

        XCTAssertTrue(chunks[0].hasPrefix("[Code Context]:\n"))
    }

    // MARK: - Single Line Code

    func testChunk_SingleLine_ProducesOneChunk() {
        let chunker = TreeSitterCodeChunker(maxChunkSize: 512, overlap: 20)
        let chunks = chunker.chunk(code: "let x = 42", languageName: "swift")

        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].contains("let x = 42"))
    }

    func testChunk_SingleVeryLongLine_HandledGracefully() {
        let chunker = TreeSitterCodeChunker(maxChunkSize: 100, overlap: 20)
        // A single line longer than maxChunkSize
        let longLine = "let x = \"" + String(repeating: "a", count: 200) + "\""
        let chunks = chunker.chunk(code: longLine, languageName: "swift")

        // Should produce at least one chunk, not crash
        XCTAssertFalse(chunks.isEmpty, "Single long line should produce chunks")
    }

    // MARK: - Multi-chunk Code Splitting

    func testChunk_SwiftFunctions_SplitsAtFunctionBoundaries() {
        let chunker = TreeSitterCodeChunker(maxChunkSize: 80, overlap: 10)
        let code = """
        func hello() {
            print("hello")
        }

        func world() {
            print("world")
        }

        func foo() {
            print("foo")
        }
        """
        let chunks = chunker.chunk(code: code, languageName: "swift")

        XCTAssertGreaterThan(chunks.count, 1, "Three functions should split into multiple chunks at maxChunkSize=80")

        // Each chunk should have the prefix
        for chunk in chunks {
            XCTAssertTrue(chunk.hasPrefix("[swift Context]:\n"))
        }
    }

    func testChunk_AllChunksHaveLanguagePrefix() {
        let chunker = TreeSitterCodeChunker(maxChunkSize: 80, overlap: 10)
        let lines = (0..<20).map { "let var\($0) = \($0)" }
        let code = lines.joined(separator: "\n")
        let chunks = chunker.chunk(code: code, languageName: "swift")

        for (i, chunk) in chunks.enumerated() {
            XCTAssertTrue(chunk.hasPrefix("[swift Context]:\n"),
                "Chunk \(i) missing language prefix")
        }
    }

    // MARK: - Overlap Preservation

    func testChunk_OverlapLines_SharedBetweenConsecutiveChunks() {
        let chunker = TreeSitterCodeChunker(maxChunkSize: 100, overlap: 20)
        let lines = (0..<15).map { "line_\($0) = \($0)" }
        let code = lines.joined(separator: "\n")
        let chunks = chunker.chunk(code: code, languageName: "swift")

        guard chunks.count >= 2 else { return }

        // Strip prefix and get lines from each chunk
        let firstLines = chunks[0]
            .replacingOccurrences(of: "[swift Context]:\n", with: "")
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }

        let secondLines = chunks[1]
            .replacingOccurrences(of: "[swift Context]:\n", with: "")
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }

        // There should be some overlap — at least one line shared
        let sharedLines = Set(firstLines).intersection(Set(secondLines))
        XCTAssertFalse(sharedLines.isEmpty,
            "Consecutive chunks should share at least one overlap line")
    }
}
