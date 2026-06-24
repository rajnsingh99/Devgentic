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
            if case .workflowNodeCompleted(let nodeID, let name, let summary) = event {
                return (nodeID, name, summary)
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

    // MARK: - Progress & Loop Events

    static func progressEvents(from events: [AgentStreamEvent]) -> [(completed: Int, total: Int)] {
        events.compactMap { event in
            if case .workflowProgress(let completed, let total) = event {
                return (completed, total)
            }
            return nil
        }
    }

    static func loopIterationEvents(from events: [AgentStreamEvent]) -> [(nodeID: UUID, iteration: Int, maxIterations: Int)] {
        events.compactMap { event in
            if case .workflowLoopIteration(let nodeID, _, let iter, let max) = event {
                return (nodeID, iter, max)
            }
            return nil
        }
    }

    // MARK: - HITL Events

    static func confirmationRequests(from events: [AgentStreamEvent]) -> [(toolName: String, params: String, operationID: UUID)] {
        events.compactMap { event -> (toolName: String, params: String, operationID: UUID)? in
            if case .requestConfirmation(let name, let params, let opID, _) = event {
                return (name, params, opID)
            }
            return nil
        }
    }

    /// [E1] Gate requests emitted by the workflow (per-option routing replaced the old binary gate).
    static func gateRequests(from events: [AgentStreamEvent]) -> [(prompt: String, options: [String], operationID: UUID)] {
        events.compactMap { event -> (prompt: String, options: [String], operationID: UUID)? in
            if case .requestGate(let prompt, let options, let opID, _, _) = event {
                return (prompt, options, opID)
            }
            return nil
        }
    }

    // MARK: - Gate Helper

    /// Consumes a workflow stream, auto-responding to the first gate by choosing `option`. Passing
    /// `nil` resolves the gate with no choice (simulating a timeout / cancel — the gate then fails).
    /// A brief delay lets the suspension register before responding.
    static func collectWithGateChoice(
        from stream: AsyncThrowingStream<AgentStreamEvent, Error>,
        choosing option: String?
    ) async throws -> [AgentStreamEvent] {
        var events: [AgentStreamEvent] = []
        for try await event in stream {
            events.append(event)
            if case .requestGate(_, _, let operationID, _, _) = event {
                try await Task.sleep(for: .milliseconds(50))
                await ExecutionSuspensionService.shared.resumeGate(for: operationID, chosenOption: option)
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
        let orderedIDs = expectedNodeIDs.filter { startedIDs.contains($0) }
        XCTAssertEqual(orderedIDs, expectedNodeIDs.filter { startedIDs.contains($0) },
                       "Node execution order mismatch", file: file, line: line)

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
