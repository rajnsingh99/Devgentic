// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowEngineTailTests.swift
//  DevgenticTests
//
//  Register `Workflow_Production_Readiness_Fresh.md`, engine cluster — the rows fixed 2026-09-01:
//  `EXC-8` (a retry loop that TRAPPED on a negative count), `EXC-6` (a Stop manufacturing a routing
//  decision), `EXC-4` (a cancelled structural node emitting no terminal event), `EIO-10` (classifier
//  tokens matching inside ordinary words) and `EXA-5` (same-level variable writes never visible).
//
//  ⚠️ EVERY ONE of these governs an event or a code path that is STRUCTURALLY UNOBSERVABLE through
//  the integration harness: they are reached only on a cancelled task tree, and the producer task is
//  cancelled BY `continuation.onTermination`, so by the time a terminal event is yielded the stream
//  is already torn down. That is the same wall `settledStreamEndStatus` and `UserSkipTeardownPolicy`
//  hit, and the house answer is the same one: extract the DECISION and truth-table it here, then let
//  the executor merely plumb it. A test that tried to assert on the stream event would hang or flake
//  rather than fail, which is worse than no test — so it is not written.
//
//  What that leaves unverified, stated plainly: that each executor call site passes the right
//  arguments to these functions. That is a reading check, not a test.
//

import XCTest
import Synchronization
@testable import devgentic

final class WorkflowEngineTailTests: XCTestCase {

    // MARK: - EXC-8 — the retry loop must not be able to trap

    /// The filed defect: `for attempt in 0...maxRetries` with a negative count is a `ClosedRange`
    /// precondition failure — it ABORTS THE APP, it does not produce an empty range.
    func testANegativeRetryCountYieldsExactlyOneAttempt() {
        XCTAssertEqual(WorkflowRetryPolicy.profileAttempts(maxNodeRetries: -1), 1)
        XCTAssertEqual(WorkflowRetryPolicy.profileAttempts(maxNodeRetries: -99), 1)
    }

    /// The ordinary values are unchanged — a clamp that also changed real counts would be a
    /// behaviour change wearing a bug fix's clothes.
    func testOrdinaryRetryCountsAreUnchanged() {
        XCTAssertEqual(WorkflowRetryPolicy.profileAttempts(maxNodeRetries: 0), 1)
        XCTAssertEqual(WorkflowRetryPolicy.profileAttempts(maxNodeRetries: 3), 4)
        XCTAssertEqual(WorkflowRetryPolicy.profileAttempts(maxNodeRetries: nil), 1, "no per-node count means no retry")
    }

    // MARK: - EXC-6 — a Stop is not a routing decision

    /// An answer that LANDED is authoritative even under cancellation: the human really did decide,
    /// and the Stop arrived afterwards. Same precedence `settledStreamEndStatus` gives an explicit
    /// terminal outcome.
    func testAnAnsweredArbitrationIsHonouredEvenUnderCancellation() {
        XCTAssertEqual(
            WorkflowExecutor.settledArbitration(chosen: "Refund", offered: ["Refund", "Escalate"], taskCancelled: true),
            .honored("Refund")
        )
    }

    /// ⚠️ THE FILED DEFECT. On Stop the park returns nil, and the arm used to fall through to its
    /// no-answer behaviour — first match on the legacy path, and the configured 'If nobody can
    /// answer' action on the current one, whose shipped default FAILS the node and fires its error
    /// port. Both attributed an outcome to a user who never chose one.
    func testACancelledArbitrationSettlesCancelledRatherThanRouting() {
        XCTAssertEqual(
            WorkflowExecutor.settledArbitration(chosen: nil, offered: ["Refund", "Escalate"], taskCancelled: true),
            .canceled
        )
    }

    /// Not cancelled and unanswered is still the fallback — the park can be force-resolved with nil
    /// WITHOUT cancellation (a superseded suspension), and that case must keep today's behaviour.
    func testAnUnansweredButUncancelledArbitrationFallsBack() {
        XCTAssertEqual(
            WorkflowExecutor.settledArbitration(chosen: nil, offered: ["Refund"], taskCancelled: false),
            .fallback
        )
    }

    /// An answer that was never OFFERED must not be honoured — the suspension resolves from several
    /// surfaces, and a stale or mis-indexed answer must not activate a port this run never matched.
    /// ⚠️ Under cancellation it settles `.canceled`, not `.fallback`: the Stop is the better
    /// explanation of a nonsense answer arriving during teardown.
    func testAnUnofferedAnswerIsNotHonoured() {
        XCTAssertEqual(
            WorkflowExecutor.settledArbitration(chosen: "Nonsense", offered: ["Refund"], taskCancelled: false),
            .fallback
        )
        XCTAssertEqual(
            WorkflowExecutor.settledArbitration(chosen: "Nonsense", offered: ["Refund"], taskCancelled: true),
            .canceled
        )
    }

