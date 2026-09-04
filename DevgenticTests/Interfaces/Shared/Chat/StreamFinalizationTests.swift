//
//  StreamFinalizationTests.swift
//  DevgenticTests
//
//  Perf/correctness batch (chat hardening round 3, 2026-07-19). Pins the pure
//  finalize-time decisions extracted onto ChatMessage:
//
//  ASM-2 `resolveThrownFinalContent` — a throw after streaming used to REPLACE the
//         prose the user watched with the error card (bubble + persistence + RAG all
//         lost the partial answer).
//  ASM-4 `resolveFallbackOutcome` — a producer that yielded `.error` and ended
//         without `.executionFinished` (and without throwing) was stamped
//         `.completed`: green chip + `completed` trace over an error card.
//  TL-1  `closeDanglingToolRows` — cancel/failure mid-tool persisted rows with
//         `isExecuting == true`, so the spinner survived reload forever.
//  P4/TL-4 `timelineRevision` — the change marker that lets the persistence flush
//         skip re-encoding an unchanged timeline and lets AgentTimelineView skip
//         regrouping; bumped by `didSet` so EVERY mutation path counts.
//

import XCTest
@testable import devgentic

// MARK: - ASM-2

final class ThrownFinalContentTests: XCTestCase {

    private let errorCard = MessageContent.error(
        title: "Response Error",
        details: "Connection reset by peer",
        category: .providerStreamError,
        suggestion: "Check the endpoint and retry."
    )

    func testPartialProseIsPreservedAndErrorDemoted() {
        let resolved = ChatMessage.resolveThrownFinalContent(
            streamed: .markdownText("Here is the first half of the answer"),
            errorCard: errorCard
        )

        XCTAssertEqual(resolved.content, .markdownText("Here is the first half of the answer"),
                       "Prose the user watched stream must survive the throw (ASM-2)")
        guard case .warning(_, let category, let text)? = resolved.demotedError else {
            XCTFail("The error must demote to a timeline warning, not vanish"); return
        }
        XCTAssertEqual(category, .midRunError)
        XCTAssertTrue(text.contains("Connection reset"))
        XCTAssertTrue(text.contains("Check the endpoint"), "Suggestion affordance survives the demotion")
    }

    func testNoProseKeepsErrorCard() {
        let resolved = ChatMessage.resolveThrownFinalContent(streamed: .markdownText("   \n"), errorCard: errorCard)

        XCTAssertEqual(resolved.content, errorCard, "Whitespace-only prose is not an answer — card replaces (control)")
        XCTAssertNil(resolved.demotedError)
    }

    func testNilStreamedKeepsErrorCard() {
        let resolved = ChatMessage.resolveThrownFinalContent(streamed: nil, errorCard: errorCard)
        XCTAssertEqual(resolved.content, errorCard)
        XCTAssertNil(resolved.demotedError)
    }

    func testStreamedErrorCardIsNotTreatedAsProse() {
        // `.error`'s textContent is non-empty ("Title: details") — a naive text check
        // would "preserve" the OLD error card and demote the new one.
        let older = MessageContent.error(title: "Earlier", details: "first failure")

        let resolved = ChatMessage.resolveThrownFinalContent(streamed: older, errorCard: errorCard)

        XCTAssertEqual(resolved.content, errorCard, "A streamed error card is not prose; the terminal card wins")
        XCTAssertNil(resolved.demotedError)
    }

    func testMediaContentKeepsErrorCard() {
        let media = MessageContent.mediaArtifact(MediaArtifact(kind: .image, reference: .ephemeralData(Data([0x1])), mimeType: "image/png", label: nil))
        let resolved = ChatMessage.resolveThrownFinalContent(streamed: media, errorCard: errorCard)
        XCTAssertEqual(resolved.content, errorCard)
        XCTAssertNil(resolved.demotedError)
    }
}

// MARK: - ASM-4

final class FallbackOutcomeTests: XCTestCase {

    private struct FakeError: LocalizedError {
        var errorDescription: String? { "boom" }
    }

    func testThrownErrorIsFailed() {
        let fallback = ChatMessage.resolveFallbackOutcome(threwError: FakeError(), content: .markdownText("partial"))
        XCTAssertEqual(fallback.outcome, .failed)
        XCTAssertEqual(fallback.reason, "boom")
    }

