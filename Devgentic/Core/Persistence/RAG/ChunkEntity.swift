//
//  ChunkEntity.swift
//  Devgentic
//
//  Created by Raj Singh on 13/07/25.
//

import Foundation
import ObjectBox

/// A custom property converter to store a UUID as a String.
final class UUIDConverter {
    typealias PropertyType = UUID
    typealias DatabaseType = String

    // UPDATED: Removed the external 'entityProperty' argument label.
    static func convert(_ entityProperty: UUID) -> String {
        return entityProperty.uuidString
    }

    // UPDATED: Removed the external 'databaseValue' argument label.
    static func convert(_ databaseValue: String?) -> UUID {
        guard let value = databaseValue, let uuid = UUID(uuidString: value) else {
            // Return a default or new UUID if the database value is nil or invalid.
            // This is important for data integrity, especially with non-optional properties.
            return UUID()
        }
        return uuid
    }
}


/// A custom property converter to store an array of Floats as Data in ObjectBox.
/// ObjectBox does not natively support array properties, so this conversion is necessary.
final class FloatArrayConverter {
    typealias PropertyType = [Float]
    typealias DatabaseType = Data

    // UPDATED: Removed the external 'entityProperty' argument label.
    static func convert(_ entityProperty: [Float]) -> Data {
        // Convert the [Float] array into raw Data.
        return entityProperty.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // UPDATED: Removed the external 'databaseValue' argument label.
    static func convert(_ databaseValue: Data?) -> [Float] {
        guard let data = databaseValue else { return [] }
        
        // Create a [Float] array from the raw Data.
        return data.withUnsafeBytes { buffer in
            // Ensure the buffer is safely bound to Float type.
            Array(buffer.bindMemory(to: Float.self))
        }
    }
}


/// An ObjectBox entity representing a single chunk of text and its corresponding vector embedding.
// objectbox: entity
final class ChunkEntity {
    
    // The unique ID for this entity, managed by ObjectBox.
    var id: Id = 0
    
    /// A reference to the original ChatMessage this chunk belongs to.
    /// This property uses the `UUIDConverter` to be stored as a `String` in the database.
    // objectbox: convert = { "dbType": "String", "converter": "UUIDConverter" }
    var sourceMessageID: UUID = UUID()
    
    /// A reference to the Conversation this chunk belongs to.
    /// This is crucial for scoping vector searches to the correct conversation.
    // objectbox: convert = { "dbType": "String", "converter": "UUIDConverter" }
    var conversationID: UUID = UUID()
    
    /// The actual text content of this chunk.
    var content: String = ""
    
    /// The vector embedding for the `content`. This is the key for similarity searches.
    /// This property uses the `FloatArrayConverter` to be stored as `Data` in the database.
    // objectbox: convert = { "dbType": "Data", "converter": "FloatArrayConverter" }
    var embedding: [Float] = []
    
    /// The timestamp when this chunk was created.
    var timestamp: Date = Date()
    
    /// The default initializer required by ObjectBox.
    init() {}
    
    /// A convenience initializer for creating new ChunkEntity instances.
    init(sourceMessageID: UUID, conversationID: UUID, content: String, embedding: [Float], timestamp: Date = Date()) {
        self.sourceMessageID = sourceMessageID
        self.conversationID = conversationID
        self.content = content
        self.embedding = embedding
        self.timestamp = timestamp
    }
}
