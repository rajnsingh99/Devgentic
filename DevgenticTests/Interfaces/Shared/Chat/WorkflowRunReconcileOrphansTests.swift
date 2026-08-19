//
//  WorkflowRunReconcileOrphansTests.swift
//  DevgenticTests
//
//  Register WF-PE6 — `reconcileOrphans()`, the zombie-run recovery path, had ZERO coverage.
//
//  A run is persisted as a `.running` stub at start and finalized at the end; a crash, force-quit
//  or failed finalize leaves the stub `.running` on disk forever. `reconcileOrphans()` is the
//  launch sweep that settles those rows — and it is what `WorkflowRunBootstrap`'s failure paths
//  explicitly defer to ("the record stays `.running` on disk and will be reconciled at the next
//  launch"). The two similarly-named suites (Settling, Resurrection) exercise DIFFERENT layers —
//  live-state settling and upsert-resurrection — so a regression here shipped green.
//
//  ⚠️ Hermetic by ID: the sweep settles EVERY `.running` row in the store, and the test host's
//  container is shared across suites, so every assertion is scoped to rows these tests created.
//  (Launch-time gating — the schema-change and test-env skips — lives at the call site in the app
//  and is not reachable from a unit test; what is pinned here is the store-level contract.)
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class WorkflowRunReconcileOrphansTests: XCTestCase {

    private var createdConversationIDs: [UUID] = []
    private var touchedConversationIDs: [UUID] = []

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
        createdConversationIDs = []
        touchedConversationIDs = []
    }

    private func makeConversation() throws -> UUID {
        guard let context = WorkflowRunHistoryStore.shared.modelContainer?.mainContext else {
            throw XCTSkip("Shared ModelContainer not configured in this test host")
        }
        let id = UUID()
        context.insert(ConversationSD(id: id, userDefinedTitle: "PE6 reconcile"))
        try context.save()
        createdConversationIDs.append(id)
        touchedConversationIDs.append(id)
        return id
    }

    private func insert(_ status: WorkflowRunRecord.RunStatus,
                        in conversationID: UUID,
                        error: String? = nil) -> UUID {
        let record = WorkflowRunRecord(
            id: UUID(), conversationID: conversationID, workflowProfileID: UUID(),
            workflowName: "Reconcile Test Flow", timestamp: Date(), userInput: "go",
            nodeResults: [], finalOutput: "", variables: [:],
            status: status, duration: 1, error: error
        )
        WorkflowRunHistoryStore.shared.upsert(record, forConversation: conversationID)
        return record.id
    }

    private func reload(_ id: UUID, in conversationID: UUID) -> WorkflowRunRecord? {
        WorkflowRunHistoryStore.shared.load(forConversation: conversationID).first { $0.id == id }
    }

    // MARK: - The contract

    /// A `.running` row with no live run behind it is the zombie; the sweep settles it to
    /// `.cancelled` with "Interrupted" — never `.failed` (nothing is known to have failed) and
    /// never `.completed` (the one thing it certainly did not do).
    func testOrphanedRunningRowIsSettledToCancelledInterrupted() throws {
        let cid = try makeConversation()
        let orphanID = insert(.running, in: cid)

        WorkflowRunHistoryStore.shared.reconcileOrphans()

        let settled = try XCTUnwrap(reload(orphanID, in: cid))
        XCTAssertEqual(settled.status, .cancelled)
        XCTAssertEqual(settled.error, "Interrupted")
    }

    /// Settled rows are NOT touched — the sweep is for zombies only. A reconcile that rewrote
    /// finished runs would corrupt history wholesale at every launch.
    func testSettledRowsAreUntouched() throws {
        let cid = try makeConversation()
        let completedID = insert(.completed, in: cid)
        let failedID = insert(.failed, in: cid, error: "boom")
        let cancelledID = insert(.cancelled, in: cid, error: "user stop")

        WorkflowRunHistoryStore.shared.reconcileOrphans()

        XCTAssertEqual(try XCTUnwrap(reload(completedID, in: cid)).status, .completed)
        let failed = try XCTUnwrap(reload(failedID, in: cid))
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.error, "boom", "a settled row's error must survive the sweep")
        XCTAssertEqual(try XCTUnwrap(reload(cancelledID, in: cid)).status, .cancelled)
    }

    /// An orphan that already carries an error keeps it — "Interrupted" is the fallback, not an
    /// overwrite; whatever the dying run managed to record is better evidence than the generic word.
    func testExistingErrorMessageIsPreserved() throws {
        let cid = try makeConversation()
        let orphanID = insert(.running, in: cid, error: "stream dropped at node 3")

        WorkflowRunHistoryStore.shared.reconcileOrphans()

        let settled = try XCTUnwrap(reload(orphanID, in: cid))
        XCTAssertEqual(settled.status, .cancelled)
        XCTAssertEqual(settled.error, "stream dropped at node 3")
    }

    /// Duration is deliberately LEFT untouched: the wall-clock since the run started would include
    /// all app downtime (a Monday crash reopened Thursday once rendered as "4320m 0s"). The stored
    /// value stays; `DurationFormat` renders nothing for a stub's 0.
    func testDurationIsNotRewrittenWithDowntime() throws {
        let cid = try makeConversation()
        let orphanID = insert(.running, in: cid)

        WorkflowRunHistoryStore.shared.reconcileOrphans()

        let settled = try XCTUnwrap(reload(orphanID, in: cid))
        XCTAssertEqual(settled.duration, 1, "the sweep must not compute a duration spanning downtime")
    }

    /// A run that is still `.running` at sweep time and IS the current session's live run is not a
    /// case the store can distinguish — the protection is that the sweep runs at LAUNCH, before any
    /// run exists. Pinned so a future caller moving the sweep to mid-session has a failing test to
    /// answer to: the sweep settles EVERY .running row it sees, including this one.
    func testSweepSettlesEveryRunningRowItSees() throws {
        let cid = try makeConversation()
        let a = insert(.running, in: cid)
        let b = insert(.running, in: cid)

        WorkflowRunHistoryStore.shared.reconcileOrphans()

        XCTAssertEqual(try XCTUnwrap(reload(a, in: cid)).status, .cancelled)
        XCTAssertEqual(try XCTUnwrap(reload(b, in: cid)).status, .cancelled,
                       "the sweep is unconditional over .running rows — safe ONLY because it runs at launch")
    }
}
