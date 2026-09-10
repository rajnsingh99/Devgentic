// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  QueryRewritingService.swift
//  Devgentic
//
//  Created by Antigravity on 12/03/26.
//

import Foundation
import os

/// A service responsible for rewriting user queries to be fully self-contained
/// using the conversation history context, optimized for Vector/RAG retrieval.
actor QueryRewritingService {

    static let shared = QueryRewritingService()

    private let logger = DGLogger(category: "QueryRewritingService")

    /// Total number of rewrites attempted since app launch.
    private var totalRewriteCount: Int = 0

    /// Number of rewrites that returned the original query unchanged.
    private var fallbackCount: Int = 0

    private init() {}

    /// Rewrites the given query if the history warrants it.
    /// Unloads the Intelligence Core model from GPU immediately after to conserve memory.
    func rewriteQuery(_ currentQuery: String, history: [ChatMessage]) async -> String {
        guard !history.isEmpty else {
            logger.debug("[RAG Rewrite] Skipped — no conversation history to contextualize against.")
            return currentQuery // Nothing to contextualize against
        }

        totalRewriteCount += 1
        let rewriteNum = totalRewriteCount

        // [M6] Log query LENGTH, not text — the query is user content and these lines reach the
        // unified OS log.
        logger.notice("[RAG Rewrite #\(rewriteNum)] BEGIN — Query: \(currentQuery.count) chars, History: \(history.count) messages")

        let recentHistory = formatRecentHistory(history)

        let systemPrompt = """
        You are an expert search query rewriting assistant. Your singular task is to rewrite a user's follow-up query into a fully self-contained, descriptive search query using the provided conversation history.

        Rules:
        1. If the query contains pronouns or ambiguous references (e.g., "it", "that", "this function", "the model"), resolve them explicitly using the history.
        2. Do NOT answer the user's question.
        3. Do NOT include any explanations, conversational filler, or preambles.
        4. If the original query is already self-contained and clear, output the original query exactly as is.
        5. Output ONLY the raw rewritten query string and nothing else.
        """

        let userPrompt = """
        <conversation_history>
        \(recentHistory)
        </conversation_history>

        Current Query: \(currentQuery)

        Rewritten Query:
        """

        let messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userPrompt]
        ]

        let rewriteStart = CFAbsoluteTimeGetCurrent()

        do {
            let rewritten = try await IntelligenceCoreService.shared.generate(
                messages: messages,
                maxTokens: 100,
                temperature: 0.1,
                caller: .ragRewriting
            )
            let cleaned = rewritten.trimmingCharacters(in: .whitespacesAndNewlines)

            // Clean up cache to prevent memory footprint issues
            await IntelligenceCoreService.shared.releaseHold(caller: .ragRewriting)

            let rewriteDuration = CFAbsoluteTimeGetCurrent() - rewriteStart

            if cleaned.isEmpty || cleaned.lowercased().starts(with: "i cannot") || cleaned.lowercased().starts(with: "i can't") {
                fallbackCount += 1
                logger.warning("[RAG Rewrite #\(rewriteNum)] FALLBACK — IC returned unusable output (\(String(format: "%.2f", rewriteDuration))s). Using original query. Total fallbacks: \(self.fallbackCount)/\(self.totalRewriteCount)")
                return currentQuery
            }

            // [Rewrite guard] The rewriter's contract is to EXPAND a query (resolve
            // references by ADDING history context), never to replace its topic.
            // Small IC models sometimes hallucinate replacements — observed:
            // "Write an essay on Fire" → "…impact of wildfires on biodiversity",
            // "Write an essay on technology" → "Explain attached file in composer
            // application" — and retrieval then searches the wrong topic entirely.
            // Falling back to the original is always safe (pre-rewrite behavior).
            if !Self.rewriteRetainsOriginalTopic(original: currentQuery, rewrite: cleaned) {
                fallbackCount += 1
                logger.warning("[RAG Rewrite #\(rewriteNum)] FALLBACK — rewrite dropped the original query's content words (\(String(format: "%.2f", rewriteDuration))s). Using original query. Total fallbacks: \(self.fallbackCount)/\(self.totalRewriteCount)")
                return currentQuery
            }

            let wasChanged = cleaned != currentQuery
            logger.notice("[RAG Rewrite #\(rewriteNum)] COMPLETE — \(String(format: "%.2f", rewriteDuration))s, Changed: \(wasChanged)")
            if wasChanged {
                // [M6] Lengths only — both original and rewritten are user-derived content.
                logger.info("[RAG Rewrite #\(rewriteNum)] Rewrote query: \(currentQuery.count) → \(cleaned.count) chars")
            }
            return cleaned

        } catch {
            let rewriteDuration = CFAbsoluteTimeGetCurrent() - rewriteStart
            fallbackCount += 1
            logger.error("[RAG Rewrite #\(rewriteNum)] FAILED — \(error.localizedDescription) (\(String(format: "%.2f", rewriteDuration))s). Fallbacks: \(self.fallbackCount)/\(self.totalRewriteCount)")

            // Ensure we attempt to unload even if an error occurred during generation or tokenization
            await IntelligenceCoreService.shared.releaseHold(caller: .ragRewriting)

            return currentQuery
        }
    }

    /// True when every content word of the original query survives (as a whole
    /// word, case-insensitive) into the rewrite. Expansion is legal — adding
    /// history context around the original words — topic replacement is not.
    /// Whole-word matching matters: substring containment would let "wildfires"
    /// satisfy "fire" and wave the observed hallucination through.
    /// `static` (nonisolated on the actor) so tests exercise it directly.
    static func rewriteRetainsOriginalTopic(original: String, rewrite: String) -> Bool {
        let stopwords: Set<String> = [
            "what", "tell", "about", "this", "that", "explain", "write", "please",
            "does", "mean", "show", "where", "when", "which", "with", "from", "have",
            "will", "would", "could", "should", "give", "describe", "method", "function"
        ]
        func tokens(_ text: String) -> [String] {
            text.lowercased()
                .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") })
                .map(String.init)
        }
        let contentTokens = tokens(original).filter { $0.count >= 4 && !stopwords.contains($0) }
        guard !contentTokens.isEmpty else { return true }
        let rewriteTokens = Set(tokens(rewrite))
        return contentTokens.allSatisfy { rewriteTokens.contains($0) }
    }

    private func formatRecentHistory(_ history: [ChatMessage], maxMessages: Int = 4) -> String {
        let relevant = Array(history.suffix(maxMessages))
        var formatted = ""
        for msg in relevant {
            let role = msg.sender == .user ? "User" : "Agent"
            let content = msg.content.textContent ?? "[Non-text content]"
            formatted += "\(role): \(content)\n"
        }
        return formatted
    }
}
