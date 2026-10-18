// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ImageTokenHeuristic.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import ImageIO

/// One shared estimate of how much context an image costs: a flat, clamped, token-realistic figure
/// refined by pixel dimensions. A warning gauge, not billing; measuring by base64 length would make a
/// single image look like a context overflow.
enum ImageTokenHeuristic {

    /// Fallback cost when dimensions are unknown — the common case for history
    /// images, whose bytes we refuse to decode just to price them.
    static let defaultTokensPerImage = 1_200

    /// Ceiling for a single image. Anthropic caps around ~1,600 tokens per image
    /// after its own downscaling; the clamp keeps a mis-read dimension from
    /// poisoning a budget.
    static let maxTokensPerImage = 2_500

    /// Floor for a very small image (icons, avatars) so they are never free.
    static let minTokensPerImage = 85

    // MARK: - Per-image cost

    /// Token estimate for one image.
    /// - Parameters: `pixels` is width x height when known (`nil` uses the flat default); `provider` is the
    /// target API.
    static func tokens(pixels: Int?, provider: ApiProvider?) -> Int {
        guard let pixels, pixels > 0 else { return defaultTokensPerImage }

        let raw: Int
        switch provider {
        case .anthropic:
            // Anthropic's own documented approximation.
            raw = pixels / 750
        case .google:
            // Gemini bills images in fixed 258-token tiles of 768×768.
            let tiles = max(1, Int((Double(pixels) / (768.0 * 768.0)).rounded(.up)))
            raw = tiles * 258
        case .openAI, .openRouter, .openAICompatible:
            // OpenAI: 85 base + 170 per 512×512 tile.
            let tiles = max(1, Int((Double(pixels) / (512.0 * 512.0)).rounded(.up)))
            raw = 85 + tiles * 170
        case .ollama, .mlx, .none:
            // Local vision models vary wildly; a flat figure is as good as a guess.
            return defaultTokensPerImage
        }
        return min(max(raw, minTokensPerImage), maxTokensPerImage)
    }

    /// Token estimate for a set of images whose dimensions are unknown.
    static func tokens(imageCount: Int, provider: ApiProvider? = nil) -> Int {
        guard imageCount > 0 else { return 0 }
        return imageCount * tokens(pixels: nil, provider: provider)
    }

    // MARK: - Char-denominated budgets

    /// Chars-per-token for the character-denominated budgets.
    /// Tracks `PromptFitCheck.charsPerToken` so image pricing always matches the denomination of the
    /// budgets it is spent against.
    static var budgetCharsPerToken: Double { PromptFitCheck.charsPerToken }

    /// Char-equivalent weight, for the budgets that count characters rather than
    /// tokens (`NativeHistoryConverter.charBudget`, `approximateTurnChars`).
    static func budgetChars(imageCount: Int) -> Int {
        guard imageCount > 0 else { return 0 }
        return Int(Double(tokens(imageCount: imageCount)) * budgetCharsPerToken)
    }

    /// Char-equivalent weight for a single image inside an already-serialized turn.
    static var budgetCharsPerImage: Int { budgetChars(imageCount: 1) }

    // MARK: - Cheap dimension probe

    /// Reads pixel dimensions from an image file's HEADER — no full decode, no
    /// bytes held. Returns `nil` for unreadable/unsupported files; callers fall
    /// back to the flat estimate rather than dropping the image from the tally.
    static func pixelCount(of url: URL) -> Int? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        return width * height
    }
}
