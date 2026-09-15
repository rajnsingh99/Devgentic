// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ComposerSuggestionKeyRoutingTests.swift
//  devgenticTests
//
//  Which keystrokes belong to an open suggestion picker rather than to the text.
//
//  ⚠️⚠️ THIS FILE EXISTS BECAUSE THE OMISSION SHIPPED. When the `/` skill picker was added, the
//  routing test inside `keyDown` still read `showPromptSuggestions || showFileSuggestions`. The
//  picker opened, filtered and highlighted correctly — and was completely deaf: arrows did not move
//  the selection, and Return fell through to `onCommit`, SENDING the half-typed `/co do the thing`
//  to the model as literal text. It was a `let` inside an `NSTextView` subclass, so nothing could
//  reach it; the decision was hoisted into `ComposerSuggestionKeyRouting` so this file could.
//

import XCTest
@testable import devgentic

final class ComposerSuggestionKeyRoutingTests: XCTestCase {

    /// ⚠️ THE REGRESSION. Before the fix this returned false and Return sent raw text.
    ///
    /// **Mutation check:** drop `|| skill` from `anyPickerIsOpen` and only this test goes red.
    func testTheSkillPickerClaimsTheKeyboard() {
        XCTAssertTrue(ComposerSuggestionKeyRouting.anyPickerIsOpen(prompt: false, file: false, skill: true),
                      "with the / picker open, Return must accept the highlighted skill — not send the half-typed text")
    }

    func testThePromptPickerClaimsTheKeyboard() {
        XCTAssertTrue(ComposerSuggestionKeyRouting.anyPickerIsOpen(prompt: true, file: false, skill: false))
    }

    func testTheFilePickerClaimsTheKeyboard() {
        XCTAssertTrue(ComposerSuggestionKeyRouting.anyPickerIsOpen(prompt: false, file: true, skill: false))
    }

    /// The control that makes the three above mean something: with nothing open, Return must reach
    /// the send path. A routing function that returned true unconditionally would swallow every
    /// Return in the composer and make the app unable to send a message at all.
    func testWithNoPickerOpenTheKeystrokeBelongsToTheText() {
        XCTAssertFalse(ComposerSuggestionKeyRouting.anyPickerIsOpen(prompt: false, file: false, skill: false))
    }

    /// ⚠️ Every trigger `TextTriggerAnalyzer` can produce must be represented here. A new case added
    /// there without a parameter here is a mouse-only trigger, and silently so — which is exactly
    /// the shape of the defect this file was written for.
    func testEveryTriggerTypeHasARoutingParameter() {
        let routed = 3 // prompt, file, skill — the parameters of `anyPickerIsOpen`
        XCTAssertEqual(TextTriggerAnalyzer.TriggerType.allCases.count, routed,
                       "a trigger type with no routing parameter opens a picker the keyboard cannot reach")
    }
}
