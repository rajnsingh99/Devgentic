//
//  AttachedFileModels.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// A struct representing a text file attached to a chat message.
struct AttachedTextFile: Codable, Equatable, Identifiable {
    var id = UUID()
    let name: String
    let url: URL
    let fileExtension: String
    let content: String
    let size: Int64 // Size in bytes

    static func == (lhs: AttachedTextFile, rhs: AttachedTextFile) -> Bool {
        return lhs.id == rhs.id && lhs.url == rhs.url
    }
}

/// A struct representing an image file attached to a chat message.
struct AttachedImageFile: Codable, Equatable, Identifiable {
    var id = UUID()
    let name: String
    let url: URL
    let fileExtension: String
    let binaryData: Data
    let size: Int64 // Size in bytes

    static func == (lhs: AttachedImageFile, rhs: AttachedImageFile) -> Bool {
        return lhs.id == rhs.id && lhs.url == rhs.url
    }
}
