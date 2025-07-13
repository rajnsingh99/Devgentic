//
//  TextChunker.swift
//  Devgentic
//
//  Created by Raj Singh on 13/07/25.
//

import Foundation

/// A utility for splitting text into smaller chunks.
///
/// This is a crucial preprocessing step for RAG, as embedding models have a fixed input size,
/// and processing smaller, focused chunks often yields more relevant search results.
struct TextChunker {
    
    /// The desired maximum size of each text chunk, in characters.
    let chunkSize: Int
    
    /// The number of characters to overlap between consecutive chunks.
    /// This helps maintain context across chunk boundaries.
    let overlap: Int

    /// Initializes a new TextChunker.
    /// - Parameters:
    ///   - chunkSize: The target size for each chunk. Defaults to 512.
    ///   - overlap: The character overlap between chunks. Defaults to 50.
    init(chunkSize: Int = 512, overlap: Int = 50) {
        precondition(chunkSize > overlap, "Chunk size must be greater than overlap.")
        self.chunkSize = chunkSize
        self.overlap = overlap
    }

    /// Splits a given text into an array of smaller string chunks.
    /// - Parameter text: The text to be split.
    /// - Returns: An array of strings, where each string is a chunk of the original text.
    func chunk(text: String) -> [String] {
        // Return the full text if it's smaller than the chunk size.
        if text.count <= chunkSize {
            return [text]
        }
        
        var chunks: [String] = []
        var currentIndex = text.startIndex
        
        while currentIndex < text.endIndex {
            // Determine the end index for the current chunk.
            let endIndex = text.index(currentIndex, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            
            // Create the chunk.
            let chunk = String(text[currentIndex..<endIndex])
            chunks.append(chunk)
            
            // Advance the current index for the next chunk, accounting for overlap.
            let advanceBy = chunkSize - overlap
            guard let nextIndex = text.index(currentIndex, offsetBy: advanceBy, limitedBy: text.endIndex) else {
                break
            }
            
            // If the next starting position is the same as the current one (can happen with very small advanceBy),
            // break the loop to prevent infinite loops.
            if nextIndex == currentIndex {
                break
            }
            
            currentIndex = nextIndex
        }
        
        return chunks
    }
}
