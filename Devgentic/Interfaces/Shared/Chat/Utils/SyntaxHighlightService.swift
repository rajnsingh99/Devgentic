//
//  SyntaxHighlightService.swift
//  Devgentic
//
//  One shared, serialized Highlightr for the whole app.
//
//  Chat code blocks used to construct a NEW `Highlightr()` for EVERY highlight —
//  inside a `Task.detached` keyed on the code string, so a streaming code block
//  rebuilt one per flush. Each construction spins up a JSContext and re-evaluates
//  the ~1.06 MB highlight.js bundle: ~21 ms of a ~24 ms call, i.e. ~88% pure waste,
//  and the detached task couldn't be cancelled — so a long streamed block left a
//  pile of concurrent JS VMs burning CPU and starving the main actor. That is what
//  made the UI drip out a reply for a minute after the model had already finished.
//
//  `Highlightr` wraps a `JSContext`, which is NOT thread-safe, so reusing one
//  instance requires serialized access — hence an actor.
//

import Foundation
import Highlightr
import os

private let logger = DGLogger(category: "SyntaxHighlightService")

actor SyntaxHighlightService {
    static let shared = SyntaxHighlightService()

    /// Built lazily on first use and kept for the process lifetime.
    private var highlightr: Highlightr?
    /// `setTheme` re-parses a CSS theme, so only call it when it actually changes.
    private var appliedTheme: String?
    /// Highlightr silently falls back to `highlightAuto` for an unknown language,
    /// which mis-detects (e.g. `let x = 1` → `abnf`). Cached so we validate cheaply.
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

    /// Highlights `code`, or returns nil if highlighting isn't possible (caller then
    /// renders plain text).
    ///
    /// - Parameter language: A fence's info string. Unknown/empty values are resolved
    ///   to nil rather than handed to Highlightr, so it renders plain instead of
    ///   guessing a wrong language.
    /// - Parameter themeName: A highlight.js CSS theme bundled with Highlightr, supplied by
    ///   the app theme (`Theme.codeHighlightThemeName`). This used to be a light/dark
    ///   boolean hardcoded to `atom-one-*`, so choosing Dracula still rendered Atom.
    func highlight(_ code: String, language: String, themeName: String) -> NSAttributedString? {
        guard let highlightr = instance() else { return nil }

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

        return highlightr.highlight(code, as: resolvedLanguage(language), fastRender: true)
    }

    /// Maps a fence info string to a language Highlightr actually knows, or nil.
    /// Callers pass things like "code" (a placeholder), "" (a bare fence), or an
    /// alias — none of which are hljs languages.
    private func resolvedLanguage(_ language: String) -> String? {
        let key = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty, key != "code", key != "plaintext", key != "text" else { return nil }
        if let supported = supportedLanguages, supported.contains(key) { return key }
        if let alias = Self.aliases[key] { return alias }
        return nil
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
