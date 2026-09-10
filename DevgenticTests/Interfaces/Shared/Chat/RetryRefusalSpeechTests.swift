// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  RetryRefusalSpeechTests.swift
//  DevgenticTests
//
//  Register CF-42 — a disabled Retry told VoiceOver nothing.
//
//  `.help(refusal?.userFacingReason ?? …)` is a hover tooltip, i.e. mouse-only, while
//  `.accessibilityLabel("Retry generating response")` was a constant. `.disabled(refusal != nil)`
//  had already removed the button from the actionable set, so a screen-reader user met a control
//  that would not respond and offered no reason.
//
//  Scope: this pins the string handed to the modifier. That the modifier reaches the user is a
//  VoiceOver (⌘F5) check — see the note in ChatAccessibilitySemanticsTests.
//
//  ⚠️ FOLLOW-UP (audit). On the `.error` block path that label was reaching nobody. The error
//  card and this button sat in a VStack carrying `.accessibilityElement(children: .combine)`
//  followed by an explicit `.accessibilityLabel("Error: … . …")`: `.combine` merges the children
//  into ONE element and drops their individual labels, and the explicit label then replaced the
//  merged one — taking this button's refusal reason and `ErrorMessageView`'s suggestion line
//  with it. `AgentBubbleContentView.swift:219` is now `.contain` with no hand-written label,
//  matching the ASM-2 Retry above it, which was already under `.contain` and where the label did
//  land. Accessibility modifiers cannot be read back from a hosted view, so that half of the row
//  stays a ⌘F5 check; the strings below are the testable half.
//

import XCTest
@testable import devgentic

final class RetryRefusalSpeechTests: XCTestCase {

    /// The admitted case is untouched — no "unavailable" on a live button.
    func testAdmittedRetryKeepsItsPlainLabel() {
        XCTAssertEqual(RetryMessageButton.spokenLabel(for: nil), "Retry generating response")
    }

    /// ⚠️ THE CF-42 PIN. The permanent refusal: the reason is the only thing that tells the user
    /// not to keep trying.
    func testAttemptCapRefusalIsSpokenInFull() {
        let label = RetryMessageButton.spokenLabel(for: RunAdmissionPolicy.Refusal.attemptCapReached(attempts: 3, cap: 3))
        XCTAssertEqual(label,
                       "Retry generating response, unavailable. This message has reached its limit of 3 attempts.")
    }

    /// The transient refusal names the action that clears it.
    func testBusyRefusalTellsTheUserWhatToDo() {
        let label = RetryMessageButton.spokenLabel(for: RunAdmissionPolicy.Refusal.conversationBusy(existingMessageID: UUID()))
        XCTAssertTrue(label.hasPrefix("Retry generating response, unavailable. "), label)
        XCTAssertTrue(label.contains("Stop"), label)
    }

    /// `userFacingReason` promises it "must not name internal ids" — the label inherits that
    /// promise, and it is the one refusal that carries an id at all.
    func testTheSpokenLabelNeverLeaksAMessageID() {
        let id = UUID()
        let label = RetryMessageButton.spokenLabel(for: RunAdmissionPolicy.Refusal.conversationBusy(existingMessageID: id))
        XCTAssertFalse(label.contains(id.uuidString), label)
        XCTAssertFalse(label.lowercased().contains(id.uuidString.prefix(8).lowercased()), label)
    }

    func testEveryRefusalProducesADistinctSpokenReason() {
        let labels = [
            RetryMessageButton.spokenLabel(for: RunAdmissionPolicy.Refusal.conversationBusy(existingMessageID: UUID())),
            RetryMessageButton.spokenLabel(for: RunAdmissionPolicy.Refusal.attemptCapReached(attempts: 3, cap: 3)),
            RetryMessageButton.spokenLabel(for: RunAdmissionPolicy.Refusal.noResponseToRegenerate)
        ]
        XCTAssertEqual(Set(labels).count, labels.count, "\(labels)")
        for label in labels {
            XCTAssertNotEqual(label, "Retry generating response",
                              "A refused Retry must not read like an available one.")
        }
    }
}
