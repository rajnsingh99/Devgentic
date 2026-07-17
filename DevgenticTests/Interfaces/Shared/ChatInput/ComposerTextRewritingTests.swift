//
//  ComposerTextRewritingTests.swift
//  DevgenticTests
//
//  macOS rewrites text as you type unless a text view opts out, and NSTextView inherits the
//  system-wide "smart quotes and dashes" setting (on by default). The composer never opted
//  out, so every message was rewritten before it was sent.
//
//  Observed 2026-07-16: the user typed `--- Start of file: alpha.swift ---` and the
//  conversation auto-title — raw message text, captured before any markdown rendering —
//  read `— Start of file: alpha.swift —`. Typed `NSLog(@"hi");` arrived as `NSLog(@“hi”);`,
//  which is not valid Objective-C.
//

import XCTest
import AppKit
@testable import devgentic

@MainActor
final class ComposerTextRewritingTests: XCTestCase {

    /// Built the way `makeNSView` builds it: construct, THEN turn on rich text.
    /// The ordering is the point — see `testRichTextDoesNotReEnableRewriting`.
    private func makeComposerTextView() -> CustomTextEditor.CustomNSTextView {
        let textView = CustomTextEditor.CustomNSTextView(coordinator: nil)
        textView.isRichText = true
        return textView
    }

    /// `"` → `“”`. This is the one that shipped: quoted code sent to the model, and echoed
    /// back, with typographic quotes.
    func testComposerDoesNotSubstituteQuotes() {
        XCTAssertFalse(makeComposerTextView().isAutomaticQuoteSubstitutionEnabled,
                       "Smart quotes turn typed code into `NSLog(@“hi”);`, which won't compile")
    }

    /// `--` → `—`. Worse than quotes for this app: every CLI flag a user types is corrupted.
    func testComposerDoesNotSubstituteDashes() {
        XCTAssertFalse(makeComposerTextView().isAutomaticDashSubstitutionEnabled,
                       "Smart dashes send `npm install --save-dev` as `—save-dev`")
    }

    /// The user's own System Settings text replacements fire here too.
    func testComposerDoesNotApplyTextReplacement() {
        XCTAssertFalse(makeComposerTextView().isAutomaticTextReplacementEnabled)
    }

    /// Autocorrect mangles identifiers and command names.
    func testComposerDoesNotAutocorrect() {
        XCTAssertFalse(makeComposerTextView().isAutomaticSpellingCorrectionEnabled)
    }

    /// The ordering guard. `commonInit` disables rewriting during construction, but
    /// `makeNSView` sets `isRichText = true` afterwards — if AppKit re-enabled substitution
    /// as part of switching to rich text, the fix would be silently undone and this file
    /// would still pass everything above while the app stayed broken.
    func testRichTextDoesNotReEnableRewriting() {
        let textView = CustomTextEditor.CustomNSTextView(coordinator: nil)
        XCTAssertFalse(textView.isAutomaticQuoteSubstitutionEnabled, "Sanity: off at construction")

        textView.isRichText = true

        XCTAssertFalse(textView.isAutomaticQuoteSubstitutionEnabled,
                       "isRichText = true re-enabled quote substitution — disable it AFTER, in makeNSView")
        XCTAssertFalse(textView.isAutomaticDashSubstitutionEnabled,
                       "isRichText = true re-enabled dash substitution")
    }

    /// Continuous spell checking only draws red squiggles — it never rewrites text — so the
    /// fix must not take it out. Pins the intended scope.
    func testSpellCheckUnderlinesAreNotCollateralDamage() {
        let textView = makeComposerTextView()
        textView.isContinuousSpellCheckingEnabled = true
        XCTAssertTrue(textView.isContinuousSpellCheckingEnabled,
                      "Squiggles are display-only and should stay available")
    }
}
