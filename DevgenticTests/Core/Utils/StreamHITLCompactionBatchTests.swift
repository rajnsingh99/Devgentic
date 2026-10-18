// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  StreamHITLCompactionBatchTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
private final class NoopChatStore: ChatPersistenceProtocol {
    func addConversation(from conversation: Conversation) {}
    func addMessage(_ message: ChatMessage, toConversation conversationId: UUID) async {}
    func addMessages(_ messages: [ChatMessage], toConversation conversationId: UUID) async {}
    func getConversation(withId id: UUID) -> ConversationSD? { nil }
    func fetchMessages(for conversationId: UUID, offset: Int, limit: Int) async -> [ChatMessage] { [] }
    func deleteConversation(with id: UUID) {}
    func updateBackendForConversation(id: UUID, backendEntityId: UUID?) {}
    func updateProfileType(for conversationId: UUID, profileTypeRaw: String) {}
    func togglePinStatus(for conversationId: UUID) {}
}

@MainActor
final class StreamHITLCompactionBatchTests: XCTestCase {

    // MARK: - CR-41: a result lands on its own row

    private func executingRow(_ name: String, params: String) -> TimelineEvent {
        .toolExecution(ToolExecutionData(id: UUID(), name: name, params: params, output: nil, isSuccess: nil, isExecuting: true))
    }

    private func row(_ event: TimelineEvent) -> ToolExecutionData? {
        if case .toolExecution(let data) = event { return data }
        return nil
    }

