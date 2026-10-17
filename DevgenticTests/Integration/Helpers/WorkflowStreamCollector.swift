// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowStreamCollector.swift
//  DevgenticTests
//
//  Workflow-specific event extraction and assertion helpers.
//  Extends the base StreamCollector with DAG orchestration event support.
//

import Foundation
import XCTest
@testable import devgentic

// MARK: - Workflow Event Extraction

enum WorkflowStreamCollector {

    // MARK: - Node Lifecycle Events

    static func nodeStartedEvents(from events: [AgentStreamEvent]) -> [(nodeID: UUID, profileName: String, index: Int, total: Int)] {
        events.compactMap { event in
            if case .workflowNodeStarted(let nodeID, let name, let idx, let total) = event {
                return (nodeID, name, idx, total)
            }
            return nil
        }
    }

    static func nodeCompletedEvents(from events: [AgentStreamEvent]) -> [(nodeID: UUID, profileName: String, summary: String)] {
        events.compactMap { event in
            if case .workflowNodeCompleted(let nodeID, let name, let summary, _) = event {
                return (nodeID, name, summary)
            }
            return nil
        }
    }

    /// Node IDs that completed WITH WARNINGS — the degraded-but-usable outcome.
    ///
    /// ⚠️ A separate extractor rather than a fourth element on `nodeCompletedEvents`, deliberately:
    /// that tuple is destructured at ~30 call sites, and widening it would move all of them for one
    /// new assertion. It exists because `nodeCompletedEvents` discards the flag with `_`, so until
    /// now NO helper could observe `hasWarnings` and the `.completedWithWarnings` arm of the
    /// executor's inner-outcome ladder was unassertable (WF-TS1).
    static func nodeCompletedWithWarnings(from events: [AgentStreamEvent]) -> [UUID] {
        events.compactMap { event in
            if case .workflowNodeCompleted(let nodeID, _, _, let hasWarnings) = event, hasWarnings {
                return nodeID
            }
            return nil
        }
    }

    static func nodeFailedEvents(from events: [AgentStreamEvent]) -> [(nodeID: UUID, profileName: String, error: String)] {
        events.compactMap { event in
            if case .workflowNodeFailed(let nodeID, let name, let error, _) = event {
                return (nodeID, name, error)
            }
            return nil
        }
    }

    /// Nodes that DID NOT RUN, with the structural cause.
    ///
    /// ⚠️ Separate from `nodeFailedEvents` on purpose. Until 2026-08-15 a skip was emitted as
    /// `workflowNodeFailed`, so tests asserted things like "3 failed events for A fails + B skipped
    /// + C skipped" — encoding the defect as the expectation. Assert the SPLIT instead: it is the
    /// distinction the whole state model exists to make.
    static func nodeSkippedEvents(from events: [AgentStreamEvent]) -> [(nodeID: UUID, profileName: String, reason: NodeSkipReason, ranBeforeSkip: Bool)] {
        events.compactMap { event in
            if case .workflowNodeSkipped(let nodeID, let name, let reason, let ranBeforeSkip) = event {
                return (nodeID, name, reason, ranBeforeSkip)
            }
            return nil
        }
    }

    /// Nodes cancelled mid-flight.
    static func nodeCancelledEvents(from events: [AgentStreamEvent]) -> [(nodeID: UUID, profileName: String)] {
        events.compactMap { event in
            if case .workflowNodeCancelled(let nodeID, let name) = event {
                return (nodeID, name)
            }
            return nil
        }
    }

    /// The run's own TERMINAL verdict — the event `ActiveStreamManager` turns into the run chip,
    /// the persisted status and the trace span's outcome.
    ///
    /// ⚠️ Nothing in the 151-case integration suite looked at this (WF-EX5): the tests watch which
    /// nodes started, finished and what text came out, so the three verdict branches could be
    /// inverted wholesale and every test would still pass.
    static func terminalOutcomes(from events: [AgentStreamEvent]) -> [(outcome: ExecutionOutcome, reason: String?)] {
        events.compactMap { event in
            if case .executionFinished(let outcome, let reason) = event { return (outcome, reason) }
            return nil
        }
    }

    /// The `.error` payloads a run emitted — the failure text the chat surfaces.
    static func errorMessages(from events: [AgentStreamEvent]) -> [String] {
        events.compactMap { event in
            if case .error(let structured) = event { return structured.message }
            return nil
        }
    }

    /// The `.content` payloads — the run's answer text.
    static func contentText(from events: [AgentStreamEvent]) -> String {
        events.compactMap { event in
            if case .content(let text) = event { return text }
            return nil
        }.joined()
    }

    // MARK: - Progress Events

    /// All `.thought` text concatenated. Used to assert that a branch was NOT entered — some
    /// executor paths are only observable by the diagnostic they would emit.
    static func thoughtText(from events: [AgentStreamEvent]) -> String {
        events.compactMap { event -> String? in
            if case .thought(let text, _, _) = event { return text }
            return nil
        }.joined(separator: "\n")
    }

    static func progressEvents(from events: [AgentStreamEvent]) -> [(completed: Int, total: Int)] {
        events.compactMap { event in
            if case .workflowProgress(let completed, let total) = event {
                return (completed, total)
            }
            return nil
        }
    }

    // MARK: - HITL Events

    static func confirmationRequests(from events: [AgentStreamEvent]) -> [(toolName: String, params: String, operationID: UUID)] {
        events.compactMap { event -> (toolName: String, params: String, operationID: UUID)? in
            if case .requestConfirmation(let name, let params, let opID, _, _) = event {
                return (name, params, opID)
            }
            return nil
        }
    }

