// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  KeylessProviderKeychainTests.swift
//  DevgenticTests
//
//  Ollama and MLX never send an API key, so a profile on them has nothing in the Keychain.
//
//  ⚠️ The defect these hold off (on-device trace, 2026-10-03): two Ollama profiles produced ~30
//  per-profile Keychain reads in one short session — one per fetch and render — plus a Keychain
//  DELETE on every save, and picking a local model in the catalog read the shared store for
//  "ollama" and "mlx". Every one of them could only answer "not found". Harmless while no item
//  exists; a needless access prompt the day a stray one does under a changed signature.
//

import SwiftData
import XCTest
@testable import devgentic

@MainActor
final class KeylessProviderKeychainTests: XCTestCase {

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

    private func details(_ provider: ApiProvider, key: String? = nil) -> ProfileDetails {
        .agent(AgentConfig(llmConfig: ProviderConfig(apiProvider: provider, modelName: "model", apiKey: key)))
    }

    func testOnlyOllamaAndMLXAreKeyless() {
        XCTAssertEqual(ApiProvider.allCases.filter { !$0.usesAPIKey }, [.ollama, .mlx])
    }

    // MARK: - Per-profile

    func testFetchingAKeylessProfileNeverReadsTheKeychain() throws {
        let container = try ModelContainer(
            for: BackendProfile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let seed = ModelContext(container)
        seed.insert(BackendProfile(displayName: "Local", details: details(.ollama)))
        seed.insert(BackendProfile(displayName: "MLX", details: details(.mlx)))
        try seed.save()

        for _ in 0..<5 {
            for row in try ModelContext(container).fetch(FetchDescriptor<BackendProfile>()) {
                _ = row.details
                _ = row.hasUnreadableProviderKey
            }
        }
        XCTAssertEqual(perProfile.readCount, 0)

        // Non-vacuity: a keyed per-profile provider DOES look, so the zero above is real.
        seed.insert(BackendProfile(displayName: "Custom", details: details(.openAICompatible)))
        try seed.save()
        ProviderKeyStore.discardCache()   // as on a fresh launch: creating the row primed the cache
        for row in try ModelContext(container).fetch(FetchDescriptor<BackendProfile>()) { _ = row.details }
        XCTAssertGreaterThan(perProfile.readCount, 0)
    }

    func testSavingAKeylessProfileNeverTouchesTheKeychain() {
        let row = BackendProfile(displayName: "Local", details: details(.ollama))
        row.details = details(.ollama)
        row.details = details(.mlx)

        XCTAssertEqual(perProfile.deleteCount, 0, "there is no item to delete — every save used to try")
        XCTAssertEqual(perProfile.readCount, 0)
        XCTAssertTrue(perProfile.store.isEmpty)
    }

    /// A provider switch can leave the old provider's key on the value; it must not be stored for
    /// a provider that never sends one, nor left in the blob.
    func testAKeyCarriedOntoAKeylessProviderIsDropped() {
        let row = BackendProfile(displayName: "Local", details: details(.ollama, key: "sk-LEFTOVER-0123456789"))
        row.details = details(.ollama, key: "sk-LEFTOVER-0123456789")

        XCTAssertTrue(perProfile.store.isEmpty)
        XCTAssertFalse(String(decoding: row.configData, as: UTF8.self).contains("LEFTOVER"))
        XCTAssertNil(row.details.providerAPIKey)
    }

    /// ⚠️ The one case a keyless save MUST touch the Keychain: leaving a provider that kept its own
    /// per-profile key. Skipping it would orphan that credential in the Keychain.
    func testSwitchingFromAKeyedProviderToAKeylessOneClearsTheOldItem() {
        let row = BackendProfile(displayName: "Switcher", details: details(.openAICompatible, key: "custom-KEY-0123456789"))
        XCTAssertEqual(perProfile.store[row.id.uuidString], "custom-KEY-0123456789", "precondition")

        row.details = details(.ollama)

        XCTAssertNil(perProfile.store[row.id.uuidString], "the old provider's key must not be orphaned")
    }

    // MARK: - App-level and Code mode

    /// Picking a local model in the catalog loads "the key" for its vendor account.
    func testTheAppLevelStoreNeverReadsForAKeylessProvider() {
        XCTAssertNil(AppProviderKeyStore.load(forAccount: ApiProvider.ollama.providerString))
        XCTAssertNil(AppProviderKeyStore.load(forAccount: ApiProvider.mlx.providerString))
        XCTAssertFalse(AppProviderKeyStore.shared.hasKey(for: .ollama))
        XCTAssertEqual(shared.readCount, 0)

        // Non-vacuity: a keyed account does reach the Keychain.
        _ = AppProviderKeyStore.load(forAccount: ApiProvider.anthropic.providerString)
        XCTAssertGreaterThan(shared.readCount, 0)
    }

    func testCodeModeKeepsNoSlotForAKeylessProvider() {
        CodeProviderKeys.remember("sk-SOMETHING-0123456789", for: .ollama)
        XCTAssertNil(CodeProviderKeys.key(for: .ollama))
        XCTAssertNil(CodeProviderKeys.key(for: .mlx))
        XCTAssertTrue(perProfile.store.isEmpty)
        XCTAssertEqual(perProfile.readCount, 0)
    }
}
