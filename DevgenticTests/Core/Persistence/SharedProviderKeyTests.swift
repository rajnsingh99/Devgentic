// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SharedProviderKeyTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import SwiftData
import XCTest
@testable import devgentic

@MainActor
final class SharedProviderKeyTests: XCTestCase {

    private let anthropicKey = "sk-ant-SHARED-TESTKEY-0123456789"
    private var shared: ProgrammableKeychain!
    private var perProfile: ProgrammableKeychain!

    override func setUp() {
        super.setUp()
        shared = ProgrammableKeychain()
        perProfile = ProgrammableKeychain()
        GlobalProviderKeys.setStorageForTesting(shared)
        ProviderKeyStore.setStorageForTesting(perProfile)
    }

    override func tearDown() {
        GlobalProviderKeys.setStorageForTesting(nil)
        ProviderKeyStore.setStorageForTesting(nil)
        shared = nil
        perProfile = nil
        super.tearDown()
    }

    private func details(_ provider: ApiProvider = .anthropic, key: String?) -> ProfileDetails {
        .agent(AgentConfig(llmConfig: ProviderConfig(apiProvider: provider, modelName: "model", apiKey: key)))
    }

    private func blobText(_ row: BackendProfile) -> String {
        String(decoding: row.configData, as: UTF8.self)
    }

