// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SemanticChunker.swift
//  Devgentic
//
//  Created by Raj Singh on 02/03/26.
//

import Foundation

/// A utility for splitting parsed markdown and code blocks into semantically meaningful chunks.
///
/// This replaces the naive 512-character sliding window approach. It respects paragraph boundaries,
/// markdown headers, and prevents splitting individual lines of code, significantly improving
/// RAG retrieval quality and reducing context tearing.
struct SemanticChunker {
    
    /// The desired maximum size of each text chunk, in characters.
    let maxChunkSize: Int
    
    /// The number of characters to overlap between consecutive chunks.
    let overlap: Int

    /// Override for CODE blocks only (`.code` → TreeSitterCodeChunker). Code is
    /// symbol-dense — WordPiece burns ~3 chars/token and the MiniLM embedder
    /// head-truncates at ~128 tokens — so code chunks need a smaller target
    /// (~384) than prose (512) to stay fully visible to semantic search.
    /// Nil = code uses `maxChunkSize` (legacy behavior).
    let codeChunkSize: Int?

    /// Initializes a new SemanticChunker.
    /// - Parameters:
    ///   - maxChunkSize: The target size for each chunk. Defaults to 512.
    ///   - overlap: The character overlap between chunks. Defaults to 50.
    ///   - codeChunkSize: Optional smaller target for code blocks.
    init(maxChunkSize: Int = 512, overlap: Int = 50, codeChunkSize: Int? = nil) {
        precondition(maxChunkSize > overlap, "Chunk size must be greater than overlap.")
        self.maxChunkSize = maxChunkSize
        self.overlap = overlap
        self.codeChunkSize = codeChunkSize
    }

    /// Splits an array of ContentBlocks into vector-ready strings.
    /// - Parameter blocks: An array of ContentBlock objects (parsed markdown).
    /// - Returns: An array of semantically chunked strings ready for embedding.
    func chunk(blocks: [ContentBlock]) -> [String] {
        var allChunks: [String] = []

        for block in blocks {
            switch block.type {
            case .code(let language, let content, _):
                if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    allChunks.append(contentsOf: chunkCode(content, language: language))
                }

            case .paragraph(let text):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    allChunks.append(contentsOf: chunkText(text))
                }

            case .heading(_, let text):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    allChunks.append(contentsOf: chunkText(text))
                }

