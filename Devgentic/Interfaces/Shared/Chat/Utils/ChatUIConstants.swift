//
//  ChatUIConstants.swift
//  Devgentic
//
//  Shared numeric constants for the chat UI. Centralised so a change here
//  propagates to every renderer/viewmodel that asks the same question
//  ("is this code block long?", "how tall should a streaming bubble be?")
//  instead of drifting between three different copies of the same literal.
//

import SwiftUI

enum ChatUIConstants {
    /// Line count above which a code block in a message bubble is collapsed
    /// behind a "Show in viewer" affordance instead of being inlined.
    /// Used by `ContentBlockView`, `AgentBubbleContentView`, and the
    /// "open in code viewer" snippet selector in `ChatHistoryViewModel`.
    static let codeBlockLineLimit: Int = 50

    /// Minimum height applied to an actively-streaming agent bubble so
    /// incremental tokens don't cause layout thrash as the bubble grows.
    static let streamingBubbleMinHeight: CGFloat = 200

    /// Widest an image renders inline in a bubble. Anything larger is scaled down to fit,
    /// so full resolution lives behind `ImageLightbox`.
    ///
    /// Was duplicated as a bare `500` in four renderers and a `512` in a fifth, which made
    /// the same image a different size depending on which code path produced it.
    static let imageMaxWidth: CGFloat = 500

    /// Placeholder height for an image that is still decoding or has failed, so the bubble
    /// doesn't jump when the picture arrives.
    static let imagePlaceholderMinHeight: CGFloat = 150

    /// Longest side of a user-attached image THUMBNAIL in the user bubble (points).
    /// Deliberately smaller than `imageMaxWidth`: a message can carry several attached
    /// photos, and each stays a downsampled chip (`ImageDownsampler`) — full resolution
    /// lives behind `ImageLightbox`, decoded only on tap.
    static let attachmentThumbnailPointSize: CGFloat = 120

    /// Tallest an inline code block grows before it scrolls internally.
    ///
    /// Without a cap a 50-line block rendered its full ~780pt, pushing the rest of the
    /// reply — and the next message — off screen. 50 lines is also the point where a block
    /// becomes a card instead (`codeBlockLineLimit`), so this only ever bites blocks just
    /// under that line: tall enough to read a whole short function, short enough that the
    /// conversation stays navigable.
    static let codeBlockMaxHeight: CGFloat = 420

    /// Base point size for code. Scales with `chatFontSize` at the call site; this is the
    /// value used when no chat size is available.
    static let defaultCodeFontSize: CGFloat = 12
}
