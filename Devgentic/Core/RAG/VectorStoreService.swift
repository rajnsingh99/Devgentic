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
    private let box: Box<ChunkEntity>
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "VectorStoreService")
    
    // MARK: - Initialization
    
    /// Private initializer to set up the ObjectBox store and entity box.
    private init() {
        do {
            // Define a specific directory for the vector database to keep it separate.
            let appSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent(Bundle.main.bundleIdentifier!)
                .appendingPathComponent("vector-db")
            
            try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true, attributes: nil)
            
            // Initialize the ObjectBox store.
            // This will open an existing database or create a new one if it doesn't exist.
            self.store = try Store(directoryPath: appSupport.path)
            
            // Get the box for our ChunkEntity.
            self.box = self.store.box(for: ChunkEntity.self)
            
            logger.info("VectorStoreService initialized successfully. DB path: \(appSupport.path)")
        } catch {
            logger.critical("Failed to initialize VectorStoreService: \(error.localizedDescription)")
            fatalError("Could not initialize ObjectBox store: \(error)")
        }
    }
    
    // MARK: - Public API
    
    /// Adds an array of `ChunkEntity` objects to the vector database.
    /// - Parameter chunks: The chunk objects to be saved.
    func add(chunks: [ChunkEntity]) {
        do {
            try box.put(chunks)
            logger.debug("Successfully added \(chunks.count) chunks to the vector store.")
        } catch {
            logger.error("Failed to add chunks to vector store: \(error.localizedDescription)")
        }
    }
    
    /// Finds the `limit` most relevant chunks in the database related to a query embedding.
    ///
    /// This function performs a brute-force nearest neighbor search by calculating the cosine
    /// similarity between the query vector and every chunk in the database.
    ///
    /// - Parameters:
    ///   - queryEmbedding: The vector embedding of the user's query.
    ///   - limit: The maximum number of relevant chunks to return.
    /// - Returns: An array of the most relevant `ChunkEntity` objects, sorted by relevance.
    func findNearest(to queryEmbedding: [Float], limit: Int) -> [ChunkEntity] {
        do {
            let allChunks = try box.all()
            if allChunks.isEmpty {
                logger.debug("No chunks in vector store to search.")
                return []
            }
            
            // Create a temporary structure to hold chunks and their similarity scores.
            let scoredChunks = allChunks.map { chunk in
                (chunk: chunk, score: cosineSimilarity(between: queryEmbedding, and: chunk.embedding))
            }
            
            // Sort by score in descending order (higher is better).
            let sortedChunks = scoredChunks.sorted { $0.score > $1.score }
            
            // Return the top `limit` chunks.
            let topChunks = Array(sortedChunks.prefix(limit).map { $0.chunk })
            
            logger.info("Found \(topChunks.count) relevant chunks for query.")
            return topChunks
            
        } catch {
            logger.error("Failed to fetch chunks for nearest neighbor search: \(error.localizedDescription)")
            return []
        }
    }
    
    // MARK: - Vector Math Helpers
    
    /// Calculates the cosine similarity between two vectors.
    /// - Returns: A Float between -1 and 1, where 1 means identical.
    private func cosineSimilarity(between vectorA: [Float], and vectorB: [Float]) -> Float {
        let dot = dotProduct(vectorA, vectorB)
        let magnitudeA = magnitude(of: vectorA)
        let magnitudeB = magnitude(of: vectorB)
        
        guard magnitudeA > 0, magnitudeB > 0 else {
            return 0.0
        }
        
        return dot / (magnitudeA * magnitudeB)
    }
    
    /// Calculates the dot product of two vectors.
    private func dotProduct(_ vectorA: [Float], _ vectorB: [Float]) -> Float {
        // Ensure vectors are the same size for a valid dot product.
        guard vectorA.count == vectorB.count else { return 0.0 }
        return zip(vectorA, vectorB).map(*).reduce(0, +)
    }
    
    /// Calculates the magnitude (L2 norm) of a vector.
    private func magnitude(of vector: [Float]) -> Float {
        return sqrt(vector.map { $0 * $0 }.reduce(0, +))
    }
}