    func testErrorCardContentWithoutThrowIsFailed() {
        // The ASM-4 case: producer yielded `.error`, then finished without throwing —
        // the old fallback stamped `.completed` over the error card.
        let fallback = ChatMessage.resolveFallbackOutcome(
            threwError: nil,
            content: .error(title: "Execution Failed", details: "node crashed")
        )
        XCTAssertEqual(fallback.outcome, .failed,
                       "An error card is not a completed run — green chip + completed trace over it was the defect")
        XCTAssertEqual(fallback.reason, "Execution Failed: node crashed")
    }

    func testCleanTextContentIsCompleted() {
        let fallback = ChatMessage.resolveFallbackOutcome(threwError: nil, content: .markdownText("done"))
        XCTAssertEqual(fallback.outcome, .completed, "Control: clean runs must keep stamping .completed")
        XCTAssertNil(fallback.reason)
    }
}

// MARK: - TL-1

final class DanglingToolRowTests: XCTestCase {

    private func makeMessage() -> ChatMessage {
        ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText(""))
    }

    private func executingRow(name: String = "fs_read") -> TimelineEvent {
        .toolExecution(ToolExecutionData(id: UUID(), name: name, params: "{}", output: nil, isSuccess: nil, isExecuting: true))
    }

    func testCancelClosesExecutingRowWithCancelledCategory() {
        let message = makeMessage()
        message.timelineEvents = [executingRow()]

        let closed = message.closeDanglingToolRows(outcome: .cancelled)

        XCTAssertEqual(closed, 1)
        guard case .toolExecution(let data) = message.timelineEvents[0] else { XCTFail(); return }
        XCTAssertFalse(data.isExecuting, "A persisted row must never claim to still be executing (TL-1)")
        // [CF-51] `isSuccess` stays nil on a CANCELLED close — a user Stop is not a tool
        // failure, so the row must not read as one. `failureCategory` still carries the cause.
        XCTAssertNil(data.isSuccess)
        XCTAssertEqual(data.failureCategory, .cancelled)
        XCTAssertEqual(data.output, "Cancelled before the tool finished.")
    }

    func testFailureClosesRowWithoutCancelledCategory() {
        let message = makeMessage()
        message.timelineEvents = [executingRow()]

        _ = message.closeDanglingToolRows(outcome: .failed)

        guard case .toolExecution(let data) = message.timelineEvents[0] else { XCTFail(); return }
        XCTAssertFalse(data.isExecuting)
        XCTAssertNil(data.failureCategory, "Failure of the RUN doesn't mean the tool was cancelled")
        XCTAssertEqual(data.output, "Interrupted before the tool finished.")
    }

    func testCompletedRowIsUntouched() {
        let message = makeMessage()
        let done = ToolExecutionData(id: UUID(), name: "fs_read", params: "{}", output: "42 lines", isSuccess: true, isExecuting: false)
        message.timelineEvents = [.toolExecution(done)]

        let closed = message.closeDanglingToolRows(outcome: .cancelled)

        XCTAssertEqual(closed, 0, "Control: finished rows must not be rewritten")
        guard case .toolExecution(let data) = message.timelineEvents[0] else { XCTFail(); return }
        XCTAssertEqual(data.output, "42 lines")
        XCTAssertEqual(data.isSuccess, true)
    }

    func testExistingPartialOutputIsPreserved() {
        let message = makeMessage()
        let partial = ToolExecutionData(id: UUID(), name: "shell", params: "{}", output: "partial stdout…", isSuccess: nil, isExecuting: true)
        message.timelineEvents = [.toolExecution(partial)]

        _ = message.closeDanglingToolRows(outcome: .cancelled)

        guard case .toolExecution(let data) = message.timelineEvents[0] else { XCTFail(); return }
        XCTAssertEqual(data.output, "partial stdout…", "Real partial output beats the synthetic marker")
        XCTAssertFalse(data.isExecuting)
    }
}

// MARK: - P4 / TL-4

final class TimelineRevisionTests: XCTestCase {

