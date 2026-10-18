// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatSearchDecomposition.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// One run of text a view can actually paint a highlight on, in render order.
struct SearchUnit: Sendable, Equatable {
    /// `ContentBlock.id` of the block that renders this text, or nil when the message renders
    /// as ONE undecomposed `Text` (user bubbles, agent `.plainText`).
    let blockID: String?
    /// EXACTLY the characters the renderer highlights over — see `highlightableText`.
    let text: String
    /// False for content whose view accepts no search query (code, tables, images, error cards, checkpoints). Such units
    /// are still emitted so the structure survives, but `performSearch` does not count them, since no highlight can be
    /// painted.
    let isHighlightable: Bool
}

/// A message projected down to just what search needs; the corpus element, instead of fully decoded messages with
/// attached image bytes.
struct SearchDocument: Sendable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let units: [SearchUnit]
}

enum ChatSearchDecomposition {

    /// The characters a highlight is measured against: block text as rendered through `AttributedString(markdown:)`, with
    /// markdown syntax stripped. The fallback for unparseable text (plain `AttributedString(text)`) is mirrored here.
    static func highlightableText(fromBlockText text: String) -> String {
        if let parsed = try? AttributedString(markdown: text) {
            return String(parsed.characters)
        }
        return text
    }

    /// Pure decomposition that touches no `ChatMessage`. `blocks` must be the same array the renderer iterates; pass nil
    /// for content kinds that are not markdown.
    static func units(sender: SenderRole, content: MessageContent, blocks: [ContentBlock]?) -> [SearchUnit] {
        // Checks the sender before the content case: `UserMessageView` builds its string from the raw text with no markdown
        // parse, so a user bubble's highlightable string is its raw text.
        guard sender == .agent else {
            guard let text = content.textContent, !text.isEmpty else { return [] }
            return [SearchUnit(blockID: nil, text: text, isHighlightable: true)]
        }

        switch content {
        case .plainText(let text):
            // Rendered by one `Text` over the raw string — no decomposition, no markdown.
            guard !text.isEmpty else { return [] }
            return [SearchUnit(blockID: nil, text: text, isHighlightable: true)]

        case .markdownText(let text):
            guard !text.isEmpty, let blocks else { return [] }
            return blocks.flatMap(units(fromBlock:))

        case .codeBlock(_, let code):
            return [SearchUnit(blockID: nil, text: code, isHighlightable: false)]

        case .error(let title, let details, _, _):
            return [SearchUnit(blockID: nil, text: "\(title ?? "Error"): \(details)", isHighlightable: false)]

        case .checkpoint(let summary):
            return [SearchUnit(blockID: nil, text: summary, isHighlightable: false)]

        case .mediaArtifact, .unknown:
            return []
        }
    }

    /// Depth-first, in render order, mirroring `ContentBlockView`'s switch. Not `ContentBlock.plainText`, which joins
    /// children and injects list prefixes and would double-count nested matches.
    private static func units(fromBlock block: ContentBlock) -> [SearchUnit] {
        switch block.type {
        case .paragraph(let text):
            return [SearchUnit(blockID: block.id,
                               text: highlightableText(fromBlockText: text),
                               isHighlightable: true)]

        case .heading(_, let text):
            return [SearchUnit(blockID: block.id,
                               text: highlightableText(fromBlockText: text),
                               isHighlightable: true)]

        case .code(_, let content, _):
            // Rendered by CodeBlockView/CodeBlockCardView, neither of which takes a query.
            return [SearchUnit(blockID: block.id, text: content, isHighlightable: false)]

        case .table(let headers, let rows, _):
            let flat = ([headers] + rows).map { $0.joined(separator: " | ") }.joined(separator: "\n")
            return [SearchUnit(blockID: block.id, text: flat, isHighlightable: false)]

        case .image(_, let altText):
            return [SearchUnit(blockID: block.id, text: altText ?? "", isHighlightable: false)]

        case .horizontalRule:
            return []

        case .listItem(_, let children, _):
            // No unit for the item itself — its marker is a separate, un-highlighted view.
            return children.flatMap(units(fromBlock:))

        case .blockquote(let children):
            return children.flatMap(units(fromBlock:))
        }
    }

    /// Live message to units, on the main actor. A streaming or already-cached message goes through
    /// `getOrCreateMarkdownBlocks` so block ids match the screen; anything else uses the pure function, which writes no
    /// cache (the corpus reaches messages outside the render window). Do not merge the two paths.
    @MainActor
    static func units(for message: ChatMessage) -> [SearchUnit] {
        let content = message.displayedContent
        guard case .markdownText(let text) = content, !text.isEmpty else {
            return units(sender: message.sender, content: content, blocks: nil)
        }
        let blocks = (message.isStreaming || message.cachedMarkdownBlocks != nil)
            ? message.getOrCreateMarkdownBlocks(from: text)
            : parseMarkdown(text)
        return units(sender: message.sender, content: content, blocks: blocks)
    }

    /// Live message → document.
    @MainActor
    static func document(for message: ChatMessage) -> SearchDocument {
        SearchDocument(id: message.id, timestamp: message.timestamp, units: units(for: message))
    }
}
