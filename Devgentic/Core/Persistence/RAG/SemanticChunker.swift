// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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

            case .horizontalRule, .image:
                break // Not useful for embedding
            }
        }

        return allChunks
    }
    
    // MARK: - Semantic Text Chunking
    
    /// Splits standard markdown text by paragraph boundaries, grouping them until the limit.
    private func chunkText(_ text: String) -> [String] {
        // Split by markdown paragraph boundaries (double newline)
        let paragraphs = text.components(separatedBy: "\n\n")
        var chunks: [String] = []
        var currentChunk = ""
        
        for paragraph in paragraphs {
            let cleanedParagraph = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanedParagraph.isEmpty { continue }
            
            let separator = currentChunk.isEmpty ? "" : "\n\n"
            
            // If adding this paragraph keeps us under the limit, append it
            if currentChunk.count + separator.count + cleanedParagraph.count <= maxChunkSize {
                currentChunk += separator + cleanedParagraph
            } else {
                // The current chunk is full. Save it.
                if !currentChunk.isEmpty {
                    chunks.append(currentChunk)
                    
                    // Start a new chunk using overlap from the previous chunk
                    let overlapText = getOverlapText(from: currentChunk, overlapSize: overlap)
                    currentChunk = overlapText + (overlapText.isEmpty ? "" : "\n\n") + cleanedParagraph
                } else {
                    // Edge case: A single paragraph is larger than maxChunkSize
                    let splitParagraphs = splitLargeText(cleanedParagraph, maxSize: maxChunkSize, overlap: overlap)
                    if let last = splitParagraphs.last {
                        chunks.append(contentsOf: splitParagraphs.dropLast())
                        currentChunk = last // Keep the last segment as the start of the next iteration
                    }
                }
            }
        }
        
        // Don't forget the final chunk
        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }
        
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
    
    /// Emergency fallback to split a single massive paragraph that exceeds maxChunkSize.
    private func splitLargeText(_ text: String, maxSize: Int, overlap: Int) -> [String] {
        var chunks: [String] = []
        var currentIndex = text.startIndex
        
        while currentIndex < text.endIndex {
            let remaining = text.distance(from: currentIndex, to: text.endIndex)
            if remaining <= maxSize {
                chunks.append(String(text[currentIndex..<text.endIndex]))
                break
            }
            
            let endIndex = text.index(currentIndex, offsetBy: maxSize, limitedBy: text.endIndex) ?? text.endIndex
            var snapIndex = endIndex
            
            // Try to snap to the last space to avoid cutting words in half
            let substring = text[currentIndex..<endIndex]
            if let lastSpace = substring.lastIndex(of: " ") {
                // Ensure we don't shrink the chunk too much (keep it at least 50% of maxSize)
                if text.distance(from: currentIndex, to: lastSpace) > maxSize / 2 {
                    snapIndex = lastSpace
                }
            }
            
            chunks.append(String(text[currentIndex..<snapIndex]))
            
            // Advance index, taking overlap into account
            let advanceBy = text.distance(from: currentIndex, to: snapIndex) - overlap
            if advanceBy <= 0 { break } // Failsafe
            
            currentIndex = text.index(currentIndex, offsetBy: advanceBy, limitedBy: text.endIndex) ?? text.endIndex
        }
        return chunks
    }
}
