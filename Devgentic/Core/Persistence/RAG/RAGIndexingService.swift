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
/// By offloading this from the Main Thread, we prevent UI locking during chat streams.
class RAGIndexingService {
    
    // MARK: - Singleton
    static let shared = RAGIndexingService()
    
    // MARK: - Dependencies
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "RAGIndexingService")
    private let persistenceService = CoreDataPersistenceService.shared
    private let embeddingService = EmbeddingService.shared
    private let vectorStoreService = VectorStoreService.shared
    
    // MARK: - State
    private var isIndexing = false
    private var indexingTask: Task<Void, Never>?
    
    private init() {}
    
    // MARK: - Public API
    
    /// Starts the background ingestion loop. Safe to call multiple times.
    func start() {
        guard indexingTask == nil else { return }
        logger.info("Starting background RAG Indexing Service...")
        
        indexingTask = Task.detached(priority: .background) { [weak self] in
            while !Task.isCancelled {
                await self?.processUnindexedMessages()
                // Poll every 10 seconds. Adjust based on performance needs.
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }
    
    /// Stops the background ingestion loop.
    func stop() {
        indexingTask?.cancel()
        indexingTask = nil
        logger.info("Stopped background RAG Indexing Service.")
    }
    
    // MARK: - Core Processing Logic
    
    private func processUnindexedMessages() async {
        // Prevent concurrent execution overlaps
        guard !isIndexing else { return }
        isIndexing = true
        defer { isIndexing = false }
        
        // Fetch a batch of unindexed messages to process
        let unindexedMessages = await persistenceService.fetchUnindexedMessages(limit: 10)
        
        guard !unindexedMessages.isEmpty else { return }
        logger.debug("Found \(unindexedMessages.count) unindexed messages. Starting batch ingestion.")
        
        let chunker = SemanticChunker(maxChunkSize: 512, overlap: 50)
        
        for message in unindexedMessages {
            // Filter out noise: Do not index error messages
            if case .error = message.content {
                await markAsIndexed(message.id)
                continue
            }
            
            // Extract the markdown blocks pre-parsed by the UI model
            let blocks = message.getBlocksForIndexing()
            
            // Pass blocks to SemanticChunker
            let chunks = chunker.chunk(blocks: blocks)
            
            guard !chunks.isEmpty else {
                // Nothing to index (e.g., pure image message, or empty text)
                await markAsIndexed(message.id)
                continue
            }
            
            // Reconstruct full text for the parent document
            let fullText = message.content.textContent ?? chunks.joined(separator: "\n\n")
            
            let parentDoc = ParentDocumentEntity(
                sourceMessageID: message.id,
                conversationID: message.conversationId,
                fullTextContent: fullText,
                timestamp: message.timestamp
            )
            
            var childEntities: [ChildChunkEntity] = []
            
            // Await EmbeddingService.generateEmbedding() for each chunk
            for (index, chunkText) in chunks.enumerated() {
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
                logger.info("Successfully indexed message \(message.id.uuidString) into \(childEntities.count) child chunks.")
            } else {
                logger.warning("Failed to generate any embeddings for message \(message.id.uuidString). Vector ingestion skipped.")
            }
            
            // Update the Core Data ChatMessage to set isIndexedForRAG = true
            await markAsIndexed(message.id)
        }
    }
    
    private func markAsIndexed(_ id: UUID) async {
        await persistenceService.markMessageAsIndexed(id: id)
    }
}
