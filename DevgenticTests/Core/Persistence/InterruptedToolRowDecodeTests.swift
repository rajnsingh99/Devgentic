// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  InterruptedToolRowDecodeTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class InterruptedToolRowDecodeTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: ConversationSD.self, ChatMessageSD.self,
            AttachedTextFileSD.self, AttachedImageFileSD.self,
            configurations: config
        )
        context = container.mainContext
    }

    override func tearDown() async throws {
        container = nil
        context = nil
    }

    // MARK: - Fixtures

    private func executingRow() -> TimelineEvent {
        .toolExecution(ToolExecutionData(id: UUID(), name: "fs_read", params: "{\"path\":\"/tmp/A.swift\"}",
                                         output: nil, isSuccess: nil, isExecuting: true))
    }

    /// Persists a message carrying one still-executing tool row under `lifecycle`, then decodes
    /// it back the way `loadConversation` does.
    private func roundTrip(lifecycle: MessageLifecycleState) -> ChatMessage {
        let message = ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText("partial"))
        message.timelineEvents = [executingRow()]
        message.lifecycleState = lifecycle

        let sd = ChatMessageSD.from(message)
        context.insert(sd)
        try? context.save()
        return sd.toChatMessage()
    }

    private func isExecuting(_ message: ChatMessage) -> Bool {
        guard case .toolExecution(let data) = message.timelineEvents.first else { return false }
        return data.isExecuting
    }

    private func output(_ message: ChatMessage) -> String? {
        guard case .toolExecution(let data) = message.timelineEvents.first else { return nil }
        return data.output
    }

    // MARK: - The fix

    /// The defect: force-quit mid-tool, relaunch, reopen the conversation, and the row spins
    /// forever. Reverting the decode-time repair leaves `isExecuting == true` here.
    func testStreamingMessageDecodesWithItsSpinnerStopped() {
        let decoded = roundTrip(lifecycle: .streaming)

        XCTAssertFalse(isExecuting(decoded),
                       "A message persisted mid-stream must not decode with a row still claiming to execute.")
    }

    /// ⚠️ THE SECOND REGRESSION GUARD, and the subtler one. The repair must NOT fabricate an
    /// observation: `isExecuting || output == nil` is how the resume engine recognises the tool a
    /// run died inside. Writing a synthetic output here would make the row look completed, so a
    /// streaming resume would stop dropping it and would replay it to the model as a finished step.
    /// If someone "improves" this by adding explanatory text, this test fails and says why.
    func testTheRepairDoesNotFabricateAnOutcome() {
        let decoded = roundTrip(lifecycle: .streaming)

        XCTAssertNil(output(decoded),
                     "The tool was never observed — an output here would look like a completed step to TimelineTurnReconstructor.")
        guard case .toolExecution(let data) = decoded.timelineEvents.first else {
            return XCTFail("Expected a tool row")
        }
        XCTAssertNil(data.isSuccess,
                     "The tool's fate is unknown; claiming success or failure would also mis-count it in the timeline header's failed total.")
    }

    /// The end-to-end statement of the above, through the engine that actually cares: a streaming
    /// resume must still DROP the interrupted tool rather than feed it back as history.
    func testStreamingResumeStillDropsTheInterruptedTool() {
        let decoded = roundTrip(lifecycle: .streaming)

        let reconstruction = TimelineTurnReconstructor.reconstruct(
            from: decoded.flattenedTimelineEvents,
            parkedOperationID: nil,
            dropDanglingTool: true
        )

        XCTAssertNil(reconstruction.parkedTool, "A streaming resume drops the dangling tool by design.")
        let replayed = reconstruction.completedSteps.flatMap { $0.toolCalls.map(\.name) }
        XCTAssertFalse(replayed.contains("fs_read"),
                       "The interrupted tool must not be replayed to the model as a completed step: \(replayed)")
    }

    /// The parked twin of the same statement: the row is still there to re-raise.
    func testParkedResumeStillFindsTheParkedTool() {
        let decoded = roundTrip(lifecycle: .parkedHITL(operationID: UUID()))

        let reconstruction = TimelineTurnReconstructor.reconstruct(
            from: decoded.flattenedTimelineEvents,
            parkedOperationID: nil,
            dropDanglingTool: false
        )

        XCTAssertEqual(reconstruction.parkedTool?.name, "fs_read",
                       "resumeRun refuses the resume when parkedTool is nil — that is what this guards.")
    }

    // MARK: - Controls

    /// ⚠️ THE REGRESSION GUARD. A parked run's dangling row is what `resumeRun` re-raises. If a
    /// future edit widens the decode repair to `lifecycleState.isInterrupted` (which includes
    /// `.parkedHITL`), this fails — and the failure is the point: that change would silently make
    /// every parked run unresumable.
    func testParkedMessageKeepsItsDanglingRowForResume() {
        let decoded = roundTrip(lifecycle: .parkedHITL(operationID: UUID()))

        XCTAssertTrue(isExecuting(decoded),
                      "A parked run's dangling tool row is load-bearing: TimelineTurnReconstructor finds the parked tool by `isExecuting || output == nil`, and resumeRun refuses the resume when it is nil.")
        XCTAssertNil(output(decoded))
    }

    /// A cleanly finished message is untouched — the repair must not rewrite settled history.
    func testFinalMessageIsUntouched() {
        let message = ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText("done"))
        let completed = ToolExecutionData(id: UUID(), name: "fs_read", params: "{}",
                                          output: "42 lines", isSuccess: true, isExecuting: false)
        message.timelineEvents = [.toolExecution(completed)]
        message.lifecycleState = .final

        let sd = ChatMessageSD.from(message)
        context.insert(sd)
        try? context.save()
        let decoded = sd.toChatMessage()

        XCTAssertFalse(isExecuting(decoded))
        XCTAssertEqual(output(decoded), "42 lines", "A completed row's own output must survive verbatim.")
    }

    /// A `.streaming` message with nothing dangling must decode unchanged — the repair is a
    /// no-op except where a row is actually stranded.
    func testStreamingMessageWithNoDanglingRowIsUnchanged() {
        let message = ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText("partial"))
        let completed = ToolExecutionData(id: UUID(), name: "fs_read", params: "{}",
                                          output: "42 lines", isSuccess: true, isExecuting: false)
        message.timelineEvents = [.toolExecution(completed)]
        message.lifecycleState = .streaming

        let sd = ChatMessageSD.from(message)
        context.insert(sd)
        try? context.save()
        let decoded = sd.toChatMessage()

        XCTAssertEqual(output(decoded), "42 lines")
    }
}
