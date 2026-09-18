// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh

import Foundation

/// Shared multimodal-translation helpers for the cloud providers (audit #14).
///
/// Each provider used to hand-roll the same loop: walk a message's `MessageBlock`s,
/// resolve image bytes to base64, and project unsupported blocks to text — differing
/// only in the JSON shape of a text/image part. That shared skeleton lives here; the
/// providers supply only the per-part formatting.
enum MultimodalTranslator {

    /// Resolves an image block's bytes and returns its `(mimeType, base64)`.
    /// Resolution can throw (file gone/unreadable); the error propagates to the caller
    /// (node failure / chat error) rather than silently dropping the image.
    static func resolveImageBase64(_ image: ImagePayload) async throws -> (mimeType: String, base64: String) {
        let data = try await image.reference.resolve()
        return (image.mimeType, data.base64EncodedString())
    }

    /// Walks a message's content blocks into provider-shaped JSON parts.
    ///
    /// Shares the block iteration, image resolution, empty-text skipping, and the
    /// text-projection of non-text/non-image blocks (`textFallback`). The provider
    /// supplies only the JSON shape of a text part and a resolved-image part.
    static func translateBlocks(
        _ content: [MessageBlock],
        text makeText: (String) -> [String: Any],
        image makeImage: (_ mimeType: String, _ base64: String) -> [String: Any]
    ) async throws -> [[String: Any]] {
        var parts: [[String: Any]] = []
        for block in content {
            switch block {
            case .text(let string):
                if !string.isEmpty { parts.append(makeText(string)) }
            case .image(let image):
                let (mimeType, base64) = try await resolveImageBase64(image)
                parts.append(makeImage(mimeType, base64))
            default:
                // audio/video/tool blocks aren't sent natively here — project to text.
                let fallback = block.textFallback
                if !fallback.isEmpty { parts.append(makeText(fallback)) }
            }
        }
        return parts
    }
}
