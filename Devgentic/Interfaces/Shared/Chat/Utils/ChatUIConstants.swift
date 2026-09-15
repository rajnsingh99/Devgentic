// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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

    /// Tallest the expanded agent execution timeline grows before it scrolls internally.
    /// Keeps an agent run with many steps or tool calls from pushing the final response
    /// and subsequent messages far down the chat viewport.
    static let agentTimelineMaxHeight: CGFloat = 300

    /// Proportional max height for the expanded timeline given the user's `chatFontSize`.
    /// Preserves roughly 5–7 visible steps regardless of whether the user sets font size to 12 or 22.
    nonisolated static func agentTimelineMaxHeight(forChatFontSize chatFontSize: CGFloat) -> CGFloat {
        max(240, min(500, 300 * (chatFontSize / 15.0)))
    }

    /// Base point size for code. Scales with `chatFontSize` at the call site; this is the
    /// value used when no chat size is available.
    static let defaultCodeFontSize: CGFloat = 12

    /// Code point size for a given chat prose size (register XUI-8).
    ///
    /// Code sits one step BELOW body prose, but it MOVES with `chatFontSize` — a reader at 20pt prose
    /// getting 12pt code with no way to change it was the defect this formula was introduced to fix
    /// on the chat side. Floored at 10 so the smallest prose setting (12) still yields legible code.
    ///
    /// ⚠️ SINGLE SOURCE for CODE sizing. The arithmetic was copy-pasted into two views
    /// (`ContentBlockView`, `AgentBubbleContentView`), and the workflow node output — the one code
    /// surface that never got the copy — silently pinned code at the 12pt default while its own
    /// prose and tables scaled. Three callers now, two of them former copies. `nonisolated` and pure
    /// so the rule is testable; a `private var` on a SwiftUI view is not.
    ///
    /// ⚠️ Two sites share this ARITHMETIC without sharing its MEANING, and are deliberately left
    /// alone — routing them here would make a later change to the code rule silently restyle prose:
    ///   • `ErrorMessageView`'s suggestion line is `max(10, chatFontSize - 2)` prose, not code.
    ///   • Markdown tables floor at 11, not 10, and that asymmetry is pre-existing.
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

    /// Horizontal space the minimized Code Viewer pill occupies at the top-trailing corner
    /// (its own width plus the 18pt inset it floats at). The chat search bar reserves this
    /// while the pill is showing: capping the bar to the content lane is not enough on a
    /// narrow window, where the centred bar's right edge still reaches under the pill.
    static let codeViewerPillFootprint: CGFloat = 104

    /// Bounds for the Code Viewer's ⌘+/⌘− font stepping. The floor keeps code legible;
    /// the ceiling keeps a wrapped 1200pt panel from becoming a word-per-line column.
    static let codeViewerFontSizeRange: ClosedRange<Double> = 9...28

    /// ⌘0 reset target — matches the `codeEditFontSize` @AppStorage default.
    static let codeViewerDefaultFontSize: Double = 13
}
