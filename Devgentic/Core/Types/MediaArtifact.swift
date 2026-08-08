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
/// ⚠️ Hand-written `RawRepresentable` so an unrecognised kind is PRESERVED, not rejected.
///
/// `MediaKind` rides two persisted blobs, and the second one is why this matters most:
/// `MediaArtifact` reaches `ChatMessageSD.contentData` through `MessageContent.mediaArtifact`, and
/// **that path has no `.unknown` catch-all** — unlike the timeline blob. Before this, one
/// unrecognised kind threw, the whole message decoded to a "Decode Error" card, and the next save
/// re-encoded that card over the original bytes. Permanent loss, from a single new enum case.
///
/// The stdlib's `RawRepresentable where RawValue == String` conformances win over
/// enum-with-associated-value synthesis, so `Codable` is byte-identical to the previous `: String`
/// form, and `Equatable`/`Hashable` still compare `rawValue`. No call site changes.
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
