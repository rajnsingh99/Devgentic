// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  PromptWindowManagerTests.swift
//  DevgenticTests
//
//  Created on 08/08/26.
//
//  Register B7 — the floating prompt editors' window lifetime.
//
//  ⚠️ A71 and A72 were both recorded as "AppKit lifetime with no unit-testable seam, verified by
//  inspection". That was true of the leak itself, and NOT true of the part that actually destroys
//  user data: `windowWillClose` is a plain method taking a `Notification`, and the callbacks it
//  clears are internal `var`s. The defect — a close notification from a window the manager no
//  longer tracks wiping the LIVE editor's callbacks — is therefore directly reproducible without
//  presenting anything on screen.
//

import XCTest
import AppKit
@testable import devgentic

@MainActor
final class PromptWindowManagerTests: XCTestCase {

    /// A window the manager has never tracked — the orphan's stand-in.
    private func foreignWindow() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                 styleMask: [.titled], backing: .buffered, defer: true)
    }

    private func closeNotification(for window: NSWindow) -> Notification {
        Notification(name: NSWindow.willCloseNotification, object: window)
    }

    // MARK: - Advanced editor (the one B7 is filed against)

    /// ⚠️ THE B7 REGRESSION. Minimizing the editor and re-opening it used to abandon the old
    /// window while it was still the manager's delegate. Closing that orphan then ran
    /// `windowWillClose`, which cleared the LIVE window's four callbacks — after which
    /// `closeWindowCommittingChanges()` called a nil `commitChanges` and the user's typed prompt
    /// was discarded with no error and no log.
    func testAForeignWindowClosingDoesNotWipeTheAdvancedEditorsCallbacks() {
        let manager = AdvancedPromptWindowManager()
        var committed = false

        manager.checkChanges = { true }
        manager.saveChanges = {}
        manager.discardChanges = {}
        manager.commitChanges = { committed = true }

        manager.windowWillClose(closeNotification(for: foreignWindow()))

        XCTAssertNotNil(manager.commitChanges,
                        "an untracked window's close must not clear the live editor's commit hook")
        XCTAssertNotNil(manager.checkChanges, "nor its unsaved-changes check")
        XCTAssertNotNil(manager.saveChanges)
        XCTAssertNotNil(manager.discardChanges)

        // And the hook still does its job — the text is committed, not lost.
        manager.closeWindowCommittingChanges()
        XCTAssertTrue(committed, "the typed prompt must still be written back")
    }

    /// The other half: `checkChanges` is what raises the Unsaved Changes prompt. If a stray close
    /// nils it, `windowShouldClose` returns true with no prompt and the edits go silently.
    func testTheUnsavedChangesPromptSurvivesAForeignClose() {
        let manager = AdvancedPromptWindowManager()
        manager.checkChanges = { true }

        manager.windowWillClose(closeNotification(for: foreignWindow()))

        XCTAssertEqual(manager.checkChanges?(), true,
                       "the dirty check must survive, or the close prompt silently stops appearing")
    }

    // MARK: - Simple editor (the twin, same defect)

    /// The bot/scheduler editor had the identical `isVisible` reuse test and the identical
    /// window-blind `windowWillClose`. A71 fixed its red-button leak and left the minimize one.
    func testTheSimpleEditorAlsoIgnoresAForeignClose() {
        let manager = SimplePromptWindowManager()
        // Nothing to assert on callbacks here — this manager has none — so the observable
        // property is simply that handling a foreign close does not trap or clear state.
        manager.windowWillClose(closeNotification(for: foreignWindow()))
        manager.updateTitle(botName: "Still alive")
    }
}
