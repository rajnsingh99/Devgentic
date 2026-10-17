// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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
    ///
    /// Takes a SNAPSHOT, never the live `ChatMessage` — see `IndexableMessage` (RAG-16). Build it
    /// where the message lives, before detaching.
    func indexSingleMessage(_ message: IndexableMessage) async {
        // Filter out noise: Do not index error messages
        if message.isError {
            logger.debug("[RAG] Not indexing message \(message.id.uuidString.prefix(8)): it is an error row.")
            return
        }

        // Synthetic stopped-run placeholders (cancelled/empty runs) carry no
        // retrievable fact — indexing them polluted conversation memory (a cancelled
        // run's "*Operation was stopped…*" was embedded and stored, observed
        // on-device 2026-07-19). Exact-match gate: a message that merely quotes the
        // phrase is real content and still indexes.
        if let text = message.textContent, ChatMessage.isSyntheticPlaceholder(text) {
            logger.debug("[RAG] Skipping vectorization for message \(message.id.uuidString.prefix(8)): synthetic stopped-run placeholder, nothing retrievable.")
            return
        }
        
        // Parse the snapshot's text into blocks (off the main actor — a pure function of the copy).
        let blocks = message.blocksForIndexing()

        // Calibrated per block kind: prose at 512, fenced code blocks at 384 so
        // their embeddings stay fully inside the ~128-token embedder window.
        let chunker = SemanticChunker(maxChunkSize: Self.proseChunkSize, overlap: 50, codeChunkSize: Self.codeChunkSize)
        let chunks = chunker.chunk(blocks: blocks)
        
        guard !chunks.isEmpty else {
            logger.debug("[RAG] Not indexing message \(message.id.uuidString.prefix(8)): no text to index (e.g. an image-only message).")
            return
        }
        
        // Strip think blocks from the full text to prevent internal model reasoning
        // from polluting the semantic index. Only user-facing content should be searchable.
        let rawFullText = message.textContent ?? chunks.joined(separator: "\n\n")
        let fullText = OutputSanitizer.stripThinkBlocksAndTokens(rawFullText)
        
        let parentDoc = ParentDocumentEntity(
            sourceMessageID: message.id,
            conversationID: message.conversationId,
            fullTextContent: fullText,
            timestamp: message.timestamp,
            sourceIdentifier: message.id.uuidString
        )

        var childEntities: [ChildChunkEntity] = []
        var failedEmbeds = 0

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
            } else {
                failedEmbeds += 1
            }
        }
        // RAG-38: a failed embed used to vanish without a word.
        if failedEmbeds > 0, !childEntities.isEmpty {
            logger.warning("[RAG] Message \(message.id.uuidString.prefix(8)) (conv \(message.conversationId.uuidString.prefix(8))): \(failedEmbeds) of \(chunks.count) chunk(s) could not be embedded. CONSEQUENCE: those passages are not retrievable; the rest of the message is.")
        }

        // Save the ParentDocumentEntity and its associated ChildChunkEntitys to ObjectBox
        if !childEntities.isEmpty {
            // Replace-on-reindex: a re-finalized message (e.g. a resumed run) replaces
            // its prior vectors instead of appending a duplicate copy — one transaction,
            // so a failed write keeps the previous copy (the store logs why).
            if vectorStoreService.replaceSemanticDocument(parent: parentDoc, children: childEntities) == .written {
                logger.info("[RAG] Indexed message \(message.id.uuidString.prefix(8)) (conv \(message.conversationId.uuidString.prefix(8))) into \(childEntities.count) chunk(s).")
            }
        } else {
            logger.warning("[RAG] No chunk of message \(message.id.uuidString.prefix(8)) (conv \(message.conversationId.uuidString.prefix(8))) could be embedded (\(chunks.count) tried). CONSEQUENCE: this message is NOT in conversation memory — later turns cannot recall it once it leaves the prompt.")
        }
    }

    /// Re-indexes an agent message as the response VERSION the user selected.
    ///
    /// The index holds whatever `content` was when the reply finalized — the newest variant. The
    /// version picker only moves `selectedVariantIndex`, so after choosing an older answer the
    /// conversation's memory still described the one the user had just rejected. Replace-on-
    /// reindex keys on the message id, so this swaps the copy rather than adding one.
    ///
    /// Snapshot taken HERE, on the main actor; the work is detached. Returns the task so a test can
    /// await it; callers ignore it.
    @MainActor @discardableResult
    static func reindexSelectedVariant(of message: ChatMessage) -> Task<Void, Never>? {
        guard let selected = message.currentAgentContent else {
            shared.logger.debug("[RAG] Variant re-index skipped for \(message.id.uuidString.prefix(8)): no selectable variant.")
            return nil
        }
        let snapshot = IndexableMessage(message, content: selected)
        return Task.detached(priority: .utility) {
            await RAGIndexingService.shared.indexSingleMessage(snapshot)
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
    ///
    /// Kind comes from `AttachmentClassifier`, shared with the transcript and the backend:
    /// only content the model received as TEXT is indexed — never images, folders, or
    /// binaries (whose text read fails, so there is nothing to chunk).
    static func isRAGEligible(_ file: FileSystemItem, fileProcessor: FileProcessorService) -> Bool {
        switch AttachmentClassifier.classify(file) {
        case .text, .document:                  return true
        case .image, .folder, .video, .binary:  return false
        }
    }

    /// - Parameters:
    ///   - messageID: The user message that carried the files — NOT a fresh UUID, so a file's
    ///     vectors can be traced to (and excluded with) the turn that delivered them.
    ///   - messageTimestamp: That message's timestamp. The parent is dated to its TURN, not to
    ///     when indexing finished: a Redo's cutoff (`RetrievalExclusion.indexedAtOrAfter`) must
    ///     see a file as belonging to the turn it arrived in.
    func indexAttachedFiles(
        files: [FileSystemItem],
        conversationID: UUID,
        messageID: UUID,
        messageTimestamp: Date
    ) async {
        let fileProcessor = FileProcessorService()

        for file in files {
            guard Self.isRAGEligible(file, fileProcessor: fileProcessor) else {
                logger.info("[RAG] Not indexing '\(file.name)' (conv \(conversationID.uuidString.prefix(8))): an image or folder has no text to index.")
                continue
            }

            guard let text = await fileProcessor.readFileContent(for: file.url, truncatingOversizeText: true) else {
                logger.warning("[RAG] Could not read '\(file.name)' for conversation memory (conv \(conversationID.uuidString.prefix(8)), msg \(messageID.uuidString.prefix(8))). CONSEQUENCE: this attachment is NOT indexed — later turns cannot recall it; the turn that carried it still delivered it as usual.")
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
            var failedEmbeds = 0
            for (index, chunkText) in chunks.enumerated() {
                guard !chunkText.isEmpty else { continue }
                if let embedding = await embeddingService.generateEmbedding(for: chunkText) {
                    childEntities.append(ChildChunkEntity(
                        chunkText: chunkText,
                        embedding: embedding,
                        chunkIndex: index,
                        conversationID: conversationID.uuidString
                    ))
                } else {
                    failedEmbeds += 1
                }
            }
            // RAG-38: a failed embed used to vanish without a word.
            if failedEmbeds > 0 {
                logger.warning("[RAG] '\(file.name)': \(failedEmbeds) of \(chunks.count) chunk(s) could not be embedded (conv \(conversationID.uuidString.prefix(8))). CONSEQUENCE: \(childEntities.isEmpty ? "the file is NOT indexed at all" : "those passages are not retrievable; the rest of the file is").")
            }

            guard !childEntities.isEmpty else { continue }

            // Create parent document referencing the file
            let parentDoc = ParentDocumentEntity(
                sourceMessageID: messageID,
                conversationID: conversationID,
                fullTextContent: "[File: \(file.name)]\n\(sanitizedText)",
                timestamp: messageTimestamp,
                sourceIdentifier: file.url.path
            )

            // Replace-on-reindex: re-attaching the same file in this conversation
            // replaces its prior vectors instead of appending a duplicate copy that
            // would crowd the limit-3 retrieval slots — one transaction (see the store).
            if vectorStoreService.replaceSemanticDocument(parent: parentDoc, children: childEntities) == .written {
                logger.info("[RAG] Indexed attachment '\(file.name)' (conv \(conversationID.uuidString.prefix(8)), msg \(messageID.uuidString.prefix(8))) → \(childEntities.count) chunk(s).")
            }
        }
    }

}
