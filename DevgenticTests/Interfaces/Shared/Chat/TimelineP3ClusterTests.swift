// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  TimelineP3ClusterTests.swift
//  DevgenticTests
//
//  Regression cover for the agent-timeline / capability-card P3s of 2026-09-03
//  (Chat_Production_Readiness_Fresh.md rows CF-46, CF-47, CF-48, CF-50, CF-51, CF-52, CF-53).
//
//  CF-49 (the interim reasoning sparkle) has no test here: the whole defect is a
//  `.symbolEffect(isActive:)` argument inside a SwiftUI body, and the fix removed the state
//  that drove it rather than adding a decision worth extracting. It is covered by review.
//

import XCTest
@testable import devgentic

// MARK: - CF-46 · the header must not claim success for a degraded run

@MainActor
final class TimelineHeaderOutcomeTests: XCTestCase {

    private func row(success: Bool?) -> TimelineEvent {
        .toolExecution(ToolExecutionData(id: UUID(), name: "read_file", params: "{}",
                                         output: "done", isSuccess: success, isExecuting: false))
    }

    /// `ReActAgentExecutor` yields `.completedWithWarnings` for iteration exhaustion with a
    /// best-effort answer. That ends the LOOP, not a tool, so no row is marked failed — and
    /// `summarize` used to consult the outcome for `.cancelled` alone, so it fell through to
    /// `failed == 0` and rendered a green checkmark above the amber TerminalOutcomeChip.
    func testDegradedTerminalOutcomeIsNotReportedAsSuccess() {
        let events = [row(success: true), row(success: true)]

        let warned = AgentTimelineView.summarize(events: events, outcome: .completedWithWarnings)
        XCTAssertEqual(warned.status, .degraded,
                       "a run that stopped early must not render the success glyph")
        XCTAssertEqual(warned.failedTools, 0, "no tool failed; only the run did")
        XCTAssertEqual(warned.status.glyph, "exclamationmark.triangle.fill")
    }

    /// `.failed` is the same shape without a usable answer, and TerminalOutcomeChip renders both
    /// identically (amber `exclamationmark.triangle.fill`) — so the header must too.
    func testFailedTerminalOutcomeIsNotReportedAsSuccess() {
        let s = AgentTimelineView.summarize(events: [row(success: true)], outcome: .failed)
        XCTAssertEqual(s.status, .degraded)
        XCTAssertEqual(s.failedTools, 0)
    }

    /// The tool count only ESCALATES: a clean outcome with failed rows is still degraded.
    func testFailedToolsStillEscalateACleanOutcome() {
        let s = AgentTimelineView.summarize(events: [row(success: true), row(success: false)],
                                            outcome: .completed)
        XCTAssertEqual(s.status, .degraded)
        XCTAssertEqual(s.failedTools, 1)
    }

    /// Control: a genuinely clean run must still read as success, so the outcome mapping did not
    /// simply paint every run amber.
    func testCompletedOutcomeWithNoFailuresStillReadsAsSuccess() {
        let s = AgentTimelineView.summarize(events: [row(success: true), row(success: true)],
                                            outcome: .completed)
        XCTAssertEqual(s.status, .succeeded)
        XCTAssertEqual(s.status.glyph, "checkmark.circle.fill")
    }

    /// Control: the workflow per-node init passes no outcome and must keep deciding on the rows.
    func testNoOutcomeStillDecidesFromTheRows() {
        XCTAssertEqual(AgentTimelineView.summarize(events: [row(success: true)]).status, .succeeded)
        XCTAssertEqual(AgentTimelineView.summarize(events: [row(success: false)]).status, .degraded)
    }

    /// Control: `.cancelled` still wins over everything, and still reports its failed count.
    func testCancelledOutcomeStillWins() {
        let s = AgentTimelineView.summarize(events: [row(success: false)], outcome: .cancelled)
        XCTAssertEqual(s.status, .cancelled)
        XCTAssertEqual(s.failedTools, 1)
    }
}

// MARK: - CF-47 · collapsing during a live run must actually collapse

