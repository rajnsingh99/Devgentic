// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  QueryRewritingService.swift
//  Devgentic
//
//  Created by Raj Singh.
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
        // A long query is self-contained, and the rewrite's 100-token output cap would cut it.
        guard currentQuery.count <= Self.maxRewritableQueryChars else {
            logger.info("[RAG Rewrite] Skipped — query is \(currentQuery.count) chars (> \(Self.maxRewritableQueryChars)). CONSEQUENCE: retrieval uses the query as typed; a long query carries its own context, and rewriting it would truncate it to the 100-token output cap.")
            return currentQuery
        }

        totalRewriteCount += 1
        let rewriteNum = totalRewriteCount

        // [M6] Log query LENGTH, not text — the query is user content and these lines reach the
        // unified OS log.
        logger.notice("[RAG Rewrite #\(rewriteNum)] BEGIN — Query: \(currentQuery.count) chars, History: \(history.count) messages")

        let recentHistory = Self.formatRecentHistory(history)

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
            // Bounded: the rewrite sits before the first token and a cold Intelligence Core load can take seconds.
            // Past the deadline the original query is used; the abandoned call drains in the background.
            let wrapped = UnsafeSendable(messages)
            let rewritten = try await Self.withDeadline(Self.rewriteDeadline) {
                defer { Task { await IntelligenceCoreService.shared.releaseHold(caller: .ragRewriting) } }
                // The local lock: never waited for here (see `claimForInTurnIntelligence`).
                return try await LocalInferenceCoordinator.inTurnIntelligence(
                    feature: "RAG query rewrite", on: await Self.coordinator()
                ) {
                    try await IntelligenceCoreService.shared.generate(
                        messages: wrapped.value,
                        maxTokens: 100,
                        temperature: 0.1,
                        caller: .ragRewriting
                    )
                }
            }
            let cleaned = rewritten.trimmingCharacters(in: .whitespacesAndNewlines)

            let rewriteDuration = CFAbsoluteTimeGetCurrent() - rewriteStart

            if cleaned.isEmpty || cleaned.lowercased().starts(with: "i cannot") || cleaned.lowercased().starts(with: "i can't") {
                fallbackCount += 1
                logger.warning("[RAG Rewrite #\(rewriteNum)] FALLBACK — IC returned unusable output (\(String(format: "%.2f", rewriteDuration))s). Using original query. Total fallbacks: \(self.fallbackCount)/\(self.totalRewriteCount)")
                return currentQuery
            }

            // The rewriter must expand a query, never replace its topic; small models sometimes hallucinate
            // replacements. Falling back to the original is always safe.
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

        } catch let busy as LocalInferenceCoordinator.LocalSlotBusy {
            fallbackCount += 1
            logger.notice("[RAG Rewrite #\(rewriteNum)] SKIPPED — the local model is busy (\(busy.holder)). CONSEQUENCE: retrieval uses the original query (pronouns unresolved) instead of waiting behind another run. Fallbacks: \(self.fallbackCount)/\(self.totalRewriteCount)")
            return currentQuery
        } catch is RewriteDeadlineExceeded {
            fallbackCount += 1
            logger.warning("[RAG Rewrite #\(rewriteNum)] TIMED OUT after \(Self.rewriteDeadline). CONSEQUENCE: retrieval uses the original query (pronouns unresolved); the abandoned rewrite is cancelled and drains in the background. Fallbacks: \(self.fallbackCount)/\(self.totalRewriteCount)")
            return currentQuery
        } catch {
            let rewriteDuration = CFAbsoluteTimeGetCurrent() - rewriteStart
            fallbackCount += 1
            logger.error("[RAG Rewrite #\(rewriteNum)] FAILED — \(error.localizedDescription) (\(String(format: "%.2f", rewriteDuration))s). CONSEQUENCE: retrieval uses the original query. Fallbacks: \(self.fallbackCount)/\(self.totalRewriteCount)")
            return currentQuery
        }
    }

    // MARK: - Bounds

    /// Longest query worth rewriting. Rewriting resolves "it"/"that" in a short follow-up.
    static let maxRewritableQueryChars = 600
    /// Wall-clock budget for the whole rewrite, model load included.
    static let rewriteDeadline: Duration = .seconds(4)

    /// The coordinator in-turn rewrites claim the local lock from. Tests point it at their own.
    nonisolated(unsafe) static var coordinatorOverride: LocalInferenceCoordinator?
    @MainActor static func coordinator() -> LocalInferenceCoordinator { coordinatorOverride ?? .shared }
    /// Per-message cap on the history shown to the rewriter: head + tail of each message.
    static let historyHeadChars = 300
    static let historyTailChars = 200

    struct RewriteDeadlineExceeded: Error {}

    /// Runs `operation`, returning its result or throwing `RewriteDeadlineExceeded` after `deadline`
    /// without waiting for it. Two unstructured tasks race through one continuation, since a task group
    /// awaits every child.
    static func withDeadline<T: Sendable>(
        _ deadline: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let once = ResumeOnce<T>()
        return try await withCheckedThrowingContinuation { continuation in
            let work = Task {
                do { once.resume(continuation, with: .success(try await operation())) }
                catch { once.resume(continuation, with: .failure(error)) }
            }
            Task {
                try? await Task.sleep(for: deadline)
                if once.resume(continuation, with: .failure(RewriteDeadlineExceeded())) { work.cancel() }
            }
        }
    }

    /// The last `maxMessages` turns, each reduced to head and tail with reasoning stripped.
    /// A follow-up's referent is in a turn's opening or closing lines; whole messages would bloat the
    /// prompt.
    static func formatRecentHistory(_ history: [ChatMessage], maxMessages: Int = 4) -> String {
        var formatted = ""
        for msg in history.suffix(maxMessages) {
            let role = msg.sender == .user ? "User" : "Agent"
            let raw = msg.content.textContent.map { OutputSanitizer.stripThinkBlocksAndTokens($0) } ?? "[Non-text content]"
            let content: String
            if raw.count > historyHeadChars + historyTailChars {
                content = String(raw.prefix(historyHeadChars)) + " … " + String(raw.suffix(historyTailChars))
            } else {
                content = raw
            }
            formatted += "\(role): \(content)\n"
        }
        return formatted
    }

    /// A query with no letter or digit (empty, punctuation, emoji-only) has nothing to match, so it is
    /// skipped.
    static func isRetrievable(_ query: String) -> Bool {
        query.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    /// True when every content word of the original query survives as a whole word (case-insensitive) in
    /// the rewrite. Expansion is legal, topic replacement is not; substring matching would let "wildfires"
    /// satisfy "fire".
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
}

/// One-shot resume for a continuation raced between two tasks — resuming twice traps.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    /// - Returns: true if this call resumed the continuation.
    @discardableResult
    func resume(_ continuation: CheckedContinuation<T, Error>, with result: Result<T, Error>) -> Bool {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { continuation.resume(with: result) }
        return first
    }
}
