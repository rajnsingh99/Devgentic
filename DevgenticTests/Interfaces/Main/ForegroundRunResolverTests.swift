// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ForegroundRunResolverTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class ForegroundRunResolverTests: XCTestCase {

    // MARK: - Fixtures

    private let convA = UUID()
    private let convB = UUID()
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func run(
        _ conversation: UUID,
        at offset: TimeInterval = 0,
        parked: Bool = false,
        queued: Bool = false,
        id: UUID = UUID()
    ) -> ForegroundRunResolver.LiveRun {
        ForegroundRunResolver.LiveRun(
            messageID: id,
            conversationID: conversation,
            startedAt: t0.addingTimeInterval(offset),
            isParked: parked,
            isQueued: queued
        )
    }

    // MARK: - The boundary rule

    func testNoLiveRuns_showsSend() {
        XCTAssertNil(ForegroundRunResolver.foregroundRun(live: [], selectedConversation: convA))
    }

    func testSingleRunInSelectedConversation_isTheTarget() {
        let r = run(convA)
        XCTAssertEqual(
            ForegroundRunResolver.foregroundRun(live: [r], selectedConversation: convA),
            r
        )
    }

    /// The background-composer-lock fix. A scheduled or ChatOps run streaming in a conversation the
    /// user is NOT looking at must not lock the composer or capture Stop. Before increment 1 this
    /// returned that run, because the slot was app-global.
    func testRunInOtherConversation_isNotTheTarget() {
        XCTAssertNil(
            ForegroundRunResolver.foregroundRun(live: [run(convB)], selectedConversation: convA),
            "a run in an unselected conversation must be out of the composer's reach"
        )
    }

    /// Five conversations streaming at once, each stoppable only from inside itself.
    func testConcurrentConversations_eachResolvesToItsOwnRun() {
        let convs = (0..<5).map { _ in UUID() }
        let runs = convs.enumerated().map { run($0.element, at: TimeInterval($0.offset)) }

        for (conv, expected) in zip(convs, runs) {
            XCTAssertEqual(
                ForegroundRunResolver.foregroundRun(live: runs, selectedConversation: conv),
                expected
            )
        }
    }

    func testNoSelectedConversation_showsSend() {
        XCTAssertNil(
            ForegroundRunResolver.foregroundRun(live: [run(convA)], selectedConversation: nil)
        )
    }

    /// A parked run is still the user's run: the banner is on screen and Stop must reach it.
    func testParkedRunIsStillStoppable() {
        let parked = run(convA, parked: true)
        XCTAssertEqual(
            ForegroundRunResolver.foregroundRun(live: [parked], selectedConversation: convA),
            parked
        )
    }

    // MARK: - THE ORPHAN REGRESSION

    /// The exact interleaving that made a run permanently unstoppable.
    ///
    /// Two runs live in one conversation. The first one ENDS (leaves the live set). With the old
    /// stored slot, that completion nil'd the slot unconditionally, the composer flipped to Send,
    /// and the survivor could never be stopped again. A derived answer cannot do that: removing a
    /// run from the live set simply re-resolves to the survivor.
    func testOrphanRegression_survivorStillResolvesAfterTheOtherRunEnds() {
        let first = run(convA, at: 0)                       // W — started first
        let second = run(convA, at: 10)                     // S — superseded it

        // Both live: deterministic pick, and critically NOT nil.
        XCTAssertNotNil(
            ForegroundRunResolver.foregroundRun(live: [first, second], selectedConversation: convA)
        )

        // S finishes and leaves the live set — the old clear site nil'd the slot here.
        XCTAssertEqual(
            ForegroundRunResolver.foregroundRun(live: [first], selectedConversation: convA),
            first,
            "the surviving run must remain the composer's target after the other run ends — "
            + "this is the orphan that made it unstoppable"
        )

        // Symmetric: the reverse completion order must also leave a live target.
        XCTAssertEqual(
            ForegroundRunResolver.foregroundRun(live: [second], selectedConversation: convA),
            second
        )

        // Only when nothing is live does the composer go back to Send.
        XCTAssertNil(
            ForegroundRunResolver.foregroundRun(live: [], selectedConversation: convA)
        )
    }

    /// Ending a run in ANOTHER conversation must not disturb this conversation's target — the
    /// cross-conversation half of the same clobber.
    func testRunEndingElsewhereDoesNotDisturbTheSelectedConversation() {
        let mine = run(convA, at: 0)
        let theirs = run(convB, at: 5)

        XCTAssertEqual(
            ForegroundRunResolver.foregroundRun(live: [mine, theirs], selectedConversation: convA),
            mine
        )
        XCTAssertEqual(
            ForegroundRunResolver.foregroundRun(live: [mine], selectedConversation: convA),
            mine
        )
    }

    // MARK: - Determinism when the invariant is violated

    /// Two live runs in one conversation should be impossible under the product model and will be
    /// refused at claim time (increment 4). Until then Redo can produce it, so the answer must not
    /// depend on dictionary ordering.
    func testTwoRunsInOneConversation_prefersMostRecentlyStarted() {
        let older = run(convA, at: 0)
        let newer = run(convA, at: 10)

        XCTAssertEqual(
            ForegroundRunResolver.foregroundRun(live: [older, newer], selectedConversation: convA),
            newer
        )
        XCTAssertEqual(
            ForegroundRunResolver.foregroundRun(live: [newer, older], selectedConversation: convA),
            newer,
            "input order must not change the answer"
        )
    }

    func testTwoRunsInOneConversation_prefersActivelyStreamingOverParked() {
        // The parked one started LATER, so this also proves unparked wins over recency.
        let streaming = run(convA, at: 0, parked: false)
        let parked = run(convA, at: 10, parked: true)

        XCTAssertEqual(
            ForegroundRunResolver.foregroundRun(live: [streaming, parked], selectedConversation: convA),
            streaming
        )
        XCTAssertEqual(
            ForegroundRunResolver.foregroundRun(live: [parked, streaming], selectedConversation: convA),
            streaming
        )
    }

    // MARK: - CR-4: a queued run is never preferred over one that started

    /// ⚠️⚠️ THE CR-4 DEFECT. A ChatOps / scheduled / Orb message queued behind the running run is
    /// registered — and timestamped — first, so it was the "most recently started, unparked" run and
    /// Stop hit it. Cancelling it did nothing, and the running run could not be stopped from here.
    func testAQueuedRunIsNeverPreferredOverTheRunningOne() {
        let running = run(convA, at: 0)
        let queued = run(convA, at: 10, queued: true)
        for order in [[running, queued], [queued, running]] {
            XCTAssertEqual(ForegroundRunResolver.foregroundRun(live: order, selectedConversation: convA), running)
        }
    }

    /// ⚠️ The fabricated-denial half. A PARKED run must be the target, so ITS task is cancelled — that
    /// is what makes its approval resolve as a cancellation and not as a "Deny" nobody pressed.
    func testAParkedRunIsPreferredOverAQueuedOne() {
        let parked = run(convA, at: 0, parked: true)
        let queued = run(convA, at: 10, queued: true)
        for order in [[parked, queued], [queued, parked]] {
            XCTAssertEqual(ForegroundRunResolver.foregroundRun(live: order, selectedConversation: convA), parked)
        }
    }

    /// The control: a queued run alone is still stoppable — the composer shows Stop for it.
    func testAQueuedRunAloneIsStillTheTarget() {
        let queued = run(convA, queued: true)
        XCTAssertEqual(ForegroundRunResolver.foregroundRun(live: [queued], selectedConversation: convA), queued)
    }

    func testIdenticalStartTimes_resolveDeterministicallyByMessageID() {
        let lo = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let hi = UUID(uuidString: "FFFFFFFF-0000-0000-0000-0000000000FF")!
        let a = run(convA, at: 0, id: lo)
        let b = run(convA, at: 0, id: hi)

        XCTAssertEqual(
            ForegroundRunResolver.foregroundRun(live: [a, b], selectedConversation: convA),
            ForegroundRunResolver.foregroundRun(live: [b, a], selectedConversation: convA),
            "a tie must not depend on input order"
        )
    }

    /// A missing start time degrades the TIE-BREAK only — never candidacy. `liveRunSnapshot`
    /// substitutes `.distantPast` if its two maps ever diverge, and that run must still be
    /// stoppable when it is the only one.
    func testMissingStartTimeStillResolvesWhenAlone() {
        let unknown = ForegroundRunResolver.LiveRun(
            messageID: UUID(), conversationID: convA, startedAt: .distantPast, isParked: false
        )
        XCTAssertEqual(
            ForegroundRunResolver.foregroundRun(live: [unknown], selectedConversation: convA),
            unknown
        )
    }

    // MARK: - liveRuns (the anomaly-detection query Stop logs from)

    func testLiveRunsFiltersToTheConversation() {
        let a1 = run(convA, at: 0), a2 = run(convA, at: 1), b1 = run(convB, at: 2)

        let inA = ForegroundRunResolver.liveRuns(in: convA, from: [a1, b1, a2])
        XCTAssertEqual(Set(inA.map(\.messageID)), Set([a1.messageID, a2.messageID]))
        XCTAssertEqual(ForegroundRunResolver.liveRuns(in: convB, from: [a1, b1, a2]), [b1])
        XCTAssertTrue(ForegroundRunResolver.liveRuns(in: nil, from: [a1, b1, a2]).isEmpty)
        XCTAssertTrue(ForegroundRunResolver.liveRuns(in: UUID(), from: [a1, b1, a2]).isEmpty)
    }
}