final class TimelineCollapseDuringRunTests: XCTestCase {

    /// The body was gated on `isTimelineExpanded || isStreaming`, so a collapse mid-run was a
    /// no-op while the chevron, `.help` and the VoiceOver label all reported it as collapsed.
    func testUserCollapseIsHonouredWhileStreaming() {
        XCTAssertFalse(
            AgentTimelineView.showsTimelineBody(isTimelineExpanded: false,
                                                isStreaming: true,
                                                userToggled: true),
            "once the user has taken the decision, the streaming default must not override it"
        )
    }

    /// The auto-expand default still applies until the user touches the control — including on
    /// the very first pass, before `.onAppear` has set the flag.
    func testStreamingStillAutoExpandsBeforeAnyUserToggle() {
        XCTAssertTrue(AgentTimelineView.showsTimelineBody(isTimelineExpanded: false,
                                                          isStreaming: true,
                                                          userToggled: false))
    }

    /// A user EXPAND after the run ended must stick — the flag alone decides once toggled.
    func testUserExpandIsHonouredAfterTheRunEnds() {
        XCTAssertTrue(AgentTimelineView.showsTimelineBody(isTimelineExpanded: true,
                                                          isStreaming: false,
                                                          userToggled: true))
    }

    /// Control: a finished, untouched, collapsed log stays collapsed.
    func testFinishedAndCollapsedStaysCollapsed() {
        XCTAssertFalse(AgentTimelineView.showsTimelineBody(isTimelineExpanded: false,
                                                           isStreaming: false,
                                                           userToggled: false))
    }
}

// MARK: - CF-48 · no LCS diff whose result nothing can read

final class TimelineWriteDiffGateTests: XCTestCase {

    private func writeAction(preWrite: String? = "old", inline: String? = "new",
                             isWrite: Bool = true) -> TimelineFileViewerAction {
        let source: TimelineFileViewerAction.ContentSource
        if let inline {
            source = .inline(inline)
        } else {
            source = .fromDisk
        }
        return TimelineFileViewerAction(
            fileName: "Foo.swift",
            filePath: "/tmp/Foo.swift",
            source: source,
            preWriteContent: preWrite,
            isWrite: isWrite
        )
    }

    /// `fileViewerChip` takes the `effect` branch for the stat, the no-op test AND the baseline
    /// flag, so `writeDiffStat` is unreadable whenever an effect exists — yet the full-file diff
    /// was computed anyway, and `.task(id:)` re-armed it on every scroll back into view.
    func testARowWithAPersistedEffectNeedsNoMeasuredDiff() {
        XCTAssertFalse(
            ActionDetailView.needsMeasuredWriteDiff(hasPersistedEffect: true,
                                                    action: writeAction()),
            "the persisted effect already answers every question the chip asks"
        )
    }

    /// Control: the reloaded-conversation path — no persisted effect — still measures.
    func testAWriteWithoutAPersistedEffectStillMeasures() {
        XCTAssertTrue(ActionDetailView.needsMeasuredWriteDiff(hasPersistedEffect: false,
                                                              action: writeAction()))
    }

    /// Controls for the conditions the original guard already enforced.
    func testNonWritesAndMissingSnapshotsNeverMeasure() {
        XCTAssertFalse(ActionDetailView.needsMeasuredWriteDiff(hasPersistedEffect: false,
                                                               action: writeAction(isWrite: false)),
                       "a read row has nothing to diff")
        XCTAssertFalse(ActionDetailView.needsMeasuredWriteDiff(hasPersistedEffect: false,
                                                               action: writeAction(preWrite: nil)),
                       "no pre-image, no measurable diff")
        XCTAssertFalse(ActionDetailView.needsMeasuredWriteDiff(hasPersistedEffect: false,
                                                               action: writeAction(inline: nil)),
                       "a `.fromDisk` row carries no post-image to compare")
        XCTAssertFalse(ActionDetailView.needsMeasuredWriteDiff(hasPersistedEffect: false,
                                                               action: nil))
    }
}

