// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowRunBootstrapTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
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

    /// Stand-in for `MainApplicationViewModel`'s workflow slots.
    private final class FakeRegistry: WorkflowRunRegistry {
        var workflowExecutionStates: [UUID: WorkflowExecutionState] = [:]
        var workflowRunHistory: [UUID: [WorkflowRunRecord]] = [:]
        /// [WF-CS4] Settable here so a test can stage "this profile's canvas is dirty" without a
        /// `WorkflowCanvasState` or a view model.
        var unsavedWorkflowCanvasProfileIDs: [UUID] = []
    }

    private func workflowProfile() -> BackendProfileSnapshot {
        BackendProfileSnapshot(
            id: UUID(),
            displayName: "Nightly Report",
            details: .workflow(WorkflowConfig())
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

    // MARK: - WF-PE7

    /// `finalize()`'s persist is deliberately fire-and-forget for the UI (all six production call
    /// sites discard the returned task), and its window contains a real await — the detached blob
    /// encode — so quitting inside it used to strand the `.running` stub and the next launch
    /// relabelled a COMPLETED run "Interrupted" with zero node results. The fix: the persist task
    /// registers itself in `pendingPersists` the moment finalize returns, and the quit teardown's
    /// `drainPendingPersists()` awaits the stragglers.
    func testFinalizeRegistersItsPersistAndTheQuitDrainCompletesTheWrite() async throws {
        let conversationID = try makeConversation()

        let registry = FakeRegistry()
        guard let ticket = WorkflowRunBootstrap.begin(
            config: BackendRequestConfig(profile: workflowProfile()),
            conversationID: conversationID,
            userInput: "go",
            registry: registry,
            origin: .chat
        ) else { return XCTFail("expected a ticket") }
        let recordID = try XCTUnwrap(ticket.state.runRecordID)

        ticket.state.handleFinalOutput("done")
        XCTAssertNotNil(ticket.finalize())

        // The registration, not the write, is what quit depends on: it must be discoverable
        // synchronously, before the persist task has had a chance to run.
        XCTAssertNotNil(WorkflowRunTicket.pendingPersists[recordID],
                        "the persist must be registered for the quit drain the moment finalize returns")

        await WorkflowRunTicket.drainPendingPersists()

        XCTAssertNil(WorkflowRunTicket.pendingPersists[recordID],
                     "a completed persist must deregister itself")
        let loaded = WorkflowRunHistoryStore.shared.load(forConversation: conversationID)
        XCTAssertEqual(loaded.first?.status, .completed,
                       "after the drain the finalized row — not the `.running` stub — is on disk")
        XCTAssertEqual(loaded.first?.finalOutput, "done")
    }

    // MARK: - WF-LC2
    //
    // ⚠️ WHAT THIS SECTION COVERS AND WHAT IT DOES NOT. Every test below drives the real
    // `WorkflowRunTicket.activeTickets` / `forceFinalizeActiveRuns` machinery — no fakes, same
    // pattern as the WF-PE7 tests above. What it CANNOT reach: the `AppDelegate` wiring itself —
    // `handleInFlightWorkflowRunsBeforeQuit()`'s alert construction, its button-to-branch mapping,
    // and its placement in `applicationShouldTerminate` — has no unit seam, matching WF-PE7's own
    // disclosure ("the ASM wiring itself has no unit seam"). That half is reviewed, not tested.

    /// A ticket is discoverable as ACTIVE by the time `begin` RETURNS it (this test's only
    /// observation point is after the call; every statement inside `begin` runs synchronously with
    /// no `await`, so it cannot distinguish registration-at-construction from registration at some
    /// other point inside `begin`'s body — that finer claim is a code-reading fact, not something
    /// this test isolates), and stops being discoverable the instant `finalize()` genuinely
    /// proceeds. `activeTickets` must mean exactly "not yet finalized", or the quit-time walk would
    /// either miss a real in-flight run or double-touch one that already settled naturally.
    func testTicketIsActiveFromBeginUntilFinalize() async throws {
        let conversationID = try makeConversation()
        let registry = FakeRegistry()
        guard let ticket = WorkflowRunBootstrap.begin(
            config: BackendRequestConfig(profile: workflowProfile()),
            conversationID: conversationID,
            userInput: "go",
            registry: registry,
            origin: .chat
        ) else { return XCTFail("expected a ticket") }
        let recordID = try XCTUnwrap(ticket.state.runRecordID)

        XCTAssertNotNil(WorkflowRunTicket.activeTickets[recordID],
                        "a started run must be discoverable as in-flight immediately")

        ticket.state.handleFinalOutput("done")
        ticket.finalize()

        XCTAssertNil(WorkflowRunTicket.activeTickets[recordID],
                     "a naturally-finalized run must not still read as in-flight")

        // Await the persist this test's own finalize() started — an un-awaited task would leave a
        // dangling `pendingPersists` entry for the rest of the process (adversarial review caught
        // this same class of leak on the sibling `activeTickets` registry).
        await WorkflowRunTicket.drainPendingPersists()
    }

    /// The core of the fix: a run that is STILL RUNNING (no `handleFinalOutput`, no `finalize()` —
    /// exactly what ⌘Q interrupts) is force-settled to `.cancelled` and its ALREADY-COMPLETED node
    /// output survives, instead of the process just exiting and the next launch relabelling the
    /// stub "Interrupted" with zero node results.
    func testForceFinalizeActiveRunsPersistsCompletedNodeOutputAsCancelled() async throws {
        let conversationID = try makeConversation()
        let registry = FakeRegistry()
        guard let ticket = WorkflowRunBootstrap.begin(
            config: BackendRequestConfig(profile: workflowProfile()),
            conversationID: conversationID,
            userInput: "go",
            registry: registry,
            origin: .chat
        ) else { return XCTFail("expected a ticket") }
        let recordID = try XCTUnwrap(ticket.state.runRecordID)

        // A node completed real work before quit interrupted the run — the output this fix exists
        // to keep. `isRunning` defaults to false (a fresh `WorkflowExecutionState` has run
        // nothing); `handleNodeStarted` is the real production trigger that flips it, so a node 2
        // starting after node 1 completed is the realistic "still running, one node done" shape
        // ⌘Q would actually interrupt.
        let completedNodeID = UUID()
        ticket.state.nodeResults = [
            WorkflowNodeResult(id: UUID(), nodeID: completedNodeID, profileName: "Researcher",
                               status: .completed, detail: "found 3 sources",
                               startTime: Date(), endTime: Date())
        ]
        ticket.state.handleNodeStarted(nodeID: UUID(), profileName: "Writer", index: 2, total: 2)
        XCTAssertTrue(ticket.state.isRunning)

        let count = WorkflowRunTicket.forceFinalizeActiveRuns(reason: "Quit during run")
        XCTAssertEqual(count, 1)
        XCTAssertNil(WorkflowRunTicket.activeTickets[recordID],
                     "the ticket must leave the active set the instant it is force-finalized")

        await WorkflowRunTicket.drainPendingPersists()

        let loaded = try XCTUnwrap(WorkflowRunHistoryStore.shared.load(forConversation: conversationID).first)
        XCTAssertEqual(loaded.status, .cancelled,
                       "the app quit under it — that is a Stop, not a failure")
        XCTAssertEqual(loaded.nodeResults.count, 2, "both the finished node and the interrupted one")
        let finishedNode = try XCTUnwrap(loaded.nodeResults.first { $0.profileName == "Researcher" })
        XCTAssertEqual(finishedNode.status, .completed,
                       "the completed node's output is exactly what WF-LC2 says is lost today")
        XCTAssertEqual(finishedNode.detail, "found 3 sources")
        let interruptedNode = try XCTUnwrap(loaded.nodeResults.first { $0.profileName == "Writer" })
        XCTAssertEqual(interruptedNode.status, .cancelled,
                       "the node that was still running when quit interrupted it is Cancelled, not Failed")
    }

    /// ⚠️ ADVERSARIAL-REVIEW-FOUND REGRESSION. `activeTickets` only removes a ticket INSIDE
    /// `finalize()` — but a run's live state reaches its TRUE terminal outcome earlier than that,
    /// at `handleStreamEnd`/`handleError` (real production call sites defer the actual `finalize()`
    /// call across real suspending work — a persistence write, a trace-end — so there is a genuine
    /// window where a ticket is still "active" by this registry's definition even though the run
    /// already succeeded or genuinely failed on its own). A naive force-finalize that always calls
    /// `handleError(cancelled: true)` would catch a run in that window and permanently overwrite
    /// its real `.completed` outcome with a fabricated `.cancelled` one — `didFinalize` being a
    /// PERMANENT guard means that true outcome could never be recovered. This test constructs
    /// exactly that window (state already settled via `handleFinalOutput`, ticket not yet
    /// finalized) and pins that force-finalize freezes the REAL outcome, not a manufactured one.
    func testForceFinalizeActiveRunsDoesNotOverwriteARunThatAlreadySettled() async throws {
        let conversationID = try makeConversation()
        let registry = FakeRegistry()
        guard let ticket = WorkflowRunBootstrap.begin(
            config: BackendRequestConfig(profile: workflowProfile()),
            conversationID: conversationID,
            userInput: "go",
            registry: registry,
            origin: .chat
        ) else { return XCTFail("expected a ticket") }

        // The run already reached its TRUE outcome — mirrors `handleStreamEnd`'s success path —
        // but `finalize()` has not been called yet (the real gap: onComplete is deferred past
        // real suspending work in production).
        ticket.state.handleFinalOutput("the real answer")
        XCTAssertFalse(ticket.state.isRunning, "settled, exactly like the window this test targets")
        XCTAssertNotNil(WorkflowRunTicket.activeTickets[try XCTUnwrap(ticket.state.runRecordID)],
                        "still active by this registry's definition — finalize() has not run yet")

        WorkflowRunTicket.forceFinalizeActiveRuns(reason: "Quit during run")
        await WorkflowRunTicket.drainPendingPersists()

        let loaded = try XCTUnwrap(WorkflowRunHistoryStore.shared.load(forConversation: conversationID).first)
        XCTAssertEqual(loaded.status, .completed,
                       "the run truly succeeded before quit — force-finalize must not relabel it Cancelled")
        XCTAssertEqual(loaded.finalOutput, "the real answer")
        XCTAssertNil(loaded.error)
    }

    /// ⚠️ THE REGRESSION GUARD for a post-hoc audit finding: `isRunning` is `false` in TWO
    /// situations this gate must not conflate — a run that already settled (the case above), and a
    /// ticket that was JUST registered by `begin()` but whose executor has not yet dispatched to
    /// its first node, so `handleNodeStarted` (the only setter of `isRunning = true`) has never
    /// fired. Gating on `isRunning` alone would treat this pristine ticket as "already settled" and
    /// skip `handleError` entirely — `finalize()` then freezes an empty `nodeResults`/no
    /// `workflowError`/`wasCancelled == false` state, which `WorkflowRunRecord.freeze`'s status
    /// derivation turns into a **falsely successful `.completed`** row for a run that never even
    /// started. This is what `completedAt == nil` (the actual gate now) is for: it stays nil for
    /// BOTH "still running" and "never started," and is set ONLY once the run genuinely settles.
    func testForceFinalizeActiveRunsCancelsAPristineTicketThatNeverStarted() async throws {
        let conversationID = try makeConversation()
        let registry = FakeRegistry()
        guard let ticket = WorkflowRunBootstrap.begin(
            config: BackendRequestConfig(profile: workflowProfile()),
            conversationID: conversationID,
            userInput: "go",
            registry: registry,
            origin: .chat
        ) else { return XCTFail("expected a ticket") }

        // Deliberately do NOT call handleNodeStarted or handleFinalOutput — this is the pristine,
        // registered-but-never-dispatched state the gap targets.
        XCTAssertFalse(ticket.state.isRunning, "a pristine ticket starts with isRunning == false, same as a settled one")
        XCTAssertNil(ticket.state.completedAt, "never started, so never settled either")

        WorkflowRunTicket.forceFinalizeActiveRuns(reason: "Quit during run")
        await WorkflowRunTicket.drainPendingPersists()

        let loaded = try XCTUnwrap(WorkflowRunHistoryStore.shared.load(forConversation: conversationID).first)
        XCTAssertEqual(loaded.status, .cancelled,
                       "a run that never got to start must be recorded as cancelled/interrupted, NOT as a falsely-successful empty completion")
    }

    /// The control: force-finalizing must not touch anything BEYOND what this test itself started.
    ///
    /// ⚠️ Delta against a captured baseline, never an absolute `== 0` — `activeTickets` is a
    /// process-wide static with no reset, so a ticket any OTHER test anywhere in the target leaves
    /// un-finalized would make an absolute-zero assertion fail for a reason unrelated to this test
    /// (adversarial review empirically reproduced exactly that against an earlier draft). This
    /// shape stays correct regardless of what else is, or later becomes, active in the process.
    func testForceFinalizeActiveRunsIsANoOpBeyondWhatItStarted() {
        let before = WorkflowRunTicket.activeRunCount
        XCTAssertEqual(WorkflowRunTicket.forceFinalizeActiveRuns(reason: "Quit during run"), before,
                       "must finalize exactly what was active, nothing manufactured and nothing skipped")
        XCTAssertEqual(WorkflowRunTicket.activeRunCount, 0,
                       "everything that WAS active must now be finalized")
    }

    /// ⚠️ THE ORDERING INVARIANT THE WHOLE FIX DEPENDS ON. `didFinalize` is a PERMANENT guard, so if
    /// the user presses Cancel at the quit prompt (or the prompt code never runs at all), the run
    /// must be able to go on and finalize NORMALLY later — this must NOT have already happened
    /// speculatively. `forceFinalizeActiveRuns` must therefore never be called except from the
    /// confirmed "Quit Anyway" branch; this test pins that a run left untouched can still finalize
    /// itself exactly as if the quit-time code had never existed.
    func testARunNeverForceFinalizedCanStillFinalizeNormallyLater() async throws {
        let conversationID = try makeConversation()
        let registry = FakeRegistry()
        guard let ticket = WorkflowRunBootstrap.begin(
            config: BackendRequestConfig(profile: workflowProfile()),
            conversationID: conversationID,
            userInput: "go",
            registry: registry,
            origin: .chat
        ) else { return XCTFail("expected a ticket") }

        // Simulates the user seeing the quit prompt and pressing Cancel — activeRunCount was read,
        // forceFinalizeActiveRuns was never called. The run keeps going and completes for real.
        // Keyed to THIS ticket's own id, not an absolute global count — `activeTickets` is a
        // process-wide static, so asserting a bare total would be fragile to whatever else is
        // active elsewhere in the process.
        XCTAssertNotNil(WorkflowRunTicket.activeTickets[try XCTUnwrap(ticket.state.runRecordID)])

        ticket.state.handleFinalOutput("finished normally")
        XCTAssertNotNil(ticket.finalize(),
                        "a run the quit prompt did NOT touch must still be finalizable by its own onComplete")

        await WorkflowRunTicket.drainPendingPersists()
        let loaded = try XCTUnwrap(WorkflowRunHistoryStore.shared.load(forConversation: conversationID).first)
        XCTAssertEqual(loaded.status, .completed,
                       "a cancelled QUIT PROMPT must never leave a run permanently unable to record its real completion")
    }

    /// ⚠️ THE FAILURE MODE THE ORDERING INVARIANT PREVENTS, actually triggered. The test above only
    /// proves the untouched happy path still works; it never exercises the dangerous direction. This
    /// one deliberately calls `forceFinalizeActiveRuns` BEFORE the run's real completion — simulating
    /// exactly the bug the code comments warn against (calling it speculatively, before "Quit Anyway"
    /// is the user's committed answer) — and shows `didFinalize` then permanently drops the run's
    /// true completion. This is why the AppDelegate wiring must call it from EXACTLY the confirmed
    /// branch: this test is what a regression moving that call earlier would light up.
    func testCallingForceFinalizeBeforeTheRunTrulyFinishesPermanentlyDropsItsRealCompletion() async throws {
        let conversationID = try makeConversation()
        let registry = FakeRegistry()
        guard let ticket = WorkflowRunBootstrap.begin(
            config: BackendRequestConfig(profile: workflowProfile()),
            conversationID: conversationID,
            userInput: "go",
            registry: registry,
            origin: .chat
        ) else { return XCTFail("expected a ticket") }

        // A node is genuinely running when the speculative call lands — the shape the
        // `isRunning`-gate exists for, so this exercises the force-cancel branch, not the
        // already-settled one `testForceFinalizeActiveRunsDoesNotOverwriteARunThatAlreadySettled`
        // already covers.
        ticket.state.handleNodeStarted(nodeID: UUID(), profileName: "Researcher", index: 1, total: 2)
        XCTAssertTrue(ticket.state.isRunning)

        // Simulates a hypothetical bug: force-finalize runs speculatively, before the user has
        // committed to quitting.
        WorkflowRunTicket.forceFinalizeActiveRuns(reason: "Quit during run")
        await WorkflowRunTicket.drainPendingPersists()

        // The run "keeps going" (the quit was, hypothetically, cancelled) and finishes for real —
        // exactly `testARunNeverForceFinalizedCanStillFinalizeNormallyLater`'s scenario, except this
        // time the ticket WAS touched first.
        ticket.state.handleFinalOutput("the real, later answer")
        let secondFinalizeTask = ticket.finalize()

        XCTAssertNil(secondFinalizeTask,
                     "didFinalize is a PERMANENT guard — the real completion's finalize is a silent no-op")
        let loaded = try XCTUnwrap(WorkflowRunHistoryStore.shared.load(forConversation: conversationID).first)
        XCTAssertEqual(loaded.status, .cancelled,
                       "the speculative call's outcome is what's on disk — the real answer never reached it")
        XCTAssertNotEqual(loaded.finalOutput, "the real, later answer",
                          "proves the loss this test exists to demonstrate, not just narrate")
    }

    /// Two runs in different conversations, interrupted together — the count and the per-run
    /// outcome must both be right, not just "at least one got saved".
    func testForceFinalizeActiveRunsHandlesMultipleConcurrentRuns() async throws {
        let convA = try makeConversation()
        let convB = try makeConversation()
        let registry = FakeRegistry()

        let before = WorkflowRunTicket.activeRunCount

        guard let ticketA = WorkflowRunBootstrap.begin(
            config: BackendRequestConfig(profile: workflowProfile()), conversationID: convA,
            userInput: "a", registry: registry, origin: .chat
        ) else { return XCTFail("expected ticket A") }
        guard let ticketB = WorkflowRunBootstrap.begin(
            config: BackendRequestConfig(profile: workflowProfile()), conversationID: convB,
            userInput: "b", registry: registry, origin: .scheduled
        ) else { return XCTFail("expected ticket B") }

        // Both genuinely running — the shape the force-cancel branch of the `isRunning` gate
        // exists for. A fresh `WorkflowExecutionState()` defaults `isRunning` to false, which
        // force-finalize now correctly leaves un-cancelled (see
        // `testForceFinalizeActiveRunsDoesNotOverwriteARunThatAlreadySettled`).
        ticketA.state.handleNodeStarted(nodeID: UUID(), profileName: "A-Node", index: 1, total: 1)
        ticketB.state.handleNodeStarted(nodeID: UUID(), profileName: "B-Node", index: 1, total: 1)

        // Delta against the pre-test baseline, not an absolute 2 — `activeTickets` is a
        // process-wide static, so an absolute count is fragile to whatever else is active
        // elsewhere in the process. Each ticket's presence is also checked directly by id.
        XCTAssertEqual(WorkflowRunTicket.activeRunCount, before + 2)
        let recordIDA = try XCTUnwrap(ticketA.state.runRecordID)
        let recordIDB = try XCTUnwrap(ticketB.state.runRecordID)
        XCTAssertNotNil(WorkflowRunTicket.activeTickets[recordIDA])
        XCTAssertNotNil(WorkflowRunTicket.activeTickets[recordIDB])

        let count = WorkflowRunTicket.forceFinalizeActiveRuns(reason: "Quit during run")
        XCTAssertEqual(count, before + 2)

        await WorkflowRunTicket.drainPendingPersists()
        let loadedA = try XCTUnwrap(WorkflowRunHistoryStore.shared.load(forConversation: convA).first)
        let loadedB = try XCTUnwrap(WorkflowRunHistoryStore.shared.load(forConversation: convB).first)
        XCTAssertEqual(loadedA.status, .cancelled)
        XCTAssertEqual(loadedB.status, .cancelled)
    }

    // MARK: - CF-28
    //
    // `Chat_Production_Readiness_Fresh.md` CF-28: a conversation switch between stream end and
    // `finalize()` used to wipe a run's node traces (`releaseSettledTraces` gated on `!isRunning`
    // alone) before `WorkflowRunRecord.freeze` read them — the record persisted with no timeline,
    // permanently, and the switch log claimed a store re-read that could not succeed. The release
    // now requires `hasFrozenRecord`, which only `finalize()` sets, right after `freeze` returns.

    /// The flag is set SYNCHRONOUSLY inside `finalize()`, before the persist task has run —
    /// `freeze` has already copied the timelines into the record value the task encodes, so the
    /// live copy is redundant from that instant, not from when the write lands.
    func testFinalizeMarksTheRecordFrozenBeforeThePersistLands() async throws {
        let conversationID = try makeConversation()
        let registry = FakeRegistry()
        guard let ticket = WorkflowRunBootstrap.begin(
            config: BackendRequestConfig(profile: workflowProfile()),
            conversationID: conversationID, userInput: "go",
            registry: registry, origin: .chat
        ) else { return XCTFail("expected a ticket") }

        XCTAssertFalse(ticket.state.hasFrozenRecord, "nothing has been captured at begin")
        ticket.state.handleFinalOutput("done")
        XCTAssertFalse(ticket.state.hasFrozenRecord,
                       "settling the run is NOT capturing it — this is the window CF-28 is about")

        let persist = ticket.finalize()

        XCTAssertTrue(ticket.state.hasFrozenRecord,
                      "finalize must mark the record frozen before it returns, not when the write lands")
        await persist?.value
    }

    /// ⚠️ THE CF-28 SCENARIO END TO END, on the real ticket. The run has ended (`isRunning` is
    /// false), its traces are resident, and finalize has not run: the switch sweep's release must
    /// refuse and leave the timelines intact, so that `freeze` finds them and the persisted record
    /// carries every event. Only after finalize may the same call release them.
    func testTheSettledButUnfinalizedWindowKeepsTheTracesForFreeze() async throws {
        let conversationID = try makeConversation()
        let registry = FakeRegistry()
        guard let ticket = WorkflowRunBootstrap.begin(
            config: BackendRequestConfig(profile: workflowProfile()),
            conversationID: conversationID, userInput: "go",
            registry: registry, origin: .chat
        ) else { return XCTFail("expected a ticket") }

        let nodeID = UUID()
        ticket.state.nodeResults = [
            WorkflowNodeResult(id: UUID(), nodeID: nodeID, profileName: "Fetcher",
                               status: .completed, detail: "done",
                               startTime: Date(), endTime: Date())
        ]
        ticket.state.nodeTimelines[nodeID] = (0..<30).map { .thought(id: UUID(), text: "e\($0)") }
        // Mirrors `handleStreamEnd`'s success path: the run is settled, finalize is still ahead.
        ticket.state.handleFinalOutput("the report")
        XCTAssertFalse(ticket.state.isRunning, "precondition: settled — the old gate would have released")

        // The conversation-switch sweep lands inside the window.
        XCTAssertEqual(ticket.state.releaseSettledTraces(), 0,
                       "a settled-but-unfrozen run must keep its traces for freeze")
        XCTAssertEqual(ticket.state.nodeTimelines[nodeID]?.count, 30)

        await ticket.finalize()?.value

        // Freeze found the traces: the persisted record carries every event.
        let loaded = try XCTUnwrap(WorkflowRunHistoryStore.shared.load(forConversation: conversationID).first)
        XCTAssertEqual(loaded.nodeResults.first?.nodeTimeline?.count, 30,
                       "⚠️ this is the trace CF-28 lost — the sweep used to empty it before freeze read it")

        // …and now the same sweep may release the live copy, since the record has it.
        XCTAssertEqual(ticket.state.releaseSettledTraces(), 30)
        XCTAssertTrue(ticket.state.nodeTimelines.isEmpty)
    }

    /// The quit-time force path is the same `finalize()`, so it captures the traces too and the
    /// state reads as frozen afterwards.
    func testForceFinalizeMarksTheRecordFrozen() async throws {
        let conversationID = try makeConversation()
        let registry = FakeRegistry()
        guard let ticket = WorkflowRunBootstrap.begin(
            config: BackendRequestConfig(profile: workflowProfile()),
            conversationID: conversationID, userInput: "go",
            registry: registry, origin: .scheduled
        ) else { return XCTFail("expected a ticket") }
        ticket.state.handleNodeStarted(nodeID: UUID(), profileName: "Writer", index: 1, total: 1)
        XCTAssertFalse(ticket.state.hasFrozenRecord)

        WorkflowRunTicket.forceFinalizeActiveRuns(reason: "Quit during run")

        XCTAssertTrue(ticket.state.hasFrozenRecord)
        await WorkflowRunTicket.drainPendingPersists()
    }

    /// ⚠️ "Frozen" means CAPTURED, not "finalize was called". The registry-deallocated return
    /// happens before `freeze`, persists nothing, and must leave the flag false — otherwise the
    /// sweep would release traces that never reached a record.
    func testFinalizeWithoutARegistryLeavesTheRecordUnfrozen() throws {
        let conversationID = try makeConversation()
        var registry: FakeRegistry? = FakeRegistry()
        guard let ticket = WorkflowRunBootstrap.begin(
            config: BackendRequestConfig(profile: workflowProfile()),
            conversationID: conversationID, userInput: "go",
            registry: try XCTUnwrap(registry), origin: .chat
        ) else { return XCTFail("expected a ticket") }
        let nodeID = UUID()
        ticket.state.nodeTimelines[nodeID] = (0..<5).map { .thought(id: UUID(), text: "e\($0)") }
        ticket.state.handleFinalOutput("done")

        registry = nil   // the ticket holds it weakly — this is the "registry deallocated" branch
        XCTAssertNil(ticket.finalize(), "precondition: the deallocated-registry branch was taken")

        XCTAssertFalse(ticket.state.hasFrozenRecord)
        XCTAssertEqual(ticket.state.releaseSettledTraces(), 0,
                       "nothing was captured, so nothing may be released")
        XCTAssertEqual(ticket.state.nodeTimelines[nodeID]?.count, 5)
    }
}
