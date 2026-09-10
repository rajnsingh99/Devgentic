// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  MessageBlock.swift
//  Devgentic
//
//  Multimodal Pipeline Migration — Phase 1A
//  Atomic unit of multimodal content, replacing String-based message boundaries.
//  All types are Sendable + Codable + Hashable — safe across actor boundaries.
//
//  Created by Raj Singh on 15/03/26.
//

import Foundation

// MARK: - Media Reference

/// Unified reference to binary media. Binary data lives on disk, never in message graphs.
/// `ephemeralData` is transient-only — must be flushed to disk via `MediaStore` before storage.
public enum MediaReference: Sendable, Codable, Hashable {
    case diskPath(URL)
    case remoteURL(URL)
    case ephemeralData(Data)

    /// Resolves to raw bytes. Loads from disk or returns ephemeral data directly.
    /// Remote URLs are not auto-fetched — callers must download and convert to diskPath first.
    public func resolve() async throws -> Data {
        switch self {
        case .diskPath(let url):
            return try Data(contentsOf: url)
        case .remoteURL:
            throw MediaReferenceError.remoteResolutionNotSupported
        case .ephemeralData(let data):
            return data
        }
    }
}

public enum MediaReferenceError: Error, LocalizedError {
    case remoteResolutionNotSupported

    public var errorDescription: String? {
        switch self {
        case .remoteResolutionNotSupported:
            return "Remote URL resolution requires explicit download via MediaStore. Convert to diskPath first."
        }
    }
}

// MARK: - Media Payloads

/// Image content payload. Reference-backed to avoid in-memory bloat.
public struct ImagePayload: Sendable, Codable, Hashable {
    public let reference: MediaReference
    public let mimeType: String            // "image/png", "image/jpeg", "image/webp"
    public let alt: String?                // Accessibility / description text
    public let width: Int?
    public let height: Int?

    public init(reference: MediaReference, mimeType: String, alt: String? = nil, width: Int? = nil, height: Int? = nil) {
        self.reference = reference
        self.mimeType = mimeType
        self.alt = alt
        self.width = width
        self.height = height
    }
}

/// Audio content payload (future-proofing).
public struct AudioPayload: Sendable, Codable, Hashable {
    public let reference: MediaReference
    public let mimeType: String
    public let durationSeconds: Double?

    public init(reference: MediaReference, mimeType: String, durationSeconds: Double? = nil) {
        self.reference = reference
        self.mimeType = mimeType
        self.durationSeconds = durationSeconds
    }
}

/// Video content payload (future-proofing).
public struct VideoPayload: Sendable, Codable, Hashable {
    public let reference: MediaReference
    public let mimeType: String
    public let durationSeconds: Double?
    public let thumbnailReference: MediaReference?

    public init(reference: MediaReference, mimeType: String, durationSeconds: Double? = nil, thumbnailReference: MediaReference? = nil) {
        self.reference = reference
        self.mimeType = mimeType
        self.durationSeconds = durationSeconds
        self.thumbnailReference = thumbnailReference
    }
}

// MARK: - MessageBlock

/// Represents a single atomic piece of multimodal content.
/// Mirrors modern frontier LLM API schemas (Anthropic, OpenAI, Gemini).
public enum MessageBlock: Sendable, Codable, Hashable {
    case text(String)
    case image(ImagePayload)
    case toolCall(id: String, name: String, arguments: [String: JSONValue])
    case toolResult(toolCallId: String, content: [MessageBlock])
    case audio(AudioPayload)
    case video(VideoPayload)

    /// Deterministic text projection for contexts that cannot handle media.
    /// Used by context compressors, working memory, and non-vision models.
    public var textFallback: String {
        switch self {
        case .text(let s):
            return s
        case .image(let payload):
            return "[Image: \(payload.alt ?? payload.mimeType)]"
        case .toolCall(_, let name, _):
            return "[Tool Call: \(name)]"
        case .toolResult(let id, let content):
            let inner = content.map(\.textFallback).joined(separator: "\n")
            return "[Tool Result \(id)]: \(inner)"
        case .audio(let payload):
            let dur = payload.durationSeconds.map { " (\(Int($0))s)" } ?? ""
            return "[Audio: \(payload.mimeType)\(dur)]"
        case .video(let payload):
            let dur = payload.durationSeconds.map { " (\(Int($0))s)" } ?? ""
            return "[Video: \(payload.mimeType)\(dur)]"
        }
    }
}

// MARK: - Payload Typealias & Extensions

/// A complete multimodal message payload — an ordered array of content blocks.
public typealias Payload = [MessageBlock]

extension Array where Element == MessageBlock {

    /// Concatenated text content from all text blocks.
    public var textContent: String {
        compactMap { block in
            if case .text(let s) = block { return s }
            return nil
        }.joined(separator: "\n")
    }

    /// All non-text media blocks.
    public var mediaBlocks: [MessageBlock] {
        filter {
            if case .text = $0 { return false }
            return true
        }
    }

    /// True if payload contains only text blocks.
    public var isTextOnly: Bool { mediaBlocks.isEmpty }
}
