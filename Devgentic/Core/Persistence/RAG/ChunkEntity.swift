// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChunkEntity.swift
//  Devgentic
//
//  Created by Raj Singh.
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
