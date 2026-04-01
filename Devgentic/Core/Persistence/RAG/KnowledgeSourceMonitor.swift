//
//  KnowledgeSourceMonitor.swift
//  Devgentic
//
//  Created on 29/03/26.
//
//  Tracks freshness of indexed knowledge sources for contextualRAG strategy.
//  Uses lazy staleness checks (stat()) instead of persistent filesystem watchers.
//  Only relevant when profile uses .contextualRAG — other strategies are inherently fresh.
//

import Foundation
import os

actor KnowledgeSourceMonitor {

    static let shared = KnowledgeSourceMonitor()

    private let logger = Logger(subsystem: "com.devgentic", category: "KnowledgeSourceMonitor")

    // MARK: - Tracked State Per Source

    struct IndexedSourceState: Sendable {
        let sourcePath: String
        let lastIndexedDate: Date
        let indexedChunkCount: Int
    }

    /// Key: file path. Value: state at last indexing.
    private var trackedSources: [String: IndexedSourceState] = [:]

    // MARK: - Trigger 1: On Query (Lazy Freshness Check)

    /// Called before RAG retrieval in BackendOrchestrationService.
    /// Checks each knowledge source for staleness and re-indexes if needed.
    /// Only call when strategy == .contextualRAG.
    func ensureFreshness(
        sources: [KnowledgeSource],
        conversationID: UUID
    ) async {
        for source in sources {
            guard source.isLocalFile else { continue }

            let path = source.location

            // stat() call — microseconds, not milliseconds
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let modificationDate = attributes[.modificationDate] as? Date else {
                logger.warning("Cannot stat knowledge source: \(source.fileName)")
                continue
            }

            if let tracked = trackedSources[path] {
                // Source was previously indexed — check if modified since
                if modificationDate <= tracked.lastIndexedDate {
                    logger.debug("Knowledge source fresh: \(source.fileName)")
                    continue
                }
                logger.info("Knowledge source stale, re-indexing: \(source.fileName)")
            } else {
                logger.info("New knowledge source, indexing: \(source.fileName)")
            }

            // Extract and index
            await indexSource(source: source, conversationID: conversationID)
        }
    }

    // MARK: - Trigger 2: On Profile Save (Source List Changed)

    /// Called when the user saves a profile with modified knowledgeSources.
    /// Diffs old vs new sources: indexes additions, removes deletions from tracking.
    func handleProfileSourcesChanged(
        oldSources: [KnowledgeSource],
        newSources: [KnowledgeSource],
        conversationID: UUID
    ) async {
        let oldPaths = Set(oldSources.map(\.location))
        let newPaths = Set(newSources.map(\.location))

        // Added sources — index them
        let added = newSources.filter { !oldPaths.contains($0.location) }
        for source in added {
            logger.info("Knowledge source added: \(source.fileName)")
            await indexSource(source: source, conversationID: conversationID)
        }

        // Removed sources — clean up tracked state
        let removedPaths = oldPaths.subtracting(newPaths)
        for path in removedPaths {
            trackedSources.removeValue(forKey: path)
            logger.info("Knowledge source removed from tracking: \(path)")
        }
    }

    // MARK: - Trigger 3: Manual Refresh

    /// Force re-index all sources. Called when user taps a "Refresh" button.
    func forceRefreshAll(
        sources: [KnowledgeSource],
        conversationID: UUID
    ) async {
        logger.info("Force refreshing \(sources.count) knowledge sources")

        // Clear all tracked state to force re-indexing
        for source in sources {
            trackedSources.removeValue(forKey: source.location)
        }

        await ensureFreshness(sources: sources, conversationID: conversationID)
    }

    // MARK: - Cleanup

    /// Clear all tracked state (e.g., on app reset).
    func clearTracking() {
        trackedSources.removeAll()
    }

    // MARK: - Private

    private func indexSource(source: KnowledgeSource, conversationID: UUID) async {
        guard let text = await FileProcessorService().readFileContent(for: source.url) else {
            logger.warning("Failed to extract content from: \(source.fileName)")
            return
        }

        let sanitizedText = OutputSanitizer.stripThinkBlocksAndTokens(text)
        guard !sanitizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Chunk the extracted text
        let blocks = [ContentBlock(id: "ks-\(source.id)", type: .paragraph(sanitizedText))]
        let chunks = SemanticChunker(maxChunkSize: 512, overlap: 50).chunk(blocks: blocks)
        guard !chunks.isEmpty else { return }

        // Generate embeddings for each chunk
        var childEntities: [ChildChunkEntity] = []
        for (index, chunkText) in chunks.enumerated() {
            guard !chunkText.isEmpty else { continue }
            if let embedding = await EmbeddingService.shared.generateEmbedding(for: chunkText) {
                childEntities.append(ChildChunkEntity(
                    chunkText: chunkText,
                    embedding: embedding,
                    chunkIndex: index
                ))
            }
        }

        guard !childEntities.isEmpty else { return }

        // Create parent document referencing the knowledge source
        let parentDoc = ParentDocumentEntity(
            sourceMessageID: UUID(),
            conversationID: conversationID,
            fullTextContent: "[Knowledge: \(source.fileName)]\n\(sanitizedText)",
            timestamp: Date()
        )

        VectorStoreService.shared.addSemanticDocument(parent: parentDoc, children: childEntities)

        // Update tracked state
        trackedSources[source.location] = IndexedSourceState(
            sourcePath: source.location,
            lastIndexedDate: Date(),
            indexedChunkCount: childEntities.count
        )

        logger.info("Indexed knowledge source: \(source.fileName) → \(childEntities.count) chunks")
    }
}
