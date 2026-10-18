// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ClassificationTokenMapper.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Bidirectional mapping between classification labels and opaque tokens.
/// Used by the AI Classifier in condition nodes to prevent label/content collision.
struct ClassificationTokenMapper: Sendable {

    /// Maps opaque token → original label.
    let tokenToLabel: [String: String]

    /// Maps original label → opaque token.
    let labelToToken: [String: String]

    // Why: keep the escape hatch: without an "if unsure" line a genuinely unsure model would guess a real token.
    /// The token the prompt advertises for "none of these fit": a dedicated sentinel that maps to no label.
    /// Answering it means no category matched, which the Router's decision policy handles like any undecided input.
    /// Generated with `excluding:` the label tokens, so it never collides with a real label's token.
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
    /// For reporting only (`parseResponse` already returns nil for the sentinel): lets the log and the node's failure reason
    /// say "nothing matched" rather than the weaker "no recognisable token", which an unparseable answer also produces.
    func isExplicitNoMatch(_ response: String) -> Bool {
        guard parseResponse(response) == nil else { return false }
        // The same boundary test `parse` uses, so the two sentinel checks cannot disagree about a sentinel embedded in a word.
        return Self.firstStandaloneOccurrence(of: fallbackToken, in: response.uppercased()) != nil
    }

    // MARK: - Prompt Building

    /// Builds the XML label block for the classification prompt, each label wrapped with its opaque token ID,
    /// e.g. `<label id="XK7M">Essay</label>`.
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

    /// Extracts a label from the model's response by scanning for any known token; returns nil if none was found.
    /// Tolerates wrapped ("I think XK7M fits best") and lowercased ("xk7m") replies.
    func parseResponse(_ response: String) -> String? {
        // Thin adapter over `parse(_:)` that returns a label only for an unambiguous single hit;
        // a reply naming two labels is `.ambiguous`.
        if case .label(let l) = parse(response) { return l }
        return nil
    }

    // Why: a reply naming two labels is ambiguous; resolving it by Dictionary order made routing differ across launches.
    /// The total classification of a model reply.
    enum ParseResult: Equatable, Sendable {
        /// Exactly one distinct label was named.
        case label(String)
        /// Two or more distinct labels were named, in first-appearance order in the reply.
        /// Reply order, not rule order: the model was told to emit one token, so what it emitted first is its answer.
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

        // Record each real token's first occurrence, then order by position. Deduped by label, keeping the earliest:
        // two rules may share a label (one output port), and this stops such a pair producing a phantom ambiguity.
        var earliestByLabel: [String: String.Index] = [:]
        for (token, label) in tokenToLabel {
            // Standalone occurrence, not bare containment: a 4-character token can sit inside a longer word ("MENTION"
            // contains "MENT"), which would manufacture a routing decision or a phantom `.ambiguous`.
            guard let idx = Self.firstStandaloneOccurrence(of: token, in: uppercased) else { continue }
            if let existing = earliestByLabel[label], existing <= idx { continue }
            earliestByLabel[label] = idx
        }

        let ordered = earliestByLabel
            .sorted { $0.value < $1.value }
            .map(\.key)

        if ordered.count == 1 { return .label(ordered[0]) }
        if ordered.count > 1 { return .ambiguous(candidates: ordered) }

        // The sentinel is consulted only when no real token was found; a reply with a real token and the sentinel
        // routes on the real token. The sentinel gets the same boundary treatment.
        if Self.firstStandaloneOccurrence(of: fallbackToken, in: uppercased) != nil {
            return .explicitNoMatch
        }
        return .unreadable
    }

    // Why: boundary is ASCII alphanumeric, not `isLetter`: Unicode letters would break CJK replies with no space around a token.
    /// The first occurrence of `token` in `haystack` that is not embedded in a longer alphanumeric run.
    /// Punctuation, whitespace, non-ASCII letters and the string ends all count as boundaries.
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
    // Excludes I/O/0/1 to avoid visual ambiguity in logs.

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
    // Why: tokens come from an ASCII alphabet, so a Unicode-wide letter test would reject tokens placed against CJK text.
    /// Boundary test for `ClassificationTokenMapper.firstStandaloneOccurrence`: true for ASCII letters and digits only.
    var isASCIITokenCharacter: Bool { isASCII && (isLetter || isNumber) }
}
