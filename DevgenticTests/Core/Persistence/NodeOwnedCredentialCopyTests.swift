// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  NodeOwnedCredentialCopyTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class NodeOwnedCredentialCopyTests: XCTestCase {

    private let sentinel = "sk-ant-NODEOWNED-TESTKEY-0123456789"
    private var createdProfileIDs: [UUID] = []
    private let workflowID = UUID()

    override func setUp() {
        super.setUp()
        // ⚠️ KC-63: the in-memory Keychain is ONE dictionary for the whole process. Starting every
        // test from an empty store is what keeps results here independent of execution order —
        // see the deliberate-leak pair at the bottom of this file, which fails without this wipe.
        TestHostKeychain.shared.removeAll()
    }

    override func tearDown() {
        for id in createdProfileIDs { ProviderKeyStore.delete(for: id) }
        createdProfileIDs = []
        // The explicit per-profile deletes above are the polite cleanup; this wipe is the
        // guarantee — nothing this class wrote outlives the class, whatever threw in between.
        TestHostKeychain.shared.removeAll()
        super.tearDown()
    }

    private func makeStore() throws -> ModelContainer {
        let container = try ModelContainer(
            for: BackendProfile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        BackendProfileStore.shared.configureContainer(container)
        return container
    }

    /// A shared cloud profile, persisted through the real store so its key lands in the Keychain
    /// under its own id — the state a user's library is actually in before they import.
    ///
    /// ⚠️ OpenAI-COMPATIBLE on purpose: since 2026-10-03 it is the cloud provider whose key is still
    /// stored per profile, which is the copy-under-its-own-identity behaviour pinned here. An
    /// Anthropic node needs no copy at all — every profile on Anthropic reads the one shared key.
    @discardableResult
    private func seedCloudSource(named name: String = "Cloud Researcher") throws -> BackendProfileModel {
        let source = BackendProfileSnapshot(
            displayName: name,
            details: .agent(AgentConfig(
                llmConfig: ProviderConfig(apiProvider: .openAICompatible, modelName: "local-model", apiKey: sentinel,
                                          baseURL: "https://llm.example.test/v1"),
                tools: [],
                instructions: "Research things."
            ))
        )
        createdProfileIDs.append(source.id)
        _ = try BackendProfileStore.shared.saveProfile(source)
        return source
    }

    /// Re-reads a row the way the app does, so the assertion runs against a DECODED snapshot rather
    /// than the in-memory value that was just written.
    private func refetch(_ id: UUID) throws -> BackendProfileModel? {
        try BackendProfileStore.shared.fetchProfile(byId: id)
    }

    // MARK: - The chain

    /// ⚠️ THE WHOLE POINT. Import a cloud profile, persist the owned row, then re-read it: the key
    /// must come back. This is what makes an imported cloud node runnable.
    func testAnImportedCloudNodeCanStillReadItsCredentialAfterARoundTrip() throws {
        _ = try makeStore()
        let source = try seedCloudSource()

        // The source as the app hands it to the factory: fetched, with the key re-injected.
        let fetchedSource = try XCTUnwrap(refetch(source.id))
        XCTAssertEqual(fetchedSource.details.providerAPIKey, sentinel,
                       "precondition: a fetched cloud profile carries its key in memory")

        let owned = WorkflowNodeProfileFactory.importedProfile(
            from: fetchedSource, workflowID: workflowID, nodeID: UUID())
        createdProfileIDs.append(owned.id)
        _ = try BackendProfileStore.shared.saveProfile(owned)

        let storedCopy = try XCTUnwrap(refetch(owned.id))
        XCTAssertEqual(storedCopy.details.providerAPIKey, sentinel,
                       "the imported node's credential must survive save + re-read, or every "
                       + "imported cloud node is unrunnable")
        XCTAssertTrue(storedCopy.isNodeOwned)
    }

    /// The key must live in the Keychain under the COPY's own uuid — not be shared with, or read
    /// through, the source. Anything else re-couples the two rows the import exists to separate.
    func testTheCopiedKeyIsStoredUnderTheCopysOwnIdentity() throws {
        _ = try makeStore()
        let source = try seedCloudSource()
        let owned = WorkflowNodeProfileFactory.importedProfile(
            from: try XCTUnwrap(refetch(source.id)), workflowID: workflowID, nodeID: UUID())
        createdProfileIDs.append(owned.id)
        _ = try BackendProfileStore.shared.saveProfile(owned)

        guard case .found(let copyKey) = ProviderKeyStore.read(for: owned.id) else {
            return XCTFail("no Keychain item under the copy's own id — the copy has no credential")
        }
        XCTAssertEqual(copyKey, sentinel)

        guard case .found(let sourceKey) = ProviderKeyStore.read(for: source.id) else {
            return XCTFail("the SOURCE lost its key — importing must not move it")
        }
        XCTAssertEqual(sourceKey, sentinel, "the source profile must be left exactly as it was")
    }

    /// ⚠️ The invariant the whole Keychain seam exists for, restated for owned rows: an imported
    /// node's credential must not appear in `configData`. Owned rows live in the same unsandboxed
    /// store as every other profile.
    func testTheImportedRowsBlobDoesNotContainTheKey() throws {
        let container = try makeStore()
        let source = try seedCloudSource()
        let owned = WorkflowNodeProfileFactory.importedProfile(
            from: try XCTUnwrap(refetch(source.id)), workflowID: workflowID, nodeID: UUID())
        createdProfileIDs.append(owned.id)
        _ = try BackendProfileStore.shared.saveProfile(owned)

        let ownedID = owned.id
        let rows = try ModelContext(container).fetch(
            FetchDescriptor<BackendProfile>(predicate: #Predicate { $0.id == ownedID }))
        let row = try XCTUnwrap(rows.first)
        let blob = String(data: row.configData, encoding: .utf8) ?? ""

        XCTAssertFalse(blob.contains(sentinel),
                       "an owned row's credential must be stripped into the Keychain like any other")
    }

    // MARK: - Independence

    /// Detachment, at the credential level: changing the node's key must not touch the source's.
    func testChangingTheNodesKeyLeavesTheSourceUntouched() throws {
        _ = try makeStore()
        let source = try seedCloudSource()
        var owned = WorkflowNodeProfileFactory.importedProfile(
            from: try XCTUnwrap(refetch(source.id)), workflowID: workflowID, nodeID: UUID())
        createdProfileIDs.append(owned.id)
        _ = try BackendProfileStore.shared.saveProfile(owned)

        owned.details = owned.details.settingProviderAPIKey("sk-ant-NODEOWNED-ROTATED-9876543210")
        _ = try BackendProfileStore.shared.saveProfile(owned)

        XCTAssertEqual(try refetch(owned.id)?.details.providerAPIKey,
                       "sk-ant-NODEOWNED-ROTATED-9876543210")
        XCTAssertEqual(try refetch(source.id)?.details.providerAPIKey, sentinel,
                       "editing a node's private credential must not reach the profile it came from")
    }

    /// ⚠️ COLLECTION MUST REACH THE KEYCHAIN, and must reach ONLY the collected row's item. The
    /// save-time reconcile deletes owned rows through `deleteProfile`; if that left the Keychain
    /// item behind, every deleted node would leak a credential, and if it took the source's the
    /// import would have destroyed the user's own profile.
    func testDeletingAnOwnedRowRemovesItsKeyAndOnlyItsKey() throws {
        _ = try makeStore()
        let source = try seedCloudSource()
        let owned = WorkflowNodeProfileFactory.importedProfile(
            from: try XCTUnwrap(refetch(source.id)), workflowID: workflowID, nodeID: UUID())
        createdProfileIDs.append(owned.id)
        _ = try BackendProfileStore.shared.saveProfile(owned)

        guard case .found = ProviderKeyStore.read(for: owned.id) else {
            return XCTFail("precondition: the copy has a stored key to delete")
        }

        try BackendProfileStore.shared.deleteProfile(withId: owned.id)

        if case .found = ProviderKeyStore.read(for: owned.id) {
            XCTFail("the deleted row's credential is still in the Keychain — every collected node leaks one")
        }
        guard case .found(let sourceKey) = ProviderKeyStore.read(for: source.id) else {
            return XCTFail("collecting a node's row destroyed the SOURCE profile's credential")
        }
        XCTAssertEqual(sourceKey, sentinel)
    }

    /// A FRESH node is MLX-backed and needs no credential — the property that makes "New node" work
    /// on a machine with no cloud keys configured at all.
    func testAFreshNodeStoresNoCredential() throws {
        _ = try makeStore()
        let fresh = WorkflowNodeProfileFactory.freshProfile(
            type: .agent, name: "Local", workflowID: workflowID, nodeID: UUID(),
            defaultMLXModelName: "mlx-community/Llama-3")
        createdProfileIDs.append(fresh.id)
        _ = try BackendProfileStore.shared.saveProfile(fresh)

        XCTAssertNil(try refetch(fresh.id)?.details.providerAPIKey)
        if case .found = ProviderKeyStore.read(for: fresh.id) {
            XCTFail("a fresh MLX node must not create a Keychain item")
        }
    }

    // MARK: - Isolation (KC-63)

    /// Fixed, so the deliberate leak below and the probe after it address the SAME item. Chosen to
    /// be recognizable-by-hand in Keychain Access and never used by anything else in this file.
    private let leakProbeID = UUID(uuidString: "DEADBEEF-C063-4000-8000-0000000000C3")!

    /// ⚠️ DELIBERATELY LEAKS. This test writes a sentinel and cleans up NOTHING, standing in for a
    /// run aborted between a save and its tearDown delete — the leak that used to make this class's
    /// results depend on test order, because the shared in-memory Keychain was never restored.
    /// XCTest runs methods alphabetically, so `testAZombieItemFromAnEarlierTestIsNeverSeenHere`
    /// runs immediately after this one and must not be able to see it.
    func testALeakedItemIsDeliberatelyLeftBehindHere() {
        ProviderKeyStore.save(sentinel, for: leakProbeID)
        guard case .found(let leaked) = ProviderKeyStore.read(for: leakProbeID) else {
            return XCTFail("precondition: the sentinel was written")
        }
        XCTAssertEqual(leaked, sentinel)
    }

    /// The other half of the isolation pair — see the leak above. ⚠️ If this fails, the shared
    /// in-memory Keychain is carrying state across tests again: setUp/tearDown no longer wipes it,
    /// and this class's results (and the classes that run after it) depend on execution order.
    func testAZombieItemFromAnEarlierTestIsNeverSeenHere() {
        guard case .notFound = ProviderKeyStore.read(for: leakProbeID) else {
            return XCTFail("""
                A credential left by an earlier test is visible here. The shared in-memory test \
                Keychain is not being restored between tests, so results depend on test order.
                """)
        }
    }
}
