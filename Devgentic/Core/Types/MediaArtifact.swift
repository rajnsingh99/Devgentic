//
//  MediaArtifact.swift
//  Devgentic
//
//  Multimodal Pipeline Migration — Phase 1A
//  Represents a completed media artifact produced by tool execution.
//  Carried through ToolExecutionResult, streamed via AgentStreamEvent,
//  stored in MemoryAction, and rendered by ChatBubbleView.
//
//  Created by Raj Singh on 15/03/26.
//

import Foundation

// MARK: - Media Kind

/// Classification of media artifacts.
public enum MediaKind: String, Sendable, Codable, Hashable {
    case image
    case audio
    case video
    case document
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
