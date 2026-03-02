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

/// A service for managing the vector database using ObjectBox.
///
/// This singleton class handles initializing the database, adding new text chunks,
/// and performing vector similarity searches (nearest neighbor search) to find
/// relevant context for RAG.
class VectorStoreService {
    
    // MARK: - Singleton Instance
    static let shared = VectorStoreService()
    
    // MARK: - Private Properties
    private let store: Store
    private let parentBox: Box<ParentDocumentEntity>
    private let childBox: Box<ChildChunkEntity>
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "VectorStoreService")
    
    // MARK: - Initialization
    
    /// Private initializer to set up the ObjectBox store and entity box.
    private init() {
        do {
            // Define a specific directory for the vector database to keep it separate.
            let appSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent(Bundle.main.bundleIdentifier!)
                .appendingPathComponent("vector-db")
            
            // --- PHASE 2: DATABASE MIGRATION (WIPE) ---
            // Wipe the existing vector-db directory to prepare for the new Parent/Child schema.
            // This ensures invalid vectors (from the broken tokenizer) and the old flat schema are destroyed.
            let migrationKey = "Phase2_VectorDB_Wiped"
            if !UserDefaults.standard.bool(forKey: migrationKey) {
                logger.info("Phase 2 Migration: Attempting to wipe old vector database...")
                if FileManager.default.fileExists(atPath: appSupport.path) {
                    try FileManager.default.removeItem(at: appSupport)
                    logger.warning("Phase 2 Migration: Successfully wiped old vector-db directory.")
                }
                UserDefaults.standard.set(true, forKey: migrationKey)
            }
            // ------------------------------------------

            // --- PHASE 3: TOKENIZER UPGRADE MIGRATION (WIPE) ---
            // The previous EmbeddingService used a broken manual tokenizer that produced
            // garbage embeddings. Now that we use a real WordPiece tokenizer via
            // swift-transformers, all existing vectors are invalid and must be regenerated.
            // This one-time wipe forces a full re-index with the correct tokenizer.
            let tokenizerMigrationKey = "Phase3_TokenizerUpgrade_Wiped"
            if !UserDefaults.standard.bool(forKey: tokenizerMigrationKey) {
                logger.info("Phase 3 Migration: Wiping vector database for tokenizer upgrade (broken → WordPiece)...")
                if FileManager.default.fileExists(atPath: appSupport.path) {
                    try FileManager.default.removeItem(at: appSupport)
                    logger.warning("Phase 3 Migration: Successfully wiped vector-db. All messages will be re-indexed.")
                }
                // Also reset the RAG indexing flags so all messages get re-processed
                CoreDataPersistenceService.shared.resetAllRAGIndexingFlags()
                UserDefaults.standard.set(true, forKey: tokenizerMigrationKey)
            }
            // ------------------------------------------
            
            try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true, attributes: nil)
            
            // Initialize the ObjectBox store.
            // This will open an existing database or create a new one if it doesn't exist.
            self.store = try Store(directoryPath: appSupport.path)
            
            // Get the boxes for our entities. (ChunkEntity has been completely removed in Phase 5)
            self.parentBox = self.store.box(for: ParentDocumentEntity.self)
            self.childBox = self.store.box(for: ChildChunkEntity.self)
            
            logger.info("VectorStoreService initialized successfully. DB path: \(appSupport.path)")
        } catch {
            logger.critical("Failed to initialize VectorStoreService: \(error.localizedDescription)")
            fatalError("Could not initialize ObjectBox store: \(error)")
        }
    }
    
    // MARK: - Public API
    
    /// Adds a semantic parent document and its associated child chunks to the vector database.
    /// - Parameters:
    ///   - parent: The full ParentDocumentEntity.
    ///   - children: An array of vectorized ChildChunkEntity objects.
    func addSemanticDocument(parent: ParentDocumentEntity, children: [ChildChunkEntity]) {
        do {
            // Link the child chunks to their parent.
            // In ObjectBox, linking a ToOne relation and putting the children will automatically
            // persist the parent if it hasn't been saved yet.
            for child in children {
                child.parentDocument.target = parent
            }
            try childBox.put(children)
            logger.debug("Successfully added Parent Document and \(children.count) semantic child chunks.")
        } catch {
            logger.error("Failed to add semantic document to vector store: \(error.localizedDescription)")
        }
    }
    
    /// Finds the most relevant parent documents in the database related to a query embedding,
    /// optionally scoped to a specific conversation. The search evaluates child chunks but returns parents.
    ///
    /// - Parameters:
    ///   - queryEmbedding: The vector embedding of the user's query.
    ///   - limit: The maximum number of relevant documents to return.
    ///   - conversationID: If provided, the search will be limited to chunks within this conversation.
    /// - Returns: An array of the most relevant `ParentDocumentEntity` objects, sorted by relevance.
    func findNearest(to queryEmbedding: [Float], limit: Int, conversationID: UUID?) -> [ParentDocumentEntity] {
        do {
            let childrenToSearch: [ChildChunkEntity]
            
            // --- Phase 5: Conditionally filter children by their parent's conversationID ---
            if let convID = conversationID {
                logger.info("Scoping vector search to conversation ID: \(convID.uuidString)")
                
                // 1. Fetch all parent documents for this conversation
                let parentQuery: Query<ParentDocumentEntity> = try parentBox.query {
                    ParentDocumentEntity.conversationID.isEqual(to: convID.uuidString, caseSensitive: false)
                }.build()
                
                let validParentIds = Set(try parentQuery.find().map { $0.id })
                
                // 2. Filter children to only those whose parent is in the valid set
                childrenToSearch = try childBox.all().filter { child in
                    guard let parent = child.parentDocument.target else { return false }
                    return validParentIds.contains(parent.id)
                }
            } else {
                // If no conversation ID is provided, fall back to searching all chunks.
                logger.warning("No conversation ID provided for vector search. Searching globally.")
                childrenToSearch = try childBox.all()
            }

            if childrenToSearch.isEmpty {
                logger.debug("No child chunks in vector store to search for the given criteria.")
                return []
            }
            
            // Create a temporary structure to hold chunks and their similarity scores.
            let scoredChunks = childrenToSearch.map { chunk in
                (chunk: chunk, score: VectorMath.cosineSimilarity(between: queryEmbedding, and: chunk.embedding))
            }
            
            // Sort by score in descending order (higher is better).
            let sortedChunks = scoredChunks.sorted { $0.score > $1.score }

            // Apply minimum similarity threshold.
            let minimumSimilarity: Float = 0.3
            let qualifiedChunks = sortedChunks.filter { $0.score >= minimumSimilarity }
            
            // Extract unique parent documents, preserving the order of the highest-scoring children
            var uniqueParents: [ParentDocumentEntity] = []
            var seenParentIDs: Set<Id> = []
            var scoresSummary: [String] = []
            
            for item in qualifiedChunks {
                if uniqueParents.count >= limit { break }
                
                // Traverse the ObjectBox relation to get the parent
                if let parent = item.chunk.parentDocument.target, !seenParentIDs.contains(parent.id) {
                    seenParentIDs.insert(parent.id)
                    uniqueParents.append(parent)
                    scoresSummary.append(String(format: "%.3f", item.score))
                }
            }

            logger.info("Found \(uniqueParents.count) relevant parent documents for query (scores: [\(scoresSummary.joined(separator: ", "))], threshold: \(minimumSimilarity)).")
            return uniqueParents
            
        } catch {
            logger.error("Failed to fetch chunks for nearest neighbor search: \(error.localizedDescription)")
            return []
        }
    }
}
