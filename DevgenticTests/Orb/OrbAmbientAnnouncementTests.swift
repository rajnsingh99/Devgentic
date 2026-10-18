// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbAmbientAnnouncementTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class OrbAmbientAnnouncementTests: XCTestCase {

    private func announcement(source: MessageSource = .localUI,
                              outcome: ExecutionOutcome? = .completed,
                              elapsed: TimeInterval = 60,
                              threshold: TimeInterval = 20) -> String? {
        OrbAmbientRunWatcher.announcement(source: source, outcome: outcome, elapsed: elapsed, threshold: threshold)
    }

    // MARK: - The reason the feature exists

    func testALongTypedRunIsAnnounced() {
        let spoken = announcement()
        XCTAssertNotNil(spoken)
        XCTAssertTrue(spoken!.lowercased().contains("main window"),
                      "The announcement must say WHERE, or it is indistinguishable from Orb's own run: \(spoken!)")
    }

    func testTheOutcomeIsNeverOverstated() {
        XCTAssertTrue(announcement(outcome: .failed)!.lowercased().contains("failed"))
        XCTAssertTrue(announcement(outcome: .completedWithWarnings)!.lowercased().contains("not cleanly"))
        // No stamped outcome means the run ended by a path that never finalized. "Finished" would
        // assert more than is known.
        let unknown = announcement(outcome: nil)
        XCTAssertNotNil(unknown)
        XCTAssertFalse(unknown!.lowercased().contains("finished"), "An unknown outcome must not claim success: \(unknown!)")
    }

    // MARK: - The silence rules

    /// Rule 2. Orb announces his own runs through the turn machinery; saying it twice is worse
    /// than not at all.
    func testOrbNeverAnnouncesHisOwnRun() {
        XCTAssertNil(announcement(source: .orb))
    }

    /// ⚠️ Rule 3, and the reason `MessageSource.scheduled` was added. "The task you started just
    /// finished" is a lie when nobody started it — and the user may be asleep.
    func testAScheduledRunIsNeverAnnounced() {
        XCTAssertNil(announcement(source: .scheduled),
                     "A cron fire has no waiting user; announcing it is the failure mode of this feature.")
    }

    func testAShortRunIsNotWorthInterruptingFor() {
        XCTAssertNil(announcement(elapsed: 3, threshold: 20))
        XCTAssertNil(announcement(elapsed: 19.9, threshold: 20))
    }

    func testTheThresholdIsInclusive() {
        XCTAssertNotNil(announcement(elapsed: 20, threshold: 20))
    }

    /// A run the user cancelled themselves — they were present for it by definition.
    func testACancelledRunIsNotAnnounced() {
        XCTAssertNil(announcement(outcome: .cancelled))
    }

    /// Every other surface still counts as "somebody is waiting".
    func testOtherSurfacesAreStillAnnounced() {
        for source in [MessageSource.localUI, .quickAccess, .telegram, .slack, .discord] {
            XCTAssertNotNil(announcement(source: source), "\(source.rawValue) has a waiting user.")
        }
    }

    // MARK: - Settings

    func testAmbientAnnouncementsAreOffByDefault() {
        // ⚠️ A product decision, not caution about the code: this is the only thing in Orb that
        // talks without being asked, and on-by-default reads as interrupting.
        let defaults = UserDefaults(suiteName: "OrbAmbientTests-\(UUID().uuidString)")!
        XCTAssertNil(defaults.object(forKey: AppSettings.orbAmbientAnnouncementsKey))
    }

    func testTheDefaultThresholdIsTwentySeconds() {
        XCTAssertEqual(OrbAmbientThreshold.standard.seconds, 20)
    }

    func testEveryThresholdStepIsDistinctAndAscending() {
        let seconds = OrbAmbientThreshold.allCases.map(\.seconds)
        XCTAssertEqual(seconds, seconds.sorted(), "Named steps must ascend: \(seconds)")
        XCTAssertEqual(Set(seconds).count, seconds.count, "Two steps with the same duration is a broken picker.")
    }
}
