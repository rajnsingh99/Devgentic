//
//  NodeOwnedProfileLifecycleTests.swift
//  DevgenticTests
//
//  Created on 29/08/26.
//
//  Phase 3 of node-owned workflow configuration: when a node's private profile row is collected.
//
//  ⚠️ The central rule under test is that collection happens at SAVE time, never on node delete.
//  Canvas undo restores deleted nodes, so deleting the row when the node disappeared would let Undo
//  resurrect a node whose configuration is gone — and the executor refuses the whole run over a
//  missing profile.
//

import XCTest
@testable import devgentic

@MainActor
final class NodeOwnedProfileLifecycleTests: XCTestCase {

    // MARK: - Harness

    private final class InMemoryStore: BackendProfileStoreProtocol {
        var profiles: [BackendProfileSnapshot] = []
        /// Ids passed to `deleteProfile`, in order — the credential cascade rides on this call.
        private(set) var deleted: [UUID] = []
        /// When non-nil, `deleteProfile` throws for this id (a partial-failure simulation).
        var failDeleteFor: UUID?
        /// When true, `fetchProfiles` throws — the store hiccup the cascade must survive safely.
        var failFetch = false

        func fetchProfiles() throws -> [BackendProfileSnapshot] {
            if failFetch { throw ProfileStoreError.containerNotConfigured }
            return profiles
        }
        func fetchProfile(byId id: UUID) throws -> BackendProfileSnapshot? {
            profiles.first { $0.id == id }
        }
        func saveProfile(_ snapshot: BackendProfileSnapshot,
                         callerFile: String, callerFunction: String, callerLine: Int) throws -> [ProfileValidationError] {
            if let i = profiles.firstIndex(where: { $0.id == snapshot.id }) { profiles[i] = snapshot }
            else { profiles.append(snapshot) }
            return []
        }
        func deleteProfile(withId id: UUID) throws {
            if id == failDeleteFor { throw ProfileStoreError.containerNotConfigured }
            deleted.append(id)
            profiles.removeAll { $0.id == id }
        }
    }

    private let workflowID = UUID()

