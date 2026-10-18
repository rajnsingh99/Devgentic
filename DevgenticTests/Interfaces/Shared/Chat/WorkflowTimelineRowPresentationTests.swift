// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowTimelineRowPresentationTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class WorkflowTimelineRowPresentationTests: XCTestCase {

    // MARK: - Fixtures

    private static func node(
        _ status: WorkflowRunDisplayData.NodeDisplayData.NodeStatus,
        detail: String = "",
        input: String? = nil
    ) -> WorkflowRunDisplayData.NodeDisplayData {
        WorkflowRunDisplayData.NodeDisplayData(
            id: UUID(), nodeID: UUID(), profileName: "N", status: status,
            detail: detail, duration: 1, input: input, inputSourceLabel: nil,
            nodeTimeline: [], isStreaming: false, supportsTimeline: true
        )
    }

    private static func reasoning(_ text: String) -> TimelineEvent {
        .reasoning(id: UUID(), text: text)
    }

    // MARK: - CF-56 — one colour decision per row
    //
    // ⚠️ THE FILED DEFECT: `expandedContent` computed `isNotRun ? muted : status.color(theme)`,
    // i.e. the did-not-run override ONLY, while the row's spine, tag and header segment all applied
    // two more. A node that completed on a best-effort answer therefore got a GREEN success frame
    // under its own amber "Completed · warnings" tag.

    /// The override the expanded panel used to drop. Amber, not the status' green.
    func testDegradedCompletionTakesTheWarningRoleNotTheStatusColour() {
        XCTAssertEqual(
            WorkflowExecutionTimelineView.nodeColorRole(
                status: .completed, hasWarnings: true, isNotRun: false),
            .degraded)
    }

    /// A clean completion is unchanged — the override must not leak onto ordinary success.
    func testCleanCompletionTakesTheStatusRole() {
        XCTAssertEqual(
            WorkflowExecutionTimelineView.nodeColorRole(
                status: .completed, hasWarnings: false, isNotRun: false),
            .status)
    }

    /// ⚠️ PRECEDENCE, and it is the pre-existing behaviour: a node that never ran is muted even
    /// when the record carries warnings. Reordering the two arms would paint a "Not run" row amber.
    func testDidNotRunWinsOverDegraded() {
        XCTAssertEqual(
            WorkflowExecutionTimelineView.nodeColorRole(
                status: .completed, hasWarnings: true, isNotRun: true),
            .notRun)
    }

    /// ⚠️ The `status == .completed` conjunct is load-bearing and dropping it survives every other
    /// test here. A node decoded from a NEWER build (`.unknown`) can carry `hasWarnings`; amber
    /// there would assert a degraded COMPLETION for a node this build cannot classify at all — the
    /// same false claim WF-UI1 exists to prevent, re-entering through the colour.
    func testWarningsOnANonCompletedStatusDoNotClaimDegradedCompletion() {
        for status: WorkflowRunDisplayData.NodeDisplayData.NodeStatus
            in [.unknown, .failed, .running, .pending, .cancelled] {
            XCTAssertEqual(
                WorkflowExecutionTimelineView.nodeColorRole(
                    status: status, hasWarnings: true, isNotRun: false),
                .status,
                "\(status) must not borrow the degraded-completion colour")
        }
    }

    // MARK: - CF-58 — the one-line preview is bounded
    //
    // The row renders `Text(preview).lineLimit(1)`. `detail` is a node's ENTIRE model output and
    // `input` is the concatenation of every upstream node's entire output; both used to arrive
    // whole, on every body pass — every hover transition included.

    /// The cap is 200 characters plus a one-character ellipsis. Stated, not derived: a test that
    /// read the limit back out of the code it claims to pin would pin nothing.
    func testALongNodeOutputIsTruncatedTo200CharactersPlusAnEllipsis() {
        let long = String(repeating: "a", count: 5_000)
        let preview = WorkflowExecutionTimelineView.collapsedPreview(
            for: Self.node(.completed, detail: long))

        XCTAssertEqual(preview?.count, 201)
        XCTAssertEqual(preview?.hasSuffix("…"), true)
    }

    /// The pending/running arm reads `input`, which is the LARGER of the two sources.
    func testALongUpstreamInputIsTruncatedForAPendingRow() {
        let long = String(repeating: "b", count: 40_000)
        let preview = WorkflowExecutionTimelineView.collapsedPreview(
            for: Self.node(.pending, input: long))

        XCTAssertEqual(preview?.count, 201)
    }

    /// A short preview is untouched — no cap artefact on the overwhelmingly common case, and no
    /// ellipsis on a string that was never cut.
    func testAShortPreviewIsReturnedVerbatim() {
        XCTAssertEqual(
            WorkflowExecutionTimelineView.collapsedPreview(
                for: Self.node(.completed, detail: "  All three files were updated.  ")),
            "All three files were updated.")
    }

    /// Boundary: exactly at the cap is NOT truncated, so nothing gains a misleading "…".
    func testAPreviewExactlyAtTheCapIsNotEllipsised() {
        let exact = String(repeating: "c", count: 200)
        let preview = WorkflowExecutionTimelineView.collapsedPreview(
            for: Self.node(.completed, detail: exact))

        XCTAssertEqual(preview, exact)
    }

    /// Empty and whitespace-only details still yield no row at all — the pre-existing contract the
    /// truncation had to preserve.
    func testWhitespaceOnlyDetailStillProducesNoPreview() {
        XCTAssertNil(WorkflowExecutionTimelineView.collapsedPreview(
            for: Self.node(.completed, detail: "   \n  ")))
        XCTAssertNil(WorkflowExecutionTimelineView.collapsedPreview(
            for: Self.node(.pending, input: nil)))
    }

    /// The `.skipped` arm shows the REASON and is bounded too — it shares `boundedPreview`, and a
    /// legacy record's reason is free text.
    func testTheSkippedArmShowsTheReasonAndIsBoundedAsWell() {
        let reason = String(repeating: "d", count: 900)
        let preview = WorkflowExecutionTimelineView.collapsedPreview(
            for: Self.node(.skipped, detail: reason, input: "the upstream input"))

        XCTAssertEqual(preview?.count, 201)
        XCTAssertEqual(preview?.hasPrefix("d"), true, "the skipped arm must not fall back to input")
    }

    // MARK: - CF-59 — the duplication predicate, and the memo over it
    //
    // The predicate itself is unchanged behaviour; these first two are new coverage that would
    // have passed before the fix as well, and are here because the memo is only as trustworthy as
    // the answer it caches.

    private static let loopGuardSentence =
        "The agent stopped after hitting its iteration budget."
    private static let unrelatedSentence =
        "The requested file could not be opened for writing."

    func testAnErrorSentenceEchoedByTheTraceTailIsReportedAsDuplicated() {
        let events = [Self.reasoning("LOOP GUARD\n\(Self.loopGuardSentence)")]
        XCTAssertTrue(WorkflowExecutionTimelineView.isDuplicatedInTimeline(
            Self.loopGuardSentence, events: events))
    }

    func testAnErrorSentenceTheTraceDoesNotCarryIsNotReportedAsDuplicated() {
        let events = [Self.reasoning("LOOP GUARD\n\(Self.loopGuardSentence)")]
        XCTAssertFalse(WorkflowExecutionTimelineView.isDuplicatedInTimeline(
            Self.unrelatedSentence, events: events))
    }

    /// The memo must agree with the predicate it wraps — a cache that answers differently is worse
    /// than the cost it saves.
    @MainActor
    func testTheMemoAgreesWithThePredicateItWraps() {
        let events = [Self.reasoning("LOOP GUARD\n\(Self.loopGuardSentence)")]
        let nodeID = UUID()

        XCTAssertEqual(
            WorkflowExecutionTimelineView.errorBodyIsDuplicated(
                nodeID: nodeID, body: Self.loopGuardSentence, events: events),
            WorkflowExecutionTimelineView.isDuplicatedInTimeline(
                Self.loopGuardSentence, events: events))
    }

    /// ⚠️ THE RISK THE MEMO ADDS, half one. Two different error bodies on the SAME node must get
    /// their own answers; a memo keyed on the node id alone returns the first one forever, which
    /// would suppress a real error paragraph (or print a duplicated one) for the rest of the
    /// session. Retried failures land exactly here — same node, new error text.
    @MainActor
    func testTheMemoRecomputesWhenTheErrorBodyChangesOnTheSameNode() {
        let events = [Self.reasoning("LOOP GUARD\n\(Self.loopGuardSentence)")]
        let nodeID = UUID()

        XCTAssertTrue(WorkflowExecutionTimelineView.errorBodyIsDuplicated(
            nodeID: nodeID, body: Self.loopGuardSentence, events: events))
        XCTAssertFalse(WorkflowExecutionTimelineView.errorBodyIsDuplicated(
            nodeID: nodeID, body: Self.unrelatedSentence, events: events),
            "a second error body on the same node must not inherit the first answer")
    }

    /// ⚠️ THE RISK THE MEMO ADDS, half three — the one the round-3 cold read caught. `nodeID` is the
    /// persistent LAYOUT node id, not a per-run identity, and `duplicationCache` is a
    /// process-lifetime static that nothing clears on run, conversation or profile change. So a
    /// Re-run presents the same node id, and if the node fails the same way with the same number of
    /// events the key is a straight hit — while the answer is trace-dependent and the second run's
    /// tail need not echo the sentence. The stale `true` asserted here is the bad one: it suppresses
    /// the red error paragraph, leaving a "Failed" node whose expanded panel never says why.
    @MainActor
    func testTheMemoRecomputesForALaterRunOfTheSameNodeWithTheSameEventCount() {
        let nodeID = UUID()   // the layout node id — identical across runs by construction

        XCTAssertTrue(WorkflowExecutionTimelineView.errorBodyIsDuplicated(
            nodeID: nodeID, body: Self.loopGuardSentence,
            events: [Self.reasoning("LOOP GUARD\n\(Self.loopGuardSentence)")]))

        // A LATER run of the same node: same error sentence, same event count, different trace.
        XCTAssertFalse(WorkflowExecutionTimelineView.errorBodyIsDuplicated(
            nodeID: nodeID, body: Self.loopGuardSentence,
            events: [Self.reasoning("Retrying after a transient connection failure.")]),
            "a second run's verdict must not be inherited from the first — the key has to carry "
            + "something that varies with the trace's identity, not only its length")
    }

    /// ⚠️ THE RISK THE MEMO ADDS, half two — and the one the caller actually produces: trace
    /// hydration replaces an empty timeline with the stored one, and `WorkflowDedicatedView`
    /// animates that transition precisely because it can retract this error paragraph. A memo blind
    /// to the trace would keep saying "not duplicated" after the evidence arrived.
    @MainActor
    func testTheMemoRecomputesWhenTheTraceArrives() {
        let nodeID = UUID()

        XCTAssertFalse(WorkflowExecutionTimelineView.errorBodyIsDuplicated(
            nodeID: nodeID, body: Self.loopGuardSentence, events: []))
        XCTAssertTrue(WorkflowExecutionTimelineView.errorBodyIsDuplicated(
            nodeID: nodeID, body: Self.loopGuardSentence,
            events: [Self.reasoning("LOOP GUARD\n\(Self.loopGuardSentence)")]),
            "hydration must be able to flip the answer")
    }

    // MARK: - CF-60 — the construction-pass scroll

    /// ⚠️ THE FILED DEFECT. The failed-run auto-focus assigns `selectedNodeID` in the same update
    /// that makes `displayData` non-nil, so the timeline is CONSTRUCTED with the id already set and
    /// a change-only observer never fired — the node the user was sent to debug sat below the fold.
    func testAnExplicitSelectionScrollsOnTheConstructionPass() {
        XCTAssertTrue(WorkflowExecutionTimelineView.shouldScrollToSelection(
            UUID(), isInitial: true))
    }

    /// ⚠️ THE REGRESSION THE GUARD PREVENTS, and the reason `initial: true` alone is not the whole
    /// fix: `nil` means the Final Outcome row, which is the resting selection every "back" press
    /// leaves behind. Scrolling to it at construction would send every freshly-opened run straight
    /// past its own timeline to the last row.
    func testTheFinalOutcomeSelectionDoesNotScrollOnTheConstructionPass() {
        XCTAssertFalse(WorkflowExecutionTimelineView.shouldScrollToSelection(
            nil, isInitial: true))
    }

    /// A REAL change to the Final Outcome still scrolls — that one the user, or a completing run,
    /// asked for.
    func testARealChangeAlwaysScrollsIncludingToTheFinalOutcome() {
        XCTAssertTrue(WorkflowExecutionTimelineView.shouldScrollToSelection(
            nil, isInitial: false))
        XCTAssertTrue(WorkflowExecutionTimelineView.shouldScrollToSelection(
            UUID(), isInitial: false))
    }
}
