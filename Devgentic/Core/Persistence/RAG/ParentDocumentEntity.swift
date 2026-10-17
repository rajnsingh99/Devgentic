// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ParentDocumentEntity.swift
//  Devgentic
//
//  Created by Raj Singh on 02/03/26.
//

import Foundation
import ObjectBox

/// An ObjectBox entity representing the full original message text to preserve complete context.
/// This acts as the parent in the relational schema, preventing context tearing during RAG retrieval.
// objectbox: entity
final class ParentDocumentEntity {
    
    // The unique ID for this entity, managed by ObjectBox.
    var id: Id = 0
    
    /// A reference to the original ChatMessage this document belongs to.
    /// Note: Relies on `UUIDConverter` defined in your project (currently in ChunkEntity.swift).
    // objectbox: convert = { "dbType": "String", "converter": "UUIDConverter" }
    var sourceMessageID: UUID = UUID()
    
    /// A reference to the Conversation this document belongs to.
    /// This is crucial for scoping vector searches to the correct conversation.
    // objectbox: convert = { "dbType": "String", "converter": "UUIDConverter" }
    var conversationID: UUID = UUID()
    
    /// The actual full text content of the message or file.
    var fullTextContent: String = ""

    /// The timestamp when this document was ingested.
    var timestamp: Date = Date()

    /// Stable identity of the indexed source within its conversation — a file path
    /// for attachments, the message UUID string for chat turns. Enables
    /// replace-on-reindex (delete prior copies before re-adding) so re-attached
    /// files and re-finalized messages don't accumulate duplicate vectors.
    /// Empty for rows written before this field existed.
    ///
    /// INDEXED (RAG-9): replace-on-reindex selects prior copies by this key.
    // objectbox: index
    var sourceIdentifier: String = ""

    /// The default initializer required by ObjectBox.
    init() {}

    /// A convenience initializer for creating new ParentDocumentEntity instances.
    init(sourceMessageID: UUID, conversationID: UUID, fullTextContent: String, timestamp: Date = Date(), sourceIdentifier: String = "") {
        self.sourceMessageID = sourceMessageID
        self.conversationID = conversationID
        self.fullTextContent = fullTextContent
        self.timestamp = timestamp
        self.sourceIdentifier = sourceIdentifier
    }
}
