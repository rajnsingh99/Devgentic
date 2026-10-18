// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SyntaxHighlightService.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import Highlightr
import os

private let logger = DGLogger(category: "SyntaxHighlightService")

/// One shared, serialized `Highlightr` for the whole app. Constructing one spins up a JSContext and re-evaluates the
/// highlight.js bundle, so it is built once; `JSContext` is not thread-safe, so access is serialized by an actor.
actor SyntaxHighlightService {
    static let shared = SyntaxHighlightService()

    /// Built lazily on first use and kept for the process lifetime.
    private var highlightr: Highlightr?
    /// `setTheme` re-parses a CSS theme, so only call it when it actually changes.
    private var appliedTheme: String?
    /// With a nil language, Highlightr runs `highlightAuto` over every bundled grammar and guesses, so `highlight` refuses
    /// to call it without a name this set (or `aliases`) vouches for; cached once so the check is a hash lookup.
    private var supportedLanguages: Set<String>?

    private func instance() -> Highlightr? {
        if let highlightr { return highlightr }
        guard let created = Highlightr() else {
            logger.error("Highlightr unavailable — code will render unhighlighted.")
            return nil
        }
        highlightr = created
        supportedLanguages = Set(created.supportedLanguages().map { $0.lowercased() })
        return created
    }

    // Why: checks cancellation first: a superseded streaming highlight is usually already cancelled by the time the actor hop
    // lands, and would otherwise run to completion ahead of the one that matters.
    /// Highlights `code`, or returns nil if highlighting isn't possible (the caller then renders plain text).
    /// - Parameter language: a fence's info string; a bare fence, `code`, `text` and `plaintext` return nil.
    /// - Parameter themeName: a highlight.js CSS theme bundled with Highlightr (`Theme.codeHighlightThemeName`).
    func highlight(_ code: String, language: String, themeName: String) -> NSAttributedString? {
        guard !Task.isCancelled else {
            logger.debug("[HIGHLIGHT] Skipped a superseded highlight (\(code.count) chars, lang='\(language)') — its task was cancelled before it started; the caller discards cancelled results, so nothing on screen is affected.")
            return nil
        }
        guard let highlightr = instance() else { return nil }

        // Resolve BEFORE the theme is touched and before Highlightr is asked anything: a nil
        // language must never reach `highlightr.highlight(_:as:)` (its nil branch guesses).
        let resolution = Self.resolvedLanguage(language, supported: supportedLanguages ?? [])
        guard case .use(let resolved) = resolution else {
            logger.debug("[HIGHLIGHT] Fence claims no language ('\(language)', \(code.count) chars) — rendering plain; Highlightr is not asked to guess.")
            return nil
        }

        if appliedTheme != themeName {
            // Returns false for a name Highlightr doesn't bundle. Falling back keeps a typo
            // in a theme definition from silently dropping ALL colour.
            if highlightr.setTheme(to: themeName) {
                appliedTheme = themeName
            } else {
                logger.error("Unknown highlight theme '\(themeName)' — falling back to atom-one-dark.")
                highlightr.setTheme(to: "atom-one-dark")
                appliedTheme = "atom-one-dark"
            }
        }

        return highlightr.highlight(code, as: resolved, fastRender: true)
    }

    /// What to do with a fence's info string.
    enum LanguageResolution: Equatable {
        /// The fence claims no language at all — render plain. Highlightr is NOT called, so it
        /// cannot fall back to `highlightAuto`.
        case renderPlain
        /// Hand this name to Highlightr. It may be an hljs canonical name or one of hljs's own
        /// aliases; `hljs.highlight(name:)` resolves both.
        case use(String)
    }

    // Why: hljs lists only canonical names but resolves ~178 aliases (`html`, `toml`, `ps1`, ...); rejecting a name
    // missing from `supported` would render those fences uncoloured.
    /// Decides a fence's info string into "render plain" or "ask hljs for this name".
    /// Only the meaningless tokens (`""`, `code`, `text`, `plaintext`) render plain; all others pass through to hljs.
    /// A small table maps tokens hljs does not know (`console`, `py3`, `node`, `docker`) onto ones it does.
    nonisolated static func resolvedLanguage(_ language: String, supported: Set<String>) -> LanguageResolution {
        let key = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty, key != "code", key != "plaintext", key != "text" else { return .renderPlain }
        if supported.contains(key) { return .use(key) }
        if let alias = aliases[key] { return .use(alias) }
        return .use(key)
    }

    /// Common fence info strings that aren't hljs identifiers.
    private static let aliases: [String: String] = [
        "sh": "bash", "shell": "bash", "zsh": "bash", "console": "bash",
        "js": "javascript", "jsx": "javascript", "node": "javascript",
        "ts": "typescript", "tsx": "typescript",
        "py": "python", "py3": "python", "python3": "python",
        "rb": "ruby", "yml": "yaml", "md": "markdown",
        "c++": "cpp", "objective-c": "objectivec", "objc": "objectivec",
        "cs": "csharp", "c#": "csharp", "golang": "go", "rs": "rust",
        "kt": "kotlin", "docker": "dockerfile"
    ]
}
