// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  HonestParkResolutionTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class HonestParkResolutionTests: XCTestCase {

    private let conversationID = UUID()

    private func confirmingTool(name: String = "delete_everything") -> AgentTool {
        AgentTool(
            name: name,
            description: "A tool the user must confirm.",
            parameters: ToolParameters(type: "object", properties: [:], required: []),
            requiresConfirmation: true,
            run: { _ in ("SHOULD NEVER RUN", []) }
        )
    }

    /// Runs `executeToolCalls` and cancels its task ONLY ONCE THE BANNER IS UP — the production
    /// window, and the only one that reaches the guard.
    ///
    /// ⚠️ CANCELLING BEFORE THE CALL DOES NOT TEST THIS. `executeToolCalls` runs interactive tools
    /// through a `try Task.checkCancellation()` at the top of its sequential loop, so a task
    /// cancelled up-front never enters `executeSingleTool` and never parks. A first draft of these
    /// tests did exactly that: they passed, and a mutation deleting the guard passed too. Waiting
    /// for `.requestConfirmation` before cancelling is what makes the assertion mean anything.
    private func runCancelledWhileParked(
        toolNamed name: String
    ) async -> (error: Error?, events: [AgentStreamEvent], memory: RunInteractionMemory) {
        let tool = confirmingTool(name: name)
        let call = PendingToolCall(id: UUID().uuidString, name: name, arguments: [:])
        let memory = RunInteractionMemory()

        // The build closure runs SYNCHRONOUSLY during init, so `task` is populated by the time the
        // stream is returned.
        var task: Task<Void, Never>?
        let stream = AsyncThrowingStream<AgentStreamEvent, Error> { continuation in
            task = Task {
                do {
                    _ = try await executeToolCalls(
                        toolCalls: [call], availableTools: [tool],
                        conversationID: self.conversationID, currentIteration: 1,
                        iterationSpan: TestTraceContext.make(),
                        toolMediator: ToolExecutionMediator(), interactionMemory: memory,
                        continuation: continuation, approvalNodeID: nil, onTraceUpdate: { _ in }
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }

        var events: [AgentStreamEvent] = []
        var thrown: Error?
        do {
            for try await event in stream {
                events.append(event)
                // The banner is now up and the node is parked — this is where Stop lands.
                if case .requestConfirmation = event { task?.cancel() }
            }
        } catch {
            thrown = error
        }
        return (thrown, events, memory)
    }

    // MARK: - Permission

    /// The core assertion: a cancelled permission park throws, and emits NO denial.
    func testCancelledPermissionPark_ThrowsAndEmitsNoDenial() async {
        let (error, events, _) = await runCancelledWhileParked(toolNamed: "delete_everything")

        XCTAssertTrue(events.contains { if case .requestConfirmation = $0 { return true }; return false },
                      "the tool must actually have PARKED — otherwise this test proves nothing")
        XCTAssertTrue(error is CancellationError,
                      "a torn-down park must surface as cancellation, not as a completed tool step")

        let denials = events.filter { event in
            if case .toolFailed(_, let category, _, _) = event { return category == .userDenied }
            return false
        }
        XCTAssertTrue(denials.isEmpty,
                      "no `.userDenied` event may be emitted — the user never denied anything")
    }

    /// ⚠️ THE WORST HALF, because it OUTLIVES the run: a fabricated denial is written to
    /// `RunInteractionMemory`, and the auto-deny path then refuses an identical later call with no
    /// banner shown. The user would see a tool silently refuse itself, having never denied it once.
    func testCancelledPermissionPark_RecordsNoDenialInInteractionMemory() async {
        let (_, events, memory) = await runCancelledWhileParked(toolNamed: "delete_everything")

        XCTAssertTrue(events.contains { if case .requestConfirmation = $0 { return true }; return false },
                      "the tool must actually have PARKED — otherwise this test proves nothing")
        let remembered = await memory.isDenied(toolName: "delete_everything", params: serializeToolParams([:]))
        XCTAssertFalse(remembered,
                       "a cancelled park must leave NO denial behind — otherwise an identical later call auto-denies with no banner")
    }

    // MARK: - The control: a real denial must still work

    /// ⚠️ THE MUTATION-PROOF CONTROL. A guard that swallowed *every* denial would pass the tests
    /// above while destroying the feature. This drives the SAME path with a live user answering
    /// "Deny" on an uncancelled task, and requires the denial to be recorded exactly as before.
    func testRealDenialOnALiveTask_StillRecordsTheDenial() async throws {
        let tool = confirmingTool(name: "rm_rf")
        let call = PendingToolCall(id: UUID().uuidString, name: tool.name, arguments: [:])
        let memory = RunInteractionMemory()

        var events: [AgentStreamEvent] = []
        let stream = AsyncThrowingStream<AgentStreamEvent, Error> { continuation in
            Task {
                do {
                    _ = try await executeToolCalls(
                        toolCalls: [call], availableTools: [tool],
                        conversationID: self.conversationID, currentIteration: 1,
                        iterationSpan: TestTraceContext.make(),
                        toolMediator: ToolExecutionMediator(), interactionMemory: memory,
                        continuation: continuation, approvalNodeID: nil, onTraceUpdate: { _ in }
                    )
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }

        // Answer "Deny" as a user would, once the banner's operationID arrives.
        let denier = Task {
            for await opID in await Self.confirmationOperationIDs(from: stream, into: { events.append($0) }) {
                await ExecutionSuspensionService.shared.resume(for: opID, approved: false, resolvedBy: .localUI)
            }
        }
        _ = await denier.result

        let denials = events.filter { event in
            if case .toolFailed(_, let category, _, _) = event { return category == .userDenied }
            return false
        }
        XCTAssertEqual(denials.count, 1, "a REAL denial must still be reported — the guard must not swallow it")
        let remembered = await memory.isDenied(toolName: tool.name, params: serializeToolParams([:]))
        XCTAssertTrue(remembered, "a real denial must still be remembered for the auto-deny path")
    }

    /// Bridges the event stream into the operationIDs of confirmation requests, forwarding every
    /// event to `sink` so the caller can assert on them afterwards.
    private static func confirmationOperationIDs(
        from stream: AsyncThrowingStream<AgentStreamEvent, Error>,
        into sink: @escaping (AgentStreamEvent) -> Void
    ) async -> AsyncStream<UUID> {
        AsyncStream { continuation in
            Task {
                do {
                    for try await event in stream {
                        sink(event)
                        if case .requestConfirmation(_, _, let operationID, _, _) = event {
                            continuation.yield(operationID)
                        }
                    }
                } catch { /* cancellation ends the bridge */ }
                continuation.finish()
            }
        }
    }
}
