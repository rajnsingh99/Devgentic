//
//  WorkflowRunBootstrapTests.swift
//  DevgenticTests
//
//  Regression cover for Workflow_Production_Readiness.md row WF20.
//
//  The workflow-run bookkeeping (live state + `.running` stub + freeze/persist) lived inline in
//  ONE of seven `startMessageStream` call sites. Scheduled runs, ChatOps, regenerate, QuickAccess
//  and Jarvis started workflows with `workflowExecutionState == nil` — the run executed, but left
//  no record at all, its HITL attributed to chat, and it rendered through the capability-card
//  router that is deliberately disabled for workflows.
//
//  These tests exercise `WorkflowRunBootstrap` against the REAL `WorkflowRunHistoryStore` — the
//  stub-insert/finalize round-trip through SwiftData is the behaviour under test. The view-model
//  dependency is a narrow `WorkflowRunRegistry` protocol precisely so this is testable without
//  constructing a `MainApplicationViewModel` (which claims `HITLPresenter` globally); a fake
//  registry below stands in, so the in-memory-mirror half is covered too.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class WorkflowRunBootstrapTests: XCTestCase {

    private var touchedConversationIDs: [UUID] = []
    private var createdConversationIDs: [UUID] = []

    override func tearDown() async throws {
        for id in touchedConversationIDs {
            WorkflowRunHistoryStore.shared.clearHistory(forConversation: id)
        }
        if let context = WorkflowRunHistoryStore.shared.modelContainer?.mainContext {
            for id in createdConversationIDs {
                let predicate = #Predicate<ConversationSD> { $0.id == id }
                if let row = try? context.fetch(FetchDescriptor<ConversationSD>(predicate: predicate)).first {
                    context.delete(row)
                }
            }
            try? context.save()
        }
        touchedConversationIDs = []
        createdConversationIDs = []
    }

    private func makeConversation() throws -> UUID {
        guard let context = WorkflowRunHistoryStore.shared.modelContainer?.mainContext else {
            throw XCTSkip("Shared ModelContainer not configured in this test host")
        }
        let id = UUID()
        context.insert(ConversationSD(id: id, userDefinedTitle: "WF20 test"))
        try context.save()
        createdConversationIDs.append(id)
        touchedConversationIDs.append(id)
        return id
    }

    /// Stand-in for `MainApplicationViewModel`'s two workflow slots.
    private final class FakeRegistry: WorkflowRunRegistry {
        var workflowExecutionStates: [UUID: WorkflowExecutionState] = [:]
        var workflowRunHistory: [UUID: [WorkflowRunRecord]] = [:]
    }

    private func workflowProfile() -> BackendProfileSnapshot {
        BackendProfileSnapshot(
            id: UUID(),
            displayName: "Nightly Report",
            details: .workflow(WorkflowConfig(agentProfileIDs: []))
        )
    }

    private func botProfile() -> BackendProfileSnapshot {
        BackendProfileSnapshot(
            id: UUID(),
            displayName: "Plain Bot",
            details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "test-model")))
        )
    }

    // MARK: - WF20

    /// A workflow run started from ANY surface leaves a `.running` stub immediately, and finalize
    /// rewrites that same row rather than creating a twin.
    func testStubIsPersistedAndFinalizeRewritesTheSameRow() async throws {
        let conversationID = try makeConversation()
        let profile = workflowProfile()

        let registry = FakeRegistry()
        guard let ticket = WorkflowRunBootstrap.begin(
            config: BackendRequestConfig(profile: profile),
            conversationID: conversationID,
            userInput: "run the nightly report",
            registry: registry,
            origin: .scheduled
        ) else { return XCTFail("a workflow profile must produce a ticket") }

        // The live-state slot and the in-memory mirror are armed too — the mirror is what the
        // run picker and the "N of M" badge read.
        XCTAssertNotNil(registry.workflowExecutionStates[conversationID])
        XCTAssertEqual(registry.workflowRunHistory[conversationID]?.count, 1)

        // Stub is on disk before the stream has produced anything.
        let afterStart = WorkflowRunHistoryStore.shared.load(forConversation: conversationID)
        XCTAssertEqual(afterStart.count, 1, "the run must be discoverable from frame 1")
        XCTAssertEqual(afterStart.first?.status, .running)
        XCTAssertEqual(afterStart.first?.workflowProfileID, profile.id)
        XCTAssertEqual(afterStart.first?.userInput, "run the nightly report")
        let stubID = afterStart.first?.id

        // Simulate a run that produced one completed node, then finalize.
        ticket.state.nodeResults = [
            WorkflowNodeResult(id: UUID(), nodeID: UUID(), profileName: "Fetcher",
                               status: .completed, detail: "done",
                               startTime: Date(), endTime: Date())
        ]
        ticket.state.handleFinalOutput("the report")
        await ticket.finalize()?.value

        let afterFinalize = WorkflowRunHistoryStore.shared.load(forConversation: conversationID)
        XCTAssertEqual(afterFinalize.count, 1, "finalize must REWRITE the stub, not add a second row")
        XCTAssertEqual(afterFinalize.first?.id, stubID, "…and it must reuse the stub's id")
        XCTAssertEqual(afterFinalize.first?.status, .completed)
        XCTAssertEqual(afterFinalize.first?.nodeResults.count, 1,
                       "the frozen record must carry the node detail that lives only in the live state")
        XCTAssertEqual(afterFinalize.first?.finalOutput, "the report")
    }

    /// Non-workflow profiles must get no ticket and write nothing — every call site invokes this
    /// unconditionally, so a bot run must not acquire workflow bookkeeping.
    func testNonWorkflowProfileProducesNoTicketAndNoRecord() throws {
        let conversationID = try makeConversation()

        let registry = FakeRegistry()
        let ticket = WorkflowRunBootstrap.begin(
            config: BackendRequestConfig(profile: botProfile()),
            conversationID: conversationID,
            userInput: "hello",
            registry: registry,
            origin: .chat
        )

        XCTAssertNil(ticket)
        XCTAssertTrue(WorkflowRunHistoryStore.shared.load(forConversation: conversationID).isEmpty)
        XCTAssertTrue(registry.workflowExecutionStates.isEmpty, "a bot run must not claim the workflow state slot")
        XCTAssertTrue(registry.workflowRunHistory.isEmpty)
    }

    /// A user Stop must still be recorded — the cancel path runs the same finalize.
    func testCancelledRunIsFinalizedAsCancelled() async throws {
        let conversationID = try makeConversation()

        // ⚠️ Held in a local: the ticket keeps the registry WEAKLY, so a temporary would be gone
        // by the time finalize() runs and the "registry deallocated" guard would refuse the write.
        let registry = FakeRegistry()
        guard let ticket = WorkflowRunBootstrap.begin(
            config: BackendRequestConfig(profile: workflowProfile()),
            conversationID: conversationID,
            userInput: "go",
            registry: registry,
            origin: .chatOps
        ) else { return XCTFail("expected a ticket") }

        ticket.state.handleError("Cancelled", cancelled: true)
        await ticket.finalize()?.value

        let loaded = WorkflowRunHistoryStore.shared.load(forConversation: conversationID)
        XCTAssertEqual(loaded.first?.status, .cancelled,
                       "a stopped run started from any surface is still a Cancelled record")
    }

    /// Double-finalize is refused: `onComplete` fires once today, but a second freeze would re-run
    /// the whole persist path against already-settled state.
    func testDoubleFinalizeIsIgnored() async throws {
        let conversationID = try makeConversation()

        let registry = FakeRegistry()
        guard let ticket = WorkflowRunBootstrap.begin(
            config: BackendRequestConfig(profile: workflowProfile()),
            conversationID: conversationID,
            userInput: "go",
            registry: registry,
            origin: .quickAccess
        ) else { return XCTFail("expected a ticket") }

        ticket.state.handleFinalOutput("first")
        await ticket.finalize()?.value
        ticket.state.handleFinalOutput("second — must not be persisted")
        let secondTask = ticket.finalize()
        XCTAssertNil(secondTask, "a second finalize must not even start a write")
        await secondTask?.value

        let loaded = WorkflowRunHistoryStore.shared.load(forConversation: conversationID)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.finalOutput, "first",
                       "the second finalize must be ignored, not overwrite the frozen record")
    }

    /// The in-memory mirror and the store must trim to the SAME window — they were two duplicated
    /// `20` literals with nothing tying them together.
    func testInMemoryCapMatchesTheStoreWindow() {
        XCTAssertEqual(WorkflowRunHistoryStore.maxRecordsPerConversation, 20)
    }
}
