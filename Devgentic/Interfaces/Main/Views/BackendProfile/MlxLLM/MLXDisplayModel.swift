// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXDisplayModel.swift
//  Devgentic
//
//  Created by Raj Singh.
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
    
    /// User-facing name, separate from `rawValue`, which is for persistence and logging only. `Text(x.rawValue)` is not
    /// localized, so labels must come from here to reach the String Catalog.
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
    let createdAt: Date?   // Filesystem creation date, for sorting by recency
    /// Git commit this copy was downloaded at, read back from HubApi's own download metadata.
    /// Nil for imported models and anything downloaded before revision tracking.
    var revision: String?
}


/// A unified model representing a downloadable or installed item in the Store.
struct MLXDisplayModel: Identifiable, Hashable {
    let id: String               // e.g. "mlx-community/Llama-3.2..."
    var size: String?            // Display string only, e.g. "2.4 GB" — never parse this back

    /// The authoritative byte total; sort and fit assessment must use this, never `size`. `size` comes from a
    /// locale-aware formatter, so parsing it can corrupt the value ("2,4 GB" read as 24 GB).
    var sizeBytes: Int64?

    /// Bits-per-weight, parsed from the repo id. Nil when the publisher didn't encode one.
    /// Drives the quantization badge, the filter, and the RAM-fit estimate.
    var quantization: MLXQuantization?

    /// HuggingFace requires an access token (or the user has not accepted the licence). Labelled on the card but never
    /// disables the button, since the user may already have a token configured.
    var isGated: Bool = false

    /// HuggingFace's declared `pipeline_tag`. Only the remote-search mapping fills it in; nil
    /// means "unknown", which `ModelSupportPolicy` treats as supported.
    var pipelineTag: String? = nil

    // Metadata
    let capabilities: Set<MLXModelCapability>
    let tags: [String]
    let downloads: Int
    let likes: Int
    let description: String?
    var createdAt: Date?         // Filesystem creation date for installed models

    
    // UI Helpers

    /// Non-nil when Devgentic can never run this model (decision/classifier, speech, image…).
    var unsupportedReason: String? {
        ModelSupportPolicy.unsupportedReason(pipelineTag: pipelineTag, tags: tags)
    }

    var displayName: String {
        // "mlx-community/Llama-3.2-3B" -> "Llama-3.2-3B"
        return id.components(separatedBy: "/").last ?? id
    }
    
    var organization: String {
        // "mlx-community/Llama-3.2-3B" gives "mlx-community"; an id with no slash gives "" to avoid duplicating
        // `displayName`.
        let parts = id.components(separatedBy: "/")
        return parts.count > 1 ? parts[0] : ""
    }
}
