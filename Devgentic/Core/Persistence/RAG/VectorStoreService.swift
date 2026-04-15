//
//  VectorStoreService.swift
//  Devgentic
//
//  Created by Raj Singh on 13/07/25.
//

import Foundation
import ObjectBox
import os

// MARK: - Vector Store Service

/// A service for managing the vector database using ObjectBox with a native HNSW index.
///
/// Search complexity is reduced from O(N) brute-force cosine similarity to O(log N) via ObjectBox's
/// probabilistic Hierarchical Navigable Small World graph, configured for the 384-dimensional
/// All-MiniLM-L6-v2 embedding space.  See `ChildChunkEntity` for index hyperparameter rationale.
final class VectorStoreService: @unchecked Sendable {

    // MARK: - Singleton Instance
    static let shared = VectorStoreService()

    // MARK: - Private Properties
    private let store: Store
    private let parentBox: Box<ParentDocumentEntity>
    private let childBox: Box<ChildChunkEntity>
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "VectorStoreService")

    // MARK: - HNSW Search Constants

    /// Cosine distance threshold (= 1 − cosine_similarity).
    /// L2-normalised vectors from EmbeddingService ensure cosine_distance = 1 − dot_product.
    /// Equivalent to the previous similarity threshold of 0.3 (distance ≤ 0.7 → similarity ≥ 0.3).
    private let maximumCosineDistance: Double = 0.7

    // MARK: - Initialization

    /// Private initializer to set up the ObjectBox store and entity box.
    ///
    /// ⚠️ HNSW migration note: If migrating a large pre-existing dataset, the ObjectBox engine
    /// compiles the full HNSW graph on first open (O(N·log N) complexity). For >100k vectors this
    /// should be moved to a background Task with a "Optimizing database…" UI gate to avoid an
    /// iOS Jetsam watchdog kill. For fresh installs (and after the Phase 3 wipe below) the DB
    /// is empty so graph compilation is instantaneous.
    private init() {
        do {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
                .appendingPathComponent(Bundle.main.bundleIdentifier!)
                .appendingPathComponent("vector-db")

            // --- PHASE 2: DATABASE MIGRATION (WIPE) ---
            let phase2Key = "Phase2_VectorDB_Wiped"
            if !UserDefaults.standard.bool(forKey: phase2Key) {
                logger.info("Phase 2 Migration: Wiping old vector database...")
                if FileManager.default.fileExists(atPath: appSupport.path) {
                    try FileManager.default.removeItem(at: appSupport)
                }
                UserDefaults.standard.set(true, forKey: phase2Key)
                logger.warning("Phase 2 Migration: Complete.")
            }

            // --- PHASE 3: HNSW SCHEMA MIGRATION (WIPE) ---
            // Reason: `embedding` changes from a FloatArrayConverter (Data blob) to a native
            // [Float]? property with an `hnswIndex` annotation.  ObjectBox cannot auto-migrate
            // between these fundamentally different storage representations, so a clean wipe is
            // required.  A new `conversationID: String` field is also added to ChildChunkEntity.
            let phase3Key = "Phase3_HNSW_Schema_Migrated"
            if !UserDefaults.standard.bool(forKey: phase3Key) {
                logger.info("Phase 3 Migration: Wiping vector database for HNSW schema upgrade...")
                if FileManager.default.fileExists(atPath: appSupport.path) {
                    try FileManager.default.removeItem(at: appSupport)
                    logger.warning("Phase 3 Migration: Old vector-db wiped. Fresh HNSW index will be built.")
                }
                UserDefaults.standard.set(true, forKey: phase3Key)
            }

            try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true, attributes: nil)

            self.store = try Store(directoryPath: appSupport.path)
            self.parentBox = self.store.box(for: ParentDocumentEntity.self)
            self.childBox = self.store.box(for: ChildChunkEntity.self)

            logger.info("VectorStoreService (HNSW) initialized. DB path: \(appSupport.path)")
        } catch {
            logger.critical("Failed to initialize VectorStoreService: \(error.localizedDescription)")
            fatalError("Could not initialize ObjectBox store: \(error)")
        }
    }

    // MARK: - Public API

    /// Adds a semantic parent document and its associated child chunks to the vector database.
    ///
    /// The child's `conversationID` is denormalised from the parent here so that HNSW result
    /// post-filtering can scope by conversation without an additional relation traversal per result.
    func addSemanticDocument(parent: ParentDocumentEntity, children: [ChildChunkEntity]) {
        do {
            let convIDString = parent.conversationID.uuidString
            for child in children {
                child.parentDocument.target = parent
                child.conversationID = convIDString
            }
            try childBox.put(children)
            logger.debug("Indexed \(children.count) HNSW child chunks for parent \(parent.sourceMessageID.uuidString).")
        } catch {
            logger.error("Failed to add semantic document to vector store: \(error.localizedDescription)")
        }
    }

    /// Finds the most semantically relevant parent documents using the native ObjectBox HNSW index.
    ///
    /// The HNSW graph reduces search from O(N) linear scan to O(log N) graph traversal.
    /// Results are returned in ascending distance order (ObjectBox guarantee); the first result
    /// is the closest match.  The search is optionally scoped to a single conversation via
    /// post-filtering on the denormalised `conversationID` field.
    ///
    /// - Parameters:
    ///   - queryEmbedding: L2-normalised 384-D vector from `EmbeddingService`.
    ///   - limit: Maximum number of unique parent documents to return.
    ///   - conversationID: If set, only chunks belonging to this conversation are considered.
    /// - Returns: Relevant `ParentDocumentEntity` objects, ordered by semantic proximity.
    func findNearest(to queryEmbedding: [Float], limit: Int, conversationID: UUID?) -> [ParentDocumentEntity] {
        do {
            // Oversample candidates to compensate for conversation-scoped post-filtering.
            // Conversation chunks are typically a fraction of the total corpus, so we cast a
            // wider net to ensure we fill `limit` slots after filtering.
            let candidateCount = conversationID != nil ? max(50, limit * 10) : limit * 3

            // Build the HNSW nearest-neighbours query.  ObjectBox evaluates this entirely within
            // the C++ engine, traversing the multi-layered HNSW graph without pulling vectors into
            // the Swift runtime for per-vector comparison.
            let query = try childBox.query {
                ChildChunkEntity.embedding.nearestNeighbors(
                    queryVector: queryEmbedding,
                    maxCount: candidateCount
                )
            }.build()

            // findWithScores() returns ObjectWithScore instances sorted ascending by cosine distance.
            // score = 0.0 → identical vectors; score = 2.0 → maximally dissimilar.
            let results: [ObjectWithScore<ChildChunkEntity>] = try query.findWithScores()

            if results.isEmpty {
                logger.debug("HNSW search returned no candidates.")
                return []
            }

            var uniqueParents: [ParentDocumentEntity] = []
            var seenParentIDs: Set<Id> = []
            var scoresSummary: [String] = []

            for result in results {
                guard uniqueParents.count < limit else { break }

                // Early exit: results are sorted ascending, so once distance exceeds the threshold
                // every subsequent result will also fail.
                guard result.score <= maximumCosineDistance else { break }

                let chunk = result.object

                // Conversation scoping: post-filter using the denormalised conversationID string.
                if let convID = conversationID {
                    guard chunk.conversationID == convID.uuidString else { continue }
                }

                if let parent = chunk.parentDocument.target, !seenParentIDs.contains(parent.id) {
                    seenParentIDs.insert(parent.id)
                    uniqueParents.append(parent)
                    scoresSummary.append(String(format: "d=%.3f", result.score))
                }
            }

            logger.info("HNSW: \(uniqueParents.count) documents retrieved ([\(scoresSummary.joined(separator: ", "))], maxDist: \(self.maximumCosineDistance)).")
            return uniqueParents

        } catch {
            logger.error("HNSW vector search failed: \(error.localizedDescription)")
            return []
        }
    }
}
