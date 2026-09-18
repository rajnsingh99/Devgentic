// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowNodeOutcomeTests.swift
//  DevgenticTests
//
//  Regression cover for the workflow-cluster fixes of 2026-08-11
//  (Chat_Production_Readiness.md rows CH46, CH47).
//

import XCTest
import SwiftUI
@testable import devgentic

@MainActor
final class WorkflowNodeOutcomeTests: XCTestCase {

    private func node(_ status: WorkflowRunRecord.WorkflowNodeResultSnapshot.NodeStatus,
                      detail: String = "") -> WorkflowRunRecord.WorkflowNodeResultSnapshot {
        WorkflowRunRecord.WorkflowNodeResultSnapshot(
            id: UUID(), nodeID: UUID(), profileName: "n", status: status,
            detail: detail, duration: 1, input: nil, inputSourceLabel: nil,
            nodeTimeline: nil, hasWarnings: nil
        )
    }

    private func run(with nodes: [WorkflowRunRecord.WorkflowNodeResultSnapshot]) -> WorkflowRunRecord {
        WorkflowRunRecord(
            id: UUID(), conversationID: UUID(), workflowProfileID: UUID(),
            workflowName: "wf", timestamp: Date(), userInput: "go",
            nodeResults: nodes, finalOutput: "", variables: [:],
            status: .failed, duration: 3, error: "boom"
        )
    }

    // MARK: - CH47

    /// LEGACY records (written before 2026-08-15) encode a skip as `.failed` + "Upstream
    /// dependency…", so a raw `.failed` count reported the whole cascade as failures: a 6-node
    /// workflow whose node 2 crashed said "5 failed". Old rows must still read correctly.
    func testLegacyUpstreamSkipIsNotAGenuineFailure() {
        let cascadeSkip = node(.failed, detail: "Upstream dependency failed")
        XCTAssertTrue(cascadeSkip.didNotRun)
        XCTAssertFalse(cascadeSkip.isGenuineFailure, "a node that never ran did not fail")

        let realFailure = node(.failed, detail: "Model returned an error")
        XCTAssertFalse(realFailure.didNotRun)
        XCTAssertTrue(realFailure.isGenuineFailure)
    }

    /// The CURRENT encoding: the status carries the fact, and no reason is ever a failure.
    ///
    /// ⚠️ The detail deliberately says "Model returned an error" — prose that the legacy matcher
    /// would classify as a genuine failure. A `.skipped` node must be recognised by its STATUS, or
    /// this is still prose-driven control flow wearing a new name.
    func testEverySkipReasonCountsAsDidNotRunAndNeverAsAFailure() {
        for reason in NodeSkipReason.allCases {
            let n = node(.skipped(reason), detail: "Model returned an error")
            XCTAssertTrue(n.didNotRun, "\(reason) is a node that did not run")
            XCTAssertFalse(n.isGenuineFailure, "\(reason) must never be counted as a failure")
        }
    }

    /// A cancelled node is not a failure either — the user asked for it.
    func testCancelledIsNotAGenuineFailure() {
        let n = node(.cancelled, detail: "Cancelled before the node finished.")
        XCTAssertFalse(n.isGenuineFailure, "the user's own Stop must not be reported as a fault")
        XCTAssertFalse(n.didNotRun, "it started — it just did not finish")
    }

    /// Statuses that ran are never "did not run", whatever their detail says.
    func testCompletedAndRunningAreNeitherFailureNorNotRun() {
        for status in [WorkflowRunRecord.WorkflowNodeResultSnapshot.NodeStatus.completed, .running] {
            let n = node(status, detail: "Upstream dependency failed")
            XCTAssertFalse(n.isGenuineFailure, "\(status) is not a failure")
            XCTAssertFalse(n.didNotRun, "\(status) ran")
        }
    }

    /// The spoken label must separate the two, not fold the cascade into "failed".
    func testSpokenLabelReportsFailedAndNotRunSeparately() {
        let record = run(with: [])
        let label = RunCardSpeech.label(for: record, totalNodes: 6, failedNodes: 1, notRunNodes: 4)

        XCTAssertTrue(label.contains("6 nodes"))
        XCTAssertTrue(label.contains("1 failed"))
        XCTAssertTrue(label.contains("4 not run"), "the cascade must be spoken as 'not run'")
    }

    /// Control: a clean run mentions neither.
    func testSpokenLabelOmitsBothWhenNothingWentWrong() {
        let label = RunCardSpeech.label(for: run(with: []), totalNodes: 3, failedNodes: 0)
        XCTAssertTrue(label.contains("3 nodes"))
        XCTAssertFalse(label.contains("failed"))
        XCTAssertFalse(label.contains("not run"))
    }

    /// The skip reason must survive persistence, because it is now the ONLY thing that says why a
    /// node did not run — the free-text detail is no longer parsed by anyone.
    func testSkipReasonSurvivesTheStatusRoundTrip() {
        typealias NodeStatus = WorkflowRunRecord.WorkflowNodeResultSnapshot.NodeStatus
        for reason in NodeSkipReason.allCases {
            let raw = NodeStatus.skipped(reason).rawValue
            XCTAssertEqual(NodeStatus(rawValue: raw), .skipped(reason),
                           "\(reason) must decode back to itself, not to a different cause")
        }
        XCTAssertEqual(NodeStatus.cancelled, NodeStatus(rawValue: NodeStatus.cancelled.rawValue))
    }

    /// A record written by an OLDER build has a bare "skipped" with no reason. It must still read as
    /// a skip — never fall through to `.other`, which the display maps to a neutral "Waiting" and
    /// would leave the node looking like it is still queued forever.
    func testLegacyBareSkippedStatusStillDecodesAsASkip() {
        let decoded = WorkflowRunRecord.WorkflowNodeResultSnapshot.NodeStatus(rawValue: "skipped")
        XCTAssertEqual(decoded, .skipped(.upstreamSkipped),
                       "pre-2026-08-15 rows only ever encoded the cascade case")
    }

    /// An unknown reason from a NEWER build must degrade to the neutral cause, never to one that
    /// implies something went wrong.
    func testUnknownSkipReasonDegradesToTheNeutralCause() {
        let decoded = WorkflowRunRecord.WorkflowNodeResultSnapshot.NodeStatus(rawValue: "skipped:somethingNewer")
        XCTAssertEqual(decoded, .skipped(.notChosen))
        if case .skipped(let r) = decoded { XCTAssertFalse(r.indicatesProblem) }
    }

    // MARK: - CH46

    /// Workflow markdown had no `.emphasized` branch, so italic runs fell into the generic
    /// `else` and had a NON-italic font assigned over them — the same text rendered italic in
    /// chat and plain in the workflow timeline, contradicting the contract the file states.
    ///
    /// Asserted at the `AttributedString` level, which is where the two renderers must agree:
    /// the intents the styling switch reads must actually be present.
    func testItalicAndBoldItalicIntentsAreDistinguishable() throws {
        let parsed = try AttributedString(markdown: "plain *italic* **bold** ***both***")

        var sawItalicOnly = false
        var sawBoldItalic = false
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.emphasized) && intent.contains(.stronglyEmphasized) { sawBoldItalic = true }
            else if intent.contains(.emphasized) { sawItalicOnly = true }
        }

        XCTAssertTrue(sawItalicOnly, "`*italic*` must carry .emphasized — the branch that was missing")
        XCTAssertTrue(sawBoldItalic, "`***both***` must carry both intents, needing its own branch")
    }
}
