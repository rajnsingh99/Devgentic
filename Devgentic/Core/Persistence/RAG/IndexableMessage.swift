// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  IndexableMessage.swift
//  Devgentic
//

import Foundation

/// A VALUE copy of what conversation memory indexes from one message, taken where the message
/// lives (the main actor) before indexing is handed to a detached task (RAG-16).
///
/// ⚠️ The indexer used to receive the live `ChatMessage` — `@Observable`, `@unchecked Sendable`,
/// not `@MainActor` — and read `content` from a background executor while the main actor could be
/// writing it (a Redo regenerating the message, a stream flush). An unsynchronised read of an enum
/// carrying a String payload is an ARC hazard, and it could index a half-streamed variant. A
/// snapshot freezes exactly the text that was settled when indexing was requested.
struct IndexableMessage: Sendable {

    /// The indexable shape of `MessageContent`, reduced to Sendable values.
    enum Body: Sendable, Equatable {
        /// Markdown (or plain) text — the usual case.
        case markdown(String)
        case code(language: String, code: String)
        /// Error rows, media, content from a newer build: nothing to index.
        case none
    }

    let id: UUID
    let conversationId: UUID
    let timestamp: Date
    let isError: Bool
    let body: Body
    /// `MessageContent.textContent` as it was — what the parent document stores, and what the
    /// synthetic-placeholder gate inspects.
    let textContent: String?

    /// - Parameter content: overrides the message's `content` — the response-variant picker
    ///   indexes the variant the user SELECTED, which `content` does not track.
    init(_ message: ChatMessage, content: MessageContent? = nil) {
        let content = content ?? message.content
        self.id = message.id
        self.conversationId = message.conversationId
        self.timestamp = message.timestamp
        self.textContent = content.textContent
        switch content {
        case .error:
            self.isError = true
            self.body = .none
        case .plainText(let text), .markdownText(let text), .checkpoint(let text):
            self.isError = false
            self.body = .markdown(text)
        case .codeBlock(let language, let code):
            self.isError = false
            self.body = .code(language: language ?? "text", code: code)
        case .mediaArtifact, .unknown:
            // `.unknown` is not indexed: an opaque payload would put JSON scaffolding into the
            // retrieval corpus and surface it as if it were something the user wrote.
            self.isError = false
            self.body = .none
        }
    }

    /// Parsed blocks for the chunker. Pure — `parseMarkdown` is a free function and touches no
    /// `ChatMessage` cache, which is what lets this run off the main actor.
    ///
    /// ⚠️ Reasoning is stripped from the WHOLE text, BEFORE it is split into blocks. Stripped per
    /// chunk (afterwards), a multi-paragraph `<think>` left its middle paragraphs with no tag in
    /// sight, and they were indexed as if they were the answer (RAG-23).
    func blocksForIndexing() -> [ContentBlock] {
        switch body {
        case .markdown(let text):
            return parseMarkdown(OutputSanitizer.stripThinkBlocksAndTokens(text))
        case .code(let language, let code):
            return [ContentBlock(id: "block-0", type: .code(language: language, content: code, fileName: nil))]
        case .none:
            return []
        }
    }
}