    private func makeMessage() -> ChatMessage {
        ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText(""))
    }

    func testAppendBumpsRevision() {
        let message = makeMessage()
        let before = message.timelineRevision
        message.appendTimelineEvent(.thought(id: UUID(), text: "hm"))
        XCTAssertNotEqual(message.timelineRevision, before)
    }

    func testInPlaceSubscriptMutationBumpsRevision() {
        // The critical path: CapabilityCardRouter mutates events via subscript, NOT
        // through appendTimelineEvent — the didSet must catch it or the persistence
        // skip would silently drop card updates.
        let message = makeMessage()
        message.timelineEvents = [.thought(id: UUID(), text: "a")]
        let before = message.timelineRevision
        message.timelineEvents[0] = .thought(id: UUID(), text: "b")
        XCTAssertNotEqual(message.timelineRevision, before)
    }

    func testRemoveAllBumpsRevision() {
        let message = makeMessage()
        message.timelineEvents = [.thought(id: UUID(), text: "a")]
        let before = message.timelineRevision
        message.timelineEvents.removeAll()
        XCTAssertNotEqual(message.timelineRevision, before)
    }

    func testTwoInstancesNeverAliasRevisions() {
        // Random per-instance seed: a reloaded/regenerated instance of the same
        // persisted message must not collide with the store's cached revision from
        // the previous instance — an aliased skip would drop a timeline write.
        XCTAssertNotEqual(makeMessage().timelineRevision, makeMessage().timelineRevision)
    }
}

// MARK: - TL-2 / P3

@MainActor
final class TimelineEvictionTests: XCTestCase {

    private func thought(_ text: String) -> TimelineEvent { .thought(id: UUID(), text: text) }

    func testOverflowEvictsOldestNarrativeFirst() {
        var events: [TimelineEvent] = (0...ChatMessage.maxTimelineEvents).map { thought("t\($0)") }

        ChatMessage.evictOverflow(&events, context: "test")

        XCTAssertEqual(events.count, ChatMessage.maxTimelineEvents)
        if case .thought(_, let text) = events.first {
            XCTAssertEqual(text, "t1", "Oldest narrative goes first")
        } else { XCTFail() }
    }

    func testCapabilityCardIsNeverEvicted() {
        let card = TimelineEvent.planExecution(PlanRunData(id: UUID(), phase: .executing, steps: []))
        var events: [TimelineEvent] = [card]
        events.append(contentsOf: (0..<ChatMessage.maxTimelineEvents).map { _ in
            TimelineEvent.toolExecution(ToolExecutionData(id: UUID(), name: "t", params: "{}", output: "ok", isSuccess: true, isExecuting: false))
        })

        ChatMessage.evictOverflow(&events, context: "test")

        XCTAssertEqual(events.count, ChatMessage.maxTimelineEvents)
        XCTAssertTrue(events.contains { $0.isCapabilityCard }, "The card holds the run's shape — never evicted")
        if case .planExecution = events.first {} else {
            XCTFail("With no narrative present, the oldest NON-CARD event is evicted — the leading card survives")
        }
    }

    func testUnderCapIsNoOp() {
        var events: [TimelineEvent] = [thought("only")]
        ChatMessage.evictOverflow(&events, context: "test")
        XCTAssertEqual(events.count, 1)
    }

    /// The actual TL-2/P3 defect, through the REAL router: events routed into a plan
    /// step's nested sub-timeline used to bypass the cap entirely.
    func testNestedStepTimelineIsCappedThroughRouter() {
        let message = ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText(""))
        let router = CapabilityCardRouter(message: message)
        router.handlePlanGenerated([SubTask(id: "s1", description: "step one")])
        router.handleSubtaskStarted(id: "s1", description: "step one")

        for i in 0..<(ChatMessage.maxTimelineEvents + 100) {
            XCTAssertTrue(router.route(.thought(id: UUID(), text: "n\(i)")), "A step is active — routing must succeed")
        }

        guard case .planExecution(let plan)? = message.timelineEvents.first(where: { $0.isCapabilityCard }),
              let step = plan.steps.first(where: { $0.id == "s1" }) else {
            XCTFail("Plan card with step s1 must exist"); return
        }
        XCTAssertEqual(step.events.count, ChatMessage.maxTimelineEvents,
                       "Nested step timelines share the top-level cap — they used to grow without bound (TL-2/P3)")
        if case .thought(_, let text) = step.events.last {
            XCTAssertEqual(text, "n\(ChatMessage.maxTimelineEvents + 99)", "Newest events survive; oldest evicted")
        } else { XCTFail() }
    }
}

// MARK: - Regeneration variant (P0 crash fix, 2026-07-19)

