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
    static let streamingBubbleMinHeight: CGFloat = 550
}
