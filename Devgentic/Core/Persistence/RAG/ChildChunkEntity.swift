// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChildChunkEntity.swift
//  Devgentic
//
//  Created by Raj Singh on 02/03/26.
//

import Foundation
import ObjectBox

/// An ObjectBox entity representing a specific vectorized chunk of a parent document.
/// These chunks are the primary index for HNSW vector similarity searches, leading back to the parent.
// objectbox: entity
final class ChildChunkEntity {

    // The unique ID for this entity, managed by ObjectBox.
    var id: Id = 0

    /// The actual text content of this specific chunk.
    var chunkText: String = ""

    /// The vector embedding for the `chunkText`, indexed with a native ObjectBox HNSW graph.
    ///
    /// Hyperparameter rationale (per HNSW analysis for All-MiniLM-L6-v2, 384-dim, mixed text+code):
    /// - dimensions=384:            Matches the All-MiniLM-L6-v2 output dimensionality exactly.
    /// - neighborsPerNode=48:       Fortified M value to create long-range escape edges out of hyper-dense
    ///                              code clusters, neutralising the structural hubness problem.
    /// - indexingSearchCount=200:   Elevated efConstruction ensures optimal edge selection during background
    ///                              ingestion, maximising recall at query time.
    /// - distanceType="cosine":     Aligns with the contrastive-loss training objective of sentence-transformers.
    ///                              Mathematically equivalent to dotProduct on L2-normalised vectors (as
    ///                              produced by EmbeddingService), but maps efficiently to Apple Silicon SIMD.
    /// - vectorCacheHintSizeKB=524288: Caps the in-RAM HNSW graph at 512 MB, protecting against iOS Jetsam
    ///                              terminations on standard (non-Pro) devices with constrained unified memory.
    // objectbox:hnswIndex: dimensions=384, neighborsPerNode=48, indexingSearchCount=200, distanceType="cosine", vectorCacheHintSizeKB=524288
    var embedding: [Float]?

    /// The sequential order of this chunk within the parent document.
    var chunkIndex: Int = 0

    /// Denormalised conversation ID (mirrors ParentDocumentEntity.conversationID as a String).
    /// The scoped retrieval scan filters on this key, so an EMPTY value makes a chunk
    /// invisible to every conversation. Required at construction (convenience init) and
    /// re-stamped from the parent in `VectorStoreService.addSemanticDocument` (the parent
    /// is the authority) — the "" default exists only for ObjectBox's parameterless `init()`.
    var conversationID: String = ""

    /// Relation back to the complete parent document.
    var parentDocument: ToOne<ParentDocumentEntity> = nil

    /// The default initializer required by ObjectBox.
    init() {}

    /// A convenience initializer for creating new ChildChunkEntity instances.
    /// `conversationID` is REQUIRED (no default): a writer that forgets it would produce
    /// chunks silently invisible to scoped retrieval. Pass "" only when scoping is
    /// genuinely irrelevant (entity-level tests) — explicitly, never by omission.
    init(chunkText: String, embedding: [Float], chunkIndex: Int, conversationID: String) {
        self.chunkText = chunkText
        self.embedding = embedding
        self.chunkIndex = chunkIndex
        self.conversationID = conversationID
    }
}
