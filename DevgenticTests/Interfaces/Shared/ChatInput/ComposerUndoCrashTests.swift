//
//  ComposerUndoCrashTests.swift
//  DevgenticTests
//
//  Regression guard for audit finding #3 (2026-07-18): the composer crashed on ⌘Z
//  after sending a message.
//
//  Root cause: the composer's programmatic clear (send / query-history nav / draft
//  restore) replaced the whole field via a direct `textStorage.replaceCharacters`,
//  bypassing NSTextView's undo registration. The coalesced `NSUndoTyping` group from
//  the user's typing kept a range into the OLD text; after the clear the field is
//  empty, so a subsequent ⌘Z applied that stale range and aborted the process:
//    NSRangeException — Range {0, N} out of bounds; string length 0
//    -[NSTextStorage(NSUndo) _undoRedoAttributedSubstringFromRange:]
//    -[NSUndoTyping undoRedo:]
//  (Reproduced standalone, exit 134; `breakUndoCoalescing()` alone did NOT fix it —
//  the stale action is already registered, so it must be discarded, not merely closed.)
//
//  Fix: `CustomNSTextView.replaceEntireContents(with:selecting:)` drops the undo
//  history after the external replacement.
//
//  NB the *real* NSUndoTyping group only registers through live key events, which the
//  headless test host can't drive (no window-server session) — so the full-fidelity
//  repro below XCTSkips there and the standalone binary is the RED→GREEN proof. The
//  deterministic test pins the fix's contract (clear ⇒ empty undo stack) and always runs.
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
}
