// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SemanticChunker.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// A utility for splitting parsed markdown and code blocks into semantically meaningful chunks.
/// Respects paragraph boundaries and markdown headers, and never splits individual lines of code.
struct SemanticChunker {
    
    /// The desired maximum size of each text chunk, in characters.
    let maxChunkSize: Int
    
    /// The number of characters to overlap between consecutive chunks.
    let overlap: Int

    /// Target chunk size for code blocks only (`.code` via `TreeSitterCodeChunker`). Code is symbol-dense and the embedder
    /// truncates at ~128 tokens, so code uses a smaller target (~384) than prose (512). Nil means code uses `maxChunkSize`.
    let codeChunkSize: Int?

    /// Creates a chunker.
    /// - Parameters: maxChunkSize is the target size per chunk (default 512); overlap is the character overlap (default 50).
    /// codeChunkSize is an optional smaller target for code blocks.
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
                // `plainText` recursively flattens the item's child blocks; nested list items arrive as their own blocks,
                // so each stays an independent chunk.
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
                // Indexed as the markdown the author wrote, so a query can match an image by its alt text and path.
                let imageText = "![\(altText ?? "")](\(url))"
                if !(altText ?? "").isEmpty || !url.isEmpty {
                    allChunks.append(contentsOf: chunkText(imageText))
                }
            }
        }

        return allChunks
    }
    
    // MARK: - Semantic Text Chunking
    
    /// Splits markdown text at paragraph boundaries, grouping paragraphs until the limit.
    /// No chunk exceeds `maxChunkSize`: the embedder reads ~128 tokens (~500 chars), so the excess is invisible to search.
    /// Oversized paragraphs split at line breaks first; only a single over-long line falls back to word-snapped windows.
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
    
    // Why: keep it linear: measuring `distance(from:to:)` per window is quadratic, and every oversized upload line passes here.
    /// Splits one over-long run of text into windows of at most `maxSize`,
    /// snapped back to a space when that keeps at least half a window.
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

            // Advance, taking overlap into account; when the overlap would not move forward (a small window),
            // advance past the window instead of dropping the rest of the text.
            let advanceBy = text.distance(from: currentIndex, to: snapIndex) - overlap
            currentIndex = advanceBy > 0 ? text.index(currentIndex, offsetBy: advanceBy) : snapIndex
        }
        return chunks
    }
}
