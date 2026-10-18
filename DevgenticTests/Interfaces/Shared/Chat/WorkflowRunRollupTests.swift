// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowRunRollupTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class WorkflowRunRollupTests: XCTestCase {

    // MARK: - Fixtures

    private func node(_ status: WorkflowRunRecord.WorkflowNodeResultSnapshot.NodeStatus,
                      name: String = "Node",
                      detail: String = "") -> WorkflowRunRecord.WorkflowNodeResultSnapshot {
        WorkflowRunRecord.WorkflowNodeResultSnapshot(
            id: UUID(), nodeID: UUID(), profileName: name, status: status,
            detail: detail, duration: 1, input: nil, inputSourceLabel: nil,
            nodeTimeline: nil, hasWarnings: nil
        )
    }

    private func record(_ status: WorkflowRunRecord.RunStatus,
                        nodes: [WorkflowRunRecord.WorkflowNodeResultSnapshot],
                        error: String? = nil) -> WorkflowRunDisplayData {
        .from(record: WorkflowRunRecord(
            id: UUID(), conversationID: UUID(), workflowProfileID: UUID(),
            workflowName: "wf", timestamp: Date(), userInput: "go",
            nodeResults: nodes, finalOutput: "", variables: [:],
            status: status, duration: 3, error: error
        ))
    }

    // MARK: - Report join key (workflow Report button, 2026-08-23)

    /// The workflow surface has no chat bubbles, so its Report button reads the join
    /// key off the display projection — BOTH adapters must carry it, or one of the
    /// two views (live vs historical) silently opens an empty report.
    func testDisplayDataCarriesTraceIDAndRunIDFromRecord() {
        let recordID = UUID()
        let d = WorkflowRunDisplayData.from(record: WorkflowRunRecord(
            id: recordID, conversationID: UUID(), workflowProfileID: UUID(),
            workflowName: "wf", timestamp: Date(), userInput: "go",
            nodeResults: [], finalOutput: "", variables: [:],
            status: .completed, duration: 3, error: nil, traceID: "trace-abc"
        ))
        XCTAssertEqual(d.traceID, "trace-abc")
        XCTAssertEqual(d.runID, recordID)
    }

    @MainActor
    func testDisplayDataCarriesTraceIDAndRunIDFromLiveState() {
        let state = WorkflowExecutionState()
        state.traceID = "trace-live"
        let recordID = UUID()
        state.runRecordID = recordID
        let d = WorkflowRunDisplayData.from(live: state)
        XCTAssertEqual(d.traceID, "trace-live")
        XCTAssertEqual(d.runID, recordID)
    }

    /// Pre-trace-era rows have no traceID — the projection must say so honestly
    /// (nil), because the report panel's "never recorded" state keys off it.
    func testPreTraceRecordYieldsNilTraceID() {
        let d = record(.completed, nodes: [])
        XCTAssertNil(d.traceID)
        XCTAssertNotNil(d.runID)
    }

    // MARK: - The pill: persisted status WINS over derived heuristics

    /// The `.running` orphan stub (finalize never ran — crash, or reconcile skipped). Deriving
    /// from its empty node list said "Completed"; the persisted status must win.
    func testRunningStubShowsRunningNotCompleted() {
        let d = record(.running, nodes: [])
        XCTAssertEqual(d.pillVerdict, .running)
        XCTAssertEqual(d.pillLabel, "Running")
    }

    /// WF-UI1's record: stamped by a NEWER build. The pill must say Unknown — and now the Final
    /// Outcome row override must agree with it instead of asserting a green "Completed".
    func testUnknownPersistedStatusIsNeverReportedAsSuccess() {
        let d = record(.other("archived"), nodes: [node(.completed), node(.completed)])
        XCTAssertEqual(d.pillVerdict, .unknown)
        XCTAssertEqual(d.pillLabel, "Unknown")
        XCTAssertTrue(d.hasUnknownPersistedStatus,
                      "the Final Outcome row keys its override off this — it must fire")
        XCTAssertEqual(d.rollupOutcome, .completed,
                       "the DERIVED outcome still says completed; the override at the row is what prevents the false claim")
    }

    func testCancelledRecordShowsCancelled() {
        let d = record(.cancelled, nodes: [node(.completed), node(.cancelled)], error: "Cancelled")
        XCTAssertEqual(d.pillVerdict, .cancelled)
        XCTAssertTrue(d.isCancelledRun)
    }

    /// A record marked completed that nonetheless CARRIES a failed node reports failed — the nodes
    /// are the evidence, the roll-up is a summary of them.
    func testCompletedRecordWithGenuineFailureReportsFailed() {
        let d = record(.completed, nodes: [node(.completed), node(.failed, detail: "boom")])
        XCTAssertEqual(d.pillVerdict, .failed)
    }

    // MARK: - WF-RU4: a genuine node failure the engine still routed to a successful terminal

    /// The persisted `.completedWithWarnings` status is trusted directly — `freeze()` already did
    /// the work of confirming a genuine failure was present AND the engine still reached a
    /// successful terminal, so the display layer does not re-derive it.
    func testCompletedWithWarningsRecordShowsCompletedWithWarningsPill() {
        let d = record(.completedWithWarnings, nodes: [node(.completed), node(.failed, detail: "boom")])
        XCTAssertEqual(d.pillVerdict, .completedWithWarnings)
        XCTAssertEqual(d.pillLabel, "Completed with warnings")
    }

    // MARK: - Genuine failure vs routing

    /// A skipped node is ROUTING. Counting it as failure turned the pill red on every healthy
    /// conditional run — the original WF4 defect, now pinned at the view's own seam.
    func testSkippedNodesAreNotFailures() {
        let d = record(.completed, nodes: [node(.completed), node(.skipped(.notChosen)), node(.completed)])
        XCTAssertFalse(d.hasGenuineFailure)
        XCTAssertEqual(d.pillVerdict, .completed)
        XCTAssertEqual(d.rollupOutcome, .completed)
    }

    /// A cancelled node is the user's own Stop, not a fault.
    func testCancelledNodesAreNotFailures() {
        let d = record(.cancelled, nodes: [node(.completed), node(.cancelled)])
        XCTAssertFalse(d.hasGenuineFailure)
    }

    // MARK: - The step counter

    func testStepCounterNamesTheGenuinelyFailedStep() {
        let d = record(.completed, nodes: [
            node(.completed),
            node(.skipped(.upstreamFailed)),                      // not run — must be skipped over
            node(.failed, detail: "boom"),                        // the real break: step 3
            node(.completed)
        ])
        XCTAssertTrue(d.stepCounterDescription.contains("failed at step 3 of 4"),
                      "got: \(d.stepCounterDescription)")
    }

    func testStepCounterOnACleanRunCountsSteps() {
        let d = record(.completed, nodes: [node(.completed), node(.completed)])
        XCTAssertTrue(d.stepCounterDescription.hasPrefix("2 steps"), "got: \(d.stepCounterDescription)")
    }

    func testStepCounterOnACancelledRunSaysStopped() {
        let d = record(.cancelled, nodes: [node(.completed), node(.cancelled)])
        XCTAssertTrue(d.stepCounterDescription.hasPrefix("stopped"), "got: \(d.stepCounterDescription)")
    }

    /// [WF-RU4] The wording is deliberately NOT "failed at step X of N" — that phrasing would
    /// frame a survived failure as where the run stopped, one line under a pill that just said
    /// "Completed with warnings". Just the count.
    func testStepCounterOnCompletedWithWarningsRunNamesFailedCountNotStep() {
        let d = record(.completedWithWarnings, nodes: [
            node(.completed), node(.failed, detail: "boom"), node(.completed)
        ])
        XCTAssertFalse(d.stepCounterDescription.contains("failed at step"),
                       "must not read like a hard failure — got: \(d.stepCounterDescription)")
        XCTAssertTrue(d.stepCounterDescription.hasPrefix("3 steps · 1 failed"),
                      "got: \(d.stepCounterDescription)")
    }

    // MARK: - Unknown NODE status (WF-UI3)

    /// A node stamped by a newer build is a FINISHED node: it must land in the display vocabulary
    /// as `.unknown` (label "Unknown"), never `.pending` ("Waiting") — a run that finished days
    /// ago must not claim it never started.
    func testUnknownNodeStatusRendersAsUnknownNotWaiting() {
        let d = record(.completed, nodes: [node(.completed), node(.other("paused"))])
        let unknownNode = d.nodeResults.first { $0.profileName == "Node" && $0.status == .unknown }
            ?? d.nodeResults.last!
        XCTAssertEqual(unknownNode.status, .unknown)
        XCTAssertEqual(unknownNode.status.label, "Unknown")
        XCTAssertNotEqual(unknownNode.status.label, "Waiting")
    }

    /// …and it counts as SETTLED — it finished; only genuinely pending/running nodes are unsettled.
    func testUnknownNodeCountsAsSettled() {
        let d = record(.completed, nodes: [node(.completed), node(.other("paused"))])
        XCTAssertEqual(d.settledNodeCount, 2)
    }

    // MARK: - Live orphan append (WF-UI7)

    /// A live result whose node is NOT in the layout must be APPENDED, not dropped — the record
    /// path already did this ("Showing its persisted trace rather than hiding the evidence") while
    /// the live path silently compactMap-dropped it: delete a node mid-run, save, return to
    /// Execution, and the EXECUTING node's row vanished while the step counter changed denominator.
    @MainActor
    func testLiveResultForANodeOutsideTheLayoutIsAppended() {
        let state = WorkflowExecutionState()
        state.isRunning = true
        let orphanID = UUID()
        state.handleNodeStarted(nodeID: orphanID, profileName: "Deleted Mid-Run", index: 1, total: 1)

        let survivor = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Still Here")
        let layout = WorkflowLayout(nodes: [survivor], edges: [], annotations: [])

        let d = WorkflowRunDisplayData.from(live: state, layout: layout)

        XCTAssertTrue(d.nodeResults.contains { $0.nodeID == survivor.id },
                      "the layout node still renders (as pending)")
        let orphan = d.nodeResults.first { $0.nodeID == orphanID }
        XCTAssertNotNil(orphan, "the executing orphan must stay visible — evidence is never hidden")
        XCTAssertEqual(orphan?.status, .running)
        XCTAssertEqual(orphan?.profileName, "Deleted Mid-Run")
    }

    // MARK: - Final Outcome row: what it TAGS must be what it SPEAKS (WF-RU3)

    /// ⚠️ Before this fix, `.accessibilityLabel` read the raw `status.label` while the visible tag
    /// read this same override chain — VoiceOver announced "Failed" on a run the screen correctly
    /// tagged "Cancelled". `finalOutcomeTagLabel` is now the ONE computation both consumers call,
    /// so this suite doubles as the accessibility pin `ChatAccessibilitySemanticsTests`'s header
    /// note says is the only reachable way to test a `.accessibilityLabel` value.
    func testCancelledRunTagsAndSpeaksCancelledNotFailed() {
        let label = WorkflowExecutionTimelineView.finalOutcomeTagLabel(
            status: .failed, isCancelled: true, isUnknown: false,
            isRunning: false, settledCount: 2, totalNodeCount: 3)
        XCTAssertEqual(label, "Cancelled",
                       "a cancelled run's raw rollup status is .failed — the row must not say so")
    }

    /// The UNKNOWN twin of the same bug (WF-UI1's override): a record from a newer build must not
    /// assert "Completed" when the header pill honestly says "Unknown".
    func testUnknownPersistedStatusTagsAndSpeaksUnknownNotCompleted() {
        let label = WorkflowExecutionTimelineView.finalOutcomeTagLabel(
            status: .completed, isCancelled: false, isUnknown: true,
            isRunning: false, settledCount: 3, totalNodeCount: 3)
        XCTAssertEqual(label, "Unknown")
    }

    /// ⚠️ The THIRD divergence the 2026-08-23 revalidation found and the original filing missed:
    /// a still-running, still-pending run must announce its live progress, not a bare "Waiting"
    /// that drops the step count the visible tag has always shown.
    func testPendingAndRunningTagsAndSpeaksLiveProgressNotBareWaiting() {
        let label = WorkflowExecutionTimelineView.finalOutcomeTagLabel(
            status: .pending, isCancelled: false, isUnknown: false,
            isRunning: true, settledCount: 2, totalNodeCount: 5)
        XCTAssertEqual(label, "Awaiting inputs · 2/5")
    }

    /// Pending but NOT running (a persisted record that never got past its first node) must fall
    /// through to the plain status label — "Waiting" is honest once the run isn't live.
    func testPendingButNotRunningFallsBackToPlainStatusLabel() {
        let label = WorkflowExecutionTimelineView.finalOutcomeTagLabel(
            status: .pending, isCancelled: false, isUnknown: false,
            isRunning: false, settledCount: 0, totalNodeCount: 3)
        XCTAssertEqual(label, "Waiting")
    }

    /// The control: an ordinary completed run with none of the three overrides in play must
    /// still read its plain status — the overrides must not swallow the normal case.
    func testOrdinaryCompletedRunTagsAndSpeaksCompleted() {
        let label = WorkflowExecutionTimelineView.finalOutcomeTagLabel(
            status: .completed, isCancelled: false, isUnknown: false,
            isRunning: false, settledCount: 3, totalNodeCount: 3)
        XCTAssertEqual(label, "Completed")
    }

    /// [WF-RU4] The fourth override: `status` (a node-shaped vocabulary reused for this row) has
    /// no value of its own for "a node failed but the run still reached a successful terminal" —
    /// same shape as the cancelled/unknown overrides above.
    func testCompletedWithWarningsTagsAndSpeaksCompletedWithWarnings() {
        let label = WorkflowExecutionTimelineView.finalOutcomeTagLabel(
            status: .completed, isCancelled: false, isUnknown: false,
            isCompletedWithWarnings: true,
            isRunning: false, settledCount: 3, totalNodeCount: 3)
        XCTAssertEqual(label, "Completed with warnings")
    }

    /// Cancelled still outranks the new override — the precedence chain must not have shuffled.
    func testCancelledOutranksCompletedWithWarnings() {
        let label = WorkflowExecutionTimelineView.finalOutcomeTagLabel(
            status: .failed, isCancelled: true, isUnknown: false,
            isCompletedWithWarnings: true,
            isRunning: false, settledCount: 2, totalNodeCount: 3)
        XCTAssertEqual(label, "Cancelled")
    }

    /// The zero-node edge case the `max(totalNodeCount, 1)` guard exists for — must not divide
    /// by, or announce, a "/0" denominator.
    func testAwaitingProgressGuardsAgainstZeroTotalNodes() {
        let label = WorkflowExecutionTimelineView.finalOutcomeTagLabel(
            status: .pending, isCancelled: false, isUnknown: false,
            isRunning: true, settledCount: 0, totalNodeCount: 0)
        XCTAssertEqual(label, "Awaiting inputs · 0/1")
    }

    // MARK: - Final Outcome panel (register XUI-2)

    /// A record with `finalOutput`, which the shared `record(...)` fixture hardcodes empty.
    private func record(_ status: WorkflowRunRecord.RunStatus,
                        nodes: [WorkflowRunRecord.WorkflowNodeResultSnapshot],
                        error: String? = nil,
                        finalOutput: String) -> WorkflowRunDisplayData {
        .from(record: WorkflowRunRecord(
            id: UUID(), conversationID: UUID(), workflowProfileID: UUID(),
            workflowName: "wf", timestamp: Date(), userInput: "go",
            nodeResults: nodes, finalOutput: finalOutput, variables: [:],
            status: status, duration: 3, error: error
        ))
    }

    /// ⚠️ THE XUI-2 PIN. A run that failed BEFORE any node dispatched (pre-flight validation,
    /// unresolvable config) froze with zero node results — and the panel's empty/pending branch
    /// sat AHEAD of the error branch, so the user saw an hourglass "Waiting for execution"
    /// directly under a "Failed" tag, with the actual reason nowhere on screen.
    func testPreflightFailureRecordShowsErrorNotWaiting() {
        let d = record(.failed, nodes: [], error: "Validation failed: the graph contains a cycle")
        XCTAssertEqual(d.finalOutcomePanel(rowStatus: .failed),
                       .error("Validation failed: the graph contains a cycle"))
    }

    /// The orphan-reconciliation shape: `.cancelled`, error "Interrupted", zero nodes.
    ///
    /// ⚠️ UPDATED FOR XUI-13, and the old expectation (`.error("Interrupted")`) WAS THE DEFECT —
    /// do not restore it or weaken this to a looser assertion. The run ended because the app quit,
    /// not because anything failed, and `.error` renders in `theme.errorColor` behind a red
    /// container edge under the row's own amber "Cancelled" tag.
    func testReconciledOrphanShowsItsInterruptedReasonNotAnError() {
        let d = record(.cancelled, nodes: [], error: "Interrupted")
        XCTAssertEqual(d.finalOutcomePanel(rowStatus: .cancelled), .reason("Interrupted"))
    }

    /// ⚠️ THE XUI-13 PIN. Every cancel path leaves a `workflowError` behind, so the error branch
    /// could not tell the user's own Stop from a fault and reported it back as one — on the surface
    /// the user is most likely to be looking at, since the Final Outcome row expands by default.
    func testAStoppedRunReportsItsReasonInTheNeutralRegister() {
        let d = record(.cancelled, nodes: [], error: "Cancelled")
        XCTAssertEqual(d.finalOutcomePanel(rowStatus: .cancelled), .reason("Cancelled"))
    }

    /// ⚠️ OUTPUT OUTRANKS THE REASON, exactly as on the history card. `handleStreamEnd` preserves
    /// a stopped run's partial answer deliberately ("a Stop discards no evidence") and the reason
    /// is already stated by the tag above. Ordering these the other way re-creates the half of
    /// XUI-5 that HID the output.
    func testAStoppedRunShowsItsPartialOutputAheadOfTheReason() {
        let d = record(.cancelled, nodes: [], error: "Cancelled", finalOutput: "half an answer")
        XCTAssertEqual(d.finalOutcomePanel(rowStatus: .cancelled), .output("half an answer"))
    }

    /// ⚠️ THE GATE IS LOAD-BEARING. Without the `isCancelledRun` conjunct the neutral branch would
    /// swallow EVERY genuine failure — strictly worse than the bug it fixes, and it would re-open
    /// XUI-2 by shadowing the error branch that was reordered ahead of the hourglass.
    func testAGenuineFailureIsStillReportedAsAnError() {
        for status: WorkflowRunRecord.RunStatus in [.failed, .completed, .running] {
            let d = record(status, nodes: [], error: "Boom")
            XCTAssertEqual(d.finalOutcomePanel(rowStatus: .failed), .error("Boom"), "\(status)")
        }
    }

    /// A cancelled run with neither output nor reason falls through to the zero-node arm rather
    /// than rendering a glyph beside nothing at all.
    ///
    /// ⚠️ The EMPTY-STRING half of this failed on the first run and the divergence was real, not a
    /// bad expectation: `finalOutcomePanel` returned `.error("")` — an error-red line with no text —
    /// where `RunCardBody.of` on the history card already normalised a blank message away. Making
    /// the two surfaces agree is the whole point of this row, so the panel was normalised to match
    /// rather than this assertion loosened. (`.waiting` for a terminal zero-node run is a separate,
    /// pre-existing wart of the empty/pending arm and is not what this test is about.)
    func testACancelledRunWithNoReasonAndNoOutputFallsThroughToWaiting() {
        let d = record(.cancelled, nodes: [], error: nil)
        XCTAssertEqual(d.finalOutcomePanel(rowStatus: .cancelled), .waiting)

        let empty = record(.cancelled, nodes: [], error: "")
        XCTAssertEqual(empty.finalOutcomePanel(rowStatus: .cancelled), .waiting)
    }

    /// The hourglass stays HONEST where it is true: a live run that has dispatched nothing.
    func testLiveRunWithNothingDispatchedShowsWaiting() {
        let state = WorkflowExecutionState()
        state.isRunning = true
        let d = WorkflowRunDisplayData.from(live: state)
        XCTAssertEqual(d.finalOutcomePanel(rowStatus: .pending), .waiting)
    }

    /// Live with settled nodes and no final output yet → progress, whose spinner wording tracks
    /// the Final Outcome ROW's own status.
    func testLiveRunWithSettledNodesShowsProgress() {
        let state = WorkflowExecutionState()
        state.isRunning = true
        state.nodeResults = [WorkflowNodeResult(
            id: UUID(), nodeID: UUID(), profileName: "A", status: .completed,
            detail: "done", startTime: Date(), endTime: Date()
        )]
        let d = WorkflowRunDisplayData.from(live: state)
        XCTAssertEqual(d.finalOutcomePanel(rowStatus: .running), .progress(synthesising: true))
        XCTAssertEqual(d.finalOutcomePanel(rowStatus: .pending), .progress(synthesising: false))
    }

    /// Hand-built display data — the ONLY way to put a `.pending` node into `nodeResults`:
    /// neither status mapper can emit `.pending` (it exists only as a layout placeholder), so
    /// record-path fixtures cannot represent the production-dominant live shape, where the
    /// layout factory seeds every undispatched node as pending from frame one.
    private func liveDisplayData(nodes: [WorkflowRunDisplayData.NodeDisplayData],
                                 error: String? = nil,
                                 finalOutput: String = "") -> WorkflowRunDisplayData {
        WorkflowRunDisplayData(
            isLive: true, isRunning: true, nodeResults: nodes, finalOutput: finalOutput,
            variables: [:], totalNodes: nodes.count, workflowError: error,
            userInput: "go", timestamp: Date(), status: nil, duration: 1
        )
    }

    private func pendingNode() -> WorkflowRunDisplayData.NodeDisplayData {
        WorkflowRunDisplayData.NodeDisplayData(
            id: UUID(), nodeID: UUID(), profileName: "P", status: .pending,
            detail: "", duration: 0, input: nil, inputSourceLabel: nil,
            nodeTimeline: [], isStreaming: false, supportsTimeline: true
        )
    }

    private func completedNode() -> WorkflowRunDisplayData.NodeDisplayData {
        WorkflowRunDisplayData.NodeDisplayData(
            id: UUID(), nodeID: UUID(), profileName: "C", status: .completed,
            detail: "done", duration: 1, input: nil, inputSourceLabel: nil,
            nodeTimeline: [], isStreaming: false, supportsTimeline: true
        )
    }

    /// A live run whose layout placeholders are ALL still pending — the honest hourglass. Kills
    /// the delete-the-allSatisfy-clause mutant (which would claim "Awaiting node outputs…" at
    /// run start).
    func testLiveRunAllPendingPlaceholdersShowsWaiting() {
        let d = liveDisplayData(nodes: [pendingNode(), pendingNode()])
        XCTAssertEqual(d.finalOutcomePanel(rowStatus: .pending), .waiting)
    }

    /// ⚠️ The MIXED settled+pending row — the production-dominant live shape (every real live
    /// run carries pending placeholders from frame one) and the one that separates `allSatisfy`
    /// from `contains`: a contains-mutant shows the "Waiting for execution" hourglass for
    /// essentially the entire run, the exact misreport class XUI-2 was filed against.
    func testMixedSettledAndPendingShowsProgress() {
        let d = liveDisplayData(nodes: [completedNode(), pendingNode()])
        XCTAssertEqual(d.finalOutcomePanel(rowStatus: .running), .progress(synthesising: true))
    }

    /// The ordinary settled case renders the output.
    func testCompletedRecordShowsFinalOutput() {
        let d = record(.completed, nodes: [node(.completed)], finalOutput: "The answer")
        XCTAssertEqual(d.finalOutcomePanel(rowStatus: .completed), .output("The answer"))
    }

    /// Parity with the pre-fix behavior: an error alongside a REAL final output still shows the
    /// output — the error branch only owns runs that produced nothing.
    func testErrorWithFinalOutputStillShowsOutput() {
        let d = record(.completed, nodes: [node(.completed), node(.failed)],
                       error: "one branch failed", finalOutput: "Partial answer")
        XCTAssertEqual(d.finalOutcomePanel(rowStatus: .completed), .output("Partial answer"))
    }

    // MARK: - Captured-trace gate (register XUI-1)

    private func displayNode(supportsTimeline: Bool, events: [TimelineEvent]) -> WorkflowRunDisplayData.NodeDisplayData {
        WorkflowRunDisplayData.NodeDisplayData(
            id: UUID(), nodeID: UUID(), profileName: "N", status: .skipped,
            detail: "Skipped by you", duration: 1.2, input: nil, inputSourceLabel: nil,
            nodeTimeline: events, isStreaming: false,
            supportsTimeline: supportsTimeline
        )
    }

    private var traceEvent: TimelineEvent {
        .toolExecution(ToolExecutionData(id: UUID(), name: "fs_read", params: "{}",
                                         output: "ok", isSuccess: true, isExecuting: false))
    }

    /// ⚠️ THE XUI-1 PIN. A node skipped mid-flight (or cancelled while executing) HAS a captured
    /// trace — persisted by `freeze` up to 400 events — and the `.skipped`/`.cancelled` arms
    /// rendered only a one-line status, leaving the evidence unreachable ("an 829ms model call in
    /// the Run Report and nothing at all in the timeline", 2026-08-23).
    func testCapturedTraceShowsForTimelineCapableNodeWithEvents() {
        let d = record(.completed, nodes: [])
        XCTAssertTrue(d.nodeShowsCapturedTrace(displayNode(supportsTimeline: true, events: [traceEvent])))
    }

    func testNoTraceForEmptyTimeline() {
        let d = record(.completed, nodes: [])
        XCTAssertFalse(d.nodeShowsCapturedTrace(displayNode(supportsTimeline: true, events: [])))
    }

    /// Single-shot kinds (bot, imageGen, structural transforms) hold only incidental events —
    /// `supportsTimeline` stays the gate, exactly as on the settled arm.
    func testNoTraceForSingleShotNodeKind() {
        let d = record(.completed, nodes: [])
        XCTAssertFalse(d.nodeShowsCapturedTrace(displayNode(supportsTimeline: false, events: [traceEvent])))
    }
}
