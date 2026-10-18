// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MediaArtifact.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// MARK: - Media Kind

// Why: `MediaArtifact` persists in a blob with no `.unknown` catch-all; a throwing decode loses the message on the next save.
/// Classification of media artifacts; an unrecognised raw value is preserved, not rejected.
public enum MediaKind: RawRepresentable, Sendable, Codable, Hashable {
    case image
    case audio
    case video
    case document
    /// A kind written by a newer build, carried verbatim so re-encoding preserves it.
    case other(String)

    public init?(rawValue: String) {
        switch rawValue {
        case "image":    self = .image
        case "audio":    self = .audio
        case "video":    self = .video
        case "document": self = .document
        default:         self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .image:          return "image"
        case .audio:          return "audio"
        case .video:          return "video"
        case .document:       return "document"
        case .other(let raw): return raw
        }
    }
}

// MARK: - Media Artifact

/// A completed media artifact produced during agent execution.
/// References binary data on disk via `MediaReference` — never holds raw bytes.
public struct MediaArtifact: Sendable, Codable, Identifiable, Hashable {
    public let id: UUID
    public let kind: MediaKind
    public let reference: MediaReference
    public let mimeType: String
    public let label: String?                   // Human-readable label ("Generated chart", "Screenshot")
    public let metadata: [String: JSONValue]    // Extensible (dimensions, model used, etc.)
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: MediaKind,
        reference: MediaReference,
        mimeType: String,
        label: String? = nil,
        metadata: [String: JSONValue] = [:],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.reference = reference
        self.mimeType = mimeType
        self.label = label
        self.metadata = metadata
        self.createdAt = createdAt
    }
}