    /// [E1] Gate requests emitted by the workflow (per-option routing replaced the old binary gate).
    /// ⚠️ WF-TS9: `deadline` is surfaced because it was previously discarded here, which made the
    /// gate's countdown — the thing the banner renders and the auto-decision fires on — invisible
    /// to every test in the suite.
    /// Plan-review requests that reached the OUTER stream. The fourth HITL kind — and the one the
    /// sub-workflow arm silently dropped until 2026-08-19, which was a permanent hang (design doc §9 N2).
    static func planReviewRequests(from events: [AgentStreamEvent]) -> [(subtasks: [SubTask], operationID: UUID, sourceNodeID: UUID?, sourceNodeName: String?)] {
        events.compactMap { event in
            if case .requestPlanReview(let subtasks, let opID, let nodeID, let nodeName) = event {
                return (subtasks, opID, nodeID, nodeName)
            }
            return nil
        }
    }

    static func gateRequests(from events: [AgentStreamEvent]) -> [(prompt: String, options: [String], operationID: UUID, deadline: Date?, inputText: String?, highlights: [RuleMatchSpan])] {
        events.compactMap { event -> (prompt: String, options: [String], operationID: UUID, deadline: Date?, inputText: String?, highlights: [RuleMatchSpan])? in
            if case .requestGate(let prompt, let options, let opID, let deadline, _, let inputText, let highlights, _) = event {
                return (prompt, options, opID, deadline, inputText, highlights)
            }
            return nil
        }
    }

    // MARK: - Gate Helper

    /// Consumes a workflow stream, auto-responding to the first gate by choosing `option`. Passing
    /// `nil` resolves the gate with no choice: a DISMISSAL, so the Gate node settles as cancelled
    /// and takes no branch (CR-47). Only a Gate's own timer expires it.
    /// A brief delay lets the suspension register before responding.
    static func collectWithGateChoice(
        from stream: AsyncThrowingStream<AgentStreamEvent, Error>,
        choosing option: String?
    ) async throws -> [AgentStreamEvent] {
        var events: [AgentStreamEvent] = []
        for try await event in stream {
            events.append(event)
            if case .requestGate(_, _, let operationID, _, _, _, _, _) = event {
                try await Task.sleep(for: .milliseconds(50))
                await ExecutionSuspensionService.shared.resumeGate(for: operationID, chosenOption: option, resolvedBy: .localUI)
            }
        }
        return events
    }

    // MARK: - Cancellation Helper

    /// Collects events from a stream, cancelling the task when a predicate matches.
    /// Returns all events collected before AND including the triggering event.
    /// Waits briefly after cancel to let the executor's cancellation handler emit final events.
    static func collectUntilCancelled(
        from stream: AsyncThrowingStream<AgentStreamEvent, Error>,
        cancelWhen predicate: @escaping (AgentStreamEvent) -> Bool
    ) async -> [AgentStreamEvent] {
        var events: [AgentStreamEvent] = []
        do {
            for try await event in stream {
                events.append(event)
                if predicate(event) {
                    break // Stop consuming — the outer task should be cancelled by the caller
                }
            }
        } catch is CancellationError {
            // Expected — stream was cancelled
        } catch {
            // Other error — still return what we collected
        }
        return events
    }

    // MARK: - Assertions

    /// Asserts that node-started events appear in the expected order (by node ID).
    static func assertNodeExecutionOrder(
        _ events: [AgentStreamEvent],
        expectedNodeIDs: [UUID],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let startedIDs = nodeStartedEvents(from: events).map(\.nodeID)

        // ⚠️ WF-TS11: this assertion used to compare `expectedNodeIDs.filter { … }` against a
        // second, identical `expectedNodeIDs.filter { … }` — the same expression on both sides,
        // so it held for EVERY possible run and reported nothing. The real work is the relative
        // ordering loop below; what belongs here is the *observed* sequence, restricted to the
        // nodes under test, compared against what was expected.
        let observedOrder = startedIDs.filter { expectedNodeIDs.contains($0) }
        XCTAssertEqual(observedOrder, expectedNodeIDs.filter { startedIDs.contains($0) },
                       "Node execution order mismatch — observed \(observedOrder), expected \(expectedNodeIDs)",
                       file: file, line: line)

        // Verify relative ordering within the full started sequence
        for (i, expectedID) in expectedNodeIDs.enumerated() {
            guard let pos = startedIDs.firstIndex(of: expectedID) else {
                XCTFail("Expected node \(expectedID) not found in started events", file: file, line: line)
                return
            }
            if i > 0, let prevPos = startedIDs.firstIndex(of: expectedNodeIDs[i - 1]) {
                XCTAssertLessThan(prevPos, pos,
                                  "Node \(expectedNodeIDs[i-1]) should execute before \(expectedID)",
                                  file: file, line: line)
            }
        }
    }

    /// Asserts that every started node has a corresponding completed or failed event.
    static func assertAllNodesTerminated(
        _ events: [AgentStreamEvent],
        expectedCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let started = Set(nodeStartedEvents(from: events).map(\.nodeID))
        let completed = Set(nodeCompletedEvents(from: events).map(\.nodeID))
        let failed = Set(nodeFailedEvents(from: events).map(\.nodeID))
        let terminated = completed.union(failed)

        for nodeID in started {
            XCTAssertTrue(terminated.contains(nodeID),
                          "Node \(nodeID) started but never completed or failed",
                          file: file, line: line)
        }

        let totalTerminated = nodeCompletedEvents(from: events).count + nodeFailedEvents(from: events).count
        XCTAssertEqual(totalTerminated, expectedCount,
                       "Expected \(expectedCount) terminated nodes, got \(totalTerminated)",
                       file: file, line: line)
    }
}
