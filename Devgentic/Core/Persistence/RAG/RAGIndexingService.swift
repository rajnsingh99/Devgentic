//
//  RAGIndexingService.swift
//  Devgentic
//
//  Created by Raj Singh on 02/03/26.
//

import Foundation
import os

/// A background worker service responsible for asynchronously processing
/// chat messages and files into semantic vector embeddings for RAG.
class RAGIndexingService {
    
    // MARK: - Singleton
    static let shared = RAGIndexingService()
    
    // MARK: - Dependencies
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "RAGIndexingService")
    private let embeddingService = EmbeddingService.shared
    private let vectorStoreService = VectorStoreService.shared
    
    // MARK: - State
    // No longer needed as we use detached tasks per message.
    
    private init() {}
    
    // MARK: - Core Processing Logic
    
    /// Processes a single message for RAG vectorization.
    /// This should be called asynchronously as a fire-and-forget task when a message finishes streaming.
    func indexSingleMessage(_ message: ChatMessage) async {
        // Filter out noise: Do not index error messages
        if case .error = message.content {
            logger.debug("Skipping vectorization: message is an error.")
            return
        }
        
        // Extract the markdown blocks pre-parsed by the UI model
        let blocks = message.getBlocksForIndexing()
        
        let chunker = SemanticChunker(maxChunkSize: 512, overlap: 50)
        let chunks = chunker.chunk(blocks: blocks)
        
        guard !chunks.isEmpty else {
            logger.debug("Skipping vectorization: no text content found (e.g. pure image message).")
            return
        }
        
        // Strip think blocks from the full text to prevent internal model reasoning
        // from polluting the semantic index. Only user-facing content should be searchable.
        let rawFullText = message.content.textContent ?? chunks.joined(separator: "\n\n")
        let fullText = OutputSanitizer.stripThinkBlocksAndTokens(rawFullText)
        
        let parentDoc = ParentDocumentEntity(
            sourceMessageID: message.id,
            conversationID: message.conversationId,
            fullTextContent: fullText,
            timestamp: message.timestamp
        )
        
        var childEntities: [ChildChunkEntity] = []
        
        // Await EmbeddingService.generateEmbedding() for each chunk
        for (index, rawChunkText) in chunks.enumerated() {
            // Strip think blocks from individual chunks as well
            let chunkText = OutputSanitizer.stripThinkBlocksAndTokens(rawChunkText)
            guard !chunkText.isEmpty else { continue }
            if let embedding = await embeddingService.generateEmbedding(for: chunkText) {
                let child = ChildChunkEntity(
                    chunkText: chunkText,
                    embedding: embedding,
                    chunkIndex: index
                )
                childEntities.append(child)
            }
        }
        
        // Save the ParentDocumentEntity and its associated ChildChunkEntitys to ObjectBox
        if !childEntities.isEmpty {
            vectorStoreService.addSemanticDocument(parent: parentDoc, children: childEntities)
            logger.info("Successfully indexed message \(message.id.uuidString) into \(childEntities.count) semantic child chunks.")
        } else {
            logger.warning("Failed to generate any embeddings for message \(message.id.uuidString). Vector ingestion failed.")
        }
    }
}
