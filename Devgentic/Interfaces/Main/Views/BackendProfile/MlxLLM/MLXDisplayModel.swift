//
//  MLXDisplayModel.swift
//  Devgentic
//
//  Created by Raj Singh on 04/02/26.
//

import Foundation
import SwiftUI

/// Represents specific capabilities a model might have, used for UI badges.
enum MLXModelCapability: String, Codable, Hashable, CaseIterable {
    case reasoning = "Reasoning"      // e.g. DeepSeek-R1 (Chain of Thought)
    case toolUse = "Tool Use"         // e.g. Function Calling support
    case vision = "Vision"            // e.g. Image-to-Text
    case coding = "Coding"            // e.g. Specialized code models
    case textGeneration = "Chat"      // Standard text models
    
    /// User-facing name. ⚠️ Separate from `rawValue` on purpose: `Text(x.rawValue)` binds to
    /// the non-localizing `StringProtocol` overload, so every rawValue-sourced label was
    /// invisible to the String Catalog extractor and would have shipped untranslated inside
    /// otherwise-translated chrome. `rawValue` stays for persistence and logging only.
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .reasoning:      return "Reasoning"
        case .toolUse:        return "Tool Use"
        case .vision:         return "Vision"
        case .coding:         return "Coding"
        case .textGeneration: return "Chat"
        }
    }

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
    /// Git commit this copy was downloaded at, read back from HubApi's own download metadata.
    /// Nil for imported models and anything downloaded before revision tracking.
    var revision: String?
}


/// A unified model representing a downloadable or installed item in the Store.
struct MLXDisplayModel: Identifiable, Hashable {
    let id: String               // e.g. "mlx-community/Llama-3.2..."
    var size: String?            // Display string only, e.g. "2.4 GB" — never parse this back

    /// The authoritative byte total.
    ///
    /// ⚠️ Sort and fit-assessment MUST use this, never `size`. `size` comes from a
    /// locale-aware `ByteCountFormatter`, which emits "," as the decimal separator across
    /// most of Europe; the old parser kept only ASCII digits and ".", so the separator was
    /// *stripped rather than converted* and "2,4 GB" became 24 GB. On a German Mac that put
    /// a compatible 2.4 GB model past `effectiveBudget`, producing an `.incompatible`
    /// verdict and diverting the user into a "Model Too Large" sheet — capability metadata
    /// blocking an action on a number the code itself had corrupted.
    var sizeBytes: Int64?

    /// Bits-per-weight, parsed from the repo id. Nil when the publisher didn't encode one.
    /// Drives the quantization badge, the filter, and the RAM-fit estimate.
    var quantization: MLXQuantization?

    /// HuggingFace requires an access token (or the user hasn't accepted the licence).
    /// Labelled on the card, never used to disable the button — the user may well have a
    /// token configured, and gating on a listing flag would block a download that works.
    var isGated: Bool = false

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
