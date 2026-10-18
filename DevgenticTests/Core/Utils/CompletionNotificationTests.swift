// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CompletionNotificationTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class CompletionNotificationTests: XCTestCase {

    func testACancelledRunIsNotAnnounced() {
        XCTAssertNil(ActiveStreamManager.completionNotificationTitle(outcome: .cancelled, hasError: false),
                     "the device log: a run cancelled by closing the orb notified 'Query Completed'")
        XCTAssertNil(ActiveStreamManager.completionNotificationTitle(outcome: .cancelled, hasError: true))
    }

    func testACompletedRunIsAnnouncedAsCompleted() {
        XCTAssertEqual(ActiveStreamManager.completionNotificationTitle(outcome: .completed, hasError: false), "Query Completed")
        XCTAssertEqual(ActiveStreamManager.completionNotificationTitle(outcome: .completedWithWarnings, hasError: false), "Query Completed")
    }

    func testAFailedRunIsAnnouncedAsFailedEvenWithoutAThrownError() {
        // A run can yield `.error` and finish without throwing; its outcome is still `.failed`.
        XCTAssertEqual(ActiveStreamManager.completionNotificationTitle(outcome: .failed, hasError: false), "Query Failed")
        XCTAssertEqual(ActiveStreamManager.completionNotificationTitle(outcome: .failed, hasError: true), "Query Failed")
        XCTAssertEqual(ActiveStreamManager.completionNotificationTitle(outcome: .timedOut, hasError: true), "Query Failed")
    }

    /// Source pin: `finalizeMessage` must take the title from the policy and stop for a cancel.
    func testTheEndOfEveryRunAsksThePolicy() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("Devgentic/Core/Utils/ActiveStreamManager.swift")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw XCTSkip("ActiveStreamManager.swift not reachable from \(root.path) — running outside a checkout")
        }
        let source = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(source.contains("guard let notificationTitle = Self.completionNotificationTitle(outcome: message.terminalOutcome,"))
        XCTAssertTrue(source.contains("title: notificationTitle,"))
        XCTAssertFalse(source.contains("hasError ? \"Query Failed\" : \"Query Completed\""),
                       "the old error-only title is the defect")
    }
}
