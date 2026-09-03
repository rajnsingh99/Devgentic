//
//  ProfileFetchWindowTests.swift
//  DevgenticTests
//
//  Created on 31/08/26.
//
//  The 500-row fetch window versus node-owned profile rows.
//
//  ⚠️ `fetchProfiles()` caps at 500 rows sorted by `lastSelected` descending. That was a safe UI
//  bound while the table held only profiles the user deliberately created; node-owned configuration
//  makes it hold one row per bot/agent NODE across every workflow, so the table scales with graph
//  size and the window becomes a cliff. Past it, three things failed silently: the save-time
//  reconcile stopped collecting, the workflow-delete cascade orphaned rows and credentials, and —
//  worst — the executor's profile map went short, so pre-flight reported nodes as "Profile not
//  found" and refused ENTIRE runs over rows sitting on disk.
//
//  The fix is query-level predicates (`fetchOwnedProfiles`, `fetchProfiles(ids:)`, and a
//  shared-only predicate under the picker cap). These tests seed PAST the cap against a real
//  in-memory container, so the truncation is what they actually reproduce — a sub-cap fixture
//  would pass against the broken code.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class ProfileFetchWindowTests: XCTestCase {

    private let workflowID = UUID()

    private func makeStore() throws -> ModelContainer {
        let container = try ModelContainer(
            for: BackendProfile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        BackendProfileStore.shared.configureContainer(container)
        return container
    }

    /// Seeds directly through a context so `lastSelected` can be set explicitly — `saveProfile`
    /// stamps "now", which would defeat the aging this file exists to test.
    private func seed(
        _ context: ModelContext, name: String, lastSelected: Date,
        ownerWorkflow: UUID? = nil, ownerNode: UUID? = nil
    ) -> UUID {
        let row = BackendProfile(
            displayName: name,
            lastSelected: lastSelected,
            details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .mlx, modelName: "m"))),
            ownerWorkflowID: ownerWorkflow,
            ownerNodeID: ownerNode
        )
        context.insert(row)
        return row.id
    }

    /// ⚠️ THE RECONCILE/CASCADE HALF. An owned row older than the 500 most-recently-touched rows
    /// must still be found — under the old filter-after-fetch shape it was invisible, so its
    /// node's configuration was never collected and workflow deletion orphaned it forever.
    func testOwnedRowsAgedPastTheWindowAreStillFound() throws {
        let container = try makeStore()
        let context = ModelContext(container)

        // The owned rows are the OLDEST rows in the table...
        let ancient = Date(timeIntervalSinceNow: -86_400 * 365)
        let ownedIDs = (0..<5).map { i in
            seed(context, name: "Node \(i)", lastSelected: ancient,
                 ownerWorkflow: workflowID, ownerNode: UUID())
        }
        // ...buried under 510 fresher shared rows, so they are strictly outside the 500 window.
        for i in 0..<510 {
            _ = seed(context, name: "Shared \(i)", lastSelected: Date(timeIntervalSinceNow: -Double(i)))
        }
        try context.save()

        let found = try BackendProfileStore.shared.fetchOwnedProfiles(forWorkflow: workflowID)

        XCTAssertEqual(Set(found.map(\.id)), Set(ownedIDs),
                       "every owned row must be found regardless of age — the reconcile and the "
                       + "delete cascade both enumerate through this")
    }

    /// ⚠️ THE RUN-BLOCKING HALF. The executor resolves a run's profile map by ids; a node row aged
    /// past the window used to come back missing, and pre-flight refused the whole run.
    func testByIdsFetchIgnoresTheWindowEntirely() throws {
        let container = try makeStore()
        let context = ModelContext(container)

        let ancient = Date(timeIntervalSinceNow: -86_400 * 365)
        let nodeRowID = seed(context, name: "Aged Node Row", lastSelected: ancient,
                             ownerWorkflow: workflowID, ownerNode: UUID())
        for i in 0..<510 {
            _ = seed(context, name: "Shared \(i)", lastSelected: Date(timeIntervalSinceNow: -Double(i)))
        }
        try context.save()

        // Precondition that makes this test meaningful: the row genuinely is outside the window.
        let windowed = try BackendProfileStore.shared.fetchProfiles()
        XCTAssertFalse(windowed.contains { $0.id == nodeRowID },
                       "precondition: the aged row must be OUTSIDE the capped global fetch — "
                       + "otherwise this test would pass against the broken code")

        let resolved = try BackendProfileStore.shared.fetchProfiles(ids: [nodeRowID])
        XCTAssertEqual(resolved.map(\.id), [nodeRowID],
                       "the executor's map must resolve a row the capped fetch cannot see — "
                       + "this is the difference between a run and a false 'Profile not found'")
    }

    /// ⚠️ THE PICKER HALF, in the OTHER direction: owned rows must not consume the shared window.
    /// 510 owned rows fresher than everything else used to push the user's real library out of the
    /// 500 most-recently-touched rows — profiles vanishing from pickers while existing on disk.
    func testOwnedRowsCannotCrowdSharedProfilesOutOfThePickerWindow() throws {
        let container = try makeStore()
        let context = ModelContext(container)

        let sharedID = seed(context, name: "My Real Profile",
                            lastSelected: Date(timeIntervalSinceNow: -86_400 * 30))
        for i in 0..<510 {
            _ = seed(context, name: "Node \(i)", lastSelected: Date(timeIntervalSinceNow: -Double(i)),
                     ownerWorkflow: workflowID, ownerNode: UUID())
        }
        try context.save()

        let shared = try BackendProfileStore.shared.fetchSharedProfiles()

        XCTAssertTrue(shared.contains { $0.id == sharedID },
                      "the user's profile must stay in the picker however many node rows exist — "
                      + "the 500 window must count only SHARED profiles")
        XCTAssertFalse(shared.contains { $0.isNodeOwned },
                       "and no owned row may appear in it")
    }

    /// The cap itself must survive on the picker path — it is a genuine UI bound, and removing it
    /// wholesale would trade the cliff for unbounded picker lists.
    func testTheSharedPickerWindowIsStillCapped() throws {
        let container = try makeStore()
        let context = ModelContext(container)
        for i in 0..<520 {
            _ = seed(context, name: "Shared \(i)", lastSelected: Date(timeIntervalSinceNow: -Double(i)))
        }
        try context.save()

        XCTAssertEqual(try BackendProfileStore.shared.fetchSharedProfiles().count, 500,
                       "the picker bound stays — only its accounting changed")
    }
}
