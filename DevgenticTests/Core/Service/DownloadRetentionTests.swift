// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DownloadRetentionTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class DownloadRetentionPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func daysAgo(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: now)!
    }

    private func shouldPrune(index: Int, age: Int, days: Int = 90, keep: Int = 500) -> Bool {
        DownloadHistoryStore.shouldPrune(
            index: index, updatedAt: daysAgo(age), now: now,
            olderThanDays: days, keepingNewest: keep
        )
    }

    func testRecentRecordsAreKept() {
        XCTAssertFalse(shouldPrune(index: 0, age: 0))
        XCTAssertFalse(shouldPrune(index: 10, age: 30))
        XCTAssertFalse(shouldPrune(index: 499, age: 89))
    }

    func testRecordsPastTheAgeCapArePruned() {
        XCTAssertTrue(shouldPrune(index: 0, age: 91))
        XCTAssertTrue(shouldPrune(index: 0, age: 365))
    }

    /// Either condition alone is enough — a recent record still goes if there are already
    /// `keep` newer ones ahead of it.
    func testRecordsPastTheCountCapArePrunedEvenWhenRecent() {
        XCTAssertTrue(shouldPrune(index: 500, age: 0))
        XCTAssertTrue(shouldPrune(index: 900, age: 1))
    }

    /// The boundary is exclusive on the count side: index 499 is the 500th kept record.
    func testTheCountBoundaryIsExact() {
        XCTAssertFalse(shouldPrune(index: 499, age: 0, keep: 500))
        XCTAssertTrue(shouldPrune(index: 500, age: 0, keep: 500))
    }

    /// Sanity on the shipped constants — a retention window measured in days, not hours, and
    /// a cap that keeps a meaningful amount of history.
    func testShippedConstantsAreSane() {
        XCTAssertGreaterThanOrEqual(DownloadHistoryStore.retentionDays, 30)
        XCTAssertGreaterThanOrEqual(DownloadHistoryStore.retentionMaxRecords, 100)
    }

    /// ⚠️ The statuses the sweep is allowed to touch. `.paused` must NEVER be prunable: pause
    /// is an explicit "I'll come back to this" and the partial bytes are deliberately still on
    /// disk, so removing the row would take away the only Resume affordance pointing at them.
    /// Active states are excluded for the obvious reason.
    /// ⚠️ Rewritten 2026-08-03. This previously declared BOTH sets as local literals and then
    /// asserted they were disjoint and that `.paused` was in the protected one — all true by
    /// construction of the test's own data. Adding `.paused` to the real prunable set left it
    /// green. It now reads `DownloadHistoryStore.prunableStatuses`, which is what the sweep's
    /// predicate is built from.
    func testOnlyFinishedNonResumableIntentStatusesAreEligible() {
        let eligible = Set(DownloadHistoryStore.prunableStatuses)

        XCTAssertFalse(
            eligible.contains(.paused),
            "pausing must survive a retention sweep — the row is the only Resume affordance pointing at bytes still on disk"
        )
        XCTAssertFalse(eligible.contains(.queued), "a queued download is not history")
        XCTAssertFalse(eligible.contains(.downloading), "pruning a running download's row orphans it")

        XCTAssertEqual(
            eligible, [.completed, .cancelled, .failed, .interrupted],
            "the prunable set changed — confirm the new membership is deliberate"
        )

        // Every status must be classified. A new case defaults to "protected" by omission,
        // which is the safe side, but it should be a decision rather than an oversight.
        let protected = Set(DownloadRecordStatus.allCases).subtracting(eligible)
        XCTAssertEqual(
            eligible.count + protected.count,
            DownloadRecordStatus.allCases.count,
            "a status was added without deciding whether retention may prune it"
        )
    }

    /// The predicate the sweep actually runs is built from `prunableStatuses`, so the raw
    /// strings it matches against must be the persisted ones — a display-side rename of a
    /// `rawValue` would silently stop matching every existing row.
    func testPrunablePredicateUsesPersistedRawValues() {
        XCTAssertEqual(
            Set(DownloadHistoryStore.prunableStatuses.map(\.rawValue)),
            ["completed", "cancelled", "failed", "interrupted"]
        )
    }
}
