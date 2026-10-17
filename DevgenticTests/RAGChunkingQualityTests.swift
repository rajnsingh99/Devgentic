// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RAGChunkingQualityTests.swift
//  devgenticTests
//
//  Batch 4 of the RAG readiness register:
//    RAG-3  — no prose chunk exceeds the cap; a PDF page after the first is no longer one chunk.
//    RAG-23 — a code line longer than a chunk is cut, not embedded whole; `<think>` never indexed.
//    RAG-35 — the splitter never drops text (its old failsafe `break` did).
//    RAG-36 — CRLF is one line break, so code chunks carry no phantom blank lines.
//
//  The embedder reads ~128 tokens (~500 chars); text past the cap is invisible to semantic search,
//  so "no chunk exceeds the cap" IS the retrieval-quality invariant.
//

import XCTest
@testable import devgentic

final class RAGChunkingQualityTests: XCTestCase {

    private func words(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: { $0.isWhitespace }).map(String.init))
    }

    private func proseChunks(_ text: String, max: Int = 512, overlap: Int = 50) -> [String] {
        SemanticChunker(maxChunkSize: max, overlap: overlap)
            .chunk(blocks: [ContentBlock(id: "upload", type: .paragraph(text))])
    }

    // MARK: - RAG-3: prose

    /// ⚠️⚠️ The PDF shape: pages joined by "\n\n", lines by "\n" — what `PDFExtractor` produces and
    /// `uploadContentBlocks` hands over as ONE paragraph block. Page 2 onward used to be one chunk
    /// per page (~3K chars), ~80% of it never embedded.
    func testEveryPageOfAPDFIsChunkedWithinTheCap() {
        let line = "Quarterly revenue grew in every region while operating costs held steady overall."
        let page = { (n: Int) in (0..<38).map { "\(line) [page \(n) line \($0)]" }.joined(separator: "\n") }
        let pdf = (1...4).map(page).joined(separator: "\n\n")

        let chunks = proseChunks(pdf)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 512 },
                      "a chunk exceeds the cap — largest is \(chunks.map(\.count).max() ?? 0) chars")
        XCTAssertGreaterThan(chunks.count, 4 * 6, "pages were not split — got \(chunks.count) chunks for 4 × ~4K-char pages")
        XCTAssertTrue(words(pdf).isSubset(of: chunks.reduce(into: Set<String>()) { $0.formUnion(words($1)) }),
                      "text was lost while chunking")
    }

    /// Property: for any mix of paragraph sizes, line structure and long unbroken lines, every chunk
    /// is within the cap and every word survives — including small configs, where the old splitter's
    /// failsafe `break` silently dropped the rest of a paragraph.
    func testNoChunkExceedsTheCapAndNoWordIsLost() {
        var rng = SystemRandomNumberGenerator()
        let vocabulary = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa",
                          "lambda", "mu", "omicron", "sigma", "upsilon", "omega"]
        for (max, overlap) in [(512, 50), (384, 50), (120, 40), (60, 50)] {
            for round in 0..<60 {
                var counter = 0
                func word() -> String { counter += 1; return vocabulary.randomElement(using: &rng)! + "\(counter)" }
                func lineText(_ words: Int) -> String { (0..<words).map { _ in word() }.joined(separator: " ") }
                let paragraphs = (0..<Int.random(in: 1...6, using: &rng)).map { _ -> String in
                    switch Int.random(in: 0...3, using: &rng) {
                    case 0: return lineText(Int.random(in: 1...8, using: &rng))                       // short
                    case 1: return lineText(Int.random(in: 60...400, using: &rng))                    // one long line
                    default: return (0..<Int.random(in: 2...30, using: &rng))                         // many lines
                        .map { _ in lineText(Int.random(in: 3...15, using: &rng)) }.joined(separator: "\n")
                    }
                }
                let text = paragraphs.joined(separator: "\n\n")
                let chunks = proseChunks(text, max: max, overlap: overlap)
                let oversized = chunks.filter { $0.count > max }
                XCTAssertTrue(oversized.isEmpty, "(\(max)/\(overlap)) round \(round): \(oversized.count) chunk(s) over the cap, largest \(oversized.map(\.count).max() ?? 0)")
                let lost = words(text).subtracting(chunks.reduce(into: Set<String>()) { $0.formUnion(words($1)) })
                XCTAssertTrue(lost.isEmpty, "(\(max)/\(overlap)) round \(round): \(lost.count) word(s) lost, e.g. \(lost.prefix(3))")
            }
        }
    }

    /// Text with no spaces at all (CJK prose, a base64 blob) is cut at the cap and fully kept.
    func testAnUnbrokenRunIsCutAtTheCapAndFullyKept() {
        let run = String(repeating: "知識検索の品質", count: 300) // 2,100 chars, no spaces
        let chunks = proseChunks(run, max: 512, overlap: 50)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 512 })
        XCTAssertGreaterThanOrEqual(chunks.reduce(0) { $0 + $1.count }, run.count, "characters were dropped")
        XCTAssertEqual(chunks.first.map { String($0.prefix(7)) }, "知識検索の品質")
        XCTAssertTrue(chunks.last.map { run.hasSuffix($0) } ?? false, "the tail of the run is missing")
    }

    // MARK: - RAG-23: code

    /// ⚠️⚠️ Minified JS / one-line JSON: one line far longer than a chunk. It used to become ONE chunk
    /// of the whole line. Now it is cut into windows that reassemble to the original exactly.
    func testAMinifiedLineIsCutIntoWindowsThatReassembleExactly() {
        let minified = (0..<400).map { "var a\($0)=function(b){return b*\($0)};" }.joined()
        for language in ["javascript", "unknownlang"] { // AST path and fallback path
            let chunks = TreeSitterCodeChunker(maxChunkSize: 384, overlap: 50).chunk(code: minified, languageName: language)
            XCTAssertTrue(chunks.allSatisfy { $0.count <= 384 },
                          "\(language): a chunk exceeds the cap — largest \(chunks.map(\.count).max() ?? 0)")
            let prefix = "[\(language) Context]:\n"
            XCTAssertEqual(chunks.map { String($0.dropFirst(prefix.count)) }.joined(), minified,
                           "\(language): the windows do not reassemble to the line")
        }
    }

    /// Long-but-fitting lines: the 2-line overlap used to be carried even when it left no room, so a
    /// long line was emitted twice and chunks ran over the cap.
    func testLongLinesNeverOverflowOrRepeat() {
        let code = (0..<40).map { "let value\($0) = \"" + String(repeating: "x", count: 150) + "\"" }.joined(separator: "\n")
        for language in ["swift", "unknownlang"] {
            let chunks = TreeSitterCodeChunker(maxChunkSize: 384, overlap: 50).chunk(code: code, languageName: language)
            XCTAssertTrue(chunks.allSatisfy { $0.count <= 384 }, "\(language): over the cap — largest \(chunks.map(\.count).max() ?? 0)")
            XCTAssertEqual(Set(chunks).count, chunks.count, "\(language): a chunk was emitted twice")
            for n in 0..<40 {
                XCTAssertTrue(chunks.contains { $0.contains("let value\(n) =") }, "\(language): line \(n) was lost")
            }
        }
    }

    /// RAG-36: `\r\n` is one break. Split as two, every CRLF file gained a blank line per line and its
    /// line indices drifted from the AST rows the split points are looked up by.
    func testCRLFIsOneLineBreak() {
        let chunks = TreeSitterCodeChunker(maxChunkSize: 384, overlap: 50)
            .chunk(code: "let a = 1\r\nlet b = 2\r\nlet c = 3", languageName: "unknownlang")
        XCTAssertEqual(chunks, ["[unknownlang Context]:\nlet a = 1\nlet b = 2\nlet c = 3"])
    }

    // MARK: - RAG-23: reasoning never reaches the index

    /// ⚠️⚠️ A multi-paragraph `<think>`: stripped per chunk (after splitting into blocks), its middle
    /// paragraphs carried no tag and were indexed as if they were the answer.
    func testAMultiParagraphThinkBlockIsNeverIndexed() {
        let message = ChatMessage(id: UUID(), conversationId: UUID(), timestamp: Date(), sender: .agent,
                                  content: .markdownText("""
            <think>
            First I will consider option one.

            The SECRET-REASONING middle paragraph weighs the trade-offs.

            Finally I settle on the answer.
            </think>

            The answer is forty-two.
            """))
        let chunks = SemanticChunker(maxChunkSize: 512, overlap: 50, codeChunkSize: 384)
            .chunk(blocks: message.getBlocksForIndexing())
        XCTAssertFalse(chunks.contains { $0.contains("SECRET-REASONING") || $0.contains("option one") },
                       "reasoning reached the index: \(chunks)")
        XCTAssertTrue(chunks.contains { $0.contains("forty-two") }, "the answer itself was lost: \(chunks)")
    }
}
