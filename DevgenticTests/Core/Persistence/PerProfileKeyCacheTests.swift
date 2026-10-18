// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  PerProfileKeyCacheTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import SwiftData
import XCTest
@testable import devgentic

@MainActor
final class PerProfileKeyCacheTests: XCTestCase {

    private var perProfile: ProgrammableKeychain!

    override func setUp() {
        super.setUp()
        perProfile = ProgrammableKeychain()
        ProviderKeyStore.setStorageForTesting(perProfile)
    }

    override func tearDown() {
        ProviderKeyStore.setStorageForTesting(nil)
        perProfile = nil
        super.tearDown()
    }

    private func customDetails(key: String?) -> ProfileDetails {
        .agent(AgentConfig(llmConfig: ProviderConfig(
            apiProvider: .openAICompatible, modelName: "model", apiKey: key, baseURL: "https://llm.example.test/v1")))
    }

    /// ⚠️ THE WIRING TEST. Ten refetches of the same profile — ten fresh instances — read the
    /// Keychain once.
    func testRefetchingAProfileReadsItsKeyOnce() throws {
        let container = try ModelContainer(
            for: BackendProfile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let seed = ModelContext(container)
        let row = BackendProfile(displayName: "Custom", details: customDetails(key: "custom-KEY-0123456789"))
        seed.insert(row)
        try seed.save()
        ProviderKeyStore.discardCache()   // as on a fresh launch: the save above primed it

        for _ in 0..<10 {
            for fetched in try ModelContext(container).fetch(FetchDescriptor<BackendProfile>()) {
                XCTAssertEqual(fetched.details.providerAPIKey, "custom-KEY-0123456789")
            }
        }
        XCTAssertEqual(perProfile.readCount, 1)
    }

    /// A key absent from the Keychain is remembered as absent too — the common case for a profile
    /// that has none.
    func testAnAbsentKeyIsAlsoReadOnce() {
        let id = UUID()
        for _ in 0..<5 { XCTAssertEqual(ProviderKeyStore.read(for: id), .notFound) }
        XCTAssertEqual(perProfile.readCount, 1)
    }

    func testSaveAndDeleteKeepTheCacheTruthful() {
        let id = UUID()
        _ = ProviderKeyStore.read(for: id)
        XCTAssertTrue(ProviderKeyStore.save("new-KEY-0123456789", for: id))
        XCTAssertEqual(ProviderKeyStore.read(for: id), .found("new-KEY-0123456789"),
                       "a save must not leave a stale 'not found' behind")

        XCTAssertTrue(ProviderKeyStore.delete(for: id))
        XCTAssertEqual(ProviderKeyStore.read(for: id), .notFound,
                       "a delete must not leave the old key behind to be re-injected")
        XCTAssertEqual(perProfile.readCount, 1, "both answers came from the cache")
    }

    /// A failed write leaves the item in an unknown state — the next read must ask the Keychain.
    func testAFailedSaveForgetsTheCachedAnswer() {
        let id = UUID()
        _ = ProviderKeyStore.read(for: id)
        perProfile.saveStatusOverride = errSecInteractionNotAllowed
        XCTAssertFalse(ProviderKeyStore.save("new-KEY-0123456789", for: id))
        _ = ProviderKeyStore.read(for: id)
        XCTAssertEqual(perProfile.readCount, 2)
    }

    /// ⚠️ A failed read is answered from the cache for a fresh fetch — so a denied prompt is not
    /// re-raised on every refetch — but a caller with its own retry policy (the profile's KC-20
    /// re-read, Try Again) still reaches the Keychain, so the cache never stretches how long a
    /// profile stays unreadable.
    func testAFailedReadIsCachedButTheRetryPathBypassesIt() {
        let id = UUID()
        perProfile.store[id.uuidString] = "custom-KEY-0123456789"
        perProfile.readStatusOverride = errSecInteractionNotAllowed

        XCTAssertEqual(ProviderKeyStore.read(for: id), .failed(errSecInteractionNotAllowed))
        XCTAssertEqual(ProviderKeyStore.read(for: id), .failed(errSecInteractionNotAllowed))
        XCTAssertEqual(perProfile.readCount, 1, "a fresh fetch must not re-raise the prompt")

        perProfile.readStatusOverride = nil
        XCTAssertEqual(ProviderKeyStore.read(for: id, bypassingFailedRead: true), .found("custom-KEY-0123456789"))
        XCTAssertEqual(perProfile.readCount, 2)
    }

    /// End to end through the profile: Try Again recovers a key the cache last saw fail.
    func testTryAgainRecoversThroughTheCache() {
        let row = BackendProfile(displayName: "Custom", details: customDetails(key: "custom-KEY-0123456789"))
        ProviderKeyStore.discardCache()
        perProfile.readStatusOverride = errSecInteractionNotAllowed
        row.resetDecodeCacheForTesting()
        XCTAssertTrue(row.hasUnreadableProviderKey)

        perProfile.readStatusOverride = nil
        XCTAssertTrue(row.retryProviderKeyRead())
        XCTAssertEqual(row.details.providerAPIKey, "custom-KEY-0123456789")
    }
}

// MARK: - Hugging Face token: one home

@MainActor
final class HuggingFaceTokenSingleHomeTests: XCTestCase {

    private var shared: ProgrammableKeychain!
    private var hf: ProgrammableKeychain!

    override func setUp() {
        super.setUp()
        shared = ProgrammableKeychain()
        hf = ProgrammableKeychain()
        GlobalProviderKeys.setStorageForTesting(shared)
        HuggingFaceTokenStore.setBackingForTesting(hf)
    }

    override func tearDown() {
        GlobalProviderKeys.setStorageForTesting(nil)
        HuggingFaceTokenStore.setBackingForTesting(nil)
        shared = nil
        hf = nil
        super.tearDown()
    }

    private let account = AppProviderKeyStore.huggingFaceAccount

    func testSavingTheTokenWritesOnlyItsOwnStore() {
        XCTAssertTrue(AppProviderKeyStore.save("hf_TOKEN0123456789abcdef", forAccount: account))
        XCTAssertEqual(hf.store.values.first, "hf_TOKEN0123456789abcdef")
        XCTAssertTrue(shared.store.isEmpty, "no second copy under the shared provider service")
    }

    func testReadingTheTokenNeverFallsBackToTheSharedStore() {
        // A leftover copy from the old double-write must not be resurrected by a read.
        shared.store[account] = "hf_STALECOPY0123456789"
        XCTAssertNil(AppProviderKeyStore.load(forAccount: account))
        XCTAssertFalse(AppProviderKeyStore.shared.hasKey(forAccount: account))
        XCTAssertEqual(shared.readCount, 0)

        XCTAssertTrue(AppProviderKeyStore.save("hf_TOKEN0123456789abcdef", forAccount: account))
        XCTAssertEqual(AppProviderKeyStore.load(forAccount: account), "hf_TOKEN0123456789abcdef")
        XCTAssertEqual(shared.readCount, 0)
    }

    func testClearingTheTokenTouchesOnlyItsOwnStore() {
        XCTAssertTrue(AppProviderKeyStore.save("hf_TOKEN0123456789abcdef", forAccount: account))
        XCTAssertTrue(AppProviderKeyStore.delete(forAccount: account))
        XCTAssertTrue(hf.store.isEmpty)
        XCTAssertEqual(shared.deleteCount, 0)
        XCTAssertNil(AppProviderKeyStore.load(forAccount: account))
    }
}