    private func agentMessage(_ events: [TimelineEvent]) -> ChatMessage {
        let message = ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText(""))
        for event in events { message.appendTimelineEvent(event) }
        return message
    }

    /// THE CALL SITE (top-level timeline): two parallel `read_file`s finish in REVERSE order.
    /// Mutation that must turn this red: match on the name alone (`lastIndex` by name) again.
    func testParallelSameNameCallsCompleteTheirOwnRows() {
        let message = agentMessage([executingRow("read_file", params: #"{"path":"/p/A"}"#),
                                    executingRow("read_file", params: #"{"path":"/p/B"}"#)])
        // A finishes FIRST — the last executing row by name is B's.
        ActiveStreamManager.completeToolTimelineEvent(
            output: ToolOutput(toolName: "read_file", params: #"{"path":"/p/A"}"#, output: "contents of A", isSuccess: true),
            failureCategory: nil, durationMs: 1, sourceNodeID: nil, agentMessage: message, workflowExecutionState: nil)
        ActiveStreamManager.completeToolTimelineEvent(
            output: ToolOutput(toolName: "read_file", params: #"{"path":"/p/B"}"#, output: "contents of B", isSuccess: true),
            failureCategory: nil, durationMs: 1, sourceNodeID: nil, agentMessage: message, workflowExecutionState: nil)

        let rows = message.timelineEvents.compactMap(row)
        XCTAssertEqual(rows.map(\.output), ["contents of A", "contents of B"], "results were crossed between rows")
        XCTAssertTrue(rows.allSatisfy { !$0.isExecuting }, "a row was left executing")
    }

    /// A call refused before it started has no row. Its result must not complete the OTHER
    /// same-name row that is still running.
    func testAResultWithNoRowDoesNotCompleteAnotherCall() {
        let message = agentMessage([executingRow("read_file", params: #"{"path":"/p/B"}"#)])
        ActiveStreamManager.completeToolTimelineEvent(
            output: ToolOutput(toolName: "read_file", params: #"{"path":"/outside"}"#, output: "declined", isSuccess: false),
            failureCategory: .userDenied, durationMs: nil, sourceNodeID: nil, agentMessage: message, workflowExecutionState: nil)
        XCTAssertEqual(message.timelineEvents.compactMap(row).first?.isExecuting, true, "B's row was completed with another call's denial")
    }

    /// A banner edit changes the params between the row and the result; `rowParams` joins them,
    /// and the row then shows what actually ran.
    func testAnEditedCallCompletesItsRowAndShowsTheEditedParams() {
        let message = agentMessage([executingRow("write_file", params: #"{"path":"/p/a"}"#),
                                    executingRow("write_file", params: #"{"path":"/p/b"}"#)])
        ActiveStreamManager.completeToolTimelineEvent(
            output: ToolOutput(toolName: "write_file", params: #"{"path":"/p/edited"}"#, output: "ok", isSuccess: true,
                               rowParams: #"{"path":"/p/a"}"#),
            failureCategory: nil, durationMs: 1, sourceNodeID: nil, agentMessage: message, workflowExecutionState: nil)
        let rows = message.timelineEvents.compactMap(row)
        XCTAssertEqual(rows[0].params, #"{"path":"/p/edited"}"#)
        XCTAssertFalse(rows[0].isExecuting)
        XCTAssertTrue(rows[1].isExecuting, "the other write's row must be untouched")
    }

    /// THE CALL SITE (card-nested rows, i.e. most Plan & Execute / Reflexion runs).
    /// Mutation that must turn this red: match the card-nested row on the name alone.
    func testCardNestedParallelCallsCompleteTheirOwnRows() throws {
        let message = ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText(""))
        let router = CapabilityCardRouter(message: message)
        router.handlePlanGenerated([SubTask(id: "step_1", description: "Read both")])
        router.handleSubtaskStarted(id: "step_1", description: "Read both")
        XCTAssertTrue(router.route(executingRow("read_file", params: "A")))
        XCTAssertTrue(router.route(executingRow("read_file", params: "B")))

        XCTAssertTrue(router.completeTool(output: ToolOutput(toolName: "read_file", params: "A", output: "a", isSuccess: true),
                                          failureCategory: nil, durationMs: nil))
        XCTAssertTrue(router.completeTool(output: ToolOutput(toolName: "read_file", params: "B", output: "b", isSuccess: true),
                                          failureCategory: nil, durationMs: nil))

        let card = try XCTUnwrap(message.timelineEvents.compactMap { event -> PlanRunData? in
            if case .planExecution(let data) = event { return data }
            return nil
        }.first)
        XCTAssertEqual(card.steps[0].events.compactMap(row).map(\.output), ["a", "b"])
    }

    // MARK: - CR-40: no banner for a request already answered

    private func resolvedOperation() async -> UUID {
        let operationID = UUID()
        let conversationID = UUID()
        let park = Task { await ExecutionSuspensionService.shared.suspend(for: operationID, conversationID: conversationID) }
        for _ in 0..<2_000 where !(await ExecutionSuspensionService.shared.hasPendingSuspensions()) { await Task.yield() }
        await ExecutionSuspensionService.shared.resume(for: operationID, approved: false, resolvedBy: .localUI)
        _ = await park.value
        return operationID
    }

    func testTheSuspensionServiceRemembersAResolution() async {
        let resolved = await resolvedOperation()
        let wasResolved = await ExecutionSuspensionService.shared.wasResolved(resolved)
        XCTAssertTrue(wasResolved)
        let unseen = await ExecutionSuspensionService.shared.wasResolved(UUID())
        XCTAssertFalse(unseen, "a request never resolved must never be treated as answered")
    }

    /// THE CALL SITE: a request resolved while its banner was being prepared gets no banner;
    /// a live one still does. Mutation that must turn this red: drop the `wasResolved` guard.
    func testABannerIsNotRaisedForAResolvedRequest() async {
        let store = NoopChatStore()
        let manager = ActiveStreamManager(persistenceService: store, fileProcessorService: FileProcessorService())
        let center = InteractionCenter()
        manager.interactionCenter = center
        let conversationID = UUID()

        let resolved = await resolvedOperation()
        await manager.enqueueHITL(
            operationID: resolved, kind: .clarification(PendingClarification(id: resolved, question: "?")),
            conversationID: conversationID, profileType: .agent, workflowState: nil, sourceNodeID: nil,
            profileID: nil, traceContext: TestTraceContext.make())
        XCTAssertTrue(center.items(for: conversationID).isEmpty, "a banner was raised for a request already answered")

        let live = UUID()
        await manager.enqueueHITL(
            operationID: live, kind: .clarification(PendingClarification(id: live, question: "?")),
            conversationID: conversationID, profileType: .agent, workflowState: nil, sourceNodeID: nil,
            profileID: nil, traceContext: TestTraceContext.make())
        XCTAssertEqual(center.items(for: conversationID).map(\.id), [live], "a live request must still be shown")
    }

    // MARK: - CR-39: the checkpoint boundary

    private let base = Date(timeIntervalSince1970: 1_000)

    private func msg(_ offset: TimeInterval, _ sender: SenderRole, _ text: String = "x") -> ChatMessage {
        ChatMessage(conversationId: UUID(), timestamp: base.addingTimeInterval(offset), sender: sender, content: .plainText(text))
    }

    func testABatchNeverEndsOnAQuestion() throws {
        let turns = [msg(0, .user), msg(1, .agent), msg(2, .user), msg(3, .agent), msg(4, .user), msg(5, .agent)]
        let aligned = try XCTUnwrap(HistoryCompactionService.alignBatchBoundary(Array(turns.prefix(5)), in: turns))
        XCTAssertEqual(aligned.batch.count, 4, "the trailing question must stay with its reply")
        XCTAssertEqual(aligned.batch.last?.sender, .agent)
    }

    /// The reply 0.2 ms after the batch's end used to fall inside last+1 ms and vanish.
    func testAMessageWithinAMillisecondIsKept() throws {
        let turns = [msg(0, .user), msg(1, .agent), msg(2, .user), msg(3, .agent), msg(3.0002, .user), msg(3.0004, .agent)]
        let aligned = try XCTUnwrap(HistoryCompactionService.alignBatchBoundary(Array(turns.prefix(4)), in: turns))
        let kept = turns.filter { $0.timestamp > aligned.checkpointTimestamp }
        XCTAssertEqual(kept.count, 2, "a message right after the batch was dropped from both summary and history")
        XCTAssertTrue(aligned.batch.allSatisfy { $0.timestamp < aligned.checkpointTimestamp })
    }

    /// Two messages with the SAME timestamp cannot be split by a timestamp: the boundary moves back.
    func testABoundaryIsNeverPlacedBetweenEqualTimestamps() throws {
        let turns = [msg(0, .user), msg(1, .agent), msg(2, .user), msg(3, .agent), msg(3, .user), msg(4, .agent)]
        let aligned = try XCTUnwrap(HistoryCompactionService.alignBatchBoundary(Array(turns.prefix(4)), in: turns))
        XCTAssertEqual(aligned.batch.count, 2)
        XCTAssertEqual(turns.filter { $0.timestamp > aligned.checkpointTimestamp }.count, 4)
    }

    /// THE CALL SITES: the planner uses the aligned boundary, and `execute` stamps the checkpoint
    /// with it. Mutations that must turn this red: plan with the raw fitted batch; stamp the
    /// checkpoint last+1 ms again.
    func testAPlannedCheckpointKeepsEveryUncompactedMessage() async throws {
        let body = String(repeating: "x", count: 600)
        // 10 pairs: each reply 0.2 ms after its question, each question 0.5 ms after the previous
        // reply — so "last compacted + 1 ms" swallowed the first kept message.
        var history: [ChatMessage] = []
        var t: TimeInterval = 0
        for _ in 0..<10 {
            history.append(msg(t, .user, body)); t += 0.0002
            history.append(msg(t, .agent, body)); t += 0.0005
        }
        let plan = try XCTUnwrap(HistoryCompactionService.planCompaction(
            chatHistory: history, charBudget: 1_000, icContextWindow: 4096,
            charBudgetTriggerRatio: 0.6, icPromptOverheadChars: 800))
        XCTAssertEqual(plan.turnsToCompact.last?.sender, .agent, "the batch ended on a question")

        let result = try await HistoryCompactionService.shared.execute(plan: plan, conversationID: UUID()) { _ in "summary" }
        let checkpoint = result.checkpointMessage.timestamp
        let compactedIDs = Set(plan.turnsToCompact.map(\.id))
        let kept = history.filter { $0.timestamp > checkpoint }
        XCTAssertEqual(kept.count + compactedIDs.count, history.count,
                       "a message is in neither the summary nor the history after the checkpoint")
        XCTAssertTrue(kept.allSatisfy { !compactedIDs.contains($0.id) })
    }

    // MARK: - CR-58: synthesis is bounded

    /// Source pin: the IC call runs inside `DeadlineRace`, and a timeout returns the deterministic
    /// answer. Mutation that must turn this red: call `generate` directly again.
    func testSynthesisIsBoundedByADeadline() throws {
        let source = try Self.read("Devgentic/Core/Backends/TextGen/ResponseSynthesizer.swift")
        XCTAssertNotNil(source.range(of: #"DeadlineRace\.run\(limit: Self\.synthesisDeadlineSeconds[\s\S]{0,400}?IntelligenceCoreService\.shared\.generate\("#,
                                     options: .regularExpression), "the IC synthesis call must run inside the deadline race")
        XCTAssertNotNil(source.range(of: #"case \.timedOut[\s\S]{0,600}?return buildDeterministicFallback\(summary: summary\)"#,
                                     options: .regularExpression), "a timed-out synthesis must fall back, not wait")
        XCTAssertEqual(source.components(separatedBy: "IntelligenceCoreService.shared.generate(").count - 1, 1,
                       "every IC generate call in the synthesizer must be the bounded one")
        XCTAssertGreaterThan(ResponseSynthesizer.synthesisDeadlineSeconds, 0)
    }

    private static func read(_ relativePath: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return try String(contentsOf: candidate, encoding: .utf8) }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("Could not locate \(relativePath)")
    }
}