            case .listItem:
                // `plainText` recursively flattens the item's child blocks (prefix +
                // checkbox marker + content). Nested list items arrive as their own
                // blocks, so each stays an independent chunk.
                let listText = block.plainText
                if !listText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    allChunks.append(contentsOf: chunkText(listText))
                }

            case .blockquote:
                let quoteText = block.plainText
                if !quoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    allChunks.append(contentsOf: chunkText(quoteText))
                }

            case .table(let headers, let rows, _):
                let headerText = headers.joined(separator: " | ")
                let rowsText = rows.map { $0.joined(separator: " | ") }.joined(separator: "\n")
                let tableText = headerText + "\n" + rowsText
                if !tableText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    allChunks.append(contentsOf: chunkText(tableText))
                }

            case .horizontalRule:
                break // Not useful for embedding

            case .image(let url, let altText):
                // [mc-3] Indexed as the markdown the author wrote. Before the parser split
                // image-bearing paragraphs, an INLINE image's `![alt](path)` sat inside the
                // paragraph text and was embedded with it — "where did you save the histogram?"
                // retrieved on the alt text and the path. Once the image became its own block it
                // fell into the old `break` here and both vanished from the index. A standalone
                // image was never indexed; it now is, for the same reason.
                let imageText = "![\(altText ?? "")](\(url))"
                if !(altText ?? "").isEmpty || !url.isEmpty {
                    allChunks.append(contentsOf: chunkText(imageText))
                }
            }
        }

        return allChunks
    }
    
    // MARK: - Semantic Text Chunking
    
    /// Splits standard markdown text by paragraph boundaries, grouping them until the limit.
    ///
    /// ⚠️ INVARIANT: no chunk exceeds `maxChunkSize`. The embedder reads ~128 tokens (~500 chars),
    /// so anything past the cap is invisible to semantic search.
    ///
    /// The old packer appended an oversized paragraph WHOLE whenever a chunk was already open —
    /// `splitLargeText` only ran for the very first paragraph. Uploads arrive as one `.paragraph`
    /// with PDF pages joined by "\n\n", so every page after the first became one 2–4K-char chunk
    /// whose text past ~500 chars no embedding ever saw (RAG-3). It also re-seeded the 50-char
    /// overlap without re-checking the cap.
    ///
    /// Oversized paragraphs now split at LINE breaks first (a PDF page keeps its line structure),
    /// and only a single over-long line falls back to word-snapped windows.
    private func chunkText(_ text: String) -> [String] {
        pack(text.components(separatedBy: "\n\n"), joiner: "\n\n") { paragraph in
            pack(paragraph.components(separatedBy: "\n"), joiner: "\n") { line in
                splitLargeText(line, maxSize: maxChunkSize, overlap: overlap)
            }
        }
    }

    /// Greedily packs `pieces` into chunks of at most `maxChunkSize`, joined by `joiner`, carrying
    /// a word-snapped overlap into the next chunk when it fits. A piece larger than a chunk is
    /// handed to `splitOversized`, which must return pieces of at most `maxChunkSize`.
    private func pack(_ pieces: [String], joiner: String, splitOversized: (String) -> [String]) -> [String] {
        var chunks: [String] = []
        var current = ""
        for raw in pieces {
            let piece = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if piece.isEmpty { continue }

            if piece.count > maxChunkSize {
                if !current.isEmpty { chunks.append(current) }
                let parts = splitOversized(piece)
                chunks.append(contentsOf: parts.dropLast())
                current = parts.last ?? ""
                continue
            }
            if current.isEmpty {
                current = piece
            } else if current.count + joiner.count + piece.count <= maxChunkSize {
                current += joiner + piece
            } else {
                chunks.append(current)
                // The overlap SHRINKS to the room left beside `piece` rather than pushing the chunk
                // past the cap (or being dropped): context survives and so does the invariant.
                let room = min(overlap, maxChunkSize - joiner.count - piece.count)
                let overlapText = room > 0 ? getOverlapText(from: current, overlapSize: room) : ""
                current = overlapText.isEmpty ? piece : overlapText + joiner + piece
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
    
    // MARK: - Code Block Chunking
    
    /// Splits code blocks by line breaks, never severing a single line.
    /// Prepends the language context to every chunk to aid the embedding model.
    private func chunkCode(_ code: String, language: String?) -> [String] {
        // [RAG UPGRADE] Offload to the Tree-Sitter aware chunker!
        // This parses the AST to ensure we split at syntactically safe boundaries.
        let treeSitterChunker = TreeSitterCodeChunker(maxChunkSize: codeChunkSize ?? maxChunkSize, overlap: overlap)
        return treeSitterChunker.chunk(code: code, languageName: language ?? "")
    }
    
    // MARK: - Utility Methods

    /// Helper to extract overlap text snapping to a word boundary (space) if possible.
    private func getOverlapText(from text: String, overlapSize: Int) -> String {
        guard text.count > overlapSize else { return text }
        let startIndex = text.index(text.endIndex, offsetBy: -overlapSize)
        let overlapCandidate = String(text[startIndex...])
        
        // Try to snap to the first space in the overlap to avoid splitting words
        if let firstSpace = overlapCandidate.firstIndex(of: " ") {
            return String(overlapCandidate[firstSpace...]).trimmingCharacters(in: .whitespaces)
        }
        return overlapCandidate
    }
    
    /// Splits one over-long run of text (no paragraph or line break left to use) into windows of at
    /// most `maxSize`, snapped back to a space when that keeps at least half a window.
    ///
    /// ⚠️ Linear. The old loop measured `distance(from: currentIndex, to: endIndex)` on every window —
    /// O(remaining) each time, quadratic overall (a 500K-char run cost ~10⁸ steps, RAG-35) — and this
    /// path is now hot: every oversized line of every upload goes through it.
    private func splitLargeText(_ text: String, maxSize: Int, overlap: Int) -> [String] {
        var chunks: [String] = []
        var currentIndex = text.startIndex
        while currentIndex < text.endIndex {
            // `limitedBy` caps the walk at maxSize characters — never a scan of the remainder.
            guard let windowEnd = text.index(currentIndex, offsetBy: maxSize, limitedBy: text.endIndex),
                  windowEnd < text.endIndex else {
                chunks.append(String(text[currentIndex...]))
                break
            }
            var snapIndex = windowEnd
            // Try to snap to the last space to avoid cutting words in half
            if let lastSpace = text[currentIndex..<windowEnd].lastIndex(of: " "),
               text.distance(from: currentIndex, to: lastSpace) > maxSize / 2 {
                snapIndex = lastSpace
            }
            chunks.append(String(text[currentIndex..<snapIndex]))

            // Advance, taking overlap into account. When the overlap would not move forward (a small
            // window), advance past the window instead — the old `break` here DROPPED the rest of the
            // text without a trace.
            let advanceBy = text.distance(from: currentIndex, to: snapIndex) - overlap
            currentIndex = advanceBy > 0 ? text.index(currentIndex, offsetBy: advanceBy) : snapIndex
        }
        return chunks
    }
}