// MARK: - CF-53 · an open must not land in the conversation the user switched TO

final class TimelineOpenDestinationTests: XCTestCase {

    /// The disk read is an uncancelled `Task` the view holds no handle to, so a conversation
    /// switch while it runs used to drop the tab into the newly opened conversation.
    func testAnOpenStartedElsewhereIsDropped() {
        XCTAssertFalse(ActionDetailView.shouldDeliverOpen(origin: UUID(), current: UUID(),
                                                          isLoadInFlight: false))
    }

    func testAnOpenIsDeliveredWhenTheConversationIsStillOpen() {
        let id = UUID()
        XCTAssertTrue(ActionDetailView.shouldDeliverOpen(origin: id, current: id,
                                                         isLoadInFlight: false))
    }

    /// Nothing is loaded (the welcome screen, or a `loadConversation(id: nil)` that has already
    /// emptied the messages) — there is no destination to match, so the tab must not be planted.
    ///
    /// NOTE this is NOT the mid-load state: see `testAnOpenIsDroppedWhileAConversationSwitchIsInFlight`.
    func testAnOpenIsDroppedWhenNoConversationIsLoaded() {
        XCTAssertFalse(ActionDetailView.shouldDeliverOpen(origin: UUID(), current: nil,
                                                          isLoadInFlight: false))
    }

    /// THE mid-load case, and the reason `isLoadInFlight` exists. `loadConversation` assigns
    /// `currentChatMessages` only after its fetch returns, so between `resetCodeViewer()` and
    /// `restoreCodeViewerSession(for:)` the displayed identity is STILL the outgoing conversation
    /// — i.e. `current == origin`. Judging on identity alone therefore delivered exactly when the
    /// viewer had just been emptied for someone else, planting the tab in the incoming
    /// conversation and suppressing its own restore (which only fires on an empty viewer).
    func testAnOpenIsDroppedWhileAConversationSwitchIsInFlight() {
        let outgoing = UUID()
        XCTAssertFalse(ActionDetailView.shouldDeliverOpen(origin: outgoing, current: outgoing,
                                                          isLoadInFlight: true),
                       "mid-load the displayed id still equals the origin; that must not deliver")
    }

    /// ⚠️ These two pin the `origin == nil` CONTRACT, not the workflow surface. That surface
    /// now supplies a conversation of its own — `WorkflowExecutionTimelineView` passes its
    /// `conversationID` to all four `AgentTimelineView` inits — so it is covered by the identity
    /// term like any other caller, and is exercised by the origin-bearing tests above. A nil
    /// origin remains reachable for any future caller that omits it, which is what these hold.
    func testARowWithNoConversationIdentityIsStillDroppedMidSwitch() {
        XCTAssertFalse(ActionDetailView.shouldDeliverOpen(origin: nil, current: UUID(),
                                                          isLoadInFlight: true))
        XCTAssertFalse(ActionDetailView.shouldDeliverOpen(origin: nil, current: nil,
                                                          isLoadInFlight: true))
    }

    /// Control: outside a load a row with no conversation identity still delivers — the viewer's
    /// owner has not moved, so a caller that supplies no origin must not get a dead button.
    func testARowWithNoConversationIdentityDeliversOutsideALoad() {
        XCTAssertTrue(ActionDetailView.shouldDeliverOpen(origin: nil, current: UUID(),
                                                         isLoadInFlight: false))
        XCTAssertTrue(ActionDetailView.shouldDeliverOpen(origin: nil, current: nil,
                                                         isLoadInFlight: false))
    }
}

// MARK: - CF-50 · the degraded pill must reach VoiceOver

final class PlanCardDegradedLabelTests: XCTestCase {

    private func plan(phase: PlanRunPhase, statuses: [PlanStepStatus]) -> PlanRunData {
        PlanRunData(
            phase: phase,
            steps: statuses.enumerated().map { index, status in
                PlanStepData(id: "step_\(index)", title: "Step \(index)", status: status)
            }
        )
    }

