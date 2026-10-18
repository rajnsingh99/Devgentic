// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RetryRefusalSpeechTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
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
