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

    /// Initializes a new SemanticChunker.
    /// - Parameters:
    ///   - maxChunkSize: The target size for each chunk. Defaults to 512.
    ///   - overlap: The character overlap between chunks. Defaults to 50.
    init(maxChunkSize: Int = 512, overlap: Int = 50) {
        precondition(maxChunkSize > overlap, "Chunk size must be greater than overlap.")
        self.maxChunkSize = maxChunkSize
        self.overlap = overlap
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

            case .listItem(let prefix, let text, _):
                let listText = "\(prefix) \(text)"
                if !listText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    allChunks.append(contentsOf: chunkText(listText))
                }

            case .table(let headers, let rows):
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
    private func chunkCode(_ code: String, language: String) -> [String] {
        let lines = code.components(separatedBy: .newlines)
        var chunks: [String] = []
        var currentChunkLines: [String] = []
        var currentSize = 0
        
        let langName = language.isEmpty ? "Code" : language
        let prefix = "[\(langName) Context]:\n"
        let prefixSize = prefix.count
        
        for line in lines {
            let lineSize = line.count + 1 // +1 for the newline character
            
            // If adding this line exceeds the chunk size (and we already have lines)
            if prefixSize + currentSize + lineSize > maxChunkSize && !currentChunkLines.isEmpty {
                // Save the current code chunk
                chunks.append(prefix + currentChunkLines.joined(separator: "\n"))
                
                // Overlap: retain the last 2 lines of code to maintain structural context across chunks
                let overlapLines = Array(currentChunkLines.suffix(2))
                currentChunkLines = overlapLines
                currentSize = overlapLines.reduce(0) { $0 + $1.count + 1 }
            }
            
            currentChunkLines.append(line)
            currentSize += lineSize
        }
        
        // Save any remaining lines
        if !currentChunkLines.isEmpty {
            chunks.append(prefix + currentChunkLines.joined(separator: "\n"))
        }
        
        return chunks
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
