// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowHistoryLoadStripTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class WorkflowHistoryLoadStripTests: XCTestCase {

    private var conversationID: UUID!

    override func setUp() async throws {
        guard let context = WorkflowRunHistoryStore.shared.modelContainer?.mainContext else {
            throw XCTSkip("Shared ModelContainer not configured in this test host")
        }
        conversationID = UUID()
        context.insert(ConversationSD(id: conversationID, userDefinedTitle: "vm-6 test"))
        try context.save()
    }

    override func tearDown() async throws {
        guard let id = conversationID else { return }
        WorkflowRunHistoryStore.shared.clearHistory(forConversation: id)
        if let context = WorkflowRunHistoryStore.shared.modelContainer?.mainContext {
            let predicate = #Predicate<ConversationSD> { $0.id == id }
            if let row = try? context.fetch(FetchDescriptor<ConversationSD>(predicate: predicate)).first {
                context.delete(row)
            }
            try? context.save()
        }
        conversationID = nil
    }

    private func node(events: Int, name: String) -> WorkflowRunRecord.WorkflowNodeResultSnapshot {
        WorkflowRunRecord.WorkflowNodeResultSnapshot(
            id: UUID(), nodeID: UUID(), profileName: name, status: .completed,
            detail: "out-\(name)", duration: 2, input: "in-\(name)", inputSourceLabel: "src-\(name)",
            nodeTimeline: events == 0 ? nil : (0..<events).map { .thought(id: UUID(), text: "e\($0)") },
            hasWarnings: false, ranBeforeSkip: true
        )
    }

    private func record(_ nodes: [WorkflowRunRecord.WorkflowNodeResultSnapshot],
                        name: String = "wf") -> WorkflowRunRecord {
        WorkflowRunRecord(
            id: UUID(), conversationID: conversationID, workflowProfileID: UUID(), workflowName: name,
            timestamp: Date(timeIntervalSince1970: 1_000), userInput: "go", nodeResults: nodes,
            finalOutput: "answer-\(name)", variables: ["k": "v"], status: .completed,
            duration: 4, error: nil
        )
    }

    // MARK: - The pin

    /// THE pin: what comes back carries NO node traces, and the count of what was dropped comes
    /// back with it.
    func testLoadReturnsRecordsWithoutTracesAndCountsWhatItDropped() async {
        await WorkflowRunHistoryStore.shared.upsertFinalized(
            record([node(events: 40, name: "Alpha"), node(events: 2, name: "Beta"), node(events: 0, name: "Gamma")]),
            forConversation: conversationID)

        let loaded = await WorkflowRunHistoryStore.shared.loadFinalized(forConversation: conversationID)

        XCTAssertEqual(loaded.records.count, 1)
        XCTAssertEqual(loaded.droppedEvents, 42)
        XCTAssertTrue(loaded.records[0].nodeResults.allSatisfy { $0.nodeTimeline == nil },
                      "a trace that reaches the caller is a trace that was materialised for nothing")
    }

    /// The count is summed across every run on the page, not just the first.
    func testDroppedCountCoversEveryRunOnThePage() async {
        for i in 0..<3 {
            await WorkflowRunHistoryStore.shared.upsertFinalized(
                record([node(events: 5, name: "N\(i)")], name: "wf\(i)"), forConversation: conversationID)
        }

        let loaded = await WorkflowRunHistoryStore.shared.loadFinalized(forConversation: conversationID)

        XCTAssertEqual(loaded.records.count, 3)
        XCTAssertEqual(loaded.droppedEvents, 15)
    }

    /// ⚠️ EVERYTHING the history list reads must survive the strip — it renders status, counts,
    /// durations, the final output and the node names. Stripping the wrong thing would leave the
    /// list wrong rather than merely trace-free, which is far harder to notice.
    func testEverythingButTheTracesSurvives() async {
        let original = record([node(events: 7, name: "Alpha"), node(events: 0, name: "Beta")])
        await WorkflowRunHistoryStore.shared.upsertFinalized(original, forConversation: conversationID)

        let loaded = await WorkflowRunHistoryStore.shared.loadFinalized(forConversation: conversationID)
        let back = try? XCTUnwrap(loaded.records.first)

        XCTAssertEqual(back?.id, original.id)
        XCTAssertEqual(back?.workflowName, original.workflowName)
        XCTAssertEqual(back?.finalOutput, original.finalOutput)
        XCTAssertEqual(back?.userInput, original.userInput)
        XCTAssertEqual(back?.status, original.status)
        XCTAssertEqual(back?.variables, original.variables)
        XCTAssertEqual(back?.nodeResults.count, 2)
        XCTAssertEqual(back?.nodeResults.map(\.profileName), ["Alpha", "Beta"])
        XCTAssertEqual(back?.nodeResults.map(\.detail), ["out-Alpha", "out-Beta"])
        XCTAssertEqual(back?.nodeResults.map(\.inputSourceLabel), ["src-Alpha", "src-Beta"])
    }

    /// A run with no traces at all reports zero dropped — the count must describe what was
    /// actually thrown away, not how many runs were read.
    func testATraceFreeRunDropsNothing() async {
        await WorkflowRunHistoryStore.shared.upsertFinalized(
            record([node(events: 0, name: "Alpha")]), forConversation: conversationID)

        let loaded = await WorkflowRunHistoryStore.shared.loadFinalized(forConversation: conversationID)

        XCTAssertEqual(loaded.records.count, 1)
        XCTAssertEqual(loaded.droppedEvents, 0)
    }

    /// The single-run hydration read is the OTHER half of this design and must be untouched:
    /// the list is trace-free precisely so that opening one run can re-read its trace.
    func testTheSingleRunReadStillCarriesItsTraces() async {
        let original = record([node(events: 9, name: "Alpha")])
        await WorkflowRunHistoryStore.shared.upsertFinalized(original, forConversation: conversationID)

        let hydrated = await WorkflowRunHistoryStore.shared.loadRecord(id: original.id)

        XCTAssertEqual(hydrated?.nodeResults.first?.nodeTimeline?.count, 9,
                       "stripping the LIST must not strip the record the run view opens")
    }

    /// The merge keeps its own strip as an idempotent guard — a mutant that stopped stripping
    /// there is documented to have survived a previous battery, so it stays testable.
    func testTheMergeStripIsIdempotentOverAlreadyStrippedRecords() {
        let stripped = record([node(events: 3, name: "Alpha")]).strippingNodeTimelines()

        let merged = ConversationSwitchCoordinator.mergeLoadedHistory(existing: [], loaded: [stripped.record])

        XCTAssertEqual(stripped.droppedEvents, 3, "sanity: there was something to strip")
        XCTAssertEqual(merged.droppedEvents, 0, "nothing left to drop the second time")
        XCTAssertEqual(merged.merged.count, 1)
        XCTAssertTrue(merged.merged[0].nodeResults.allSatisfy { $0.nodeTimeline == nil })
    }
}
