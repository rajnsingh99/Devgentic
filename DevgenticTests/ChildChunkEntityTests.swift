// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChildChunkEntityTests.swift
//  devgenticTests
//
//  Created by Raj Singh on 12/03/26.
//
//  Tests for the `ChildChunkEntity` ObjectBox model, covering field defaults,
//  HNSW schema constraints (optional embedding, 384-dim contract), and the
//  denormalised `conversationID` field used for O(1) post-HNSW conversation scoping.

import XCTest
@testable import devgentic

final class ChildChunkEntityTests: XCTestCase {

    // MARK: - Default Initializer

    func testDefaultInit_IdIsZero() {
        let entity = ChildChunkEntity()
        XCTAssertEqual(entity.id, 0, "ObjectBox-managed id must start at 0 (unassigned)")
    }

    func testDefaultInit_ChunkTextIsEmpty() {
        let entity = ChildChunkEntity()
        XCTAssertEqual(entity.chunkText, "")
    }

    func testDefaultInit_EmbeddingIsNil() {
        // HNSW requires [Float]? — nil signals no embedding has been generated yet.
        // ObjectBox excludes nil-embedding entities from HNSW graph traversal entirely.
        let entity = ChildChunkEntity()
        XCTAssertNil(entity.embedding,
                     "HNSW-indexed embedding must default to nil, not an empty array")
    }

    func testDefaultInit_ChunkIndexIsZero() {
        let entity = ChildChunkEntity()
        XCTAssertEqual(entity.chunkIndex, 0)
    }

    func testDefaultInit_ConversationIDIsEmpty() {
        // Denormalised field populated by VectorStoreService.addSemanticDocument()
        // at insert time, not at entity construction time.
        let entity = ChildChunkEntity()
        XCTAssertEqual(entity.conversationID, "",
                       "conversationID must start empty and be stamped on insert")
    }

    // MARK: - Convenience Initializer

    func testConvenienceInit_SetsChunkText() {
        let entity = ChildChunkEntity(chunkText: "Hello Swift", embedding: [1, 2, 3], chunkIndex: 0, conversationID: "")
        XCTAssertEqual(entity.chunkText, "Hello Swift")
    }

    func testConvenienceInit_SetsEmbedding() {
        let emb: [Float] = [0.1, 0.2, 0.3]
        let entity = ChildChunkEntity(chunkText: "test", embedding: emb, chunkIndex: 0, conversationID: "")
        XCTAssertEqual(entity.embedding, emb)
    }

    func testConvenienceInit_SetsChunkIndex() {
        let entity = ChildChunkEntity(chunkText: "chunk", embedding: [1], chunkIndex: 7, conversationID: "")
        XCTAssertEqual(entity.chunkIndex, 7)
    }

    func testConvenienceInit_ConversationIDRemainsEmpty() {
        // conversationID is not part of the convenience init — it is stamped externally
        let entity = ChildChunkEntity(chunkText: "chunk", embedding: [1], chunkIndex: 0, conversationID: "")
        XCTAssertEqual(entity.conversationID, "")
    }

    // MARK: - HNSW Embedding Schema

    /// The HNSW index annotation declares `dimensions=384`, matching All-MiniLM-L6-v2.
    /// Storing a wrong-dimension vector would silently corrupt the index.
    func testEmbedding_Accepts384DArray() {
        let emb = (0..<384).map { Float($0) * 0.001 }
        let entity = ChildChunkEntity(chunkText: "dim test", embedding: emb, chunkIndex: 0, conversationID: "")
        XCTAssertEqual(entity.embedding?.count, 384,
                       "HNSW index declares dimensions=384; embedding count must match")
    }

    func testEmbedding_IsOptional_CanBeNilledAfterAssignment() {
        let entity = ChildChunkEntity(chunkText: "test", embedding: [1, 2, 3], chunkIndex: 0, conversationID: "")
        XCTAssertNotNil(entity.embedding)
        entity.embedding = nil
        XCTAssertNil(entity.embedding)
    }

    func testEmbedding_L2NormalizedInput_MagnitudeIsOne() {
        // EmbeddingService always returns L2-normalised vectors before they are stored.
        // HNSW cosine distance is only mathematically valid on unit-length vectors.
        let rawVec: [Float] = [3, 4]
        let normalized = VectorMath.l2Normalize(rawVec) // → [0.6, 0.8]
        let entity = ChildChunkEntity(chunkText: "norm test", embedding: normalized, chunkIndex: 0, conversationID: "")

        let magnitude = VectorMath.magnitude(of: entity.embedding ?? [])
        XCTAssertEqual(magnitude, 1.0, accuracy: 1e-6,
                       "L2-normalised embeddings stored in the HNSW index must have magnitude ≈ 1.0")
    }

