// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  VisionImageFormat.swift
//  Devgentic
//
//  What image formats may be sent to a vision model, and under what MIME label.
//
//  WHY AN ALLOWLIST: the vision APIs accept a NARROW set — Anthropic documents
//  jpeg/png/gif/webp and 400s on anything else. macOS, meanwhile, hands us HEIC by
//  default from the Photos library and the camera, and `FileProcessorService`
//  happily classifies HEIC/TIFF/BMP as images because they conform to `UTType.image`.
//
//  That mismatch was survivable while images only ever rode the CURRENT turn: one
//  request failed and the user could retry with a different file. Once prior-turn
//  images ride the history payload (see `HistoryTurn`), an unsupported image becomes
//  a permanent member of every subsequent request in that conversation — so a single
//  HEIC screenshot would 400 the chat forever, with the failure surfacing as an
//  opaque provider error rather than anything pointing at the image.
//
//  Hence: validate BEFORE serializing, and omit-with-a-log rather than send a label
//  we know will be rejected. Omitting one image degrades an answer; sending it
//  breaks the conversation.
//

import Foundation

enum VisionImageFormat {

    /// MIME types accepted by EVERY vision provider the app targets — the true
    /// INTERSECTION, so one list is safe to send on any provider's history payload.
    ///
    /// ⚠️ It is NOT "Anthropic's set": the intersection is narrower than any single
    /// provider, because they disagree at the edges —
    ///   • Gemini REJECTS `image/gif` (accepts png/jpeg/webp/heic/heif);
    ///   • Anthropic & OpenAI REJECT heic/heif (accept png/jpeg/gif/webp).
    /// Intersection = jpeg ∩ png ∩ webp. `gif` was included once and would have
    /// permanently 400'd a Gemini conversation the moment a prior-turn gif replayed.
    /// A per-provider widening (gif on Anthropic/OpenAI, heic on Gemini) can come
    /// later; for the poison-prevention history path, the conservative shared set is
    /// the correct default.
    static let supportedMimeTypes: Set<String> = [
        "image/jpeg", "image/png", "image/webp"
    ]

    /// Maps a file extension to a MIME type accepted by every targeted provider, or
    /// `nil` when the format cannot be sent as-is on the shared path.
    ///
    /// `nil` is a real answer, not an error: HEIC/HEIF/TIFF/BMP/GIF are legitimate
    /// image files that at least one target API rejects. Callers must omit and log
    /// rather than guess a label — guessing is what produced "declared JPEG, actually
    /// HEIC" 400s, and sending `image/gif` to Gemini is the same failure class.
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

    /// A raw image resolved to something every targeted vision provider can actually
    /// load — the SINGLE choke point every image builder (current-turn and history)
    /// routes through, so the policy lives in exactly one place. The decision is made
    /// from the REAL container sniffed out of the BYTES, never the filename:
    ///   • bytes are genuinely jpeg/png/webp → the original bytes, untouched
    ///     (`wasTranscoded=false`);
    ///   • any other DECODABLE container (HEIC/HEIF/TIFF/BMP/GIF/…) → a JPEG transcode
    ///     (`wasTranscoded=true`) — relabelling won't help (Ollama can't decode HEIC
    ///     bytes; Anthropic/OpenAI reject the format), only re-encoding does;
    ///   • undecodable bytes → `nil`, meaning OMIT + log: degrading one image beats
    ///     400-ing the whole request.
    ///
    /// WHY byte-based, not extension-based: a file named `photo.jpg` that actually holds
    /// HEIC bytes (rename, bad export tool) would pass a name check and then 400 — the
    /// exact "declared JPEG, actually HEIC" failure this module exists to prevent, and on
    /// the history path it 400s EVERY later turn. Sniffing the container closes that, and
    /// also catches a corrupt file under a supported extension (undecodable → omit, not a
    /// garbage payload). The ImageIO work lives in `ImageConstraints`; this stays the
    /// format-policy owner and just delegates.
    static func resolveSendable(data: Data) -> (data: Data, mimeType: String, wasTranscoded: Bool)? {
        if let mime = ImageConstraints.supportedWebMimeType(for: data) {
            return (data, mime, false)
        }
        if let jpeg = ImageConstraints.transcodeToJPEG(data) {
            return (jpeg, "image/jpeg", true)
        }
        return nil
    }

    /// Whether a file with this extension can be put in front of a vision model at all —
    /// either already-loadable (jpeg/png/webp) or transcoded to JPEG on the way out
    /// (HEIC/HEIF/TIFF/BMP/GIF). Used by the pre-flight FIT GAUGE to count image cost that
    /// will ACTUALLY ship, now that the send path transcodes rather than omits. This is a
    /// cheap extension-based proxy for a cost ESTIMATE only — never the wire decision,
    /// which is `resolveSendable`'s byte-truthful check.
    static func isVisionEligible(fileExtension ext: String) -> Bool {
        visionEligibleExtensions.contains(ext.lowercased())
    }

    private static let visionEligibleExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "jfif", "png", "webp",   // ship as-is
        "heic", "heif", "tif", "tiff", "bmp", "gif"    // transcoded to jpeg
    ]
}
