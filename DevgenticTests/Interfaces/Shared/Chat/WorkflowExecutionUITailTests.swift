// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowExecutionUITailTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class WorkflowExecutionUITailTests: XCTestCase {

    private static func record(
        status: WorkflowRunRecord.RunStatus,
        error: String?,
        finalOutput: String = ""
    ) -> WorkflowRunRecord {
        WorkflowRunRecord(
            id: UUID(), conversationID: UUID(), workflowProfileID: UUID(),
            workflowName: "Test", timestamp: Date(timeIntervalSince1970: 0),
            userInput: "hi", nodeResults: [], finalOutput: finalOutput,
            variables: [:], status: status, duration: 1, error: error
        )
    }

    // MARK: - XUI-4 — the recovery tier must read the envelope the encoder writes

    /// ⚠️ THE FILED DEFECT, and it was backwards from what you would guess: the last-resort tier
    /// recovered both LEGACY shapes and was dead against the CURRENT one, because it looked for
    /// `nodes` while the shared `VersionedBlob` encoder writes `payload`.
    func testTheCurrentVersionedEnvelopeIsRecognised() throws {
        let blob = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "payload": [["id": "a"], ["id": "b"]]
        ])

        let nodes = try XCTUnwrap(WorkflowRunRecordSD.rawNodeArray(inBlob: blob))

        XCTAssertEqual(nodes.count, 2)
    }

    /// Only the current envelope is read. The pre-`VersionedBlob` `nodes` envelope and the bare
    /// array were dropped with the rest of the legacy blob handling (2026-10-03).
    func testTheRetiredEnvelopeAndBareArrayAreRejected() throws {
        let legacy = try JSONSerialization.data(withJSONObject: [
            "version": 1, "nodes": [["id": "a"]]
        ])
        XCTAssertNil(WorkflowRunRecordSD.rawNodeArray(inBlob: legacy))

        let bare = try JSONSerialization.data(withJSONObject: [["id": "a"], ["id": "b"], ["id": "c"]])
        XCTAssertNil(WorkflowRunRecordSD.rawNodeArray(inBlob: bare))
    }

    /// A blob that is not a node array at all must report nil rather than an empty array — the
    /// caller logs a different consequence for each.
    func testANonNodeBlobIsRejected() throws {
        let notNodes = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "payload": ["a": 1]])
        XCTAssertNil(WorkflowRunRecordSD.rawNodeArray(inBlob: notNodes))
        XCTAssertNil(WorkflowRunRecordSD.rawNodeArray(inBlob: Data("not json".utf8)))
        XCTAssertNil(WorkflowRunRecordSD.rawNodeArray(inBlob: Data()))
    }

    /// ⚠️ THE CRASH, not a drop. Without `.fragmentsAllowed` a SCALAR element makes
    /// `JSONSerialization` raise `NSInvalidArgumentException` — an Objective-C exception that `try?`
    /// cannot catch — so the LAST-RESORT RECOVERY TIER aborted the process (SIGABRT) on exactly the
    /// malformed bytes it exists to survive. Every other test in this file passes with the option
    /// removed; this one takes the runner down with it, which is the point.
    ///
    /// Goes through `decodeRecord(from:)` rather than `rawNodeArray(inBlob:)` because the raise
    /// happens in the per-ELEMENT loop, one layer past where the envelope tests stop.
    func testScalarElementsAreDroppedRatherThanAbortingTheProcess() {
        let blob = #"{"schemaVersion":1,"payload":[{"nodeID":"\#(UUID().uuidString)"},"a bare string",7,null,true,[1,2]]}"#
        let snapshot = WorkflowRunRecordSD.RowSnapshot(
            cached: nil, id: UUID(), conversationID: UUID(), workflowProfileID: UUID(),
            workflowName: "Scalars", timestamp: Date(timeIntervalSince1970: 0),
            userInput: "hi", finalOutput: "the answer survived", statusRaw: "completed",
            duration: 1, errorMessage: nil,
            nodeResultsData: Data(blob.utf8), variablesData: Data("{}".utf8), traceID: nil
        )

        let record = WorkflowRunRecordSD.decodeRecord(from: snapshot)

        XCTAssertEqual(record.finalOutput, "the answer survived",
                       "the run's own columns must be untouched by an unreadable node blob")
        XCTAssertTrue(record.nodeResults.count <= 1,
                      "no scalar element may decode into a node")
    }

    // MARK: - XUI-5 — a Stop is not a failure

    /// ⚠️ THE FILED DEFECT. `freeze` sets `error` on every cancel path ("Cancelled", "Interrupted"),
    /// so keying the row on `error != nil` drew a red warning triangle beside the card's own amber
    /// "Cancelled" badge — reporting the user's own Stop back to them as a fault.
    func testAStoppedRunIsNotDrawnAsAFailure() {
        let body = RunCardBody.of(status: .cancelled, error: "Cancelled", finalOutput: "")

        XCTAssertEqual(body, .reason("Cancelled"))
        if case .failure = body { XCTFail("a Stop must never take the failure register") }
    }

    /// …and the partial output a Stop preserved must still be shown. The old branch was EXCLUSIVE,
    /// so the error arm hid the very evidence `handleStreamEnd` keeps deliberately.
    func testAStoppedRunShowsItsPartialOutputRatherThanItsReason() {
        XCTAssertEqual(
            RunCardBody.of(status: .cancelled, error: "Cancelled", finalOutput: "half an answer"),
            .output("half an answer")
        )
    }

    /// A genuine failure is unchanged — the fix must not soften real faults.
    func testAGenuineFailureKeepsTheErrorRegister() {
        XCTAssertEqual(
            RunCardBody.of(status: .failed, error: "tool exploded", finalOutput: ""),
            .failure("tool exploded")
        )
    }

    /// ⚠️ A failure's error outranks its partial output: the reason is what the user needs first.
    /// That precedence is the OPPOSITE of the cancelled case, which is the whole point of the split.
    func testAFailureReportsItsReasonEvenWithPartialOutput() {
        XCTAssertEqual(
            RunCardBody.of(status: .failed, error: "tool exploded", finalOutput: "half an answer"),
            .failure("tool exploded")
        )
    }

    func testACompletedRunShowsItsOutput() {
        XCTAssertEqual(
            RunCardBody.of(status: .completed, error: nil, finalOutput: "the answer"),
            .output("the answer")
        )
    }

    /// An empty error string must be treated as no error — `freeze` can write one.
    func testAnEmptyErrorIsNotAFailure() {
        XCTAssertEqual(RunCardBody.of(status: .completed, error: "", finalOutput: ""), RunCardBody.none)
        XCTAssertEqual(RunCardBody.of(status: .cancelled, error: "", finalOutput: ""), RunCardBody.none)
    }

    /// ⚠️ THE HALF-APPLIED-FIX GUARD. Fixing only the VISIBLE row would have left VoiceOver
    /// announcing "Error: Cancelled" for a card that now shows a neutral stop glyph and its partial
    /// output — two descriptions of one card contradicting each other, which is precisely the defect
    /// `nodeTagLabel` exists to prevent one screen over. Both now read `RunCardBody`.
    func testTheSpokenLabelDoesNotCallAStopAnError() {
        let record = Self.record(status: .cancelled, error: "Cancelled")

        let spoken = RunCardSpeech.label(for: record, totalNodes: 1, failedNodes: 0)

        XCTAssertFalse(spoken.contains("Error:"), "a Stop is not a fault — got: \(spoken)")
        XCTAssertTrue(spoken.contains("Reason:"), "…but the reason must still be announced")
    }

    /// A genuine failure must still be announced as an error.
    func testTheSpokenLabelStillCallsAFailureAnError() {
        let record = Self.record(status: .failed, error: "tool exploded")

        XCTAssertTrue(RunCardSpeech.label(for: record, totalNodes: 1, failedNodes: 1).contains("Error:"))
    }

    // MARK: - XUI-10 — the visible tag and the VoiceOver label must be the same word
    //
    // ⚠️ The pill's hit-testing half of this row is SwiftUI runtime behaviour with no headless seam
    // and is genuinely untested. The LABEL half is not, and it is the more serious of the two: the
    // divergence meant a node blocking on the user announced itself as merely "Running...".

    private static func displayData(_ nodes: [WorkflowRunDisplayData.NodeDisplayData])
        -> WorkflowRunDisplayData {
        WorkflowRunDisplayData(
            isLive: false, isRunning: false, nodeResults: nodes, finalOutput: "",
            variables: [:], totalNodes: nodes.count, workflowError: nil,
            userInput: "go", timestamp: Date(), status: nil, duration: 1
        )
    }

    private static func node(
        _ status: WorkflowRunDisplayData.NodeDisplayData.NodeStatus,
        hasWarnings: Bool = false,
        ranBeforeSkip: Bool? = nil
    ) -> WorkflowRunDisplayData.NodeDisplayData {
        WorkflowRunDisplayData.NodeDisplayData(
            id: UUID(), nodeID: UUID(), profileName: "N", status: status,
            detail: "", duration: 1, input: nil, inputSourceLabel: nil,
            nodeTimeline: [], isStreaming: false, hasWarnings: hasWarnings,
            ranBeforeSkip: ranBeforeSkip, supportsTimeline: true
        )
    }

    /// ⚠️ THE FILED DEFECT. A node parked on a HITL prompt was TAGGED "Needs your input" and
    /// ANNOUNCED "Running..." — the one state on this screen that blocks on the user was the one
    /// state VoiceOver could not learn.
    func testAnAwaitingNodeIsCalledAwaitingAndNotRunning() {
        let n = Self.node(.running)
        let data = Self.displayData([n])

        XCTAssertEqual(data.nodeTagLabel(for: n, isAwaiting: true), "Needs your input")
        XCTAssertEqual(data.nodeTagLabel(for: n, isAwaiting: false), n.status.label)
    }

    /// The second override the label used to miss: a degraded node announced as a clean "Completed".
    func testADegradedNodeIsNotAnnouncedAsCleanlyCompleted() {
        let n = Self.node(.completed, hasWarnings: true)
        XCTAssertEqual(Self.displayData([n]).nodeTagLabel(for: n, isAwaiting: false),
                       "Completed · warnings")
    }

    /// ⚠️ The `status == .completed` half of the degraded test is LOAD-BEARING, and dropping that
    /// conjunct survived the rest of this file. A decoded node whose status this build does not
    /// recognise (`RunStatus.other` → `.unknown`) can still carry `hasWarnings` across builds —
    /// without the conjunct it would be both tagged and announced "Completed · warnings" for a node
    /// this build cannot claim completed.
    func testAWarningOnANonCompletedNodeDoesNotClaimCompletion() {
        for status: WorkflowRunDisplayData.NodeDisplayData.NodeStatus in [.failed, .running, .pending] {
            let n = Self.node(status, hasWarnings: true)
            XCTAssertEqual(Self.displayData([n]).nodeTagLabel(for: n, isAwaiting: false),
                           status.label, "\(status) must not borrow the completed wording")
        }
    }

    /// The one override the label DID have must survive the consolidation.
    func testADidNotRunNodeStillReportsItsSkipWording() {
        let notRun = Self.node(.skipped, ranBeforeSkip: false)
        XCTAssertEqual(Self.displayData([notRun]).nodeTagLabel(for: notRun, isAwaiting: false), "Not run")

        let ran = Self.node(.skipped, ranBeforeSkip: true)
        XCTAssertEqual(Self.displayData([ran]).nodeTagLabel(for: ran, isAwaiting: false), "Skipped")
    }

    /// ⚠️ PRECEDENCE. Awaiting outranks everything — a node that is both skipped and awaiting is
    /// blocking on the user, and that is what must be said.
    func testAwaitingOutranksTheOtherOverrides() {
        let n = Self.node(.skipped, hasWarnings: true, ranBeforeSkip: false)
        XCTAssertEqual(Self.displayData([n]).nodeTagLabel(for: n, isAwaiting: true), "Needs your input")
    }

    /// An ordinary node just uses its status word — the overrides must not leak.
    func testAnOrdinaryNodeUsesItsStatusLabel() {
        for status: WorkflowRunDisplayData.NodeDisplayData.NodeStatus in [.completed, .failed, .pending, .running] {
            let n = Self.node(status)
            XCTAssertEqual(Self.displayData([n]).nodeTagLabel(for: n, isAwaiting: false),
                           status.label, "\(status)")
        }
    }

    // MARK: - XUI-6 — the trace cap must keep the TAIL, and say what it dropped

    /// ⚠️ The DIRECTION is the half a reader cannot verify by inspection. On a failure the most
    /// recent events are the diagnostic ones; keeping the head would preserve the setup and discard
    /// the evidence.
    func testTheTraceCapKeepsTheMostRecentEvents() {
        let cap = WorkflowRunRecord.maxPersistedNodeTimelineEvents
        let events = (0..<(cap + 25)).map { TimelineEvent.thought(id: UUID(), text: "e\($0)") }

        let (kept, dropped) = WorkflowRunRecord.cappedNodeTimeline(events)

        XCTAssertEqual(kept.count, cap)
        XCTAssertEqual(dropped, 25)
        if case .thought(_, let text) = kept.last {
            XCTAssertEqual(text, "e\(cap + 24)", "the LAST event must survive")
        } else {
            XCTFail("expected a thought event")
        }
        if case .thought(_, let text) = kept.first {
            XCTAssertEqual(text, "e25", "the first 25 are the ones dropped")
        } else {
            XCTFail("expected a thought event")
        }
    }

    /// A trace at or under the cap is returned untouched, and reports nothing dropped — otherwise
    /// every freeze would log a truncation that did not happen.
    func testATraceUnderTheCapIsUntouched() {
        let events = (0..<10).map { TimelineEvent.thought(id: UUID(), text: "e\($0)") }
        let (kept, dropped) = WorkflowRunRecord.cappedNodeTimeline(events)
        XCTAssertEqual(kept.count, 10)
        XCTAssertEqual(dropped, 0)

        let exact = (0..<WorkflowRunRecord.maxPersistedNodeTimelineEvents).map { TimelineEvent.thought(id: UUID(), text: "e\($0)") }
        XCTAssertEqual(WorkflowRunRecord.cappedNodeTimeline(exact).dropped, 0, "the boundary is inclusive")
    }

    /// The persisted cap must stay BELOW the live one — that asymmetry is the reason it exists.
    ///
    /// ⚠️ The VALUE is pinned as well as the relation. Every other assertion here derives its
    /// expectation FROM the constant, so the cap could be retuned to 40 — a fat-fingered digit, or a
    /// well-meant memory saving — with all of them still green while every persisted run report
    /// silently lost 90% of each node's trace. That is the exact silent-truncation class this row
    /// was filed for, so the number gets stated rather than referred to.
    func testThePersistedCapIsBelowTheLiveCap() {
        XCTAssertEqual(WorkflowRunRecord.maxPersistedNodeTimelineEvents, 400)
        XCTAssertLessThan(WorkflowRunRecord.maxPersistedNodeTimelineEvents, ChatMessage.maxTimelineEvents)
    }

    // MARK: - XUI-8 — workflow code blocks must scale with the user's font setting

    /// ⚠️ The FILED defect is that this rule existed on the chat side and not in workflow output.
    /// Naming the answers pins the rule itself, so a future "simplification" back to a constant is
    /// caught rather than merely re-derived.
    func testCodeSizeTracksTheChatFontSetting() {
        XCTAssertEqual(ChatUIConstants.codeFontSize(forChatFontSize: 15), 13)
        XCTAssertEqual(ChatUIConstants.codeFontSize(forChatFontSize: 22), 20)
    }

    /// ⚠️ The floor is real: the smallest prose setting is 12, and 12 − 2 = 10 is exactly the floor,
    /// so code never renders below legibility even at the extreme.
    func testCodeSizeIsFlooredAtTenPoints() {
        XCTAssertEqual(ChatUIConstants.codeFontSize(forChatFontSize: 12), 10)
        XCTAssertEqual(ChatUIConstants.codeFontSize(forChatFontSize: 10), 10)
        XCTAssertEqual(ChatUIConstants.codeFontSize(forChatFontSize: 0), 10)
    }
}