final class RegenerationVariantTests: XCTestCase {

    private func makeMessage(attempts: Int = 1) -> ChatMessage {
        let message = ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText("answer"))
        message.agentResponse = AgentResponse(
            variants: [ResponseMessageVariant(content: .markdownText("answer"), backendEntityId: nil)],
            selectedVariantIndex: 0,
            generationAttempts: attempts
        )
        return message
    }

    func testBeginRegenerationAppendsSelectsAndIncrements() {
        let message = makeMessage()
        let backendID = UUID()

        XCTAssertTrue(message.beginRegenerationVariant(backendEntityId: backendID))

        XCTAssertEqual(message.agentResponse?.variants.count, 2)
        XCTAssertEqual(message.agentResponse?.selectedVariantIndex, 1, "The fresh variant is selected")
        XCTAssertEqual(message.agentResponse?.variants[1].content, .markdownText(""))
        XCTAssertEqual(message.agentResponse?.variants[1].backendEntityId, backendID)
        XCTAssertEqual(message.agentResponse?.generationAttempts, 2)
        XCTAssertTrue(message.isStreaming)
    }

    func testAttemptCapBlocksWithoutMutation() {
        let message = makeMessage(attempts: ChatMessage.maxGenerationAttempts)

        XCTAssertFalse(message.beginRegenerationVariant(backendEntityId: nil))

        XCTAssertEqual(message.agentResponse?.variants.count, 1, "Cap refusal must not half-mutate")
        XCTAssertEqual(message.agentResponse?.generationAttempts, ChatMessage.maxGenerationAttempts)
        XCTAssertFalse(message.isStreaming)
    }

    func testNoAgentResponseBlocks() {
        let message = ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText("x"))
        message.agentResponse = nil

        XCTAssertFalse(message.beginRegenerationVariant(backendEntityId: nil))
        XCTAssertFalse(message.isStreaming)
    }

    func testRepeatedRegenerationsWalkToTheCap() {
        let message = makeMessage(attempts: 1)
        var accepted = 0
        for _ in 0..<10 where message.beginRegenerationVariant(backendEntityId: nil) {
            accepted += 1
        }
        XCTAssertEqual(accepted, ChatMessage.maxGenerationAttempts - 1, "1 initial + 4 retries = cap of 5")
        XCTAssertEqual(message.agentResponse?.generationAttempts, ChatMessage.maxGenerationAttempts)
    }
}

// MARK: - Synthetic placeholder RAG gate (log finding #5, 2026-07-19)

final class PlaceholderIndexGateTests: XCTestCase {

    func testCurrentPlaceholderIsSynthetic() {
        XCTAssertTrue(ChatMessage.isSyntheticPlaceholder(ChatMessage.stoppedRunPlaceholder))
    }

    func testLegacyPlaceholderIsSynthetic() {
        XCTAssertTrue(ChatMessage.isSyntheticPlaceholder(ChatMessage.legacyStoppedRunPlaceholder))
    }

    func testWhitespacePaddingStillMatches() {
        XCTAssertTrue(ChatMessage.isSyntheticPlaceholder("  \n" + ChatMessage.stoppedRunPlaceholder + "\n"))
    }

    func testRealProseIsNotSynthetic() {
        XCTAssertFalse(ChatMessage.isSyntheticPlaceholder("Here is the summary you asked for."),
                       "Control: ordinary answers must keep indexing")
    }

    func testQuotedPlaceholderInsideLongerTextIsNotSynthetic() {
        // Exact-match, not contains: a message DISCUSSING the placeholder (e.g. this
        // very session's debugging) is real content.
        let quoting = "The bug showed \(ChatMessage.stoppedRunPlaceholder) in the bubble — here's why."
        XCTAssertFalse(ChatMessage.isSyntheticPlaceholder(quoting))
    }

    func testProducerAndDetectorAreStructurallyLinked() {
        // The gate must recognize exactly what resolveFinalizedContent emits for an
        // empty run — shared constant makes drift impossible, this pins the linkage.
        let emptyRun = ChatMessage.resolveFinalizedContent(streamed: nil, imageArtifact: nil)
        XCTAssertTrue(ChatMessage.isSyntheticPlaceholder(emptyRun.textContent ?? ""),
                      "The placeholder the finalizer writes is the placeholder the RAG gate skips")
    }
}
