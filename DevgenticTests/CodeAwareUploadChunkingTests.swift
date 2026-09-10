// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  CodeAwareUploadChunkingTests.swift
//  devgenticTests
//
//  Created on 11/07/26.
//
//  Covers chunker routing + calibration: source files (and fenced code blocks
//  inside chat messages) go to the Tree-Sitter AST chunker at the 384-char code
//  target, prose stays on the 512-char paragraph path — one sizing mechanism
//  (SemanticChunker.codeChunkSize) shared by the upload and message paths.
//

import XCTest
@testable import devgentic

final class CodeAwareUploadChunkingTests: XCTestCase {

    /// The production chunker configuration both indexing paths use.
    private var calibratedChunker: SemanticChunker {
        SemanticChunker(
            maxChunkSize: RAGIndexingService.proseChunkSize,
            overlap: 50,
            codeChunkSize: RAGIndexingService.codeChunkSize
        )
    }

    // MARK: - Routing

    func testSwiftFile_RoutesToCodeBlock() {
        let blocks = RAGIndexingService.uploadContentBlocks(
            for: URL(fileURLWithPath: "/tmp/ChatInputAreaView.swift"),
            id: "file-1",
            text: "func hello() {}"
        )
        guard case .code(let language, let content, let fileName) = blocks.first?.type else {
            return XCTFail("swift upload must produce a .code block")
        }
        XCTAssertEqual(language.lowercased(), "swift")
        XCTAssertEqual(content, "func hello() {}")
        XCTAssertEqual(fileName, "ChatInputAreaView.swift")
    }

    func testPlainTextAndMarkdown_StayOnProsePath() {
        for path in ["/tmp/notes.txt", "/tmp/README.md", "/tmp/unknown.xyz123"] {
            let blocks = RAGIndexingService.uploadContentBlocks(
                for: URL(fileURLWithPath: path),
                id: "file-1",
                text: "Some prose.\n\nAnother paragraph."
            )
            guard case .paragraph = blocks.first?.type else {
                return XCTFail("\(path) must stay a .paragraph block")
            }
        }
    }

    // MARK: - End-to-end AST chunking

    func testSwiftSource_ChunksCarryLanguagePrefix_AndKeepSymbolsIntact() {
        let source = """
        import Foundation

        struct AttachmentManager {
            private var files: [String] = []

            func addAttachedFiles(fileItems: [String]) {
                for item in fileItems {
                    files.append(item)
                }
            }

            func removeAttachedFile(named name: String) {
                files.removeAll { $0 == name }
            }

            func clearAllAttachments() {
                files.removeAll()
            }
        }
        """

        let blocks = RAGIndexingService.uploadContentBlocks(
            for: URL(fileURLWithPath: "/tmp/AttachmentManager.swift"),
            id: "file-1",
            text: source
        )
        let chunks = calibratedChunker.chunk(blocks: blocks)

        XCTAssertFalse(chunks.isEmpty)
        XCTAssertTrue(chunks.allSatisfy { $0.hasPrefix("[swift Context]:") },
                      "every code chunk must carry the language prefix for the embedder")
        // The declaration names must survive chunking intact (the lexical boost
        // and centered windows both depend on symbol text being present verbatim).
        let joined = chunks.joined(separator: "\n")
        XCTAssertTrue(joined.contains("addAttachedFiles"))
        XCTAssertTrue(joined.contains("removeAttachedFile"))
        XCTAssertTrue(joined.contains("clearAllAttachments"))
    }

    func testLargeSwiftSource_ProducesMultipleBoundedChunks() {
        // ~40 small functions → well past one 384-char chunk.
        let functions = (0..<40).map { i in
            "    func generatedFunction\(i)() {\n        print(\"value \\(\(i))\")\n    }"
        }.joined(separator: "\n\n")
        let source = "struct Generated {\n\(functions)\n}"

        let blocks = RAGIndexingService.uploadContentBlocks(
            for: URL(fileURLWithPath: "/tmp/Generated.swift"),
            id: "file-1",
            text: source
        )
        let chunks = calibratedChunker.chunk(blocks: blocks)

        XCTAssertGreaterThan(chunks.count, 3, "a multi-KB source must split into several chunks")
        // Chunk size ≈ 128-token embedding budget: allow slack for the prefix +
        // a single long line, but nothing should balloon to prose-chunk scale.
        XCTAssertTrue(chunks.allSatisfy { $0.count <= RAGIndexingService.codeChunkSize + 160 },
                      "code chunks must stay near the embedder-visible budget")
    }

    // MARK: - Message-side calibration (mixed prose + fenced code)

    func testMixedMessageBlocks_CodeCalibratedSmaller_ProseStaysLarger() {
        // A chat message shape: explanation paragraph + a fenced code block —
        // the same SemanticChunker instance must size them differently.
        let prose = (0..<40).map { "Sentence number \($0) explaining the approach in plain words." }
            .joined(separator: " ")
        let codeLines = (0..<30).map { "    let generatedValue\($0) = compute(index: \($0))" }
            .joined(separator: "\n")
        let code = "func generatedExample() {\n\(codeLines)\n}"

        let blocks = [
            ContentBlock(id: "p", type: .paragraph(prose)),
            ContentBlock(id: "c", type: .code(language: "swift", content: code, fileName: nil))
        ]
        let chunks = calibratedChunker.chunk(blocks: blocks)

        let codeChunks = chunks.filter { $0.hasPrefix("[swift Context]:") }
        let proseChunks = chunks.filter { !$0.hasPrefix("[swift Context]:") }

        XCTAssertFalse(codeChunks.isEmpty, "fenced code must route through the AST chunker")
        XCTAssertFalse(proseChunks.isEmpty)
        XCTAssertTrue(codeChunks.allSatisfy { $0.count <= RAGIndexingService.codeChunkSize + 160 },
                      "message code blocks must respect the 384-char code target")
        XCTAssertTrue(proseChunks.contains { $0.count > RAGIndexingService.codeChunkSize },
                      "prose keeps the larger 512 target — calibration must not shrink it")
        XCTAssertTrue(proseChunks.allSatisfy { $0.count <= RAGIndexingService.proseChunkSize + 60 })
    }
}
