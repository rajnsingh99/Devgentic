// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  MLXDownloadNotificationTests.swift
//  DevgenticTests
//
//  G13 — completion notifications. Model downloads are the longest-running operation in the
//  app (tens of minutes to hours) and the terminal transition used to write a SwiftData row
//  and nothing else, so a user who switched away had to poll the sidebar.
//
//  These pin the POLICY, which is where the judgement lives. Delivery itself goes through
//  `NotificationDispatcher`, which is already exercised elsewhere.
//

import XCTest
@testable import devgentic

final class DownloadNotificationPolicyTests: XCTestCase {

    /// A finished download must reach the user. Success can wait until they switch away —
    /// the sidebar, badge and store card all show it while the app is in front.
    func testCompletionNotifiesOnlyWhenTheUserHasSwitchedAway() {
        XCTAssertEqual(DownloadTerminalClassification.completed.notificationPolicy, .whenAway)
    }

    /// ⚠️ Failure is deliberately NOT suppressed when frontmost. Its only in-app surface is
    /// the MLX store's error banner; a user sitting in a chat would never learn the download
    /// failed.
    func testFailureNotifiesEvenWhenTheAppIsFrontmost() {
        XCTAssertEqual(DownloadTerminalClassification.failed.notificationPolicy, .always)
    }

    /// Cancel and pause are user-initiated — they pressed the button a moment ago. Notifying
    /// would be telling them what they just did.
    func testUserInitiatedStopsStaySilent() {
        XCTAssertEqual(DownloadTerminalClassification.cancelled.notificationPolicy, .silent)
        XCTAssertEqual(DownloadTerminalClassification.paused.notificationPolicy, .silent)
    }

    /// Every case must have a policy — a new terminal state that silently defaulted to
    /// "no notification" is exactly the gap G13 describes.
    /// ⚠️ Rewritten 2026-08-03. This walked a hand-written array — so a terminal state added
    /// later was skipped in silence, the very gap it claimed to close — and asserted
    /// `XCTAssertNotNil` on a non-optional `NotificationPolicy`, which cannot fail.
    func testEveryClassificationHasAnExplicitPolicy() {
        let all = DownloadTerminalClassification.allCases
        XCTAssertEqual(all.count, 4, "a terminal classification was added — give it a policy below")

        for classification in all {
            XCTAssertFalse(classification.rawValue.isEmpty)
        }

        // The asymmetry is the point, so pin it per case rather than by counting.
        XCTAssertEqual(
            Set(all.filter { $0.notificationPolicy == .silent }), [.cancelled, .paused],
            "only user-initiated stops stay silent"
        )
        XCTAssertEqual(
            Set(all.filter { $0.notificationPolicy == .always }), [.failed],
            "failure is the one state with no in-app surface a user in a chat would see"
        )
        XCTAssertEqual(
            Set(all.filter { $0.notificationPolicy == .whenAway }), [.completed],
            "success is already visible in-app; notifying while frontmost duplicates it"
        )
    }

    /// The classification is logged by `rawValue`, so those strings are part of the log
    /// contract that a field diagnosis reads.
    func testRawValuesMatchTheLoggedVocabulary() {
        XCTAssertEqual(DownloadTerminalClassification.completed.rawValue, "completed")
        XCTAssertEqual(DownloadTerminalClassification.failed.rawValue, "failed")
        XCTAssertEqual(DownloadTerminalClassification.cancelled.rawValue, "cancelled")
        XCTAssertEqual(DownloadTerminalClassification.paused.rawValue, "paused")
    }
}
