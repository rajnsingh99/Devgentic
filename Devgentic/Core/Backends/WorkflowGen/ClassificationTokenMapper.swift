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

    /// The fallback token (opaque form of the fallback label).
    let fallbackToken: String

    // MARK: - Initialization

    /// Creates a fresh mapping for the given labels and fallback.
    /// Generates unique 4-char uppercase alphanumeric tokens.
    /// - Parameters:
    ///   - labels: The classification labels (from rule definitions).
    ///   - fallbackLabel: The catch-all label (must be one of `labels`).
    init(labels: [String], fallbackLabel: String) {
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
        fallbackToken = l2t[fallbackLabel] ?? l2t.values.first ?? "XXXX"
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
        let uppercased = response.uppercased()

        // Exact token match first (most common for well-behaved models)
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let label = tokenToLabel[trimmed] {
            return label
        }

        // Scan for any token in the response (handles wrapped/verbose output)
        for (token, label) in tokenToLabel {
            if uppercased.contains(token) {
                return label
            }
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