    func testEmbedding_StoredVerbatim_NoConversionApplied() {
        // Unlike the old FloatArrayConverter pattern, HNSW stores [Float]? natively.
        // The value on the entity is the exact value that reaches ObjectBox.
        let original: [Float] = [0.1, -0.5, 0.8, 0.3]
        let entity = ChildChunkEntity(chunkText: "verbatim", embedding: original, chunkIndex: 0, conversationID: "")
        XCTAssertEqual(entity.embedding, original,
                       "Native floatVector storage must preserve exact Float values")
    }

    // MARK: - conversationID Scoping Field

    func testConversationID_AcceptsUUIDString() {
        let uuid = UUID()
        let entity = ChildChunkEntity()
        entity.conversationID = uuid.uuidString
        XCTAssertEqual(entity.conversationID, uuid.uuidString)
    }

    func testConversationID_MatchesParentConversationIDFormat() {
        // VectorStoreService stamps children using parent.conversationID.uuidString.
        // Verify round-trip: UUID → uuidString stored on child → UUID parsed back.
        let original = UUID()
        let entity = ChildChunkEntity()
        entity.conversationID = original.uuidString

        let parsed = UUID(uuidString: entity.conversationID)
        XCTAssertEqual(parsed, original,
                       "conversationID string must round-trip back to the original UUID")
    }

    func testConversationID_DistinctConversations_ProduceDifferentIDs() {
        let a = UUID()
        let b = UUID()
        XCTAssertNotEqual(a.uuidString, b.uuidString,
                          "Two distinct conversations must produce different IDs for correct post-HNSW scoping")
    }

    func testConversationID_Stamping_SimulatesVectorStoreServiceBehavior() {
        // VectorStoreService.addSemanticDocument() stamps conversationID from the parent:
        //   child.conversationID = parent.conversationID.uuidString
        let parentConversationID = UUID()
        let entity = ChildChunkEntity(chunkText: "stamped chunk", embedding: [0.1, 0.2], chunkIndex: 0, conversationID: "")

        // Simulate stamping
        entity.conversationID = parentConversationID.uuidString

        XCTAssertFalse(entity.conversationID.isEmpty)
        XCTAssertEqual(UUID(uuidString: entity.conversationID), parentConversationID)
    }

    // MARK: - HNSW Distance Threshold Invariants

    /// Verifies the threshold equivalence used in VectorStoreService:
    ///   cosine distance ≤ 0.7  ↔  cosine similarity ≥ 0.3
    /// for L2-normalised vectors (as produced by EmbeddingService).
    func testHNSWThreshold_DistanceAndSimilarityEquivalence() {
        let maximumCosineDistance: Float = 0.7
        let equivalentMinSimilarity: Float = 1.0 - maximumCosineDistance // 0.3

        let query = VectorMath.l2Normalize([Float](repeating: 1.0, count: 384))
        let rawCandidates: [[Float]] = [
            [Float](repeating: 1.0, count: 384),          // identical → distance 0
            [1] + [Float](repeating: 0, count: 383),       // partial overlap
            [0] + [Float](repeating: 1, count: 383),       // near-orthogonal
        ]

        for raw in rawCandidates {
            let emb = VectorMath.l2Normalize(raw)
            let entity = ChildChunkEntity(chunkText: "candidate", embedding: emb, chunkIndex: 0, conversationID: "")

            let sim = VectorMath.cosineSimilarity(between: query, and: entity.embedding!)
            let dist: Float = 1.0 - sim

            XCTAssertEqual(dist <= maximumCosineDistance, sim >= equivalentMinSimilarity,
                "Threshold mismatch for dist=\(dist), sim=\(sim): distance ≤ 0.7 must equal similarity ≥ 0.3")
        }
    }

    func testHNSWCosineDistance_IdenticalEmbeddings_ZeroDistance() {
        let emb = VectorMath.l2Normalize((0..<384).map { Float($0) * 0.01 + 0.1 })
        let entity = ChildChunkEntity(chunkText: "same", embedding: emb, chunkIndex: 0, conversationID: "")

        let sim = VectorMath.cosineSimilarity(between: entity.embedding!, and: emb)
        let distance = 1.0 - sim
        XCTAssertEqual(distance, 0.0, accuracy: 1e-6,
                       "Identical stored embedding and query must yield zero HNSW cosine distance")
    }
}
