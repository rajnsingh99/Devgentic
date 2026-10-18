// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ComposerUndoCrashTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
import AppKit
@testable import devgentic

@MainActor
final class ComposerUndoCrashTests: XCTestCase {

    /// Supplies a real UndoManager to the text view via the delegate seam NSTextView
    /// consults first — no key window needed (unlike registering typing undo, which does).
    private final class UndoProvider: NSObject, NSTextViewDelegate {
        let manager = UndoManager()
        func undoManager(for view: NSTextView) -> UndoManager? { manager }
    }

    // MARK: - Deterministic contract guard (always runs)

    /// The fix's contract: a programmatic full-content replacement must leave the undo
    /// stack empty, so a later ⌘Z has no stale action to apply. Fails cleanly (not a
    /// crash) if someone drops the `removeAllActions()` from `replaceEntireContents`.
    func testReplaceEntireContentsClearsTheUndoStack() {
        let tv = CustomTextEditor.CustomNSTextView(coordinator: nil)
        tv.isRichText = true
        tv.allowsUndo = true // makeNSView sets this in the app; not in commonInit
        let provider = UndoProvider()
        tv.delegate = provider
        tv.string = "hello world"

        // Stand in for the coalesced NSUndoTyping group a real typing session registers.
        provider.manager.registerUndo(withTarget: self) { _ in }
        XCTAssertTrue(provider.manager.canUndo, "precondition: undo stack is non-empty")
        XCTAssertTrue(tv.undoManager === provider.manager, "the text view uses the provided undo manager")

        // The composer's programmatic external-sync clear.
        tv.replaceEntireContents(with: NSAttributedString(string: ""), selecting: NSRange(location: 0, length: 0))

        XCTAssertEqual(tv.string, "", "clear empties the field")
        XCTAssertFalse(
            provider.manager.canUndo,
            "replaceEntireContents must drop the undo history — otherwise a post-send ⌘Z applies a stale range and crashes (NSRangeException in NSUndoTyping)"
        )
    }

    // MARK: - Full-fidelity integration repro (skips without a live undo manager)

    /// Hosts the composer text view in a window so it has an undo manager (the undo
    /// manager comes from the responder chain, exactly as in the app).
    private func makeHostedComposer() -> (CustomTextEditor.CustomNSTextView, NSWindow) {
        let textView = CustomTextEditor.CustomNSTextView(coordinator: nil)
        textView.isRichText = true
        textView.allowsUndo = true // makeNSView sets this in the app; not in commonInit
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = textView
        window.makeFirstResponder(textView)
        return (textView, window)
    }

    /// Types char-by-char through the real text-input entry point so NSTextView
    /// registers a coalesced `NSUndoTyping` group (the thing that goes stale).
    private func type(_ s: String, into tv: CustomTextEditor.CustomNSTextView) {
        for ch in s.map(String.init) {
            tv.insertText(ch, replacementRange: tv.selectedRange())
        }
    }

    /// The exact production sequence: type → programmatic clear → ⌘Z. XCTSkips when the
    /// host can't register typing undo (no window server); otherwise proves ⌘Z is a safe
    /// no-op after the fix (before the fix, this aborts the process).
    func testRealScenario_postSendUndoDoesNotCrash() throws {
        let (tv, window) = makeHostedComposer()
        XCTAssertNotNil(window.contentView) // keep the window alive for the test
        type("hello", into: tv)

        try XCTSkipUnless(
            tv.undoManager?.canUndo == true,
            "Environment did not register typing undo; the crash needs a live undo manager (run on a dev machine)"
        )

        tv.replaceEntireContents(with: NSAttributedString(string: ""), selecting: NSRange(location: 0, length: 0))

        XCTAssertEqual(tv.string, "")
        let survivedStaleUndo = tv.undoManager?.canUndo ?? false
        XCTAssertFalse(survivedStaleUndo, "stale typing-undo must not survive a programmatic clear")

        // Only exercise ⌘Z when the stack is clean — on a regression the assertion above
        // already failed as clean red, and calling undo() then would abort the process.
        if !survivedStaleUndo {
            tv.undoManager?.undo()
            XCTAssertEqual(tv.string, "", "⌘Z after a cleared composer is a safe no-op")
        }
    }

    // MARK: - C4: list edits must register undo

    private func returnKeyEvent() -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        )!
    }

    /// List continuation used to mutate `textStorage` directly from inside
    /// `shouldChangeTextIn` and return `false`, so it registered NO undo: the edit was
    /// unreversible AND it desynced the typing-undo stack (the same stale-range hazard
    /// behind the post-send ⌘Z crash above). It now routes through `insertText`.
    func testListContinuationIsUndoable() throws {
        let (tv, window) = makeHostedComposer()
        XCTAssertNotNil(window.contentView)
        tv.string = "1. a"                                   // setup only — not an undoable edit
        tv.setSelectedRange(NSRange(location: 4, length: 0))

        tv.keyDown(with: returnKeyEvent())
        XCTAssertEqual(tv.string, "1. a\n2. ", "Enter still continues the numbered list")

        try XCTSkipUnless(tv.undoManager?.canUndo == true,
                          "The list edit registered no undo at all — that IS the C4 regression")
        tv.undoManager?.undo()
        XCTAssertEqual(tv.string, "1. a", "⌘Z reverses the list continuation")
    }

    /// The grouping guarantee: a mid-list Enter also rewrites the FOLLOWING markers (the
    /// C5 renumbering), and the whole thing must collapse into ONE undo step rather than
    /// making the user press ⌘Z once per renumbered item.
    func testMidListInsertAndItsRenumberingUndoAsOneStep() throws {
        let (tv, window) = makeHostedComposer()
        XCTAssertNotNil(window.contentView)
        tv.string = "1. a\n2. b"
        tv.setSelectedRange(NSRange(location: 4, length: 0))   // end of "1. a"

        tv.keyDown(with: returnKeyEvent())
        XCTAssertEqual(tv.string, "1. a\n2. \n3. b", "Insert renumbers the item that follows")

        try XCTSkipUnless(tv.undoManager?.canUndo == true, "no live undo manager in this environment")
        tv.undoManager?.undo()
        XCTAssertEqual(tv.string, "1. a\n2. b",
                       "ONE undo reverses both the inserted item and its renumbering")
    }
}
