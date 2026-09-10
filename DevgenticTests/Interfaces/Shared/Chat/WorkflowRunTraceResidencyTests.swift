// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  WorkflowRunTraceResidencyTests.swift
//  DevgenticTests
//
//  Register `Workflow_Production_Readiness_Fresh.md` — `XUI-11`, fixed 2026-09-02: the in-memory
//  run-history dictionary is keyed by conversation and only ever GROWS, so every workflow
//  conversation the user visits leaves up to `maxRecordsPerConversation` fully decoded records —
//  each node carrying up to 400 timeline events, tool rows holding whole outputs — resident until
//  the app quits.
//
//  The fix drops the TRACES from the in-memory mirror and re-reads them for the one run the user
//  opens; it does NOT evict conversations. Eviction is the dangerous shape: the load-once guard
//  `loadedRunHistoryConversationIDs` is a monotone Set private to a different coordinator than the
//  one that clears the dictionary, and `finalize` inserts on a miss.
//
//  ⚠️⚠️ THE DATA-LOSS DIRECTION IS THE ONE THAT MATTERS. Stripping the record that gets PERSISTED
//  instead of the mirror would silently destroy every run's debugging evidence — invisibly, and
//  worst for exactly the failed runs the traces are kept for. `testFinalizePersistsTheFullTrace…`
//  below rides the real store round-trip for that reason and must never be weakened to a mirror
//  -only assertion.
//
//  ⚠️ What is NOT covered here: the SwiftUI `.onChange` that triggers hydration and the `@State`
//  cache it fills have no headless seam. The decision they act on — `needsTraceHydration` — is
//  pure and truth-tabled below, and the fetch it calls is covered by the store round-trip.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class WorkflowRunTraceResidencyTests: XCTestCase {

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
        context.insert(ConversationSD(id: id, userDefinedTitle: "XUI-11 test"))
        try context.save()
        createdConversationIDs.append(id)
        touchedConversationIDs.append(id)
        return id
    }

    private final class FakeRegistry: WorkflowRunRegistry {
        var workflowExecutionStates: [UUID: WorkflowExecutionState] = [:]
        var workflowRunHistory: [UUID: [WorkflowRunRecord]] = [:]
        var unsavedWorkflowCanvasProfileIDs: [UUID] = []
    }

    /// ⚠️ Every field carries a DISTINCT, non-default value. The first version hard-coded
    /// `profileName: "N"` and `ranBeforeSkip: nil` for every snapshot, so an assertion on either
    /// compared a constant to itself and a mutant that dropped them survived the whole battery.
    private func snapshot(events: Int,
                          name: String = "Fetcher",
                          status: WorkflowRunRecord.WorkflowNodeResultSnapshot.NodeStatus = .completed,
                          ranBeforeSkip: Bool? = true)
        -> WorkflowRunRecord.WorkflowNodeResultSnapshot {
        WorkflowRunRecord.WorkflowNodeResultSnapshot(
            id: UUID(), nodeID: UUID(), profileName: name, status: status,
            detail: "out", duration: 1, input: "in", inputSourceLabel: "src",
            nodeTimeline: events == 0 ? nil
                : (0..<events).map { .thought(id: UUID(), text: "e\($0)") },
            hasWarnings: false, ranBeforeSkip: ranBeforeSkip
        )
    }

    private func record(_ nodes: [WorkflowRunRecord.WorkflowNodeResultSnapshot],
                        id: UUID = UUID(),
                        status: WorkflowRunRecord.RunStatus = .completed) -> WorkflowRunRecord {
        WorkflowRunRecord(
            id: id, conversationID: UUID(), workflowProfileID: UUID(), workflowName: "wf",
            timestamp: Date(timeIntervalSince1970: 0), userInput: "go", nodeResults: nodes,
            finalOutput: "answer", variables: [:], status: status, duration: 3, error: nil
        )
    }

    // MARK: - Stripping

    func testStrippingDropsEveryTimelineAndCountsWhatItDropped() {
        let full = record([snapshot(events: 400), snapshot(events: 12), snapshot(events: 0)])

        let (lean, dropped) = full.strippingNodeTimelines()

        XCTAssertEqual(dropped, 412)
        XCTAssertTrue(lean.nodeResults.allSatisfy { $0.nodeTimeline == nil })
    }

    /// ⚠️ EVERYTHING ELSE MUST SURVIVE. The mirror is what the history list, the run picker and the
    /// "N of M" badge read — status, counts, durations, the final output and the failure flags all
    /// have to be intact or the list is wrong while the traces are merely absent.
    func testStrippingChangesNothingButTheTimelines() {
        let full = record([snapshot(events: 5, name: "Alpha", status: .failed, ranBeforeSkip: false),
                           snapshot(events: 5, name: "Beta", ranBeforeSkip: true)])
        let (lean, _) = full.strippingNodeTimelines()

        XCTAssertEqual(lean.id, full.id)
        XCTAssertEqual(lean.status, full.status)
        XCTAssertEqual(lean.finalOutput, full.finalOutput)
        XCTAssertEqual(lean.duration, full.duration)
        XCTAssertEqual(lean.nodeResults.count, full.nodeResults.count)
        for (a, b) in zip(lean.nodeResults, full.nodeResults) {
            XCTAssertEqual(a.id, b.id)
            XCTAssertEqual(a.nodeID, b.nodeID)
            XCTAssertEqual(a.status, b.status)
            XCTAssertEqual(a.detail, b.detail)
            XCTAssertEqual(a.duration, b.duration)
            XCTAssertEqual(a.input, b.input)
            XCTAssertEqual(a.inputSourceLabel, b.inputSourceLabel)
            XCTAssertEqual(a.hasWarnings, b.hasWarnings)
            XCTAssertEqual(a.isGenuineFailure, b.isGenuineFailure)
            // ⚠️ These two were missing, and the fixture's constants hid it: `profileName` is the
            // node card's name on every historical run, and `ranBeforeSkip` decides "Skipped" vs
            // "Not run" — whose LEGACY fallback reads timeline emptiness, the very thing stripped.
            XCTAssertEqual(a.profileName, b.profileName)
            XCTAssertEqual(a.ranBeforeSkip, b.ranBeforeSkip)
        }
    }

    func testStrippingARecordWithNoTracesReportsNothingDropped() {
        let (lean, dropped) = record([snapshot(events: 0)]).strippingNodeTimelines()
        XCTAssertEqual(dropped, 0)
        XCTAssertEqual(lean.nodeResults.count, 1)
    }

    // MARK: - When to re-read

    func testARecordWhoseTracesWereStrippedNeedsHydration() {
        let (lean, _) = record([snapshot(events: 9)]).strippingNodeTimelines()
        XCTAssertTrue(WorkflowRunRecord.needsTraceHydration(lean, liveTimelinesAvailable: false))
    }

    func testARecordThatAlreadyHasItsTracesIsNotReRead() {
        XCTAssertFalse(WorkflowRunRecord.needsTraceHydration(record([snapshot(events: 9)]),
                                                             liveTimelinesAvailable: false))
    }

    /// ⚠️ ONE node still holding a trace is enough. `allSatisfy` rather than `contains` because a
    /// partially-hydrated record cannot occur — records are stripped whole — and re-reading a run
    /// that has ANY trace would fetch on every selection of a run whose first node simply recorded
    /// nothing.
    func testARecordWithOneRemainingTraceIsNotReRead() {
        let mixed = record([snapshot(events: 0), snapshot(events: 3)])
        XCTAssertFalse(WorkflowRunRecord.needsTraceHydration(mixed, liveTimelinesAvailable: false))
    }

    /// Traces held in memory are never re-read — re-reading would hand back the frozen snapshot and
    /// stop the timeline animating as events arrive.
    func testARunWhoseTracesAreInMemoryIsNeverReRead() {
        let (lean, _) = record([snapshot(events: 9)]).strippingNodeTimelines()
        XCTAssertFalse(WorkflowRunRecord.needsTraceHydration(lean, liveTimelinesAvailable: true))
    }

    /// ⚠️ THE XUI-15 COUPLING. This predicate used to ask "is this the LIVE run", which was the
    /// same question only until `releaseSettledTraces` began dropping a settled run's timelines
    /// while its state keeps the live slot. Identity-keyed, those runs would be skipped forever and
    /// render an empty Timeline — the same defect XUI-11's cold read caught in the earlier
    /// identity-keyed trigger. **Owning the slot is no longer evidence that the traces are there.**
    func testARunThatOwnsTheLiveSlotButHasNoTracesIsStillReRead() {
        let (lean, _) = record([snapshot(events: 9)]).strippingNodeTimelines()
        XCTAssertTrue(WorkflowRunRecord.needsTraceHydration(lean, liveTimelinesAvailable: false))
    }

    /// A `.running` record has nothing frozen on disk worth reading.
    ///
    /// ⚠️ The fixture MUST carry nodes. The first version used a zero-node stub, which the
    /// `nodeResults.isEmpty` guard one line below rejects anyway — so deleting the `.running`
    /// guard entirely left this green. A `.running` record WITH node results is reachable: the
    /// displaced-run path, where a second run steals the conversation's live slot and the older
    /// run is settled by the launch reconcile rather than by its own finalize.
    func testARunningRecordWithNodesIsStillNeverReRead() {
        let (lean, _) = record([snapshot(events: 9)], status: .running).strippingNodeTimelines()
        XCTAssertFalse(WorkflowRunRecord.needsTraceHydration(lean, liveTimelinesAvailable: false))
    }

    func testAZeroNodeRecordIsNeverReRead() {
        XCTAssertFalse(WorkflowRunRecord.needsTraceHydration(record([]), liveTimelinesAvailable: false))
    }

    // MARK: - [XUI-14] The row must not park a second full copy of the record

    /// ⚠️ THE FILED DEFECT. `apply`/`init` used to stash the record — traces included — in the
    /// row's `@Transient _cachedRecord`, and nothing ever nils it, so every run finalized in the
    /// session stayed fully resident through `ConversationSD.workflowRuns`. `XUI-11` dropped the
    /// traces from the view model's mirror and this quietly kept them.
    func testAHealthyWriteRetainsNothingInMemory() {
        let blobs = WorkflowRunRecordSD.EncodedBlobs(nodeResults: Data("[]".utf8),
                                                     variables: Data("{}".utf8))
        XCTAssertFalse(WorkflowRunRecordSD.retainsInMemoryRecord(blobs))
    }

    /// ⚠️ THE DATA-INTEGRITY DIRECTION. A refused blob leaves the PREVIOUS bytes on disk (update)
    /// or a deliberately-unreadable marker (insert), so the in-memory record is the only readable
    /// copy of the truth. Dropping it there converts a logged, recoverable refusal into silent loss.
    func testARefusedBlobKeepsTheOnlyReadableCopy() {
        for blobs in [WorkflowRunRecordSD.EncodedBlobs(nodeResults: nil, variables: Data("{}".utf8)),
                      WorkflowRunRecordSD.EncodedBlobs(nodeResults: Data("[]".utf8), variables: nil),
                      WorkflowRunRecordSD.EncodedBlobs(nodeResults: nil, variables: nil)] {
            XCTAssertTrue(WorkflowRunRecordSD.retainsInMemoryRecord(blobs))
        }
    }

    /// End-to-end on the INSERT seam: a healthy insert leaves the row holding nothing, so a later
    /// read decodes the blob instead of handing back a retained copy.
    func testAHealthyInsertLeavesTheRowHoldingNothing() {
        let full = record([snapshot(events: 40)])
        let row = WorkflowRunRecordSD(record: full)

        XCTAssertNil(row.rowSnapshot.cached,
                     "⚠️ a non-nil cache here is a second full copy of the run, for the app's life")
        XCTAssertEqual(WorkflowRunRecordSD.decodeRecord(from: row.rowSnapshot)
                        .nodeResults.first?.nodeTimeline?.count, 40,
                       "…and the traces must still be readable, from the blob")
    }

    /// The same seam with a refused blob: the row keeps the record, because the bytes cannot.
    func testAnInsertWithARefusedBlobKeepsTheRecord() {
        let full = record([snapshot(events: 40)])
        let row = WorkflowRunRecordSD(
            record: full,
            blobs: WorkflowRunRecordSD.EncodedBlobs(nodeResults: nil, variables: Data("{}".utf8)))

        XCTAssertEqual(row.rowSnapshot.cached?.id, full.id)
    }

    /// ⚠️ [CF-34] The one behaviour `decodeRecord(from:)` has that the deleted instance
    /// `decodeRecord()` never did: it hands back `snapshot.cached` WITHOUT decoding. That reads
    /// like a warm-cache optimisation and is not one — the cache is filled only when an encode was
    /// REFUSED, so the bytes in the snapshot are the previous run's (update) or the deliberately
    /// unreadable marker this insert wrote. Deleting the short-circuit would decode the marker
    /// instead and report a run whose nodes are sitting right there as having none. Nothing pinned
    /// it while the dead instance twin was still in the file to draw the eye.
    func testDecodeReturnsTheRetainedRecordRatherThanTheUnreadableBytes() {
        let full = record([snapshot(events: 12)])
        let row = WorkflowRunRecordSD(
            record: full,
            blobs: WorkflowRunRecordSD.EncodedBlobs(nodeResults: nil, variables: Data("{}".utf8)))

        let decoded = WorkflowRunRecordSD.decodeRecord(from: row.rowSnapshot)

        XCTAssertEqual(decoded.id, full.id)
        XCTAssertEqual(decoded.nodeResults.first?.nodeTimeline?.count, 12,
                       "⚠️ this row holds the ONLY readable copy of the run; decoding the refusal "
                       + "marker instead turns a logged, recoverable refusal into silent loss")
    }

    /// And the UPDATE seam, which is the one `finalize` actually takes.
    func testAHealthyUpdateClearsWhateverTheRowWasHolding() {
        let full = record([snapshot(events: 40)])
        let row = WorkflowRunRecordSD(
            record: full,
            blobs: WorkflowRunRecordSD.EncodedBlobs(nodeResults: nil, variables: nil))
        XCTAssertNotNil(row.rowSnapshot.cached, "precondition: the refused insert retained it")

        row.apply(full, blobs: WorkflowRunRecordSD.encodeBlobs(for: full))

        XCTAssertNil(row.rowSnapshot.cached,
                     "a healthy write must RELEASE a copy an earlier refusal made it keep")
    }

    // MARK: - [XUI-15] Live traces are released for conversations left behind
    //
    // ⚠️ [CF-28] "Settled" was the wrong predicate, and the fixture makes the freeze gate explicit
    // for every state it builds. `isRunning` goes false in `handleStreamEnd`, but the freeze that
    // copies the timelines into the record runs only after the stream's `await finalizeMessage`
    // and a main-queue hop — a conversation switch inside that window used to wipe the traces
    // before `WorkflowRunRecord.freeze` read them, and the record persisted with no timeline,
    // permanently. `hasFrozenRecord` is what the release now requires.

    private func liveState(runID: UUID, events: Int, running: Bool, frozen: Bool) -> WorkflowExecutionState {
        let state = WorkflowExecutionState()
        state.runRecordID = runID
        state.isRunning = running
        state.nodeTimelines[UUID()] = (0..<events).map { .thought(id: UUID(), text: "e\($0)") }
        if frozen { state.markRecordFrozen() }
        return state
    }

    /// ⚠️ THE STATE OBJECT SURVIVES. `workflowExecutionStates` is keyed by conversation and holds
    /// `runRecordID`, `isRunning` and the HITL wiring; evicting the ENTRY is the shape XUI-11
    /// rejected outright. Only the traces go, and the run view re-reads them from the store.
    func testASettledRunReleasesItsTracesAndKeepsItsIdentity() {
        let runID = UUID()
        let state = liveState(runID: runID, events: 120, running: false, frozen: true)

        XCTAssertEqual(state.releaseSettledTraces(), 120)
        XCTAssertTrue(state.nodeTimelines.isEmpty)
        XCTAssertEqual(state.runRecordID, runID)
        XCTAssertFalse(state.isRunning)
    }

    /// ⚠️ A RUN IN FLIGHT IS UNTOUCHABLE. Scheduled, ChatOps, QuickAccess and Jarvis runs continue
    /// in conversations that are not on screen, appending to their trace as they go. Dropping it
    /// mid-flight deletes the evidence of a live run and makes whatever arrives after the drop look
    /// like the whole story.
    func testARunningRunNeverReleasesItsTraces() {
        let state = liveState(runID: UUID(), events: 120, running: true, frozen: false)

        XCTAssertEqual(state.releaseSettledTraces(), 0)
        XCTAssertEqual(state.nodeTimelines.values.reduce(0) { $0 + $1.count }, 120)
    }

    /// Releasing twice reports nothing the second time, so the switch log cannot claim a saving it
    /// did not make.
    func testReleasingAnAlreadyReleasedStateReportsNothing() {
        let state = liveState(runID: UUID(), events: 40, running: false, frozen: true)
        XCTAssertEqual(state.releaseSettledTraces(), 40)
        XCTAssertEqual(state.releaseSettledTraces(), 0)
    }

    // MARK: - [CF-28] Settled is not persisted

    /// ⚠️ THE CF-28 PIN. This is the exact shape of the window: the stream has ended
    /// (`isRunning == false`), the traces are resident, and `finalize()` — the only thing that
    /// copies them into the record — has not run. A release here is not "re-read later"; the
    /// store holds only the `.running` stub, so the traces would be gone for good.
    func testASettledRunWhoseRecordIsNotYetFrozenKeepsItsTraces() {
        let state = liveState(runID: UUID(), events: 120, running: false, frozen: false)

        XCTAssertEqual(state.releaseSettledTraces(), 0,
                       "nothing may be released before the record has captured the trace")
        XCTAssertEqual(state.nodeTimelines.values.reduce(0) { $0 + $1.count }, 120,
                       "…and the timelines must be exactly as they were")
    }

    /// The same state becomes releasable the instant the record is frozen — the flag, not time,
    /// is what unlocks it.
    func testMarkingTheRecordFrozenUnlocksTheRelease() {
        let state = liveState(runID: UUID(), events: 120, running: false, frozen: false)
        XCTAssertEqual(state.releaseSettledTraces(), 0, "precondition: refused while unfrozen")

        state.markRecordFrozen()

        XCTAssertTrue(state.hasFrozenRecord)
        XCTAssertEqual(state.releaseSettledTraces(), 120)
        XCTAssertTrue(state.nodeTimelines.isEmpty)
    }

    /// ⚠️ THE CONJUNCTION CONTROL. Freezing must not override the in-flight refusal: a mutant
    /// that keeps only the `hasFrozenRecord` guard passes every test above and drops a running
    /// run's trace the moment anything marks it frozen.
    func testARunningRunNeverReleasesItsTracesEvenOnceMarkedFrozen() {
        let state = liveState(runID: UUID(), events: 120, running: true, frozen: true)

        XCTAssertEqual(state.releaseSettledTraces(), 0)
        XCTAssertEqual(state.nodeTimelines.values.reduce(0) { $0 + $1.count }, 120)
    }

    /// A fresh state has captured nothing, so nothing may be released from it.
    ///
    /// ⚠️ [CF-33] This used to also drive `reset()` back to `false` on a reused state. `reset()`
    /// has been DELETED: it had no production caller and cleared only SOME of the state's stored
    /// properties, so its first caller would have frozen the next run as `.cancelled` under the
    /// previous run's `traceID`. Every run now gets a fresh state at `WorkflowRunBootstrap.begin`,
    /// and `hasFrozenRecord` is `private(set)` with `markRecordFrozen()` as its only writer — so
    /// "unfrozen at birth" is the whole of the invariant that remains.
    ///
    /// ⚠️ The tally (how many it cleared, and which fields survived) is stated ONCE, in the
    /// tombstone that replaced `reset()` in `WorkflowExecutionState` — deliberately NOT repeated
    /// here. An earlier draft of this comment said "nine" while that tombstone said ten; ten is
    /// right (the ninth-and-tenth pair being `runRecordID` and `hasFrozenRecord`), and two copies
    /// of a hand-counted number is how the disagreement happened in the first place.
    func testAFreshStateIsNotFrozen() {
        let fresh = WorkflowExecutionState()
        XCTAssertFalse(fresh.hasFrozenRecord)
        XCTAssertEqual(fresh.releaseSettledTraces(), 0)
    }

    /// ⚠️ THE KEEP-TEST. Inverted, this frees the traces of the run the user is looking at and
    /// leaves every other conversation's resident — the exact opposite of the row — and it survived
    /// the first battery because the loop lived on a method taking a `MainApplicationViewModel`.
    func testOnlyConversationsLeftBehindAreSwept() {
        let current = UUID(), other = UUID()
        let states = [current: liveState(runID: UUID(), events: 10, running: false, frozen: true),
                      other: liveState(runID: UUID(), events: 20, running: false, frozen: true)]

        let swept = ConversationSwitchCoordinator.statesLeftBehind(in: states, keeping: current)

        XCTAssertEqual(swept.count, 1)
        XCTAssertEqual(swept.first?.nodeTimelines.values.reduce(0) { $0 + $1.count }, 20,
                       "the OTHER conversation's state is the one swept")
    }

    /// No selection means nothing is on screen, so every state is left behind.
    func testWithNoSelectionEveryStateIsSwept() {
        let states = [UUID(): liveState(runID: UUID(), events: 10, running: false, frozen: true),
                      UUID(): liveState(runID: UUID(), events: 20, running: false, frozen: true)]
        XCTAssertEqual(ConversationSwitchCoordinator.statesLeftBehind(in: states, keeping: nil).count, 2)
    }

    // MARK: - The disk-load merge (the leak itself)

    /// ⚠️ THE MUTANT THAT SURVIVED THE FIRST BATTERY. This path — first visit to a conversation —
    /// is the leak the row was filed about, and it had no test at all: the strip could be deleted
    /// from it and every other assertion stayed green. That is why the rule is a pure function.
    func testTheDiskLoadDropsEveryTraceItBringsIn() {
        let loaded = [record([snapshot(events: 400), snapshot(events: 50)]),
                      record([snapshot(events: 30)])]

        let result = ConversationSwitchCoordinator.mergeLoadedHistory(existing: [], loaded: loaded)

        XCTAssertEqual(result.merged.count, 2)
        XCTAssertEqual(result.droppedEvents, 480)
        XCTAssertTrue(result.merged.allSatisfy { $0.nodeResults.allSatisfy { $0.nodeTimeline == nil } })
        XCTAssertEqual(result.merged.map(\.id), loaded.map(\.id), "order must be preserved")
    }

    /// The pre-existing merge rule, now pinned: a run started while the decode was in flight is
    /// newer than anything on disk and must survive, keyed by id.
    func testARunStartedDuringTheLoadSurvivesTheMerge() {
        let sharedID = UUID()
        let inMemory = [record([snapshot(events: 3)], id: sharedID, status: .running)]
        let loaded = [record([snapshot(events: 9)], id: sharedID),
                      record([snapshot(events: 9)])]

        let result = ConversationSwitchCoordinator.mergeLoadedHistory(existing: inMemory, loaded: loaded)

        XCTAssertEqual(result.merged.count, 2, "the disk copy of the in-flight run must not be added")
        XCTAssertEqual(result.merged.first?.id, sharedID)
        XCTAssertEqual(result.merged.first?.status, .running,
                       "in-memory wins on id — the disk row is the stale `.running` stub's ancestor")
        XCTAssertEqual(result.merged.first?.nodeResults.first?.nodeTimeline?.count, 3,
                       "…and the in-memory row is passed through UNTOUCHED, traces and all: this "
                       + "function strips what it LOADS, never what the caller already holds")
        // ⚠️ The non-empty branch has its OWN return, and its count was unverified — the merge
        // log's "N events left on disk" clause reads from exactly this value. 9 + 9 loaded, and
        // the in-memory row's 3 must NOT be counted.
        XCTAssertEqual(result.droppedEvents, 18)
    }

    func testMergingAnEmptyLoadChangesNothing() {
        let inMemory = [record([snapshot(events: 3)])]
        let result = ConversationSwitchCoordinator.mergeLoadedHistory(existing: inMemory, loaded: [])
        XCTAssertEqual(result.merged.map(\.id), inMemory.map(\.id))
        XCTAssertEqual(result.droppedEvents, 0)
    }

    // MARK: - The store round-trip

    /// ⚠️⚠️ THE DATA-LOSS PIN, and it rides the REAL store on purpose. `finalize` strips the
    /// in-memory mirror and persists the FULL record; stripping the other one destroys every run's
    /// trace silently, and no mirror-only assertion would notice.
    func testFinalizePersistsTheFullTraceWhileTheMirrorHoldsNone() async throws {
        let conversationID = try makeConversation()
        let profile = BackendProfileSnapshot(
            id: UUID(), displayName: "Nightly", details: .workflow(WorkflowConfig(agentProfileIDs: [])))

        let registry = FakeRegistry()
        guard let ticket = WorkflowRunBootstrap.begin(
            config: BackendRequestConfig(profile: profile),
            conversationID: conversationID, userInput: "go",
            registry: registry, origin: .scheduled
        ) else { return XCTFail("a workflow profile must produce a ticket") }

        let nodeID = UUID()
        ticket.state.nodeResults = [
            WorkflowNodeResult(id: UUID(), nodeID: nodeID, profileName: "Fetcher",
                               status: .completed, detail: "done",
                               startTime: Date(), endTime: Date())
        ]
        ticket.state.nodeTimelines[nodeID] = (0..<30).map { .thought(id: UUID(), text: "e\($0)") }
        ticket.state.handleFinalOutput("the report")
        await ticket.finalize()?.value

        let mirrored = registry.workflowRunHistory[conversationID]?.first
        XCTAssertEqual(mirrored?.nodeResults.count, 1, "the list still needs its node row")
        XCTAssertNil(mirrored?.nodeResults.first?.nodeTimeline,
                     "the mirror must not hold the trace — that is the whole row")

        // ⚠️⚠️ READ THE STORED BYTES, NOT THE VALUE CACHE. The first version of this assertion
        // used `load(forConversation:)`, which returns `WorkflowRunRecordSD._cachedRecord` — the
        // very full record `apply` parked on the row moments earlier. It therefore proved nothing
        // about what reached disk: a mutant that stripped only the ENCODED blob passed it green
        // while every trace on disk was destroyed, surfacing only after a relaunch. The pin that
        // the header calls the data-loss pin has to bypass the cache, so it decodes the column.
        let context = try XCTUnwrap(WorkflowRunHistoryStore.shared.modelContainer?.mainContext)
        let runID = try XCTUnwrap(mirrored?.id)
        let row = try XCTUnwrap(
            context.fetch(FetchDescriptor<WorkflowRunRecordSD>(
                predicate: #Predicate { $0.id == runID })).first)
        let fromDisk = WorkflowRunRecordSD.decodeRecord(from: WorkflowRunRecordSD.RowSnapshot(
            cached: nil,
            id: row.id, conversationID: row.conversationID,
            workflowProfileID: row.workflowProfileID, workflowName: row.workflowName,
            timestamp: row.timestamp, userInput: row.userInput, finalOutput: row.finalOutput,
            statusRaw: row.statusRaw, duration: row.duration, errorMessage: row.errorMessage,
            nodeResultsData: row.nodeResultsData, variablesData: row.variablesData,
            traceID: row.traceID))

        XCTAssertEqual(fromDisk.nodeResults.first?.nodeTimeline?.count, 30,
                       "⚠️ THE STORED BYTES MUST KEEP EVERY EVENT — stripping the persisted record "
                       + "instead of the mirror destroys the debugging evidence of every run, "
                       + "silently, and worst for the failed runs traces exist for")

        // ⚠️ The store's ordinary read agrees. This assertion USED to be described here as "the
        // cache path … what makes a same-session reopen instant"; after XUI-14 that is false —
        // the write path no longer parks a record on the row, so this decodes the blob too. The
        // hand-built `cached: nil` snapshot above is kept anyway: it pins the disk contents even
        // if a future change starts warming the cache again, which is precisely how the earlier
        // version of this test came to prove nothing.
        let viaStore = WorkflowRunHistoryStore.shared.load(forConversation: conversationID).first
        XCTAssertEqual(viaStore?.nodeResults.first?.nodeTimeline?.count, 30)
    }

    /// The re-read the view performs when a stripped run is opened.
    func testLoadRecordReturnsTheFullTraceForOneRun() async throws {
        let conversationID = try makeConversation()
        let profile = BackendProfileSnapshot(
            id: UUID(), displayName: "Nightly", details: .workflow(WorkflowConfig(agentProfileIDs: [])))

        let registry = FakeRegistry()
        guard let ticket = WorkflowRunBootstrap.begin(
            config: BackendRequestConfig(profile: profile),
            conversationID: conversationID, userInput: "go",
            registry: registry, origin: .scheduled
        ) else { return XCTFail("a workflow profile must produce a ticket") }

        let nodeID = UUID()
        ticket.state.nodeResults = [
            WorkflowNodeResult(id: UUID(), nodeID: nodeID, profileName: "Fetcher",
                               status: .completed, detail: "done",
                               startTime: Date(), endTime: Date())
        ]
        ticket.state.nodeTimelines[nodeID] = (0..<7).map { .thought(id: UUID(), text: "e\($0)") }
        await ticket.finalize()?.value

        let mirrored = try XCTUnwrap(registry.workflowRunHistory[conversationID]?.first)
        XCTAssertTrue(WorkflowRunRecord.needsTraceHydration(mirrored, liveTimelinesAvailable: false))

        // ⚠️ This exercises the fetch, the predicate AND the blob decode. It did not always: while
        // the write path parked a full record on the row, `decodeRecord(from:)` short-circuited on
        // `snapshot.cached` and this proved only the fetch. XUI-14 stopped that retention, so a
        // same-session re-read now takes the same path a cold one does.
        let hydrated = await WorkflowRunHistoryStore.shared.loadRecord(id: mirrored.id)
        XCTAssertEqual(hydrated?.id, mirrored.id)
        XCTAssertEqual(hydrated?.nodeResults.first?.nodeTimeline?.count, 7)
        XCTAssertFalse(WorkflowRunRecord.needsTraceHydration(try XCTUnwrap(hydrated),
                                                             liveTimelinesAvailable: false),
                       "the hydrated copy must not ask to be re-read again")
    }

    /// A run whose row is gone returns nil rather than throwing — the caller keeps what it has.
    func testLoadRecordReturnsNilForAnUnknownRun() async {
        let missing = await WorkflowRunHistoryStore.shared.loadRecord(id: UUID())
        XCTAssertNil(missing)
    }
}
