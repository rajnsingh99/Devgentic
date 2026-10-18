// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeProfileSingletonTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class CodeProfileSingletonTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()

        container = try ModelContainer(
            for: BackendProfile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        BackendProfileStore.shared.configureContainer(container)
        context = container.mainContext

        // ⚠️ A private suite, never `.standard`. Under the test host `UserDefaults.standard` IS the
        // shipping app's domain, so clearing the handle there would delete the developer's own
        // `devgentic.codeProfileID` — handing them the exact defect under test.
        suiteName = "CodeProfileSingletonTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        context = nil
        container = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func codeDetails(model: String) -> ProfileDetails {
        .code(AgentConfig(
            llmConfig: ProviderConfig(apiProvider: .ollama, modelName: model),
            tools: CodeToolPreset.defaultTools,
            historyStrategy: .pointer
        ))
    }

    /// Seeds directly through the context so `lastSelected` can be set explicitly — `saveProfile`
    /// stamps "now", which would defeat the ordering the adoption rule is built on.
    @discardableResult
    private func seedCodeProfile(
        model: String = "",
        lastSelected: Date = .distantPast,
        ownerWorkflow: UUID? = nil,
        ownerNode: UUID? = nil
    ) -> UUID {
        let row = BackendProfile(
            displayName: "Code Session",
            lastSelected: lastSelected,
            details: codeDetails(model: model),
            ownerWorkflowID: ownerWorkflow,
            ownerNodeID: ownerNode
        )
        context.insert(row)
        return row.id
    }

    @discardableResult
    private func seedBot(named name: String) -> UUID {
        let row = BackendProfile(
            displayName: name,
            lastSelected: Date(),
            details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .mlx, modelName: "m")))
        )
        context.insert(row)
        return row.id
    }

    private func allProfiles() throws -> [BackendProfileSnapshot] {
        try BackendProfileStore.shared.fetchProfiles()
    }

    private func sharedCodeRows() throws -> [BackendProfileSnapshot] {
        try allProfiles().filter { $0.profileType == .code && !$0.isNodeOwned }
    }

    // MARK: - The invariant

    /// ⚠️ THE ONE THAT MATTERS. A lost handle with rows still on disk is the exact state the
    /// bundle-identifier rename left behind, and it is what used to mint a duplicate.
    func testLostHandleAdoptsAnExistingRowInsteadOfCreatingADuplicate() throws {
        let older = seedCodeProfile(model: "deepseek-r1:14b", lastSelected: Date(timeIntervalSince1970: 1_000))
        let newer = seedCodeProfile(model: "deepseek-r1:32b", lastSelected: Date(timeIntervalSince1970: 2_000))

        // No handle — exactly what a wiped defaults domain leaves.
        let manager = CodeSessionManager(defaults: defaults)
        XCTAssertNil(manager.codeProfileID, "precondition: the manager starts with no handle")

        let resolved = manager.ensureCodeProfile()

        XCTAssertTrue([older, newer].contains(resolved),
                      "ensureCodeProfile minted a NEW row while code profiles existed on disk — that is the duplicate defect")
        XCTAssertEqual(try sharedCodeRows().count, 1,
                       "the store must hold exactly one code profile after adoption")
        XCTAssertEqual(try sharedCodeRows().first?.id, resolved)
    }

    /// The tie-break: the row the user actually configured wins over a bare skeleton, whatever the
    /// timestamps say. Adopting the skeleton would read as the model being silently forgotten.
    func testAConfiguredRowIsAdoptedOverAMoreRecentBareSkeleton() throws {
        let configured = seedCodeProfile(model: "deepseek-r1:32b", lastSelected: Date(timeIntervalSince1970: 1_000))
        seedCodeProfile(model: "", lastSelected: Date(timeIntervalSince1970: 9_000))

        let manager = CodeSessionManager(defaults: defaults)
        let resolved = manager.ensureCodeProfile()

        XCTAssertEqual(resolved, configured, "the skeleton was adopted over a configured row")
        XCTAssertEqual(manager.modelName, "deepseek-r1:32b",
                       "adoption must hydrate the caches, or the toolbar reads 'Select Model' for a configured session")
        XCTAssertEqual(try sharedCodeRows().count, 1)
    }

    /// Most-recently-selected wins when both rows are configured.
    func testAmongConfiguredRowsTheMostRecentlySelectedIsAdopted() throws {
        seedCodeProfile(model: "old-model", lastSelected: Date(timeIntervalSince1970: 1_000))
        let newest = seedCodeProfile(model: "new-model", lastSelected: Date(timeIntervalSince1970: 5_000))

        let manager = CodeSessionManager(defaults: defaults)

        XCTAssertEqual(manager.ensureCodeProfile(), newest)
        XCTAssertEqual(manager.modelName, "new-model")
    }

    // MARK: - What collapse must not touch

    /// ⚠️ A workflow node's private code row belongs to that node's graph. Adopting one would hand
    /// the Code interface a configuration it does not own; collapsing one would delete part of a
    /// workflow. `!isNodeOwned` is the same rule `fetchSharedProfiles()` enforces.
    func testNodeOwnedCodeRowsAreNeitherAdoptedNorCollapsed() throws {
        let nodeOwned = seedCodeProfile(
            model: "node-model",
            lastSelected: Date(timeIntervalSince1970: 9_000),
            ownerWorkflow: UUID(),
            ownerNode: UUID()
        )
        let shared = seedCodeProfile(model: "shared-model", lastSelected: Date(timeIntervalSince1970: 1_000))

        let manager = CodeSessionManager(defaults: defaults)
        let resolved = manager.ensureCodeProfile()

        XCTAssertEqual(resolved, shared, "a node-owned row was adopted as the session singleton")
        XCTAssertNotNil(try allProfiles().first { $0.id == nodeOwned },
                        "collapse deleted a workflow node's private code row")
    }

    /// Collapse is scoped to `.code`. Bots and agents share the table and must be untouched.
    func testCollapseLeavesOtherProfileTypesAlone() throws {
        seedBot(named: "Kept Bot A")
        seedBot(named: "Kept Bot B")
        seedCodeProfile(model: "a", lastSelected: Date(timeIntervalSince1970: 1_000))
        seedCodeProfile(model: "b", lastSelected: Date(timeIntervalSince1970: 2_000))

        CodeSessionManager(defaults: defaults).ensureCodeProfile()

        XCTAssertEqual(try allProfiles().filter { $0.profileType == .bot }.count, 2,
                       "collapse deleted rows outside the code type")
        XCTAssertEqual(try sharedCodeRows().count, 1)
    }

    // MARK: - Handle persistence

    /// Adoption has to WRITE the handle back, or the next launch re-adopts forever — and re-adopts
    /// are only harmless while a row survives to be found.
    func testAdoptionPersistsTheHandleSoALaterManagerRestoresIt() throws {
        let seeded = seedCodeProfile(model: "deepseek-r1:32b", lastSelected: Date())

        let first = CodeSessionManager(defaults: defaults)
        XCTAssertEqual(first.ensureCodeProfile(), seeded)

        // A second manager over the same defaults is the next launch.
        let second = CodeSessionManager(defaults: defaults)
        XCTAssertEqual(second.codeProfileID, seeded, "the adopted handle was not written back to defaults")
        XCTAssertEqual(second.modelName, "deepseek-r1:32b")
    }

    /// ⚠️ THE ONE THAT REACHES AN ALREADY-BROKEN MACHINE. A store that has accumulated duplicates
    /// still has a perfectly VALID handle — pointing at the newest row — so the adopt path that
    /// collapses them never runs. Without a reconcile on the restore path the existing orphans are
    /// permanent, and the fix would only ever help users who had not hit the bug yet.
    func testARestoredHandleStillCollapsesDuplicatesAlreadyOnDisk() throws {
        let live = seedCodeProfile(model: "deepseek-r1:32b", lastSelected: Date(timeIntervalSince1970: 9_000))
        seedCodeProfile(model: "", lastSelected: Date(timeIntervalSince1970: 1_000))
        seedCodeProfile(model: "deepseek-r1:14b", lastSelected: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(try sharedCodeRows().count, 3, "precondition: three rows, as found in the wild")

        // The handle resolves — this is a working install that merely accumulated orphans.
        defaults.set(live.uuidString, forKey: "devgentic.codeProfileID")

        let manager = CodeSessionManager(defaults: defaults)

        XCTAssertEqual(manager.codeProfileID, live, "the restored handle must keep pointing at its own row")
        XCTAssertEqual(manager.modelName, "deepseek-r1:32b", "the live session's configuration must survive the collapse")
        XCTAssertEqual(try sharedCodeRows().count, 1, "the orphans already on disk were left behind")
        XCTAssertEqual(try sharedCodeRows().first?.id, live)
    }

    func testAnEmptyStoreStillCreatesExactlyOneProfile() throws {
        let manager = CodeSessionManager(defaults: defaults)
        let created = manager.ensureCodeProfile()

        let rows = try sharedCodeRows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, created)

        // Idempotent: a second call must not add a second row.
        XCTAssertEqual(manager.ensureCodeProfile(), created)
        XCTAssertEqual(try sharedCodeRows().count, 1)
    }

    // MARK: - resetSession

    /// ⚠️ Home RESETS the singleton, never deletes it (2026-09-24). Deleting it lost every per-tool
    /// setting and MCP tool on the row; see `CodeProjectSessionTests`. Asserted here too because a
    /// delete would re-open exactly the handle-loss paths this file exists for.
    func testResetSessionKeepsTheRowAndTheHandle() throws {
        let manager = CodeSessionManager(defaults: defaults)
        let id = manager.ensureCodeProfile()

        manager.resetSession()

        XCTAssertEqual(manager.codeProfileID, id)
        XCTAssertEqual(defaults.string(forKey: "devgentic.codeProfileID"), id.uuidString)
        XCTAssertEqual(try sharedCodeRows().count, 1)
    }

    /// ⚠️ Seen on device 2026-09-24. The handle resolves lazily, so Home pressed before any Code
    /// action this launch had no handle, reset nothing, and the adoption that followed brought the
    /// row's stale folder straight back.
    func testHomeBeforeAnyCodeActionStillResetsTheRow() throws {
        var config = AgentConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "gemma"),
                                 tools: CodeToolPreset.defaultTools, historyStrategy: .pointer)
        config.projectPath = "/tmp/devgentic-tests/stale-project"
        let row = BackendProfile(displayName: "Code Session", lastSelected: Date(), details: .code(config))
        context.insert(row)

        let manager = CodeSessionManager(defaults: defaults)   // no stored handle
        manager.resetSession()
        manager.ensureCodeProfile()

        XCTAssertNil(manager.projectPath, "Home was undone — the stale folder came back on adoption")
        let stored = try XCTUnwrap(try BackendProfileStore.shared.fetchProfile(byId: row.id))
        XCTAssertNil(stored.details.agentConfig?.projectPath, "Home did not reset the row it never had a handle for")
    }

    // MARK: - The re-hydrate gate

    /// ⚠️ The re-hydrate added for unreadable launch reads must fire on an EXPLICIT flag, never on
    /// "the model cache is empty" — several paths empty that cache on purpose while the row still
    /// carries a model, and re-reading the row there silently undoes what the user just did.
    ///
    /// `updateProvider` is the reachable one: it clears the model cache without touching the row,
    /// because the user has picked a provider and not yet picked a model under it. If `ensureCodeProfile`
    /// re-hydrated on emptiness, tapping the Tools button at that moment would snap both the model and
    /// the provider back to the stored pair — a selection reverting with no warning.
    func testSwitchingProviderIsNotUndoneByALaterEnsure() throws {
        seedCodeProfile(model: "deepseek-r1:32b", lastSelected: Date())

        let manager = CodeSessionManager(defaults: defaults)
        manager.ensureCodeProfile()
        XCTAssertEqual(manager.modelName, "deepseek-r1:32b", "precondition: adoption hydrated the model")
        XCTAssertEqual(manager.provider, .ollama, "precondition: adoption hydrated the provider")

        manager.updateProvider(.anthropic)

        // Anything that needs the profile handle — the Tools button, a send — runs this.
        manager.ensureCodeProfile()

        XCTAssertEqual(manager.provider, .anthropic, "the provider the user chose was reverted by a re-hydrate")
        XCTAssertEqual(manager.modelName, "", "a stale model came back under the newly chosen provider")
    }

    /// Home keeps the model — it is the "last used" a project with no remembered model starts
    /// with — and a later ensure must not change that either way.
    func testResetKeepsTheModelAcrossALaterEnsure() throws {
        seedCodeProfile(model: "deepseek-r1:32b", lastSelected: Date())

        let manager = CodeSessionManager(defaults: defaults)
        manager.ensureCodeProfile()
        XCTAssertEqual(manager.modelName, "deepseek-r1:32b", "precondition: adoption hydrated the model")

        manager.resetSession()
        manager.ensureCodeProfile()

        XCTAssertEqual(manager.modelName, "deepseek-r1:32b")
    }
}
