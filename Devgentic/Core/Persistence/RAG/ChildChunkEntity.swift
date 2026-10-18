// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChildChunkEntity.swift
//  Devgentic
//
//  Created by Raj Singh.
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

    /// The vector embedding for `chunkText`, indexed with a native ObjectBox HNSW graph (384-dim All-MiniLM-L6-v2, cosine,
    /// 48 neighbors per node, 200 indexing search count). The in-RAM graph is capped at 512 MB (`vectorCacheHintSizeKB`).
    // objectbox:hnswIndex: dimensions=384, neighborsPerNode=48, indexingSearchCount=200, distanceType="cosine", vectorCacheHintSizeKB=524288
    var embedding: [Float]?

    /// The sequential order of this chunk within the parent document.
    var chunkIndex: Int = 0

    /// Denormalised conversation ID (mirrors `ParentDocumentEntity.conversationID`), indexed because every retrieval,
    /// delete and replace selects by it. Empty makes a chunk invisible to scoped retrieval; the parent is the authority.
    // objectbox: index
    var conversationID: String = ""

    /// This chunk's BM25 tokens (`VectorStoreService.bm25Tokens`), space-delimited with leading and trailing spaces so a
    /// whole-token match is a byte search for `" term "`. Stored once; "" ranks by tokenising `chunkText` on the fly.
    var bm25Terms: String = ""

    /// Token count of `bm25Terms` — BM25's document length.
    var bm25Length: Int = 0

    /// Relation back to the complete parent document.
    var parentDocument: ToOne<ParentDocumentEntity> = nil

    /// The default initializer required by ObjectBox.
    init() {}

    /// A convenience initializer for new chunks. `conversationID` is required: a chunk without it is invisible to scoped
    /// retrieval. Pass "" only when scoping is irrelevant (entity-level tests).
    init(chunkText: String, embedding: [Float], chunkIndex: Int, conversationID: String) {
        self.chunkText = chunkText
        self.embedding = embedding
        self.chunkIndex = chunkIndex
        self.conversationID = conversationID
        let document = VectorStoreService.bm25Document(for: chunkText)
        self.bm25Terms = document.terms
        self.bm25Length = document.length
    }
}
