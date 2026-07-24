//
//  RAGIndexingService.swift
//  Devgentic
//
//  Created by Raj Singh on 02/03/26.
//

import Foundation
import os
import CodeEditLanguages

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

        // Synthetic stopped-run placeholders (cancelled/empty runs) carry no
        // retrievable fact — indexing them polluted conversation memory (a cancelled
        // run's "*Operation was stopped…*" was embedded and stored, observed
        // on-device 2026-07-19). Exact-match gate: a message that merely quotes the
        // phrase is real content and still indexes.
        if let text = message.content.textContent, ChatMessage.isSyntheticPlaceholder(text) {
            logger.debug("[RAG] Skipping vectorization for message \(message.id.uuidString.prefix(8)): synthetic stopped-run placeholder, nothing retrievable.")
            return
        }
        
        // Extract the markdown blocks pre-parsed by the UI model
        let blocks = message.getBlocksForIndexing()

        // Calibrated per block kind: prose at 512, fenced code blocks at 384 so
        // their embeddings stay fully inside the ~128-token embedder window.
        let chunker = SemanticChunker(maxChunkSize: Self.proseChunkSize, overlap: 50, codeChunkSize: Self.codeChunkSize)
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
            timestamp: message.timestamp,
            sourceIdentifier: message.id.uuidString
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
                    chunkIndex: index,
                    conversationID: message.conversationId.uuidString
                )
                childEntities.append(child)
            }
        }

        // Save the ParentDocumentEntity and its associated ChildChunkEntitys to ObjectBox
        if !childEntities.isEmpty {
            // Replace-on-reindex: a re-finalized message (e.g. a resumed run) replaces
            // its prior vectors instead of appending a duplicate copy.
            vectorStoreService.removeDocuments(sourceIdentifier: message.id.uuidString, conversationID: message.conversationId)
            vectorStoreService.addSemanticDocument(parent: parentDoc, children: childEntities)
            logger.info("Successfully indexed message \(message.id.uuidString) into \(childEntities.count) semantic child chunks.")
        } else {
            logger.warning("Failed to generate any embeddings for message \(message.id.uuidString). Vector ingestion failed.")
        }
    }

    // MARK: - Upload Chunker Routing

    /// Prose chunk target (chars).
    static let proseChunkSize = 512
    /// Code chunk target (chars). Code is symbol-dense — WordPiece burns ~3 chars
    /// per token and the MiniLM embedder head-truncates at ~128 tokens, so code
    /// chunks stay near 384 chars to keep the WHOLE chunk visible to semantic
    /// search (a 512-char code chunk's tail is invisible to the embedding).
    static let codeChunkSize = 384

    /// Routes an uploaded file to the right chunker. Source files become `.code`
    /// blocks so SemanticChunker hands them to TreeSitterCodeChunker — AST-boundary
    /// splits with a "[lang Context]:" prefix — instead of chunking code as prose.
    /// (Previously EVERY upload was wrapped as one `.paragraph`, so the AST chunker
    /// never ran on real files; functions were sliced mid-body at arbitrary 512-char
    /// windows.) Markdown and plain text stay on the prose path — paragraph
    /// boundaries suit them better than a syntax tree. Sizing is uniform across
    /// message and upload indexing: SemanticChunker's `codeChunkSize` calibrates
    /// code blocks; prose uses `maxChunkSize`.
    static func uploadContentBlocks(for url: URL, id: String, text: String) -> [ContentBlock] {
        let language = CodeLanguage.detectLanguageFrom(url: url)
        let proseLike: Set<TreeSitterLanguage> = [.plainText, .markdown, .markdownInline]
        guard !proseLike.contains(language.id) else {
            return [ContentBlock(id: id, type: .paragraph(text))]
        }
        return [ContentBlock(id: id, type: .code(language: language.id.rawValue, content: text, fileName: url.lastPathComponent))]
    }

    // MARK: - Batch File Indexing (Awaitable)

    /// Index multiple attached files for conversation-memory retrieval on LATER
    /// turns. Runs post-retrieval in the orchestrator (Section 3b), so a file never
    /// re-surfaces via RAG in the same turn it was injected.
    /// Whether an attached file should be attempted for conversation-memory RAG
    /// indexing. Static + pure so the eligibility contract is testable without
    /// the embedding stack.
    ///
    /// ATT-1: this must mirror the backend's direct-injection rule (skip only
    /// images) — the old `canExtract || isTextFile` gate was extension-keyed, so
    /// extension-less files (Makefile, LICENSE, .env) that the model DID see on
    /// turn 1 were unfindable by turn-2+ retrieval. Readability is decided by
    /// the read probe at index time, not by the extension.
    static func isRAGEligible(_ file: FileSystemItem, fileProcessor: FileProcessorService) -> Bool {
        guard !file.isDirectory else { return false }
        let mime = fileProcessor.getFileMimeType(for: file.url)
        return !fileProcessor.isImageFile(mimeType: mime, url: file.url)
    }

    func indexAttachedFiles(
        files: [FileSystemItem],
        conversationID: UUID,
        messageID: UUID
    ) async {
        let fileProcessor = FileProcessorService()

        for file in files {
            guard Self.isRAGEligible(file, fileProcessor: fileProcessor) else {
                logger.info("Skipping RAG indexing for '\(file.name)' — image or folder, not text-indexable.")
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

            // Chunk the extracted text — code files route to the AST chunker,
            // with the same prose/code sizing the message path uses.
            let blocks = Self.uploadContentBlocks(for: file.url, id: "file-\(file.id)", text: sanitizedText)
            let chunks = SemanticChunker(maxChunkSize: Self.proseChunkSize, overlap: 50, codeChunkSize: Self.codeChunkSize).chunk(blocks: blocks)
            guard !chunks.isEmpty else { continue }

            // Generate embeddings for each chunk
            var childEntities: [ChildChunkEntity] = []
            for (index, chunkText) in chunks.enumerated() {
                guard !chunkText.isEmpty else { continue }
                if let embedding = await embeddingService.generateEmbedding(for: chunkText) {
                    childEntities.append(ChildChunkEntity(
                        chunkText: chunkText,
                        embedding: embedding,
                        chunkIndex: index,
                        conversationID: conversationID.uuidString
                    ))
                }
            }

            guard !childEntities.isEmpty else { continue }

            // Create parent document referencing the file
            let parentDoc = ParentDocumentEntity(
                sourceMessageID: messageID,
                conversationID: conversationID,
                fullTextContent: "[File: \(file.name)]\n\(sanitizedText)",
                timestamp: Date(),
                sourceIdentifier: file.url.path
            )

            // Replace-on-reindex: re-attaching the same file in this conversation
            // replaces its prior vectors instead of appending a duplicate copy that
            // would crowd the limit-3 retrieval slots.
            vectorStoreService.removeDocuments(sourceIdentifier: file.url.path, conversationID: conversationID)
            vectorStoreService.addSemanticDocument(parent: parentDoc, children: childEntities)
            logger.info("RAG-indexed attachment: \(file.name) → \(childEntities.count) chunks")
        }
    }

}