    // MARK: - EXC-4 — exactly one terminal event, by construction
    //
    // ⚠️ THE FIRST FIX FOR THIS ROW WAS WRONG, and the tests that pinned it were pinning the wrong
    // property. It decided who emits from whether an outer compute budget existed, reasoning that a
    // sentinel's throw would reach the catch arm. That is a RACE: `withComputeTimeout` returns
    // whichever task-group child finishes FIRST, and on a Stop both are cancelled at once — a
    // cold-read probe reproduced the work child winning in ~23% of trials for a parked node and ~75%
    // when its cancellation handler does not hop through a Task. In those runs NEITHER catch arm ran
    // and the node emitted no terminal event at all: the very defect the row was filed for, left open
    // in the DEFAULT configuration. The property below is the one that actually matters.

    /// Exactly one claimant wins, however many times the gate is asked.
    func testTheTerminalEmitGateAdmitsExactlyOneClaimant() {
        let gate = WorkflowExecutor.TerminalEmitGate()

        XCTAssertTrue(gate.claim(), "the first emitter must win")
        XCTAssertFalse(gate.claim(), "a second emit is the double-terminal-event bug")
        XCTAssertFalse(gate.claim())
    }

    /// ⚠️ And it holds under CONCURRENT claims, which is the whole point — the three emitters live on
    /// different task-group children racing to finish.
    func testTheTerminalEmitGateAdmitsExactlyOneClaimantUnderConcurrency() {
        for _ in 0..<200 {
            let gate = WorkflowExecutor.TerminalEmitGate()
            let winners = Mutex(0)
            DispatchQueue.concurrentPerform(iterations: 8) { _ in
                if gate.claim() { winners.withLock { $0 += 1 } }
            }
            XCTAssertEqual(winners.withLock { $0 }, 1, "exactly one emitter, never zero and never two")
        }
    }

    // MARK: - EIO-10 — a classifier token must not match inside a word

    /// ⚠️ THE FILED DEFECT, with the codebase's own token alphabet. Tokens are 4 characters drawn
    /// from A–Z minus I/O plus 2–9, so real English words containing them are easy to hit — and the
    /// model echoing the prompt is the normal case, not an adversarial one.
    func testATokenEmbeddedInAWordIsNotAMatch() {
        XCTAssertNil(ClassificationTokenMapper.firstStandaloneOccurrence(of: "MENT", in: "MENTION THE REFUND"))
        XCTAssertNil(ClassificationTokenMapper.firstStandaloneOccurrence(of: "RATE", in: "ACCURATELY"))
    }

    /// A standalone token still matches, wherever it sits and whatever punctuation surrounds it —
    /// a fix that stopped legitimate replies from routing would be worse than the defect.
    func testAStandaloneTokenStillMatches() {
        for haystack in ["MENT", "ANSWER: MENT", "MENT.", "(MENT)", "THE ANSWER IS MENT!", "\"MENT\"", "MENT\nDONE"] {
            XCTAssertNotNil(
                ClassificationTokenMapper.firstStandaloneOccurrence(of: "MENT", in: haystack),
                "must still match in: \(haystack)"
            )
        }
    }

    /// ⚠️ The boundary predicate must be ALPHANUMERIC, not "is in the token alphabet". That alphabet
    /// omits I, O, 0 and 1, so a membership-based test would still accept MENT inside MENTION.
    func testTheBoundaryTestCoversLettersOutsideTheTokenAlphabet() {
        XCTAssertNil(ClassificationTokenMapper.firstStandaloneOccurrence(of: "MENT", in: "MENTI"))
        XCTAssertNil(ClassificationTokenMapper.firstStandaloneOccurrence(of: "MENT", in: "OMENT"))
        XCTAssertNil(ClassificationTokenMapper.firstStandaloneOccurrence(of: "MENT", in: "MENT0"))
        XCTAssertNil(ClassificationTokenMapper.firstStandaloneOccurrence(of: "MENT", in: "1MENT"))
    }

    /// It must find a LATER standalone occurrence when the first one is embedded — returning nil
    /// after the first embedded hit would trade a false match for a missed one.
    func testAnEmbeddedHitDoesNotHideALaterStandaloneOne() {
        let idx = ClassificationTokenMapper.firstStandaloneOccurrence(of: "MENT", in: "MENTION IT, THEN MENT")
        XCTAssertNotNil(idx)
        XCTAssertEqual("MENTION IT, THEN MENT"[idx!...], "MENT")
    }

    /// ⚠️ NON-ASCII IS A BOUNDARY. `Character.isLetter` is true for every Unicode letter, so a
    /// Unicode-wide boundary test made a Japanese or Chinese reply — where a token sits directly
    /// against a character with no space, which is normal in those scripts — fail to match, silently
    /// turning a decided classification into `.unreadable`. A token is ASCII, so only ASCII
    /// alphanumerics can be "more of the same token".
    func testANonASCIILetterIsABoundaryNotAContinuation() {
        XCTAssertNotNil(ClassificationTokenMapper.firstStandaloneOccurrence(of: "MENT", in: "返金はMENTです"))
        XCTAssertNotNil(ClassificationTokenMapper.firstStandaloneOccurrence(of: "MENT", in: "MENT。"))
        XCTAssertNotNil(ClassificationTokenMapper.firstStandaloneOccurrence(of: "MENT", in: "환불MENT"))
    }