    @discardableResult
    private func makeStore() throws -> ModelContainer {
        let container = try ModelContainer(
            for: BackendProfile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        BackendProfileStore.shared.configureContainer(container)
        return container
    }

    private func saveSnapshot(_ name: String, _ details: ProfileDetails) throws -> UUID {
        let snapshot = BackendProfileSnapshot(displayName: name, details: details)
        _ = try BackendProfileStore.shared.saveProfile(snapshot)
        return snapshot.id
    }

    // MARK: - One key, every profile

    func testProfilesOnTheSameProviderShareOneKey() {
        XCTAssertTrue(AppProviderKeyStore.save(anthropicKey, for: .anthropic))

        let first = BackendProfile(displayName: "First", details: details(key: nil))
        let second = BackendProfile(displayName: "Second", details: details(key: nil))

        XCTAssertEqual(first.details.providerAPIKey, anthropicKey)
        XCTAssertEqual(second.details.providerAPIKey, anthropicKey)
        XCTAssertTrue(perProfile.store.isEmpty, "a shared-provider profile must not keep its own Keychain copy")
        XCTAssertFalse(blobText(first).contains(anthropicKey), "the key must never reach the stored blob")
    }

    func testReplacingTheSharedKeyReachesEveryProfileImmediately() {
        XCTAssertTrue(AppProviderKeyStore.save("sk-ant-OLD-TESTKEY-0123456789", for: .anthropic))
        let row = BackendProfile(displayName: "Row", details: details(key: nil))
        _ = row.details

        XCTAssertTrue(AppProviderKeyStore.save(anthropicKey, for: .anthropic))

        XCTAssertEqual(row.details.providerAPIKey, anthropicKey,
                       "a profile must not keep sending the key it was created with after the catalog replaced it")
    }

    func testDeletingAProfileLeavesTheSharedKey() throws {
        try makeStore()
        XCTAssertTrue(AppProviderKeyStore.save(anthropicKey, for: .anthropic))
        let id = try saveSnapshot("Doomed", details(key: nil))

        try BackendProfileStore.shared.deleteProfile(withId: id)

        XCTAssertEqual(shared.store["anthropic"], anthropicKey, "the key belongs to every Anthropic profile, not this one")
    }

    // MARK: - A profile save never destroys or replaces the shared key

    func testAKeylessSaveNeverDeletesTheSharedKey() {
        XCTAssertTrue(AppProviderKeyStore.save(anthropicKey, for: .anthropic))
        let row = BackendProfile(displayName: "Row", details: details(key: nil))

        row.details = details(key: nil)   // a draft built without the key, or a read that failed

        XCTAssertEqual(shared.deleteCount, 0)
        XCTAssertEqual(shared.store["anthropic"], anthropicKey)
        XCTAssertEqual(row.details.providerAPIKey, anthropicKey)
    }

    func testAStaleCarriedKeyDoesNotOverwriteTheSharedKey() {
        XCTAssertTrue(AppProviderKeyStore.save(anthropicKey, for: .anthropic))
        let row = BackendProfile(displayName: "Row", details: details(key: nil))

        // An editor draft opened before the key was replaced in the catalog.
        row.details = details(key: "sk-ant-STALE-TESTKEY-0123456789")

        XCTAssertEqual(shared.store["anthropic"], anthropicKey)
        XCTAssertEqual(row.details.providerAPIKey, anthropicKey)
        XCTAssertFalse(blobText(row).contains("STALE"), "the discarded key must not be parked in the blob either")
    }

    /// Shared keys are set only in the model catalog and the Code model picker. A key arriving on
    /// a profile — a provider switch carrying the old vendor's key, an imported profile — is
    /// discarded, not promoted to every profile on the provider.
    func testAProfileSaveNeverWritesTheSharedKey() {
        let row = BackendProfile(displayName: "Row", details: details(key: anthropicKey))
        row.details = details(key: anthropicKey)

        XCTAssertTrue(shared.store.isEmpty)
        XCTAssertTrue(perProfile.store.isEmpty)
        XCTAssertFalse(blobText(row).contains(anthropicKey))
        XCTAssertNil(row.details.providerAPIKey, "no shared key yet → the profile is unconfigured")
    }

    // MARK: - Unreadable

    func testAnUnreadableSharedKeyIsReportedAndLeftAlone() {
        shared.store["anthropic"] = anthropicKey
        shared.readStatusOverride = errSecInteractionNotAllowed

        let row = BackendProfile(displayName: "Row", details: details(key: nil))
        row.details = details(key: nil)

        XCTAssertTrue(row.hasUnreadableProviderKey)
        XCTAssertEqual(shared.deleteCount, 0)
        XCTAssertEqual(shared.store["anthropic"], anthropicKey)

        shared.readStatusOverride = nil
        XCTAssertTrue(row.retryProviderKeyRead())
        XCTAssertFalse(row.hasUnreadableProviderKey)
        XCTAssertEqual(row.details.providerAPIKey, anthropicKey)
    }

    // MARK: - Read once

    /// ⚠️ The wiring test for the cache. Before it, each of these reads was a Keychain read — and,
    /// while the app's signature did not match the item, a separate blocking prompt.
    func testTheSharedKeyIsReadFromTheKeychainOncePerProcess() {
        shared.store["anthropic"] = anthropicKey
        let rows = (0..<5).map { BackendProfile(displayName: "Row \($0)", details: details(key: nil)) }

        for _ in 0..<10 {
            for row in rows { _ = row.details }
            _ = AppProviderKeyStore.shared.hasKey(for: .anthropic)
            _ = AppProviderKeyStore.shared.maskedKey(for: .anthropic)
        }

        XCTAssertEqual(shared.readCount, 1)
    }

    func testAFailedReadIsNotRetriedOnEveryRender() {
        shared.readStatusOverride = errSecInteractionNotAllowed
        let row = BackendProfile(displayName: "Row", details: details(key: nil))

        for _ in 0..<20 { _ = row.details }
        XCTAssertEqual(shared.readCount, 1, "re-reading per render would re-raise a denied prompt every frame")

        _ = row.retryProviderKeyRead()
        XCTAssertEqual(shared.readCount, 2, "Try Again must reach the Keychain")
    }

    /// A fetched shared-provider profile never looks for a per-profile item — that lookup, for
    /// every profile on every fetch, was the bulk of the launch's Keychain traffic.
    func testFetchingASharedProviderProfileNeverReadsAPerProfileItem() throws {
        let container = try ModelContainer(
            for: BackendProfile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let seed = ModelContext(container)
        seed.insert(BackendProfile(displayName: "Anthropic", details: details(.anthropic, key: nil)))
        seed.insert(BackendProfile(displayName: "Google", details: details(.google, key: nil)))
        try seed.save()

        for row in try ModelContext(container).fetch(FetchDescriptor<BackendProfile>()) { _ = row.details }
        XCTAssertEqual(perProfile.readCount, 0)

        // Non-vacuity: a freshly materialized per-profile row DOES look, so the zero above is real.
        seed.insert(BackendProfile(displayName: "Custom", details: details(.openAICompatible, key: nil)))
        try seed.save()
        ProviderKeyStore.discardCache()   // as on a fresh launch: creating the row primed the cache
        for row in try ModelContext(container).fetch(FetchDescriptor<BackendProfile>()) { _ = row.details }
        XCTAssertEqual(perProfile.readCount, 1)
    }

    // MARK: - Code mode

    func testCodeModeKeysAreTheSharedProviderKeys() {
        CodeProviderKeys.remember(anthropicKey, for: .anthropic)

        XCTAssertEqual(AppProviderKeyStore.load(for: .anthropic), anthropicKey)
        XCTAssertEqual(CodeProviderKeys.key(for: .anthropic), anthropicKey)
        XCTAssertTrue(perProfile.store.isEmpty, "no separate Code slot for a shared-key provider")

        // An OpenAI-compatible endpoint has no shared key, so Code still keeps a slot for it.
        CodeProviderKeys.remember("custom-endpoint-key", for: .openAICompatible)
        XCTAssertEqual(perProfile.store[CodeProviderKeys.slotID(for: .openAICompatible).uuidString],
                       "custom-endpoint-key")
    }
}
