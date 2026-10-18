// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ComposerTextRewritingTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
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
