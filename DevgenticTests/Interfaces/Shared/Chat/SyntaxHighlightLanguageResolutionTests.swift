// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SyntaxHighlightLanguageResolutionTests.swift
//  DevgenticTests
//
//  CF-2 (Chat_Production_Readiness_Fresh.md): `SyntaxHighlightService.highlight` resolved a
//  bare / unknown fence info string to nil and then passed that nil STRAIGHT THROUGH to
//  `highlightr.highlight(_:as:)`, whose nil branch is `highlightAuto` — a guess across all
//  ~192 bundled grammars, once per streaming flush, colouring a `plaintext`-badged block as
//  whatever grammar won (`let x = 1` → `abnf`). Two doc comments in the file described a
//  guard that did not exist.
//
//  The fix makes the resolution a pure `nonisolated static func resolvedLanguage(_:supported:) -> LanguageResolution`
//  and has `highlight` return nil BEFORE Highlightr is asked anything when it resolves to
//  nil, plus a `Task.isCancelled` check at the top so a flush that has already been
//  superseded does not run to completion on the serialised actor.
//
//  Discrimination: the pure tests pin the rule; the actor tests are the ones that fail on
//  the old code — with the pass-through, `highlight(_, language: "")` returned a NON-nil
//  `highlightAuto` result, and a pre-cancelled task still produced a highlight.
//

import XCTest
@testable import devgentic

final class SyntaxHighlightLanguageResolutionTests: XCTestCase {

    /// A stand-in for Highlightr's lowercased `supportedLanguages()` list.
    private let supported: Set<String> = ["swift", "bash", "python", "javascript", "json"]

    // MARK: - Pure rule

    func test_bareAndPlaceholderInfoStrings_resolveToNil() {
        for info in ["", "code", "text", "plaintext", "  ", "\n"] {
            XCTAssertEqual(SyntaxHighlightService.resolvedLanguage(info, supported: supported), .renderPlain,
                         "'\(info)' is not a grammar and must never reach Highlightr")
        }
    }

    /// ⚠️ THE REGRESSION GUARD. `supported` is `hljs.listLanguages()`, which returns CANONICAL
    /// names only — hljs registers ~178 further ALIASES in a separate map that this list does not
    /// contain and the app's small table does not duplicate. The first version of this fix
    /// rejected anything outside those two sets, which turned every ```html, ```svg, ```toml,
    /// ```ps1 and ```hpp block from correctly highlighted into flat uncoloured text. A name hljs
    /// can resolve must reach it.
    func test_hljsAliasesAreNotRejected() {
        for alias in ["html", "svg", "toml", "ps1", "hpp", "jsonc", "bat", "tex"] {
            XCTAssertEqual(SyntaxHighlightService.resolvedLanguage(alias, supported: supported),
                           .use(alias),
                           "'\(alias)' is an hljs alias — passing it through is what lets hljs resolve it")
        }
    }

    /// An unrecognised token is passed through too, and that is deliberate: hljs resolves its own
    /// aliases, and a fence carrying a genuinely unknown token falls back to auto-detect exactly
    /// as it did before this fix. The bare-fence hole — the actual defect — is closed by
    /// `.renderPlain` above, not by second-guessing named fences.
    func test_unknownNamedToken_isPassedThroughRatherThanRenderedPlain() {
        XCTAssertEqual(SyntaxHighlightService.resolvedLanguage("zzz", supported: supported), .use("zzz"))
        XCTAssertEqual(SyntaxHighlightService.resolvedLanguage("DijkstraSolver.java", supported: supported),
                       .use("dijkstrasolver.java"))
    }

    func test_alias_resolvesToItsHljsName() {
        XCTAssertEqual(SyntaxHighlightService.resolvedLanguage("sh", supported: supported), .use("bash"))
        XCTAssertEqual(SyntaxHighlightService.resolvedLanguage("py", supported: supported), .use("python"))
        XCTAssertEqual(SyntaxHighlightService.resolvedLanguage("c++", supported: supported), .use("cpp"))
    }

