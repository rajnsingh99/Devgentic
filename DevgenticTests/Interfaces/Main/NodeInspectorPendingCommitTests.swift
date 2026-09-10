// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  NodeInspectorPendingCommitTests.swift
//  DevgenticTests
//
//  Created on 31/08/26.
//
//  Phase 2 of node-owned configuration (option C): a panel close that bypasses Done COMMITS the
//  profile inspector's buffered edits; Cancel is the one explicit discard.
//
//  ⚠️ Tested at the hook + commit-function level per the WF-CU9 doctrine — the panel itself is an
//  AppKit `NSPanel` needing a real window server, so everything decidable lives in state that does
//  not. The three fire sites (node-gone, supersede, canvas teardown) and the Done/Cancel clears are
//  one-liners at call sites this harness cannot mount; the SEMANTICS they rely on are all here.
//

import XCTest
@testable import devgentic

@MainActor
final class NodeInspectorPendingCommitTests: XCTestCase {

    // MARK: - Hook semantics

    /// The core contract: a registered commit fires exactly once, however many close routes run.
    func testCommitFiresExactlyOncePerRegistration() {
        let hook = NodeInspectorPendingCommit()
        var fired = 0
        hook.register { fired += 1 }

        hook.commitAndClear()
        hook.commitAndClear()   // a second close route (supersede during teardown) must no-op

        XCTAssertEqual(fired, 1, "one registration, one commit — a double fire is a double save")
        XCTAssertFalse(hook.hasPendingRegistration)
    }

    /// ⚠️ Done and Cancel clear BEFORE closing: Done already saved (a second save is the redundant
    /// write that bumps `lastSelected`), and Cancel is the user explicitly discarding — the hook
    /// firing on their close would overrule both.
    func testClearPreventsTheSubsequentCloseFromCommitting() {
        let hook = NodeInspectorPendingCommit()
        var fired = 0
        hook.register { fired += 1 }

        hook.clear()            // Done or Cancel
        hook.commitAndClear()   // the close they trigger

        XCTAssertEqual(fired, 0, "after Done/Cancel the close routes must find nothing to commit")
    }

    /// Re-entrancy: a commit closure that itself triggers another close must not recurse — the
    /// hook clears BEFORE firing.
    func testAReentrantCloseInsideTheCommitIsANoOp() {
        let hook = NodeInspectorPendingCommit()
        var fired = 0
        hook.register {
            fired += 1
            hook.commitAndClear()
        }
        hook.commitAndClear()
        XCTAssertEqual(fired, 1)
    }

    /// One panel, last writer wins — a superseding inspector's registration replaces the old one
    /// (whose buffer the supersede fire site has already committed).
    func testASecondRegistrationReplacesTheFirst() {
        let hook = NodeInspectorPendingCommit()
        var first = 0, second = 0
        hook.register { first += 1 }
        hook.register { second += 1 }

        hook.commitAndClear()

        XCTAssertEqual(first, 0)
        XCTAssertEqual(second, 1)
    }

    // MARK: - The commit itself

    private final class InMemoryStore: BackendProfileStoreProtocol {
        var profiles: [BackendProfileSnapshot] = []
        var failSave = false
        private(set) var saveCount = 0
        func fetchProfiles() throws -> [BackendProfileSnapshot] { profiles }
        func fetchProfile(byId id: UUID) throws -> BackendProfileSnapshot? {
            profiles.first { $0.id == id }
        }
        func saveProfile(_ snapshot: BackendProfileSnapshot,
                         callerFile: String, callerFunction: String, callerLine: Int) throws -> [ProfileValidationError] {
            if failSave { throw ProfileStoreError.containerNotConfigured }
            saveCount += 1
            if let i = profiles.firstIndex(where: { $0.id == snapshot.id }) { profiles[i] = snapshot }
            else { profiles.append(snapshot) }
            return []
        }
        func deleteProfile(withId id: UUID) throws { profiles.removeAll { $0.id == id } }
    }

    private func makeBuffer(_ store: InMemoryStore) -> (ProfileEditBuffer, BackendProfileService) {
        let profile = BackendProfileSnapshot(
            displayName: "Node Config",
            details: .agent(AgentConfig(
                llmConfig: ProviderConfig(apiProvider: .mlx, modelName: "m"),
                tools: [], instructions: "Original."))
        )
        store.profiles = [profile]
        let service = BackendProfileService(store: store)
        return (ProfileEditBuffer(profile: profile), service)
    }

    private func edit(_ buffer: ProfileEditBuffer, instructions: String) {
        guard case .agent(var config) = buffer.draft.details else { return XCTFail("expected agent") }
        config.instructions = instructions
        buffer.draft.details = .agent(config)
    }

    /// THE COMMIT. A dirty buffer is saved, marked clean, and the edit survives in the store —
    /// what the user typed before pressing Run is what the node runs with.
    func testADirtyBufferIsPersistedAndMarkedClean() {
        let store = InMemoryStore()
        let (buffer, service) = makeBuffer(store)
        edit(buffer, instructions: "Typed just before pressing Run.")
        XCTAssertTrue(buffer.isDirty, "precondition")

        let committed = ProfileNodeInspectorView.commitBufferedEdits(
            buffer, service: service, nodeDisplayName: "Agent")

        XCTAssertTrue(committed)
        XCTAssertFalse(buffer.isDirty, "markSaved must run, or the next close commits again")
        guard case .agent(let config) = store.profiles.first!.details else { return XCTFail() }
        XCTAssertEqual(config.instructions, "Typed just before pressing Run.")
    }

    /// A clean buffer writes NOTHING — an untouched inspector closing must not cost a store write
    /// and a `lastSelected` bump (the redundant-save regression, from a new direction).
    func testACleanBufferCommitsNothing() {
        let store = InMemoryStore()
        let (buffer, service) = makeBuffer(store)

        let committed = ProfileNodeInspectorView.commitBufferedEdits(
            buffer, service: service, nodeDisplayName: "Agent")

        XCTAssertFalse(committed)
        XCTAssertEqual(store.saveCount, 0, "no edit, no write")
    }

    /// A refused save must not crash a teardown (there is no UI left to complain in) and must not
    /// mark the buffer clean — the loss is logged, not laundered.
    func testARefusedSaveIsSurvivedAndTheBufferStaysDirty() {
        let store = InMemoryStore()
        let (buffer, service) = makeBuffer(store)
        edit(buffer, instructions: "Doomed.")
        store.failSave = true

        let committed = ProfileNodeInspectorView.commitBufferedEdits(
            buffer, service: service, nodeDisplayName: "Agent")

        XCTAssertFalse(committed)
        XCTAssertTrue(buffer.isDirty, "a failed save must not pretend it saved")
    }
}