    /// The pill lives inside the Button's label, which `.accessibilityLabel` replaces wholesale,
    /// and the per-step labels that carry status are unreachable while the card is collapsed —
    /// which a FINISHED card is by default. So "2 failed · 1 ended early" reached sighted users
    /// only. The summary both labels are now built from must carry it.
    func testTheSummaryCarriesTheDegradedPillText() {
        let data = plan(phase: .finished, statuses: [.completed, .failed, .failed, .warning])
        XCTAssertEqual(
            PlanProgressCard.headerSummary(for: data, statusText: "4 steps · 1 done"),
            "4 steps · 1 done · 2 failed · 1 ended early"
        )
    }

    func testTheSuffixNamesFailuresAndEarlyStopsSeparately() {
        XCTAssertEqual(PlanProgressCard.degradedSuffix(for: plan(phase: .finished,
                                                                 statuses: [.failed, .completed])),
                       "1 failed")
        XCTAssertEqual(PlanProgressCard.degradedSuffix(for: plan(phase: .finished,
                                                                 statuses: [.warning, .completed])),
                       "1 ended early")
    }

    /// Control: a clean finished plan gets no suffix, so the label is not padded with an
    /// empty claim.
    func testACleanFinishedPlanGetsNoSuffix() {
        let data = plan(phase: .finished, statuses: [.completed, .completed])
        XCTAssertNil(PlanProgressCard.degradedSuffix(for: data))
        XCTAssertEqual(PlanProgressCard.headerSummary(for: data, statusText: "2 steps · 2 done"),
                       "2 steps · 2 done")
    }

    /// Control: the pill is a FINISHED-card affordance — the executing header shows the progress
    /// capsule instead — and the label must agree with the pill about that, since the whole
    /// defect was the two disagreeing.
    func testAnExecutingPlanGetsNoSuffixEvenWithAFailedStep() {
        XCTAssertNil(PlanProgressCard.degradedSuffix(for: plan(phase: .executing,
                                                               statuses: [.failed, .running])))
    }
}

// MARK: - CF-51 · a user Stop is not a tool failure

@MainActor
final class CancelledToolRowSettlementTests: XCTestCase {

    private func executingRow(_ name: String = "write_file") -> TimelineEvent {
        .toolExecution(ToolExecutionData(id: UUID(), name: name, params: "{}",
                                         output: nil, isSuccess: nil, isExecuting: true))
    }

    private func data(_ event: TimelineEvent) -> ToolExecutionData? {
        if case .toolExecution(let d) = event { return d }
        return nil
    }

    /// `close` stamped `isSuccess = false` unconditionally, so `ActionDetailView.statusIcon`
    /// routed the row to its failure arm — an error-coloured glyph plus a red "CANCELLED"
    /// capsule — for a run the user themselves stopped. The sibling `closeForUserSkip` had
    /// established the opposite convention for exactly this reason.
    func testACancelledCloseLeavesNoFailureVerdict() {
        var events = [executingRow()]
        XCTAssertEqual(DanglingToolRowCloser.close(&events, outcome: .cancelled), 1)

        guard let row = data(events[0]) else { return XCTFail("the row must still be a tool row") }
        XCTAssertNil(row.isSuccess, "a Stop mid-tool is not a failure the row may assert")
        XCTAssertFalse(row.isExecuting, "the spinner must still stop — that part is the point")
        XCTAssertEqual(row.failureCategory, .cancelled, "the structured cause is still recorded")
        XCTAssertEqual(row.output, "Cancelled before the tool finished.",
                       "the synthetic output still says what happened, so the row stays disclosable")
    }

    /// The user-visible half: the collapsed header read "Stopped after N steps (M tools ·
    /// 1 failed)" because `summarize` counted the very row the close had just invented a
    /// failure for.
    func testTheHeaderNoLongerCountsAStopAsAFailure() {
        var events = [executingRow(), executingRow()]
        DanglingToolRowCloser.close(&events, outcome: .cancelled)

        let summary = AgentTimelineView.summarize(events: events, outcome: .cancelled)
        XCTAssertEqual(summary.status, .cancelled)
        XCTAssertEqual(summary.failedTools, 0,
                       "nothing failed — the user stopped the run")
    }

