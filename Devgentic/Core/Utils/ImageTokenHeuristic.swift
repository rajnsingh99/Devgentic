//
//  ImageTokenHeuristic.swift
//  Devgentic
//
//  ONE shared answer to "roughly how much context does an image cost?".
//
//  WHY THIS EXISTS: every budget in the app used to measure images by the length
//  of their base64 string. A 1 MB screenshot scored ~1,370,000 characters against
//  an 8K–98K character budget, so a single image could appear to overflow a
//  context window ~14× over. Downstream that made the in-request compactor
//  (`compactNativeConversation`) evict every droppable tool exchange, hit its
//  keep-recent floor, and return 0 — shipping an over-budget request with no log.
//
//  Real image cost is roughly 1–2k tokens regardless of file size: a 6 MB PNG and
//  a 200 KB JPEG of the same scene tile identically. So we charge a flat, clamped,
//  token-realistic figure and refine it with pixel dimensions only where we can
//  read them cheaply (composer-side, from a file header — never a full decode).
//
//  These numbers are a WARNING GAUGE, not billing. They are deliberately coarse;
//  the goal is that the user sees a number at all where they previously saw zero.
//

import Foundation
import ImageIO

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

    /// Token estimate for ONE image.
    ///
    /// - Parameters:
    ///   - pixels: total pixel count (width × height) when known. `nil` → flat default.
    ///   - provider: the API the request will run against. Tokenization differs enough
    ///     between vendors to be worth a switch, but not enough to be worth precision.
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

    /// Chars-per-token used by the CHARACTER-denominated budgets.
    ///
    /// Deliberately NOT `PromptFitCheck.charsPerToken` (3.0). That constant converts
    /// chars→tokens for the advisory gauge; the budgets this weight feeds are built
    /// the other way round at 4 chars/token —
    /// `AgentConnect.charBudget = contextWindow * 0.6 * 4` and
    /// `nativeContextBudgetChars = contextWindow * 0.75 * 4`. Pricing an image at 3.0
    /// against a budget denominated at 4.0 reserved only 900 tokens' worth of room
    /// for a 1,200-token image — a systematic 25% under-charge.
    static let budgetCharsPerToken = 4.0

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
