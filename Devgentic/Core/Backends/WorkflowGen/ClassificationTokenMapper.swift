// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ClassificationTokenMapper.swift
//  Devgentic
//
//  Created by Raj Singh on 13/04/26.
//
//  Maps human-readable classification labels to opaque 4-char tokens
//  for AI Classifier prompts. Opaque tokens prevent collision with
//  upstream content and simplify response parsing — even if the model
//  wraps the token in a sentence, extraction is trivial.
//
//  Tokens are generated fresh per invocation (never cached or persisted)
//  so they can't leak into training data or cached context.
//

import Foundation

/// Bidirectional mapping between classification labels and opaque tokens.
/// Used by the AI Classifier in condition nodes to prevent label/content collision.
struct ClassificationTokenMapper: Sendable {

    /// Maps opaque token → original label.
    let tokenToLabel: [String: String]

    /// Maps original label → opaque token.
    let labelToToken: [String: String]

    /// The token the prompt advertises for "none of these fit" — a dedicated sentinel that maps to
    /// NO label. Answering it means "no category matched", which the Router's decision policy then
    /// handles like any other undecided input.
    ///
    /// ⚠️ WF-OB1: this used to be an arbitrary entry of an unordered Dictionary when no catch-all
    /// was configured — a REAL branch nobody chose, and which one could differ between app launches
    /// (Swift seeds Dictionary hashing per process). The escape hatch is KEPT rather than removed:
    /// dropping the "if unsure" line would leave a genuinely-unsure model no way to say so, and it
    /// would simply guess a real token.
    ///
    /// ⚠️ Generated with `excluding:` the label tokens, so it can never collide with a real label's
    /// token.
    let fallbackToken: String

    // MARK: - Initialization

    /// Creates a fresh mapping for the given labels.
    /// Generates unique 4-char uppercase alphanumeric tokens.
    /// - Parameter labels: The classification labels (from rule definitions).
    init(labels: [String]) {
        var t2l: [String: String] = [:]
        var l2t: [String: String] = [:]
        var usedTokens: Set<String> = []

        for label in labels {
            let token = Self.generateUniqueToken(excluding: usedTokens)
            usedTokens.insert(token)
            t2l[token] = label
            l2t[label] = token
        }

        tokenToLabel = t2l
        labelToToken = l2t
        fallbackToken = Self.generateUniqueToken(excluding: usedTokens)
    }

    /// True when `response` carries the no-match sentinel and no real label token.
    ///
    /// Used for REPORTING only — `parseResponse` already returns nil for the sentinel, because the
    /// sentinel is deliberately absent from `tokenToLabel`. This exists so the log and the node's
    /// failure reason can say "the classifier reported that nothing matched" rather than the much
    /// weaker "the reply contained no recognisable token", which is also what an unparseable answer
    /// produces. Those are different situations for the user: one means the rules do not cover the
    /// input, the other means the model misbehaved.
    func isExplicitNoMatch(_ response: String) -> Bool {
        guard parseResponse(response) == nil else { return false }
        // [EIO-10] The SAME boundary test `parse` uses. This sibling was left on bare containment in
        // the first pass, so the two sentinel checks could disagree about the same reply — one seeing
        // a sentinel embedded in a word that the other refused.
        return Self.firstStandaloneOccurrence(of: fallbackToken, in: response.uppercased()) != nil
    }

    // MARK: - Prompt Building

    /// Builds the XML label block for the classification prompt.
    /// Each label is wrapped with its opaque token ID.
    ///
    /// Example output:
    /// ```
    /// <label id="XK7M">Essay</label>
    /// <label id="QP3N">Code</label>
    /// ```
    var xmlLabelBlock: String {
        labelToToken
            .sorted(by: { $0.key < $1.key }) // Deterministic order
            .map { label, token in "<label id=\"\(token)\">\(label)</label>" }
            .joined(separator: "\n")
    }

    /// All token IDs as a comma-separated list (for constraint repetition in prompt).
    var tokenList: String {
        labelToToken.values.sorted().joined(separator: ", ")
    }

    // MARK: - Response Parsing

    /// Extracts a label from the model's response by scanning for any known token.
    /// Returns the matched label, or `nil` if no token was found.
    ///
    /// Handles common model behaviors:
    /// - Clean response: "XK7M" → "Essay"
    /// - Wrapped response: "I think XK7M fits best" → "Essay"
    /// - Lowercased response: "xk7m" → "Essay" (case-insensitive scan)
    func parseResponse(_ response: String) -> String? {
        // ⚠️ Retained as a thin adapter over `parse(_:)` so the ambiguity information cannot be
        // discarded by accident. Returns a label ONLY for an unambiguous single hit — a reply
        // naming two labels is `.ambiguous`, and collapsing that to one of them here is exactly
        // the WF-OB2 defect this rewrite removed.
        if case .label(let l) = parse(response) { return l }
        return nil
    }