    /// An alias target is an hljs identifier by construction, so it resolves even before
    /// (or without) the supported set — the set only vouches for NON-alias names.
    func test_alias_resolvesWithoutSupportedSet() {
        XCTAssertEqual(SyntaxHighlightService.resolvedLanguage("sh", supported: []), .use("bash"))
    }

    func test_supportedLanguage_resolvesToItself() {
        XCTAssertEqual(SyntaxHighlightService.resolvedLanguage("swift", supported: supported), .use("swift"))
    }

    /// A name absent from the canonical list is still handed to hljs, because that list is
    /// `hljs.listLanguages()` — canonical names ONLY — and hljs resolves ~178 aliases it does not
    /// contain. Treating "absent from the set" as "no grammar" is what broke ```html.
    func test_nameAbsentFromTheCanonicalSet_isStillHandedToHljs() {
        XCTAssertEqual(SyntaxHighlightService.resolvedLanguage("swift", supported: ["bash"]),
                       .use("swift"),
                       "The canonical list does not vouch for every name hljs knows — only the meaningless tokens render plain.")
    }

    /// Fence info strings arrive with the model's casing and trailing whitespace.
    func test_infoString_isTrimmedAndLowercased() {
        XCTAssertEqual(SyntaxHighlightService.resolvedLanguage("SWIFT ", supported: supported), .use("swift"))
        XCTAssertEqual(SyntaxHighlightService.resolvedLanguage("\tSh\n", supported: supported), .use("bash"))
    }

    // MARK: - Shared actor (integration)

    /// Probe: does Highlightr load in this host at all? Returns false when it does not,
    /// so the assertions that depend on a real grammar can `XCTSkip` instead of passing
    /// vacuously (nil-for-any-reason would make the bare-fence assertion meaningless).
    private func highlightrAvailable() async -> Bool {
        let swift = await SyntaxHighlightService.shared.highlight(
            "let x = 1", language: "swift", themeName: "atom-one-dark"
        )
        return swift != nil
    }

    /// The CF-2 mechanism: a bare fence must come back nil — rendered plain — while the same
    /// code under a real grammar comes back highlighted. On the old pass-through the bare
    /// call returned a non-nil `highlightAuto` result.
    func test_bareFence_returnsNil_whileKnownGrammarHighlights() async throws {
        // Hoisted: `XCTSkipUnless` takes a synchronous autoclosure, which cannot `await`.
        let available = await highlightrAvailable()
        try XCTSkipUnless(available, "Highlightr failed to load in this test host")

        let bare = await SyntaxHighlightService.shared.highlight(
            "let x = 1", language: "", themeName: "atom-one-dark"
        )
        XCTAssertNil(bare, "a bare fence must not be handed to Highlightr's highlightAuto")

        let placeholder = await SyntaxHighlightService.shared.highlight(
            "let x = 1", language: "code", themeName: "atom-one-dark"
        )
        XCTAssertNil(placeholder, "'code' is the parser's placeholder, not a grammar")
    }

    /// A highlight whose task was cancelled before it reached the actor must not run:
    /// `AsyncHighlightedCodeView` supersedes the previous flush's task on every flush, and
    /// before the fix each superseded call still ran to completion, serialised ahead of
    /// the one the user will actually see.
    func test_preCancelledTask_skipsTheHighlight() async throws {
        // Hoisted: `XCTSkipUnless` takes a synchronous autoclosure, which cannot `await`.
        let available = await highlightrAvailable()
        try XCTSkipUnless(available, "Highlightr failed to load in this test host")

        let task = Task.detached { () -> Bool in
            // Park until the cancel below has landed, then make the call as a cancelled task.
            while !Task.isCancelled { await Task.yield() }
            let result = await SyntaxHighlightService.shared.highlight(
                "let x = 1", language: "swift", themeName: "atom-one-dark"
            )
            return result != nil
        }
        task.cancel()
        let produced = await task.value
        XCTAssertFalse(produced, "a cancelled task must return nil without running the highlight")
    }
}