    /// Control: a genuine interruption (provider throw, or a workflow node's `.failed` settle)
    /// still asserts failure. Only the cancelled branch changed.
    func testAFailedCloseStillAssertsFailure() {
        var failedEvents = [executingRow()]
        DanglingToolRowCloser.close(&failedEvents, outcome: .failed)
        guard let failedRow = data(failedEvents[0]) else { return XCTFail("tool row expected") }
        XCTAssertEqual(failedRow.isSuccess, false)
        XCTAssertEqual(failedRow.output, "Interrupted before the tool finished.")

        var unknownEvents = [executingRow()]
        DanglingToolRowCloser.close(&unknownEvents, outcome: nil)
        guard let unknownRow = data(unknownEvents[0]) else { return XCTFail("tool row expected") }
        XCTAssertEqual(unknownRow.isSuccess, false,
                       "no outcome means the run died mid-tool, which IS a failed observation")
        XCTAssertNil(unknownRow.failureCategory,
                     "only a cancellation gets the cancelled category")
    }

    /// The nested shape most agent runs actually build — the cancelled treatment must reach
    /// rows inside a capability card too, or the header and the row disagree again.
    func testTheCancelledTreatmentReachesNestedRows() {
        var plan = PlanRunData(phase: .executing, steps: [
            PlanStepData(id: "step_1", title: "Write it", status: .running)
        ])
        plan.steps[0].events = [executingRow()]
        var events: [TimelineEvent] = [.planExecution(plan)]

        XCTAssertEqual(DanglingToolRowCloser.close(&events, outcome: .cancelled), 1)

        guard case .planExecution(let after) = events[0],
              case .toolExecution(let row) = after.steps[0].events[0] else {
            return XCTFail("plan/step/tool shape not preserved")
        }
        XCTAssertNil(row.isSuccess)
        XCTAssertFalse(row.isExecuting)
        XCTAssertEqual(AgentTimelineView.summarize(events: events, outcome: .cancelled).failedTools, 0)
    }
}

// MARK: - CF-52 · the Run Report speaks the same duration vocabulary as the timeline

final class RunReportDurationVocabularyTests: XCTestCase {

    /// `format(ms:)` never joined the CH58 consolidation: it kept its own
    /// `"\(minutes)m \(remainingSeconds)s"`, so the same 60 000 ms rendered "1m" in the timeline
    /// and "1m 0s" in the Run Report.
    func testAWholeMinuteCollapsesLikeEveryOtherHelper() {
        XCTAssertEqual(DurationFormat.format(ms: 60_000), "1m")
        XCTAssertEqual(DurationFormat.format(ms: 60_000), DurationFormat.milliseconds(60_000))
    }

    /// It also had no hour bucket, so a two-hour run read "120m 0s".
    func testHoursRollOver() {
        XCTAssertEqual(DurationFormat.format(ms: 3_600_000), "1h")
        XCTAssertEqual(DurationFormat.format(ms: 7_200_000), "2h")
        XCTAssertEqual(DurationFormat.format(ms: 5_400_000), "1h 30m")
    }

    /// Partial minutes keep their seconds, and the sub-minute forms are unchanged — the fix
    /// changed the vocabulary above 60 s, not below it.
    func testPartialMinutesAndSubMinuteFormsAreUnchanged() {
        XCTAssertEqual(DurationFormat.format(ms: 125_000), "2m 5s")
        XCTAssertEqual(DurationFormat.format(ms: 820), "820ms")
        XCTAssertEqual(DurationFormat.format(ms: 3_400), "3.4s")
    }

    /// Delegating also picked up `milliseconds`' ≥0 clamp: "-42ms" in a Run Report row read as
    /// a real measurement.
    func testNegativeDurationsAreClamped() {
        XCTAssertEqual(DurationFormat.format(ms: -42), "0ms")
    }
}
