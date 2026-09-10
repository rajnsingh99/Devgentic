// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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
    /// Handed a nil language, Highlightr runs `highlightAuto` over every one of the ~192
    /// bundled grammars and guesses (e.g. `let x = 1` → `abnf`). `highlight` therefore
    /// refuses to call it without a name this set (or `aliases`) vouches for — cached
    /// once at construction so that check is a hash lookup, not a JS round-trip.
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
    /// - Parameter language: A fence's info string. `""` (a bare fence), `code`, `text`,
    ///   `plaintext`, and anything Highlightr doesn't list return nil HERE, before
    ///   Highlightr is called at all — see `resolvedLanguage`. Until CF-2 the resolved
    ///   nil was passed straight through to `highlightr.highlight(_:as:)`, whose nil
    ///   branch is `highlightAuto`: every bare-fence flush ran a 192-grammar guess and
    ///   the block was coloured as whatever won, under a badge that said `plaintext`.
    /// - Parameter themeName: A highlight.js CSS theme bundled with Highlightr, supplied by
    ///   the app theme (`Theme.codeHighlightThemeName`). This used to be a light/dark
    ///   boolean hardcoded to `atom-one-*`, so choosing Dracula still rendered Atom.
    ///
    /// Cancellation-aware: `AsyncHighlightedCodeView` keys its `.task(id:)` on the code, so
    /// a streaming block supersedes (cancels) the previous highlight on every flush. The
    /// caller already drops a cancelled RESULT, but by the time the actor hop lands here
    /// that task is usually already cancelled — without this check each superseded call
    /// still ran to completion, serialised on this actor, ahead of the one that matters.
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

    /// Decides a fence's info string into "render plain" or "ask hljs for this name".
    ///
    /// ⚠️ ONLY the meaningless tokens return `.renderPlain`, and that is the whole of CF-2. The
    /// defect was that `""` (a bare fence — the most common shape in model output), `code`, `text`
    /// and `plaintext` resolved to nil and the nil was handed to `highlightr.highlight(_:as:)`,
    /// whose nil branch is `highlightAuto` across every bundled grammar. A directory listing in a
    /// bare fence was coloured as whatever hljs guessed, under a badge reading `plaintext`.
    ///
    /// ⚠️ EVERY other token is passed THROUGH, deliberately, and the first version of this fix got
    /// that wrong. It accepted only `supported` plus the small table below and rendered everything
    /// else plain — but `supported` comes from `Highlightr.supportedLanguages()`, i.e.
    /// `hljs.listLanguages()`, which returns CANONICAL names only. hljs registers a further ~178
    /// ALIASES in a separate map (`html`, `svg`, `toml`, `ps1`, `hpp`, `jsonc`, `bat`, `tex`, …),
    /// none of them in that list and most of them not in the table below. Rejecting them turned a
    /// ```html block from correctly highlighted into flat uncoloured text — a regression the fix
    /// introduced while closing the bare-fence hole. hljs resolves its own aliases, so the right
    /// move is to let it.
    ///
    /// The residue, stated honestly: a fence with a genuinely unknown token (`DijkstraSolver.java`)
    /// still reaches Highlightr, `hljs.highlight` returns undefined, and Highlightr falls back to
    /// `highlightAuto`. That is exactly the pre-CF-2 behaviour for a NAMED fence, it is rare, and
    /// narrowing it further would require duplicating hljs's alias map — a second source of truth
    /// that drifts on the next Highlightr bump. The table below stays only because it maps a few
    /// tokens hljs does NOT know (`console`, `py3`, `node`, `docker`) onto ones it does.
    ///
    /// `nonisolated static` and pure so the rule is unit-testable without spinning up a JSContext
    /// (`SyntaxHighlightLanguageResolutionTests`).
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
