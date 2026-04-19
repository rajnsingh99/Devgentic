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
final class RAGIndexingService: @unchecked Sendable {

    // MARK: - Singleton
    static let shared = RAGIndexingService()
    
    // MARK: - Dependencies
    private let logger = DGLogger(category: "RAGIndexingService")
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

    // MARK: - Batch File Indexing (Awaitable)

    /// Index multiple attached files for RAG-based retrieval.
    /// Unlike `indexFileAttachment()`, this is awaitable — the contextualRAG pipeline
    /// needs indexing to complete before retrieval can return relevant chunks.
    func indexAttachedFiles(
        files: [FileSystemItem],
        conversationID: UUID,
        messageID: UUID
    ) async {
        let fileProcessor = FileProcessorService()

        for file in files {
            let registry = DocumentExtractionRegistry.shared
            let canExtract = registry.canExtract(from: file.url)
            let isText = fileProcessor.isTextFile(
                mimeType: fileProcessor.getFileMimeType(for: file.url),
                url: file.url
            )

            guard canExtract || isText else {
                logger.info("Skipping non-extractable file for RAG: \(file.name)")
                continue
            }

            guard let text = await fileProcessor.readFileContent(for: file.url) else {
                logger.warning("Failed to extract text from \(file.name) for RAG indexing")
                continue
            }

            let sanitizedText = OutputSanitizer.stripThinkBlocksAndTokens(text)
            guard !sanitizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            // Chunk the extracted text
            let blocks = [ContentBlock(id: "file-\(file.id)", type: .paragraph(sanitizedText))]
            let chunks = SemanticChunker(maxChunkSize: 512, overlap: 50).chunk(blocks: blocks)
            guard !chunks.isEmpty else { continue }

            // Generate embeddings for each chunk
            var childEntities: [ChildChunkEntity] = []
            for (index, chunkText) in chunks.enumerated() {
                guard !chunkText.isEmpty else { continue }
                if let embedding = await embeddingService.generateEmbedding(for: chunkText) {
                    childEntities.append(ChildChunkEntity(
                        chunkText: chunkText,
                        embedding: embedding,
                        chunkIndex: index
                    ))
                }
            }

            guard !childEntities.isEmpty else { continue }

            // Create parent document referencing the file
            let parentDoc = ParentDocumentEntity(
                sourceMessageID: messageID,
                conversationID: conversationID,
                fullTextContent: "[File: \(file.name)]\n\(sanitizedText)",
                timestamp: Date()
            )

            vectorStoreService.addSemanticDocument(parent: parentDoc, children: childEntities)
            logger.info("RAG-indexed attachment: \(file.name) → \(childEntities.count) chunks")
        }
    }

    // MARK: - Single File Attachment Indexing (Fire-and-Forget)

    /// Index attached file content for semantic retrieval.
    /// Called after successful document extraction to enable RAG search across uploaded documents.
    func indexFileAttachment(
        fileURL: URL,
        extractedText: String,
        conversationID: UUID,
        messageID: UUID
    ) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            let sanitizedText = OutputSanitizer.stripThinkBlocksAndTokens(extractedText)
            guard !sanitizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

            // Chunk the extracted file content using paragraph-based semantic chunking
            let blocks = [ContentBlock(id: "file-0", type: .paragraph(sanitizedText))]
            let chunks = SemanticChunker(maxChunkSize: 512, overlap: 50).chunk(blocks: blocks)

            guard !chunks.isEmpty else { return }

            // Generate embeddings for each chunk
            var childEntities: [ChildChunkEntity] = []
            for (index, chunkText) in chunks.enumerated() {
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

            guard !childEntities.isEmpty else { return }

            // Create parent document referencing the file
            let parentDoc = ParentDocumentEntity(
                sourceMessageID: messageID,
                conversationID: conversationID,
                fullTextContent: "[File: \(fileURL.lastPathComponent)]\n\(sanitizedText)",
                timestamp: Date()
            )

            vectorStoreService.addSemanticDocument(parent: parentDoc, children: childEntities)
            self.logger.info("Indexed file attachment: \(fileURL.lastPathComponent) (\(childEntities.count) chunks)")
        }
    }
}
