// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowRunResurrectionTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class WorkflowRunResurrectionTests: XCTestCase {

    private var createdConversationIDs: [UUID] = []
    /// Every conversation id these tests write against, including ones that deliberately do not
    /// exist. `clearHistory` deletes run rows by `conversationID`, so this collects the orphan
    /// rows a REGRESSION (or a mutation check) would produce — otherwise proving the bug leaves
    /// exactly the unreachable rows the bug is about sitting in the store.
    private var touchedConversationIDs: [UUID] = []

    override func tearDown() async throws {
        for id in touchedConversationIDs {
            WorkflowRunHistoryStore.shared.clearHistory(forConversation: id)
        }
        if let context = WorkflowRunHistoryStore.shared.modelContainer?.mainContext {
            for id in createdConversationIDs {
                let predicate = #Predicate<ConversationSD> { $0.id == id }
                if let row = try? context.fetch(FetchDescriptor<ConversationSD>(predicate: predicate)).first {
                    context.delete(row)   // cascades to its workflowRuns
                }
            }
            try? context.save()
        }
        createdConversationIDs = []
        touchedConversationIDs = []
    }

    private func record(conversationID: UUID, status: WorkflowRunRecord.RunStatus) -> WorkflowRunRecord {
        WorkflowRunRecord(
            id: UUID(),
            conversationID: conversationID,
            workflowProfileID: UUID(),
            workflowName: "Resurrection Test Flow",
            timestamp: Date(),
            userInput: "sensitive user content",
            nodeResults: [],
            finalOutput: "sensitive result the user deleted",
            variables: [:],
            status: status,
            duration: 1,
            error: nil
        )
    }

    /// Creates a real `ConversationSD` so the control test exercises the same code path.
    private func makeConversation() throws -> UUID {
        guard let context = WorkflowRunHistoryStore.shared.modelContainer?.mainContext else {
            throw XCTSkip("Shared ModelContainer not configured in this test host")
        }
        let id = UUID()
        context.insert(ConversationSD(id: id, userDefinedTitle: "WF6 control"))
        try context.save()
        createdConversationIDs.append(id)
        touchedConversationIDs.append(id)
        return id
    }

    // MARK: - WF6

    /// Finalizing a run whose conversation was deleted must NOT write it back.
    func testFinalizeAfterConversationDeleteDoesNotResurrectTheRun() throws {
        // A conversation id that was never persisted stands in for one already deleted — the
        // store sees exactly the same thing in both cases: no `ConversationSD` row.
        let deletedConversationID = UUID()
        touchedConversationIDs.append(deletedConversationID)

        WorkflowRunHistoryStore.shared.upsert(
            record(conversationID: deletedConversationID, status: .completed),
            forConversation: deletedConversationID
        )

        XCTAssertTrue(
            WorkflowRunHistoryStore.shared.load(forConversation: deletedConversationID).isEmpty,
            "A run finalizing after its conversation was deleted must be dropped, not written back "
            + "as an unparented row — the delete path deliberately purges this user's content."
        )
    }

    /// The control: with the conversation present, the run persists normally. Without this the
    /// test above would pass against a store that simply never writes anything.
    func testRunStillPersistsWhenTheConversationExists() throws {
        let conversationID = try makeConversation()

        let run = record(conversationID: conversationID, status: .completed)
        WorkflowRunHistoryStore.shared.upsert(run, forConversation: conversationID)

        let loaded = WorkflowRunHistoryStore.shared.load(forConversation: conversationID)
        XCTAssertEqual(loaded.count, 1, "A run against a live conversation must still persist")
        XCTAssertEqual(loaded.first?.id, run.id)
    }

    // MARK: - WF18: history is per-workflow, not just per-conversation

    /// The store is keyed by conversation alone, so one conversation accumulates every workflow's
    /// runs. The dedicated view must show only THIS workflow's — otherwise the list, the "N of M"
    /// badge and the run picker all count runs this workflow never performed, and opening one
    /// renders another workflow's nodes under this workflow's header.
    ///
    /// This pins the STORE's shape (mixed) and the filter predicate the view applies, since
    /// building the SwiftUI view in a unit test is not practical.
    func testConversationHistoryMixesWorkflowsAndMustBeFilteredByProfile() throws {
        let conversationID = try makeConversation()
        let workflowA = UUID()
        let workflowB = UUID()

        for workflow in [workflowA, workflowA, workflowB] {
            var run = record(conversationID: conversationID, status: .completed)
            run = WorkflowRunRecord(
                id: run.id, conversationID: conversationID, workflowProfileID: workflow,
                workflowName: workflow == workflowA ? "Research Pipeline" : "Release Notes",
                timestamp: run.timestamp, userInput: run.userInput, nodeResults: [],
                finalOutput: run.finalOutput, variables: [:], status: .completed, duration: 1, error: nil
            )
            WorkflowRunHistoryStore.shared.upsert(run, forConversation: conversationID)
        }

        let all = WorkflowRunHistoryStore.shared.load(forConversation: conversationID)
        XCTAssertEqual(all.count, 3, "Precondition: the store really does mix workflows in one conversation")

        // The predicate `WorkflowDedicatedView.runHistory` applies.
        XCTAssertEqual(all.filter { $0.workflowProfileID == workflowA }.count, 2)
        XCTAssertEqual(all.filter { $0.workflowProfileID == workflowB }.count, 1,
                       "Workflow B's view must show its own single run, not all three")
    }

    /// The `.running` stub written at run start is subject to the same rule.
    func testRunningStubForMissingConversationIsAlsoRefused() throws {
        let missing = UUID()
        touchedConversationIDs.append(missing)

        WorkflowRunHistoryStore.shared.upsert(
            record(conversationID: missing, status: .running),
            forConversation: missing
        )

        XCTAssertTrue(WorkflowRunHistoryStore.shared.load(forConversation: missing).isEmpty)
    }
}
