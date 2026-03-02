//
//  ChildChunkEntity.swift
//  Devgentic
//
//  Created by Raj Singh on 02/03/26.
//

import Foundation
import ObjectBox

/// An ObjectBox entity representing a specific vectorized chunk of a parent document.
/// These chunks are used strictly for similarity searches, leading back to the parent.
// objectbox: entity
final class ChildChunkEntity {
    
    // The unique ID for this entity, managed by ObjectBox.
    var id: Id = 0
    
    /// The actual text content of this specific chunk.
    var chunkText: String = ""
    
    /// The vector embedding for the `chunkText`. This is the key for similarity searches.
    /// Note: Relies on `FloatArrayConverter` defined in your project (currently in ChunkEntity.swift).
    // objectbox: convert = { "dbType": "Data", "converter": "FloatArrayConverter" }
    var embedding: [Float] = []
    
    /// The sequential order of this chunk within the parent document.
    var chunkIndex: Int = 0
    
    /// Relation back to the complete parent document.
    /// ToOne represents a 1-to-N relationship back to the parent in ObjectBox.
    var parentDocument: ToOne<ParentDocumentEntity> = nil
    
    /// The default initializer required by ObjectBox.
    init() {}
    
    /// A convenience initializer for creating new ChildChunkEntity instances.
    init(chunkText: String, embedding: [Float], chunkIndex: Int) {
        self.chunkText = chunkText
        self.embedding = embedding
        self.chunkIndex = chunkIndex
    }
}