    func testAnAbsentTokenIsNil() {
        XCTAssertNil(ClassificationTokenMapper.firstStandaloneOccurrence(of: "MENT", in: "NOTHING HERE"))
        XCTAssertNil(ClassificationTokenMapper.firstStandaloneOccurrence(of: "", in: "ANYTHING"))
    }

    // MARK: - EXA-8 — a canvas that produces no new content must say so

    /// A Router-only canvas answers with the user's own message: Router, Gate and Trigger all assign
    /// `output = upstreamText`. ⚠️ WIDER than the filed row, which named only the Trigger — a Trigger
    /// cannot be created from the palette in this build, but a Router-only canvas can.
    @MainActor
    func testACanvasOfOnlyPassThroughNodesIsWarnedAbout() {
        let a = WorkflowNode(kind: .condition(ConditionNodeConfig()), position: .zero, displayName: "R1")
        let b = WorkflowNode(kind: .gate(GateNodeConfig()), position: CGPoint(x: 400, y: 0), displayName: "G1")
        let layout = WorkflowLayout(
            nodes: [a, b],
            edges: [WorkflowEdge(sourceNodeID: a.id, targetNodeID: b.id)],
            annotations: []
        )

        let issues = WorkflowValidator.validate(layout: layout, profileMap: [:])

        let issue = issues.first { $0.message.contains("produces new content") }
        XCTAssertNotNil(issue, "a canvas that can only echo its input must warn")
        XCTAssertEqual(issue?.severity, .warning,
                       "⚠️ never .error — the executor refuses to run on any error-severity issue")
    }

    /// One content-producing node is enough — the warning must not fire on ordinary canvases.
    @MainActor
    func testACanvasWithAContentProducingNodeIsNotWarnedAbout() {
        let router = WorkflowNode(kind: .condition(ConditionNodeConfig()), position: .zero, displayName: "R1")
        let code = WorkflowNode(kind: .code(CodeNodeConfig()), position: CGPoint(x: 400, y: 0), displayName: "C1")
        let layout = WorkflowLayout(
            nodes: [router, code],
            edges: [WorkflowEdge(sourceNodeID: router.id, targetNodeID: code.id)],
            annotations: []
        )

        let issues = WorkflowValidator.validate(layout: layout, profileMap: [:])

        XCTAssertNil(issues.first { $0.message.contains("produces new content") })
    }

    // MARK: - EXA-5 — a same-level variable write is never visible

    /// ⚠️ STRICTLY earlier. Same-level is the whole defect: every node on a level is handed one
    /// snapshot taken before any of them starts, and writes are folded back only after the level
    /// finishes. This is deterministic, not a race — the reader NEVER sees it, on every run.
    func testASameLevelWriteIsNeverVisible() {
        XCTAssertEqual(
            WorkflowVariableVisibility.resolve(readerLevel: 2, writerLevels: [2]),
            .writtenTooLate(earliestWriterLevel: 2)
        )
    }

    func testAnEarlierWriteIsVisible() {
        XCTAssertEqual(
            WorkflowVariableVisibility.resolve(readerLevel: 2, writerLevels: [1]),
            .visible(fromLevel: 1)
        )
    }

    func testALaterWriteIsNotVisible() {
        XCTAssertEqual(
            WorkflowVariableVisibility.resolve(readerLevel: 1, writerLevels: [3]),
            .writtenTooLate(earliestWriterLevel: 3)
        )
    }

    /// With several writers the EARLIEST decides — one upstream writer is enough to make the read
    /// meaningful, however many later ones there are.
    func testTheEarliestWriterDecides() {
        XCTAssertEqual(
            WorkflowVariableVisibility.resolve(readerLevel: 3, writerLevels: [5, 1, 4]),
            .visible(fromLevel: 1)
        )
        XCTAssertEqual(
            WorkflowVariableVisibility.resolve(readerLevel: 3, writerLevels: [5, 3, 4]),
            .writtenTooLate(earliestWriterLevel: 3)
        )
    }

    func testNoWriterAtAllIsItsOwnCase() {
        XCTAssertEqual(
            WorkflowVariableVisibility.resolve(readerLevel: 0, writerLevels: []),
            .neverWritten
        )
    }

    /// A cyclic layout gives every node the -1 sentinel, so this reports `.writtenTooLate` rather
    /// than claiming visibility. Inert in practice — a cycle is refused at pre-flight — but it must
    /// not report the optimistic answer.
    func testTheCyclicSentinelDoesNotClaimVisibility() {
        XCTAssertEqual(
            WorkflowVariableVisibility.resolve(readerLevel: -1, writerLevels: [-1]),
            .writtenTooLate(earliestWriterLevel: -1)
        )
    }
}
