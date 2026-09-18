// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AnnouncementRepeatSuppressionTests.swift
//  DevgenticTests
//
//  Register CF-40 — historical error cards re-announced to VoiceOver.
//
//  `ErrorMessageView` announces from `.task(id: spokenDescription)`, which fires on view
//  APPEARANCE as well as on id change, and `AccessibilityAnnouncer` held no already-said state.
//  The transcript is a LazyVStack, so scrolling an old error card back into view — or switching
//  conversations and back — rebuilt the view and spoke a days-old failure again as if it had just
//  happened.
//
//  These test the rule directly: `announceOnce` returns immediately when VoiceOver is off, which
//  is every test environment, so `claimAnnouncement` is the only observable form of it.
//
//  ⚠️ SCOPE, pinned here so nobody reads these tests as more than they are. They exercise the
//  RULE, not the keys production passes it. A caller that supplies no `announcementKey` still
//  keys on the error SENTENCE, so the rule silences a genuine second failure worded identically
//  exactly as it silences a rebuild. Both production callers now supply one, so that fallback is
//  currently unexercised in the app: `MediaArtifactImageView` passes artifact id + attempt, and
//  the agent `.error` card passes message id + `generationAttempts`.
//  `MediaArtifactImageView` does supply one (artifact id + a Retry-incremented attempt), so a
//  retry that fails the same way speaks again; nothing below covers that wiring.
//

import XCTest
@testable import devgentic

@MainActor
final class AnnouncementRepeatSuppressionTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // The registry is process-wide and deliberately outlives a conversation switch, so it also
    // outlives a test — cleared on both sides so neither these nor anything else inherits it.
    override func setUp() async throws {
        AccessibilityAnnouncer.resetRepeatSuppressionForTesting()
    }

    override func tearDown() async throws {
        AccessibilityAnnouncer.resetRepeatSuppressionForTesting()
    }

    func testAFirstAnnouncementIsAlwaysSpoken() {
        XCTAssertTrue(AccessibilityAnnouncer.claimAnnouncement(key: "Error: Boom", at: t0))
    }

    /// ⚠️ THE CF-40 PIN. A repeat of the same key inside the window is suppressed.
    ///
    /// It is suppressed whatever caused it: the rule reads a sentence, and a sentence says
    /// nothing about whether the card was rebuilt or the failure happened again. This test
    /// pins the suppression, NOT a claim that the announcer told a rebuild from a recurrence —
    /// see `repeatSuppressionWindow` for why it cannot, and what a real fix needs.
    func testARepeatOfTheSameKeyInsideTheWindowIsSuppressed() {
        XCTAssertTrue(AccessibilityAnnouncer.claimAnnouncement(key: "Error: Boom", at: t0))
        XCTAssertFalse(AccessibilityAnnouncer.claimAnnouncement(key: "Error: Boom", at: t0.addingTimeInterval(2)))
        XCTAssertFalse(AccessibilityAnnouncer.claimAnnouncement(key: "Error: Boom", at: t0.addingTimeInterval(120)))
    }

    /// Two different errors on screen must both be spoken — suppression is per key, not global.
    func testDifferentAnnouncementsAreIndependent() {
        XCTAssertTrue(AccessibilityAnnouncer.claimAnnouncement(key: "Error: Boom", at: t0))
        XCTAssertTrue(AccessibilityAnnouncer.claimAnnouncement(key: "Error: Bang", at: t0))
    }

    /// The window is 300 seconds, and it is a coarse rebuild filter — not a discriminator
    /// between a rebuild and a new event. Past the window the key is simply forgotten and the
    /// same sentence speaks again; INSIDE it (see the test above) a genuine second failure with
    /// identical wording is silenced along with the rebuilds. Both halves are the same rule.
    func testTheSameTextSpeaksAgainAfterTheWindow() {
        XCTAssertEqual(AccessibilityAnnouncer.repeatSuppressionWindow, 300)
        XCTAssertTrue(AccessibilityAnnouncer.claimAnnouncement(key: "Error: Boom", at: t0))
        XCTAssertFalse(AccessibilityAnnouncer.claimAnnouncement(key: "Error: Boom", at: t0.addingTimeInterval(299)))
        XCTAssertTrue(AccessibilityAnnouncer.claimAnnouncement(key: "Error: Boom", at: t0.addingTimeInterval(301)))
    }

    /// A claim that AppKit then failed to post (no window) must not silence the next attempt —
    /// nothing was said, so nothing has been announced.
    func testReleasingAnUnspokenClaimLetsItBeRetried() {
        XCTAssertTrue(AccessibilityAnnouncer.claimAnnouncement(key: "Error: Boom", at: t0))
        AccessibilityAnnouncer.releaseAnnouncement(key: "Error: Boom")
        XCTAssertTrue(AccessibilityAnnouncer.claimAnnouncement(key: "Error: Boom", at: t0.addingTimeInterval(1)))
    }

    /// The registry is bounded at 32 keys, evicting oldest-first — a long session must not grow
    /// it forever. The trade is explicit: after 32 distinct announcements inside one window the
    /// earliest can be re-announced once.
    func testTheRegistryIsBoundedAndEvictsTheOldestFirst() {
        XCTAssertEqual(AccessibilityAnnouncer.maxTrackedKeys, 32)

        for index in 0..<33 {
            XCTAssertTrue(
                AccessibilityAnnouncer.claimAnnouncement(key: "key-\(index)",
                                                         at: t0.addingTimeInterval(Double(index))),
                "key-\(index) is new and must be granted"
            )
        }

        let now = t0.addingTimeInterval(40)
        XCTAssertTrue(AccessibilityAnnouncer.claimAnnouncement(key: "key-0", at: now),
                      "The oldest key should have been evicted by the cap.")
        XCTAssertFalse(AccessibilityAnnouncer.claimAnnouncement(key: "key-32", at: now),
                       "The newest key must still be suppressed — eviction is oldest-first, not a flush.")
    }

    /// Entries older than the window are dropped rather than sitting in the registry until the
    /// cap evicts them.
    func testExpiredEntriesDoNotOccupyTheCap() {
        for index in 0..<10 {
            _ = AccessibilityAnnouncer.claimAnnouncement(key: "old-\(index)", at: t0)
        }
        let later = t0.addingTimeInterval(AccessibilityAnnouncer.repeatSuppressionWindow + 1)
        XCTAssertTrue(AccessibilityAnnouncer.claimAnnouncement(key: "old-0", at: later))
        XCTAssertTrue(AccessibilityAnnouncer.claimAnnouncement(key: "old-9", at: later))
    }
}
