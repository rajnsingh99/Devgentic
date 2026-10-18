// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  VisionImageFormat.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// Why: an unsupported image kept in history would 400 every later request in that conversation.
/// What image formats may be sent to a vision model, and under what MIME label.
/// Validates before serializing and omits (with a log) an unsupported image rather than send a rejected label.
enum VisionImageFormat {

    /// MIME types accepted by every vision provider the app targets: the true intersection, safe on any history
    /// payload. Narrower than any single provider: Gemini rejects `image/gif`, Anthropic and OpenAI reject heic/heif.
    static let supportedMimeTypes: Set<String> = [
        "image/jpeg", "image/png", "image/webp"
    ]

    /// Maps a file extension to a MIME type accepted by every targeted provider, or `nil` when it cannot be sent as-is.
    /// `nil` is a real answer, not an error: callers must omit and log rather than guess a label.
    static func mimeType(forExtension rawExtension: String) -> String? {
        switch rawExtension.lowercased() {
        case "jpg", "jpeg", "jpe", "jfif": return "image/jpeg"
        case "png":                        return "image/png"
        case "webp":                       return "image/webp"
        default:                           return nil
        }
    }

    /// Convenience for a named file (the history case, where `AttachedImageFile.name`
    /// carries the original filename) with a URL fallback.
    static func mimeType(forName name: String?, fallbackURL: URL?) -> String? {
        if let name, !name.isEmpty {
            let ext = (name as NSString).pathExtension
            if !ext.isEmpty { return mimeType(forExtension: ext) }
        }
        if let fallbackURL { return mimeType(forExtension: fallbackURL.pathExtension) }
        return nil
    }

    // Why: decide from the bytes, not the filename: a mislabelled HEIC file would otherwise 400 every later turn.
    /// Resolves image bytes to a format every targeted vision provider can load; the single choke point for builders.
    /// jpeg/png/webp pass through; other decodable containers transcode to JPEG; undecodable bytes return `nil`.
    static func resolveSendable(data: Data) -> (data: Data, mimeType: String, wasTranscoded: Bool)? {
        if let mime = ImageConstraints.supportedWebMimeType(for: data) {
            return (data, mime, false)
        }
        if let jpeg = ImageConstraints.transcodeToJPEG(data) {
            return (jpeg, "image/jpeg", true)
        }
        return nil
    }

    /// Whether a file with this extension can reach a vision model: already loadable (jpeg/png/webp) or transcoded to
    /// JPEG. A cheap extension-based proxy for the fit gauge's cost estimate only, never the wire decision
    /// (`resolveSendable`).
    static func isVisionEligible(fileExtension ext: String) -> Bool {
        visionEligibleExtensions.contains(ext.lowercased())
    }

    private static let visionEligibleExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "jfif", "png", "webp",   // ship as-is
        "heic", "heif", "tif", "tiff", "bmp", "gif"    // transcoded to jpeg
    ]
}