    private func ownedRow(_ name: String, workflow: UUID, node: UUID) -> BackendProfileSnapshot {
        BackendProfileSnapshot(
            displayName: name,
            details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .mlx, modelName: "m"))),
            ownerWorkflowID: workflow,
            ownerNodeID: node
        )
    }

    private func sharedRow(_ name: String) -> BackendProfileSnapshot {
        BackendProfileSnapshot(
            displayName: name,
            details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .mlx, modelName: "m")))
        )
    }

    private func service(_ store: InMemoryStore) -> BackendProfileService {
        BackendProfileService(store: store)
    }

    // MARK: - Reconcile

    /// A node still on the saved canvas keeps its configuration. The obvious case, and the one that
    /// makes every other assertion here meaningful.
    func testReconcileKeepsRowsThatANodeStillReferences() {
        let liveNode = UUID()
        let store = InMemoryStore()
        let row = ownedRow("Live", workflow: workflowID, node: liveNode)
        store.profiles = [row]

        let collected = service(store).reconcileOwnedProfiles(
            forWorkflow: workflowID, referencedProfileIDs: [row.id])

        XCTAssertEqual(collected, 0)
        XCTAssertEqual(store.deleted, [], "a node that survived the save must keep its configuration")
    }

    /// THE COLLECTION. A node deleted and then SAVED is past the point Undo could bring it back, so
    /// its row and its stored credential go.
    func testReconcileCollectsRowsWhoseNodeIsGoneFromTheSavedCanvas() {
        let goneNode = UUID(), liveNode = UUID()
        let store = InMemoryStore()
        let orphan = ownedRow("Deleted Node", workflow: workflowID, node: goneNode)
        let live = ownedRow("Live", workflow: workflowID, node: liveNode)
        store.profiles = [orphan, live]

        let collected = service(store).reconcileOwnedProfiles(
            forWorkflow: workflowID, referencedProfileIDs: [live.id])

        XCTAssertEqual(collected, 1)
        XCTAssertEqual(store.deleted, [orphan.id],
                       "collection goes through deleteProfile so the Keychain entry goes with the row")
        XCTAssertFalse(store.profiles.contains { $0.id == orphan.id })
    }

    /// ⚠️ SCOPED TO ONE WORKFLOW. Another workflow's nodes are not in `liveNodeIDs`, and treating
    /// absence as death would delete every other workflow's configuration on any save.
    func testReconcileNeverTouchesAnotherWorkflowsOwnedRows() {
        let otherWorkflow = UUID(), otherNode = UUID()
        let store = InMemoryStore()
        let foreign = ownedRow("Someone Else's", workflow: otherWorkflow, node: otherNode)
        store.profiles = [foreign]

        let collected = service(store).reconcileOwnedProfiles(
            forWorkflow: workflowID, referencedProfileIDs: [])

        XCTAssertEqual(collected, 0)
        XCTAssertEqual(store.deleted, [], "a row belonging to another workflow is not this save's business")
        XCTAssertTrue(store.profiles.contains { $0.id == foreign.id })
    }

    /// ⚠️ SHARED PROFILES ARE NOT COLLECTIBLE. They have no `ownerNodeID`, so no node's absence can
    /// ever justify deleting one — this is the guard against the reconcile eating the user's library.
    func testReconcileNeverCollectsSharedProfiles() {
        let store = InMemoryStore()
        let shared = sharedRow("My Chat Agent")
        store.profiles = [shared]

        let collected = service(store).reconcileOwnedProfiles(
            forWorkflow: workflowID, referencedProfileIDs: [])

        XCTAssertEqual(collected, 0)
        XCTAssertTrue(store.profiles.contains { $0.id == shared.id })
    }

    /// An emptied canvas collects every one of its rows — and only its own.
    func testReconcileOnAnEmptiedCanvasCollectsAllOfThatWorkflowsRows() {
        let store = InMemoryStore()
        let a = ownedRow("A", workflow: workflowID, node: UUID())
        let b = ownedRow("B", workflow: workflowID, node: UUID())
        let foreign = ownedRow("Foreign", workflow: UUID(), node: UUID())
        let shared = sharedRow("Library")
        store.profiles = [a, b, foreign, shared]

        let collected = service(store).reconcileOwnedProfiles(
            forWorkflow: workflowID, referencedProfileIDs: [])

        XCTAssertEqual(collected, 2)
        XCTAssertEqual(Set(store.deleted), Set([a.id, b.id]))
        XCTAssertEqual(Set(store.profiles.map(\.id)), Set([foreign.id, shared.id]))
    }

    /// A failed delete must not abort the sweep or over-report. The survivor is retried on the next
    /// successful save, which is what the log line promises.
    func testReconcileContinuesAfterAFailedDeleteAndReportsOnlyWhatItCollected() {
        let store = InMemoryStore()
        let doomed = ownedRow("Doomed", workflow: workflowID, node: UUID())
        let stubborn = ownedRow("Stubborn", workflow: workflowID, node: UUID())
        store.profiles = [stubborn, doomed]
        store.failDeleteFor = stubborn.id

        let collected = service(store).reconcileOwnedProfiles(
            forWorkflow: workflowID, referencedProfileIDs: [])

        XCTAssertEqual(collected, 1, "only the row that actually went may be counted")
        XCTAssertEqual(store.deleted, [doomed.id], "the sweep continued past the failure")
        XCTAssertTrue(store.profiles.contains { $0.id == stubborn.id })
    }

    /// ⚠️ THE LEAK PHASE 6 EXPOSED, and the reason survival is keyed on being REFERENCED rather
    /// than on the owner node existing. The ownership migration creates a row and then repoints its
    /// node; if the repoint fails to persist, the row's `ownerNodeID` still names a LIVE node — so
    /// an owner-based sweep would never collect it, and the next migration pass would mint another.
    func testReconcileCollectsARowWhoseOwnerNodeIsAliveButPointsElsewhere() {
        let node = UUID()
        let store = InMemoryStore()
        let stranded = ownedRow("Stranded By A Failed Repoint", workflow: workflowID, node: node)
        let actual = ownedRow("What The Node Actually Points At", workflow: workflowID, node: node)
        store.profiles = [stranded, actual]

        // The node exists and is the owner named by BOTH rows, but references only one.
        let collected = service(store).reconcileOwnedProfiles(
            forWorkflow: workflowID, referencedProfileIDs: [actual.id])

        XCTAssertEqual(collected, 1)
        XCTAssertEqual(store.deleted, [stranded.id],
                       "a live owner node is not enough — the row must actually be referenced")
        XCTAssertTrue(store.profiles.contains { $0.id == actual.id })
    }

    /// ⚠️ A FETCH FAILURE MUST ABORT THE WHOLE DELETE. This was `try?` with no log: the cascade was
    /// skipped silently and the workflow deleted anyway, stranding every node-configuration row and
    /// its Keychain credential with nothing left that could ever find them — the rows are hidden
    /// from every picker, the layout naming their nodes is deleted moments later, and the reconcile
    /// only ever runs for a LIVE workflow id.
    func testAFetchFailureAbortsTheWorkflowDeleteInsteadOfStrandingItsRows() {
        let store = InMemoryStore()
        let workflow = BackendProfileSnapshot(
            id: workflowID, displayName: "W",
            details: .workflow(WorkflowConfig(agentProfileIDs: [])))
        let owned = ownedRow("Node", workflow: workflowID, node: UUID())
        store.profiles = [workflow, owned]
        store.failFetch = true

        XCTAssertThrowsError(try service(store).deleteProfile(withId: workflowID),
                             "a cascade that cannot enumerate what it must delete has to abort")

        XCTAssertEqual(store.deleted, [], "nothing may be deleted — not even the workflow itself")
        XCTAssertTrue(store.profiles.contains { $0.id == workflowID },
                      "the workflow must survive so a retry can finish the job")
        XCTAssertTrue(store.profiles.contains { $0.id == owned.id },
                      "and its node's row must still be reachable through that workflow")
    }

    // MARK: - The retired agentProfileIDs list (Phase 4)

    /// ⚠️ THE REGRESSION PHASE 4 EXISTS TO PREVENT. `WorkflowConfig.agentProfileIDs` is no longer
    /// recomputed, so it is empty (or stale) forever. While a BLOCKING validator rule keyed on that
    /// emptiness, `BackendProfileStore` validating `strict: isUpdate` meant every UPDATE of a
    /// workflow threw — including a rename, which is the most ordinary edit there is.
    ///
    /// Asserted through the real `ProfileValidator` rather than a double, because the rule and the
    /// strictness live on opposite sides of the store boundary and only their COMBINATION broke.
    func testAWorkflowWithNoAgentListIsStillValidUnderStrictValidation() {
        let workflow = BackendProfileSnapshot(
            displayName: "Renamed Workflow",
            details: .workflow(WorkflowConfig(agentProfileIDs: []))
        )

        let errors = ProfileValidator.validate(workflow, strict: true)

        XCTAssertTrue(errors.blocking.isEmpty,
                      "an empty agentProfileIDs must not block an update — it would make every "
                      + "workflow permanently unsaveable, renames included. Got: "
                      + "\(errors.blocking.map(\.message))")
    }

    /// The service-level shape of the same scenario: a workflow whose canvas is entirely structural
    /// nodes (Routers, Code, Gates) references no profiles at all, and must still save and rename.
    ///
    /// ⚠️ NOT a guard on the validator rule — verified by mutation: reinstating the rule leaves this
    /// test GREEN, because `InMemoryStore` does not run `ProfileValidator` (the real store does).
    /// `testAWorkflowWithNoAgentListIsStillValidUnderStrictValidation` above is the test that
    /// actually catches that regression. This one covers the save/rename path itself.
    func testAStructuralOnlyWorkflowSavesAndRenames() throws {
        let store = InMemoryStore()
        let svc = service(store)
        var workflow = BackendProfileSnapshot(
            id: workflowID, displayName: "Structural Only",
            details: .workflow(WorkflowConfig(agentProfileIDs: []))
        )
        _ = try svc.saveProfile(workflow)

        workflow.displayName = "Structural Only (renamed)"
        XCTAssertNoThrow(try svc.saveProfile(workflow),
                         "renaming a workflow with no profile nodes must succeed")
        XCTAssertEqual(store.profiles.first { $0.id == workflowID }?.displayName,
                       "Structural Only (renamed)")
    }

    // MARK: - Delete cascade

    /// Deleting a workflow takes its nodes' private rows with it. Nothing else could ever find them:
    /// they are hidden from every picker and the layout naming their nodes is deleted too.
    func testDeletingAWorkflowCascadesToItsNodeOwnedRows() throws {
        let store = InMemoryStore()
        let workflow = BackendProfileSnapshot(
            id: workflowID, displayName: "My Workflow",
            details: .workflow(WorkflowConfig(agentProfileIDs: [])))
        let owned = ownedRow("Node Config", workflow: workflowID, node: UUID())
        let foreign = ownedRow("Other Workflow's", workflow: UUID(), node: UUID())
        let shared = sharedRow("Library")
        store.profiles = [workflow, owned, foreign, shared]

        try service(store).deleteProfile(withId: workflowID)

        XCTAssertTrue(store.deleted.contains(owned.id), "the workflow's own node rows go with it")
        XCTAssertTrue(store.deleted.contains(workflowID))
        XCTAssertEqual(Set(store.profiles.map(\.id)), Set([foreign.id, shared.id]),
                       "another workflow's rows and the shared library are untouched")
    }

    /// ⚠️ ORDER: the owned rows go FIRST, so a failure partway leaves the workflow itself intact and
    /// the next attempt can finish the job.
    func testTheCascadeDeletesOwnedRowsBeforeTheWorkflowItself() throws {
        let store = InMemoryStore()
        let workflow = BackendProfileSnapshot(
            id: workflowID, displayName: "W",
            details: .workflow(WorkflowConfig(agentProfileIDs: [])))
        let owned = ownedRow("Node", workflow: workflowID, node: UUID())
        store.profiles = [workflow, owned]

        try service(store).deleteProfile(withId: workflowID)

        XCTAssertEqual(store.deleted, [owned.id, workflowID])
    }

    /// Deleting an ordinary profile must not sweep anything — and an owned row owns nothing itself,
    /// so the cascade cannot recurse.
    func testDeletingASharedProfileCascadesToNothing() throws {
        let store = InMemoryStore()
        let shared = sharedRow("Just A Profile")
        let owned = ownedRow("Unrelated", workflow: workflowID, node: UUID())
        store.profiles = [shared, owned]

        try service(store).deleteProfile(withId: shared.id)

        XCTAssertEqual(store.deleted, [shared.id])
        XCTAssertTrue(store.profiles.contains { $0.id == owned.id })
    }
}
