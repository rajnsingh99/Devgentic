// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ComposerIMETests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
import AppKit
@testable import devgentic

@MainActor
final class ComposerIMETests: XCTestCase {

    // MARK: - Harness

    private func makeEditor(
        onCommit: @escaping (NSAttributedString) -> Void = { _ in },
        onNavigateQueryHistory: ((MainApplicationViewModel.QueryNavigationDirection) -> Void)? = nil
    ) -> CustomTextEditor {
        CustomTextEditor(
            text: .constant(""),
            onCommit: onCommit,
            minHeight: 30,
            maxHeight: 200,
            showPromptSuggestions: .constant(false),
            suggestionQuery: .constant(""),
            activePromptTriggerRange: .constant(nil),
            showFileSuggestions: .constant(false),
            fileSuggestionQuery: .constant(""),
            activeFileMentionTriggerRange: .constant(nil),
            showSkillSuggestions: .constant(false),
            skillSuggestionQuery: .constant(""),
            activeSkillTriggerRange: .constant(nil),
            attributedTextInsertion: .constant(nil),
            onNavigateQueryHistory: onNavigateQueryHistory
        )
    }

    /// Hosts the view in a window and makes it first responder — key handling and the
    /// input context both need a real responder chain.
    ///
    /// ⚠️ The coordinator is returned so the CALLER can retain it: `CustomNSTextView`
    /// holds it `weak`, so if it only lived in here it would deallocate the moment this
    /// returns, every `coordinator?.parent.onCommit(...)` would nil-chain, and the tests
    /// below would pass vacuously. (They did, until the control cases caught it.)
    private func makeHosted(_ editor: CustomTextEditor)
        -> (CustomTextEditor.CustomNSTextView, NSWindow, CustomTextEditor.Coordinator) {
        let coordinator = CustomTextEditor.Coordinator(editor, defaultTypingAttributes: [:])
        let tv = CustomTextEditor.CustomNSTextView(coordinator: coordinator)
        tv.isRichText = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = tv
        window.makeFirstResponder(tv)
        return (tv, window, coordinator)
    }

    private func keyEvent(keyCode: UInt16, characters: String) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        )!
    }

    /// Puts the view into IME composition the way an input method does.
    private func beginComposing(_ tv: CustomTextEditor.CustomNSTextView, _ text: String) {
        tv.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0),
                         replacementRange: NSRange(location: 0, length: 0))
    }

    // MARK: - Return

    func testReturnDuringCompositionDoesNotSend() throws {
        var didCommit = false
        let (tv, window, coordinator) = makeHosted(makeEditor(onCommit: { _ in didCommit = true }))
        XCTAssertNotNil(window.contentView)
        XCTAssertNotNil(coordinator, "coordinator must outlive the view (held weak)")

        beginComposing(tv, "にほん")
        try XCTSkipUnless(tv.hasMarkedText(), "Environment could not enter marked-text composition")

        tv.keyDown(with: keyEvent(keyCode: 36, characters: "\r"))

        XCTAssertFalse(
            didCommit,
            "Return during IME composition must CONFIRM the candidate, not send the half-composed message"
        )
    }

    /// CONTROL — proves the harness really can reach the send path, so the assertion
    /// above is meaningful rather than vacuously true.
    func testReturnWithoutCompositionStillSends() {
        var didCommit = false
        let (tv, window, coordinator) = makeHosted(makeEditor(onCommit: { _ in didCommit = true }))
        XCTAssertNotNil(window.contentView)
        XCTAssertNotNil(coordinator, "coordinator must outlive the view (held weak)")
        XCTAssertFalse(tv.hasMarkedText(), "precondition: nothing is being composed")

        tv.keyDown(with: keyEvent(keyCode: 36, characters: "\r"))

        XCTAssertTrue(didCommit, "Return with no composition active must still send")
    }

    // MARK: - Arrow keys

    func testArrowDuringCompositionDoesNotDriveQueryHistory() throws {
        var navigated = false
        let (tv, window, coordinator) = makeHosted(makeEditor(onNavigateQueryHistory: { _ in navigated = true }))
        XCTAssertNotNil(window.contentView)
        XCTAssertNotNil(coordinator, "coordinator must outlive the view (held weak)")

        beginComposing(tv, "にほん")
        try XCTSkipUnless(tv.hasMarkedText(), "Environment could not enter marked-text composition")

        // Exactly ONE key, while composition is verified active. Handing the event to
        // AppKit can itself END the composition, so a second key here would no longer be
        // an IME case and would legitimately drive query history — asserting across that
        // state change tested the wrong thing.
        tv.keyDown(with: keyEvent(keyCode: 126, characters: ""))   // Up

        XCTAssertFalse(
            navigated,
            "Arrows during IME composition belong to the candidate list, not query history"
        )
    }

    /// CONTROL — an empty composer with no composition navigates query history as before.
    func testArrowWithoutCompositionStillDrivesQueryHistory() {
        var navigated = false
        let (tv, window, coordinator) = makeHosted(makeEditor(onNavigateQueryHistory: { _ in navigated = true }))
        XCTAssertNotNil(window.contentView)
        XCTAssertNotNil(coordinator, "coordinator must outlive the view (held weak)")
        XCTAssertFalse(tv.hasMarkedText(), "precondition: nothing is being composed")

        tv.keyDown(with: keyEvent(keyCode: 126, characters: ""))   // Up on an empty field

        XCTAssertTrue(navigated, "Up on an empty composer still recalls the previous query")
    }
}