    /// The total classification of a model reply.
    ///
    /// ⚠️ Replaces the old "scan until the first token matches" loop, which iterated an unordered
    /// `Dictionary` — so a reply naming TWO labels resolved to whichever key Swift happened to
    /// yield first, and, because Swift seeds hashing per process, the SAME input could take a
    /// different branch after an app restart with the run reporting success either way (WF-OB2).
    /// The failure was biased toward wrong: models phrase conclusions as "not X, it's Y", so the
    /// rejected label often appeared first in the text.
    enum ParseResult: Equatable, Sendable {
        /// Exactly one distinct label was named.
        case label(String)
        /// Two or more distinct labels were named, in FIRST-APPEARANCE order in the reply.
        /// ⚠️ Reply order, not rule order: the model was instructed to emit ONE token, so what it
        /// emitted first is its answer and the rest is hedging. Deterministic either way — the
        /// point is that it comes from character positions, never Dictionary iteration.
        case ambiguous(candidates: [String])
        /// The model answered with the no-match sentinel and no real token: a verdict about the
        /// RULES ("none of these fit"). Remedy: add or widen a rule.
        case explicitNoMatch
        /// Nothing recognisable in the reply: a verdict about the MODEL. Remedy: a stronger model.
        case unreadable
    }

    /// Classifies a model reply. Total — every reply lands in exactly one case.
    func parse(_ response: String) -> ParseResult {
        let uppercased = response.uppercased()

        // Record each real token's FIRST occurrence, then order by position. Deduped BY LABEL,
        // keeping the earliest: two rules may legitimately share a label (they share one output
        // port), and without this such a pair would manufacture a phantom self-ambiguity.
        var earliestByLabel: [String: String.Index] = [:]
        for (token, label) in tokenToLabel {
            // [EIO-10] STANDALONE occurrence, not bare containment. A 4-character token can appear
            // INSIDE a longer alphanumeric run in ordinary prose — the reply "MENTION the refund"
            // contains the token "MENT" — so a plain `range(of:)` let the model's own wording
            // manufacture a routing decision it never made, or a second candidate that turned a
            // clean answer into a phantom `.ambiguous`.
            guard let idx = Self.firstStandaloneOccurrence(of: token, in: uppercased) else { continue }
            if let existing = earliestByLabel[label], existing <= idx { continue }
            earliestByLabel[label] = idx
        }

        let ordered = earliestByLabel
            .sorted { $0.value < $1.value }
            .map(\.key)

        if ordered.count == 1 { return .label(ordered[0]) }
        if ordered.count > 1 { return .ambiguous(candidates: ordered) }

        // ⚠️ The sentinel is consulted ONLY when no real token was found. A reply carrying a real
        // token AND the sentinel routes on the real token — today's semantics, preserved exactly.
        // The sentinel gets the same boundary treatment, for the same reason.
        if Self.firstStandaloneOccurrence(of: fallbackToken, in: uppercased) != nil {
            return .explicitNoMatch
        }
        return .unreadable
    }

    /// The first occurrence of `token` in `haystack` that is NOT embedded in a longer alphanumeric
    /// run (register EIO-10).
    ///
    /// ⚠️ The boundary predicate is ASCII alphanumeric — wider than `tokenCharacters` (which omits
    /// I, O, 0 and 1, so a membership test would still accept "MENT" inside "MENTION") but NARROWER
    /// than `Character.isLetter`, which is true for every Unicode letter and would break CJK replies
    /// that place a token directly against a character with no space. Punctuation, whitespace,
    /// non-ASCII letters and the string ends all count as boundaries.
    ///
    /// `nonisolated static` and pure so the rule is truth-tableable on its own (WF-UI5).
    nonisolated static func firstStandaloneOccurrence(
        of token: String,
        in haystack: String
    ) -> String.Index? {
        guard !token.isEmpty else { return nil }
        var from = haystack.startIndex
        while let r = haystack.range(of: token, range: from..<haystack.endIndex) {
            let precededByTokenChar = r.lowerBound > haystack.startIndex
                && haystack[haystack.index(before: r.lowerBound)].isASCIITokenCharacter
            let followedByTokenChar = r.upperBound < haystack.endIndex
                && haystack[r.upperBound].isASCIITokenCharacter
            if !precededByTokenChar && !followedByTokenChar { return r.lowerBound }
            guard r.lowerBound < haystack.endIndex else { return nil }
            from = haystack.index(after: r.lowerBound)
        }
        return nil
    }

    // MARK: - Token Generation

    /// Character set for token generation: uppercase letters + digits.
    private static let tokenCharacters = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    // Note: Excluded I/O/0/1 to avoid visual ambiguity in logs

    /// Generates a unique 4-character token not in the exclusion set.
    private static func generateUniqueToken(excluding used: Set<String>) -> String {
        for _ in 0..<100 {
            let token = String((0..<4).map { _ in tokenCharacters.randomElement()! })
            if !used.contains(token) { return token }
        }
        // Fallback: extremely unlikely (36^4 = 1.6M combinations)
        return String((0..<4).map { _ in tokenCharacters.randomElement()! })
    }
}

private extension Character {
    /// Boundary test for `ClassificationTokenMapper.firstStandaloneOccurrence` (register EIO-10).
    ///
    /// ⚠️ ASCII ONLY, deliberately. `Character.isLetter` is true for EVERY Unicode letter — CJK,
    /// Kana, Hangul, Thai, Devanagari — but a token is drawn from an ASCII alphabet
    /// (`tokenCharacters`), so a token can never be part of a CJK "word". Using the Unicode-wide
    /// test made a Japanese or Chinese reply that placed the token directly against a CJK character
    /// (no space, which is normal in those scripts) fail to match, silently turning a decided
    /// classification into `.unreadable`. The boundary that matters is "could this be the same TOKEN",
    /// and only ASCII alphanumerics can be.
    var isASCIITokenCharacter: Bool { isASCII && (isLetter || isNumber) }
}
