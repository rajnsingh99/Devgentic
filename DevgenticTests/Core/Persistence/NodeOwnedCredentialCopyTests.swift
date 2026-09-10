// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  NodeOwnedCredentialCopyTests.swift
//  DevgenticTests
//
//  Created on 30/08/26.
//
//  The import path's credential chain, end to end.
//
//  ⚠️ WHY THIS FILE EXISTS. "Import from a profile" is the headline half of node-owned workflow
//  configuration, and for a CLOUD profile its usefulness rests entirely on a chain that no test
//  covered: the source snapshot carries `apiKey` in memory (re-injected from the Keychain on read)
//  -> `duplicated(as:)` copies it by value -> `saveProfile` inserts -> `BackendProfile.init` strips
//  it back out of the blob and into the Keychain UNDER THE NEW ROW'S UUID -> a later read re-injects
//  it. `WorkflowNodeProfileFactoryTests` asserts only the second link (the in-memory copy holds the
//  key); the rest was asserted by comment. If any link is broken, every imported cloud node is
//  unrunnable — and the failure is silent, because the node looks correctly configured.
//
//  ⚠️ These tests touch the REAL Keychain (same as `ProviderKeyStorageTests`) and clean up in
//  tearDown. The sentinel is deliberately recognisable so a leaked item is identifiable by hand.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class NodeOwnedCredentialCopyTests: XCTestCase {

    private let sentinel = "sk-ant-NODEOWNED-TESTKEY-0123456789"
    private var createdProfileIDs: [UUID] = []
    private let workflowID = UUID()

    override func tearDown() {
        for id in createdProfileIDs { ProviderKeyStore.delete(for: id) }
        createdProfileIDs = []
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
    @discardableResult
    private func seedCloudSource(named name: String = "Cloud Researcher") throws -> BackendProfileModel {
        let source = BackendProfileSnapshot(
            displayName: name,
            details: .agent(AgentConfig(
                llmConfig: ProviderConfig(apiProvider: .anthropic, modelName: "claude-opus-5", apiKey: sentinel),
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
        XCTAssertFalse(row.hasInlineAPIKeyInStoredBlob)
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
}
