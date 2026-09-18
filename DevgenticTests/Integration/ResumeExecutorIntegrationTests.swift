// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ResumeExecutorIntegrationTests.swift
//  DevgenticTests
//
//  G1 Piece 2 — end-to-end integration of the RESUME path, the in-process proxy for manual
//  force-quit → relaunch → Resume verification. Drives `ReActAgentExecutor.execute` with a real
//  `TimelineReconstruction` as `input.resumeState`, a scripted `MockLLMProvider` for the post-resume
//  steps, and CALL-TRACKING tools, then resolves the re-raised HITL in-process.
//
//  Covers the four behavioural guarantees:
//    1. Replay-not-rerun — a tool that completed before the crash is NOT executed again (headline).
//    2. The parked HITL genuinely re-raises and resolves (real CheckedContinuation).
//    3. The run continues and completes cleanly (not .failed).
//    4. Streaming resume drops the dangling tool (never re-run) and continues from completed work.
//
//  Out of scope (stays manual / UI): real OS process kill, SwiftUI chip/banner rendering, and real
//  native-model cache-prefix replay (the default MockCognitiveGenerator drives the legacy branch).
//

import XCTest
@testable import devgentic

/// Thread-safe record of which tool closures actually executed — the spine of the replay-not-rerun check.
private actor CallLog {
    private(set) var names: [String] = []
    func record(_ name: String) { names.append(name) }
    func count(_ name: String) -> Int { names.filter { $0 == name }.count }
}

final class ResumeExecutorIntegrationTests: XCTestCase {

    // MARK: - Helpers

    /// A tool whose run closure records its invocation, so the test can assert it ran 0 or 1 times.
    private func trackingTool(name: String, output: String, requiresConfirmation: Bool = false, log: CallLog) -> AgentTool {
        AgentTool(
            name: name,
            description: "test tool",
            parameters: SchemaBuilder.object(properties: [("input", "string", "in")], required: ["input"]),
            requiresConfirmation: requiresConfirmation,
            textOnlyRun: { _ in await log.record(name); return output }
        )
    }

    private func completedTool(_ name: String, step: Int, output: String) -> TimelineEvent {
        .toolExecution(ToolExecutionData(id: UUID(), name: name, params: "{}", output: output, isSuccess: true, isExecuting: false, stepId: step))
    }

    private func danglingTool(_ name: String, step: Int) -> TimelineEvent {
        // Valid `input` arg so the re-run passes the tool's schema validation (the production parked
        // tool always has the args the model supplied).
        .toolExecution(ToolExecutionData(id: UUID(), name: name, params: "{\"input\":\"config.txt\"}", output: nil, isSuccess: nil, isExecuting: true, stepId: step))
    }

    /// Consumes the resume stream, resolving any re-raised HITL INLINE (approve / answer) — mirroring the
    /// proven `WorkflowStreamCollector.collectWithGateChoice` pattern. The request event is buffered before
    /// the executor suspends, so the consumer receives it, waits 50 ms (continuation registers), resolves,
    /// and the executor resumes and yields the rest. (A detached resolve raced and is avoided.)
    private func driveResume(_ stream: AsyncThrowingStream<AgentStreamEvent, Error>) async throws -> [AgentStreamEvent] {
        var events: [AgentStreamEvent] = []
        for try await ev in stream {
            events.append(ev)
            switch ev {
            case .requestConfirmation(_, _, let opID, _, _):
                try await Task.sleep(for: .milliseconds(50))
                await ExecutionSuspensionService.shared.resume(for: opID, approved: true, resolvedBy: .localUI)
            case .requestClarification(_, let opID, _, _, _, _):
                try await Task.sleep(for: .milliseconds(50))
                await ExecutionSuspensionService.shared.resumeClarification(for: opID, userInput: "yes, proceed", resolvedBy: .localUI)
            default:
                break
            }
        }
        return events
    }

    private func didFail(_ events: [AgentStreamEvent]) -> Bool {
        events.contains { if case .executionFinished(.failed, _) = $0 { return true } else { return false } }
    }

    // MARK: - (a) Parked resume

    func testResume_Parked_CompletedToolNotReRun_HITLReRaisedAndResolved() async throws {
        let log = CallLog()
        let readTool = trackingTool(name: "read_file", output: "PORT=8080", log: log)
        let writeTool = trackingTool(name: "write_file", output: "applied", requiresConfirmation: true, log: log)

        // Interrupted timeline: read_file COMPLETED, write_file was the parked (dangling) confirmation tool.
        let timeline: [TimelineEvent] = [
            .reasoning(id: UUID(), text: "read the config, then write"),
            completedTool("read_file", step: 1, output: "PORT=8080"),
            danglingTool("write_file", step: 2)
        ]
        let recon = TimelineTurnReconstructor.reconstruct(from: timeline, parkedOperationID: UUID())
        XCTAssertEqual(recon.completedSteps.count, 1)
        XCTAssertEqual(recon.parkedTool?.name, "write_file")

        // Post-resume: after the parked write_file is approved + run, the model finishes.
        let provider = MockLLMProvider(steps: [ModernCognitiveStep(reasoning: "Wrote the config. All done.")])
        var input = TestAgentInputFactory.make(query: "Update the config", tools: [readTool, writeTool])
        input.resumeState = recon

        let stream = ReActAgentExecutor(maxIterations: 5).execute(model: provider, input: input) { _ in }
        let events = try await driveResume(stream)

        // 1. HEADLINE — replay-not-rerun: the already-completed tool must NOT run again.
        let readCalls = await log.count("read_file")
        XCTAssertEqual(readCalls, 0, "A tool that completed before the crash must be replayed, never re-executed.")

        // 2. The parked HITL re-raised, and the parked tool ran exactly once (after approval).
        let reRaised = events.contains { if case .requestConfirmation = $0 { return true } else { return false } }
        XCTAssertTrue(reRaised, "The parked tool's HITL must re-raise on resume.")
        let writeCalls = await log.count("write_file")
        XCTAssertEqual(writeCalls, 1, "The parked tool runs exactly once after approval — no duplicate side-effect.")

        // 3. The run continues and completes cleanly.
        XCTAssertFalse(StreamCollector.contentText(from: events).isEmpty, "Resume should produce a final response.")
        XCTAssertFalse(didFail(events), "Resumed run must not end in .failed.")
    }

