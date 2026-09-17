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

    // MARK: - The orphan guard

    /// ⚠️⚠️ EVERYTHING ABOVE TESTS A FUNCTION; THIS TESTS THAT THE COMPOSER STILL CALLS IT.
    ///
    /// Delete the `if suggestionsActive { … }` block from `CustomTextEditor.keyDown` and all five
    /// tests above stay green while the `/` picker goes back to exactly what the blocker was:
    /// rendered, populated, and deaf to Return and the arrow keys. That is the defect shape this
    /// extraction was created to fix, so leaving it unguarded repeats it one level up.
    ///
    /// Asserted on the source because `keyDown` is an `NSTextView` override reached only by a real
    /// key event — there is no seam a unit test can reach. Modelled on
    /// `SkillLaunchSequenceTests.testDevgenticAppStillRunsTheLaunchSequence`, which guards the same
    /// class of defect at launch.
    func testTheComposerStillRoutesKeysThroughTheDecision() throws {
        let source = try Self.read("Devgentic/Interfaces/Shared/ChatInput/CustomTextEditor.swift")

        XCTAssertTrue(source.contains("ComposerSuggestionKeyRouting.anyPickerIsOpen("),
                      "keyDown must consult the routing decision — without the call, an open picker cannot see Return or the arrows")

        // ⚠️ Anchored on the CALL and on the keyCodes it gates, not merely on the symbol appearing
        // somewhere in the file: a leftover `let suggestionsActive = …` whose result is never
        // branched on would satisfy a bare `contains` while routing nothing.
        let call = try XCTUnwrap(source.range(of: "ComposerSuggestionKeyRouting.anyPickerIsOpen("))
        let branch = try XCTUnwrap(source.range(of: "if suggestionsActive {"))
        XCTAssertTrue(call.lowerBound < branch.lowerBound,
                      "the decision must be computed and then BRANCHED ON; a computed-and-ignored value routes nothing")

        let after = String(source[branch.upperBound...].prefix(400))
        for keyCode in ["125", "126", "36"] {   // down, up, Return
            XCTAssertTrue(after.contains("case \(keyCode):"),
                          "the picker branch must claim keyCode \(keyCode) — that is what the blocker was missing")
        }
    }

    /// ⚠️ The routing must sit AFTER the IME guard. A composition in progress belongs to AppKit, and
    /// hijacking Return mid-composition commits the wrong candidate — a defect this composer has
    /// already shipped once.
    func testRoutingHappensAfterTheIMEGuard() throws {
        let source = try Self.read("Devgentic/Interfaces/Shared/ChatInput/CustomTextEditor.swift")
        let ime = try XCTUnwrap(source.range(of: "if hasMarkedText() {"))
        let call = try XCTUnwrap(source.range(of: "ComposerSuggestionKeyRouting.anyPickerIsOpen("))
        XCTAssertTrue(ime.lowerBound < call.lowerBound,
                      "marked text is deferred to AppKit before any suggestion routing runs")
    }

    private static func read(_ relativePath: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("Could not locate \(relativePath) from \(#filePath) — source-reading tests need the checkout present.")
    }
}
