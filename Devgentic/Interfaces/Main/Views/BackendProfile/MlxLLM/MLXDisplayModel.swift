//
//  MLXDisplayModel.swift
//  Devgentic
//
//  Created by Raj Singh on 04/02/26.
//

import Foundation

/// Represents specific capabilities a model might have, used for UI badges.
enum MLXModelCapability: String, Codable, Hashable, CaseIterable {
    case reasoning = "Reasoning"      // e.g. DeepSeek-R1 (Chain of Thought)
    case toolUse = "Tool Use"         // e.g. Function Calling support
    case vision = "Vision"            // e.g. Image-to-Text
    case coding = "Coding"            // e.g. Specialized code models
    case textGeneration = "Chat"      // Standard text models
    
    var icon: String {
        switch self {
        case .reasoning: return "brain.head.profile"
        case .toolUse: return "hammer.fill"
        case .vision: return "eye.fill"
        case .coding: return "chevron.left.forwardslash.chevron.right"
        case .textGeneration: return "bubble.left.and.bubble.right.fill"
        }
    }
}

// MARK: - Data Model
struct MLXModelItem: Identifiable, Hashable {
    let id: String         // Folder Name
    let displayName: String // Readable Name (e.g. "mlx-community/Llama-3...")
    let localPath: URL
    let createdAt: Date?   // Filesystem creation date — used to sort by recency
}


/// A unified model representing a downloadable or installed item in the Store.
struct MLXDisplayModel: Identifiable, Hashable {
    let id: String               // e.g. "mlx-community/Llama-3.2..."
    var size: String?            // e.g. "2.4 GB"

    // Metadata
    let capabilities: Set<MLXModelCapability>
    let tags: [String]
    let downloads: Int
    let likes: Int
    let description: String?
    var createdAt: Date?         // Filesystem creation date for installed models
    
    // UI Helpers
    var displayName: String {
        // "mlx-community/Llama-3.2-3B" -> "Llama-3.2-3B"
        return id.components(separatedBy: "/").last ?? id
    }
    
    var organization: String {
        // "mlx-community/Llama-3.2-3B" -> "mlx-community"
        // "bodega-raptor-90m" (no slash) -> "" — avoid duplicating displayName,
        // since .first and .last on a 1-element split return the same string.
        let parts = id.components(separatedBy: "/")
        return parts.count > 1 ? parts[0] : ""
    }
}
