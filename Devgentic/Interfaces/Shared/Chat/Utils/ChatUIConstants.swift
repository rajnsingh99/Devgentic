// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatUIConstants.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// Shared numeric constants for the chat UI, centralised so renderers and view models answer the same question the same
/// way.
enum ChatUIConstants {
    /// Line count above which a code block in a bubble is collapsed behind a "Show in viewer" affordance.
    /// Used by `ContentBlockView`, `AgentBubbleContentView` and the snippet selector in `ChatHistoryViewModel`.
    static let codeBlockLineLimit: Int = 50

    /// Minimum height applied to an actively-streaming agent bubble so
    /// incremental tokens don't cause layout thrash as the bubble grows.
    static let streamingBubbleMinHeight: CGFloat = 200

    /// Widest an image renders inline in a bubble; larger images scale down to fit.
    /// Full resolution lives behind `ImageLightbox`.
    static let imageMaxWidth: CGFloat = 500

    /// Placeholder height for an image that is still decoding or has failed, so the bubble
    /// doesn't jump when the picture arrives.
    static let imagePlaceholderMinHeight: CGFloat = 150

    /// Longest side of a user-attached image thumbnail in the user bubble, in points.
    /// Smaller than `imageMaxWidth`: a message can carry several photos, each a downsampled chip decoded in full only on
    /// tap.
    static let attachmentThumbnailPointSize: CGFloat = 120

    /// Tallest an inline code block grows before it scrolls internally.
    /// Without a cap a 50-line block would push the rest of the reply off screen; this only bites blocks just under
    /// `codeBlockLineLimit`.
    static let codeBlockMaxHeight: CGFloat = 420

    /// Tallest the expanded agent execution timeline grows before it scrolls internally.
    /// Keeps an agent run with many steps or tool calls from pushing the final response
    /// and subsequent messages far down the chat viewport.
    static let agentTimelineMaxHeight: CGFloat = 450

    /// Proportional max height for the expanded timeline given the user's `chatFontSize`.
    /// Preserves roughly 5–7 visible steps regardless of whether the user sets font size to 12 or 22.
    nonisolated static func agentTimelineMaxHeight(forChatFontSize chatFontSize: CGFloat) -> CGFloat {
        max(360, min(750, 450 * (chatFontSize / 15.0)))
    }

    /// Base point size for code. Scales with `chatFontSize` at the call site; this is the
    /// value used when no chat size is available.
    static let defaultCodeFontSize: CGFloat = 12

    // Why: `ErrorMessageView` and Markdown tables share the arithmetic, not the meaning; routing them here would restyle
    // prose.
    /// Code point size for a given chat prose size: one step below body prose, scaling with `chatFontSize`, floored at 10.
    /// The single source for code sizing across the chat renderers and workflow node output; `nonisolated` and pure so it is
    /// testable.
    nonisolated static func codeFontSize(forChatFontSize chatFontSize: CGFloat) -> CGFloat {
        max(10, chatFontSize - 2)
    }

    /// Narrowest the chat column may be squeezed by the Code Viewer's split mode before
    /// the inset stops growing (the panel then overlaps the difference, as overlay mode
    /// always did). Roughly the width at which message bubbles remain readable.
    static let splitModeMinChatWidth: CGFloat = 360

    /// Width of the Code Viewer's resize divider. Shared between the panel (which draws
    /// it) and the split-mode chat inset (which must account for it — insetting by the
    /// panel width alone left the chat flush against the divider edge).
    static let codeViewerDividerWidth: CGFloat = 4

    /// Breathing room between the chat column's trailing edge and the Code Viewer's
    /// divider in split mode.
    static let splitModeChatGutter: CGFloat = 16

    /// Horizontal space the minimized Code Viewer pill occupies at the top-trailing corner (its width plus the 18pt inset).
    /// The chat search bar reserves this while the pill shows, since capping to the content lane is not enough on a narrow
    /// window.
    static let codeViewerPillFootprint: CGFloat = 104

    /// Bounds for the Code Viewer's ⌘+/⌘− font stepping. The floor keeps code legible;
    /// the ceiling keeps a wrapped 1200pt panel from becoming a word-per-line column.
    static let codeViewerFontSizeRange: ClosedRange<Double> = 9...28

    /// ⌘0 reset target — matches the `codeEditFontSize` @AppStorage default.
    static let codeViewerDefaultFontSize: Double = 13
}