    // MARK: - (b) Streaming resume

    func testResume_Streaming_CompletedReplayed_DanglingDropped() async throws {
        let log = CallLog()
        let readTool = trackingTool(name: "read_file", output: "data", log: log)
        let writeTool = trackingTool(name: "write_file", output: "applied", requiresConfirmation: true, log: log)

        // Died mid-execution: read_file completed; write_file was the dangling mid-execution tool.
        let timeline: [TimelineEvent] = [
            completedTool("read_file", step: 1, output: "data"),
            danglingTool("write_file", step: 2)
        ]
        // Streaming resume DROPS the dangling tool.
        let recon = TimelineTurnReconstructor.reconstruct(from: timeline, parkedOperationID: nil, dropDanglingTool: true)
        XCTAssertEqual(recon.completedSteps.count, 1)
        XCTAssertNil(recon.parkedTool, "Streaming resume drops the dangling tool.")

        let provider = MockLLMProvider(steps: [ModernCognitiveStep(reasoning: "Continuing from where I left off — done.")])
        var input = TestAgentInputFactory.make(query: "Update the config", tools: [readTool, writeTool])
        input.resumeState = recon

        let stream = ReActAgentExecutor(maxIterations: 5).execute(model: provider, input: input) { _ in }
        let events = try await driveResume(stream)

        // Completed tool replayed, never re-run; dangling tool dropped, never run.
        let readCalls = await log.count("read_file")
        let writeCalls = await log.count("write_file")
        XCTAssertEqual(readCalls, 0, "Completed tool is replayed, not re-executed.")
        XCTAssertEqual(writeCalls, 0, "Dangling mid-execution tool is dropped, not re-run.")
        // No HITL re-raises (nothing to re-raise — the dangling tool was dropped).
        let reRaised = events.contains { if case .requestConfirmation = $0 { return true } else { return false } }
        XCTAssertFalse(reRaised, "Streaming resume re-raises no HITL.")
        // Continues + completes.
        XCTAssertFalse(StreamCollector.contentText(from: events).isEmpty, "Streaming resume should continue to a response.")
        XCTAssertFalse(didFail(events), "Resumed run must not end in .failed.")
    }

    // MARK: - (d) Persist → reload → resume (closest in-process proxy for force-quit + relaunch)

    func testResume_PersistReloadResume_RoundTrip() async throws {
        let log = CallLog()
        let readTool = trackingTool(name: "read_file", output: "PORT=8080", log: log)
        let writeTool = trackingTool(name: "write_file", output: "applied", requiresConfirmation: true, log: log)

        // Build the interrupted agent message exactly as it would have been persisted at the park.
        let original = ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText("…"), backendEntityId: UUID())
        original.lifecycleState = .parkedHITL(operationID: UUID())
        original.timelineEvents = [
            completedTool("read_file", step: 1, output: "PORT=8080"),
            danglingTool("write_file", step: 2)
        ]

        // Simulate restart: round-trip through the SwiftData entity mapping, then resume from the RELOADED
        // state — proving the persisted timeline + lifecycle are sufficient to drive a clean resume.
        let reloaded = ChatMessageSD.from(original).toChatMessage()
        guard case .parkedHITL(let opID) = reloaded.lifecycleState else {
            return XCTFail("Reloaded message must still be parked.")
        }
        let recon = TimelineTurnReconstructor.reconstruct(from: reloaded.timelineEvents, parkedOperationID: opID)
        XCTAssertEqual(recon.parkedTool?.name, "write_file")
        XCTAssertEqual(recon.completedSteps.first?.toolCalls.first?.name, "read_file")

        let provider = MockLLMProvider(steps: [ModernCognitiveStep(reasoning: "Resumed and finished.")])
        var input = TestAgentInputFactory.make(query: "Update the config", tools: [readTool, writeTool])
        input.resumeState = recon

        let stream = ReActAgentExecutor(maxIterations: 5).execute(model: provider, input: input) { _ in }
        let events = try await driveResume(stream)

        let readCalls = await log.count("read_file")
        let writeCalls = await log.count("write_file")
        XCTAssertEqual(readCalls, 0, "Replay-not-rerun survives the persist/reload round-trip.")
        XCTAssertEqual(writeCalls, 1, "Parked tool runs once after the reloaded resume.")
        XCTAssertFalse(StreamCollector.contentText(from: events).isEmpty)
        XCTAssertFalse(didFail(events))
    }
}
