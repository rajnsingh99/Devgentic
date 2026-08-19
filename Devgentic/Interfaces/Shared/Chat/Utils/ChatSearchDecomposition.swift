//
//  ChatSearchDecomposition.swift
//  Devgentic
//
//  THE shared decomposition for find-in-conversation.
//
//  The chat search had two index spaces that did not agree. `performSearch` counted matches
//  across a message's WHOLE raw markdown source and stored that counter; every rendered block
//  was then handed that one number and compared it against offsets computed over its OWN
//  text. So the "current match" highlight landed on a different occurrence than the one being
//  navigated to, or on nothing at all. Separately, the count came from the raw markdown SOURCE
//  (syntax markers, fenced code bodies) while the highlight ran over the RENDERED string — so
//  the badge advertised positions that could never be shown, and a phrase spanning a `**`
//  marker reported "No results" for text plainly on screen.
//
//  Both were the same class of bug: a transform replicated on two sides that drifted. The fix
//  is to derive matches from the SAME decomposition and the SAME string the renderer
//  highlights, and to key the active match by BLOCK ID rather than by an integer whose meaning
//  differs across the seam. Correctness then holds by construction.
//
//  ⚠️ Never call this from inside a SwiftUI `body`: `units(for:)` reads `isStreaming` and
//  `content`, which are observed. Today's callers are `.onChange` closures and Tasks.
//

import Foundation

/// One run of text a view can actually paint a highlight on, in render order.
struct SearchUnit: Sendable, Equatable {
    /// `ContentBlock.id` of the block that renders this text, or nil when the message renders
    /// as ONE undecomposed `Text` (user bubbles, agent `.plainText`).
    let blockID: String?
    /// EXACTLY the characters the renderer highlights over — see `highlightableText`.
    let text: String
    /// False for content whose view accepts no search query (code, tables, images, error
    /// cards, checkpoints). Such units are still emitted so the structure survives, but
    /// `performSearch` does not turn them into matches: counting them would promise a
    /// highlight that cannot be painted.
    let isHighlightable: Bool
}

/// A message projected down to just what search needs.
///
/// Replaces `[ChatMessage]` as the corpus element. The old corpus held up to 1000 fully
/// decoded messages — including every attached image's full bytes — until the conversation
/// changed.
struct SearchDocument: Sendable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let units: [SearchUnit]
}

enum ChatSearchDecomposition {

    /// The characters a highlight is measured against.
    ///
    /// `ContentBlockView.createStyledString` renders block text through
    /// `AttributedString(markdown:)`, and `SearchHighlighter` then measures offsets over
    /// `String(result.characters)` — markdown syntax already stripped. Scanning the raw source
    /// instead is what made the count disagree with the screen in BOTH directions. This is the
    /// one place that transform is expressed; the renderer's fallback for unparseable text
    /// (plain `AttributedString(text)`) is mirrored here deliberately.
    static func highlightableText(fromBlockText text: String) -> String {
        if let parsed = try? AttributedString(markdown: text) {
            return String(parsed.characters)
        }
        return text
    }

    /// Pure decomposition — touches no `ChatMessage`, so it is safe anywhere.
    ///
    /// `blocks` must be the SAME array the renderer will iterate; pass nil for content kinds
    /// that are not markdown.
    static func units(sender: SenderRole, content: MessageContent, blocks: [ContentBlock]?) -> [SearchUnit] {
        // SENDER FIRST, before the content case. `UserMessageView` builds
        // `AttributedString(text)` from the RAW string with no markdown parse, so a user
        // bubble's highlightable string is its raw text whatever the content case is.
        // Branching on the content case first would decompose a markdown-bearing user message
        // into blocks the renderer never creates — breaking the one path that was already
        // correct.
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

    /// Depth-first, in render order — mirroring `ContentBlockView`'s switch.
    ///
    /// ⚠️ Deliberately NOT `ContentBlock.plainText`: that joins a container's children with a
    /// space and injects list prefixes/checkbox markers, which would double-count every nested
    /// match and shift all later indices. `plainText` stays as it is for its RAG/preview
    /// consumers.
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

    /// Live message → units, on the main actor.
    ///
    /// ⚠️ The block source is chosen deliberately. `getOrCreateMarkdownBlocks` returns the
    /// RENDERER's own blocks (mid-stream ids from `StreamingMarkdownParser` differ from a
    /// fresh parse), so a streaming or already-cached message must go through it or the block
    /// ids will not match what is on screen. But it also POPULATES a cache — and the corpus
    /// reaches messages far outside the render window, exactly the caches
    /// `trimMarkdownCachesOutsideWindow` exists to release. So anything not already cached and
    /// not streaming uses the pure free function, which produces identical output and writes
    /// nothing. Do not simplify this away.
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
