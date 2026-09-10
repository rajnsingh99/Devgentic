// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  MLXTokenizerBridge.swift
//  Devgentic
//
//  Adapts swift-transformers' `Tokenizers.Tokenizer` to the new
//  `MLXLMCommon.Tokenizer` protocol introduced in mlx-swift-lm 3.x.
//
//  Why this file exists:
//  mlx-swift-lm 3.x decoupled from swift-transformers and defined its own
//  `Tokenizer` protocol inside MLXLMCommon. Our codebase still uses
//  swift-transformers' `AutoTokenizer` for tokenization (and swift-transformers
//  internally owns the Jinja chat-template rendering). The bridge wires the
//  two together so we can pass a swift-transformers tokenizer wherever
//  mlx-swift-lm expects an MLXLMCommon.Tokenizer.
//
//  This is a direct port of the `TokenizerAdaptorMacro` + `TokenizerLoaderMacro`
//  expansions from mlx-swift-lm's MLXHuggingFace module. We re-implement them
//  as plain Swift to avoid adding MLXHuggingFace + HuggingFace package products
//  (which bring their own dependencies we don't otherwise need).
//
//  Exposes `TokenizerBridge.upstream` so callers can access the richer
//  swift-transformers API (e.g. `applyChatTemplate(chatTemplate: .literal(...))`)
//  that MLXLMCommon's protocol doesn't surface.
//

import Foundation
import MLXLMCommon
import OSLog
import Tokenizers

private let logger = DGLogger(category: "MLXTokenizerBridge")

/// Wraps a swift-transformers `Tokenizers.Tokenizer` in the `MLXLMCommon.Tokenizer`
/// protocol. Keep `upstream` public so fallback paths can access swift-transformers'
/// richer chat-template API when the default path throws `missingChatTemplate`.
struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    // MARK: - Token-level passthroughs

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        // swift-transformers uses `decode(tokens:)` while mlx-swift-lm uses `decode(tokenIds:)`.
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    // MARK: - Chat template

    /// Primary chat-template path. Relies on the tokenizer's embedded `chat_template`.
    /// Throws `MLXLMCommon.TokenizerError.missingChatTemplate` when the tokenizer has
    /// no template; callers can then fall back via the exposed `upstream` API.
    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext
            )
            // Intentionally no success log here — MLXService logs at the call site with more context
            // (including "prompt tokens" label and tool count). Avoids double-logging each render.
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            logger.warning("⚠️ [Template] Tokenizer has no embedded chat_template — caller must fall back.")
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

/// `TokenizerLoader` that loads the model's tokenizer via swift-transformers'
/// `AutoTokenizer.from(modelFolder:)` and wraps it in `TokenizerBridge` so it
/// satisfies the `MLXLMCommon.Tokenizer` protocol required by mlx-swift-lm 3.x.
struct HuggingFaceTokenizerLoader: MLXLMCommon.TokenizerLoader {

    public init() {}

    public func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        logger.info("📂 [TokenizerLoader] Loading from \(directory.lastPathComponent)")
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        logger.info("✅ [TokenizerLoader] AutoTokenizer ready — bosToken=\(upstream.bosToken ?? "nil"), eosToken=\(upstream.eosToken ?? "nil")")
        return TokenizerBridge(upstream)
    }
}
