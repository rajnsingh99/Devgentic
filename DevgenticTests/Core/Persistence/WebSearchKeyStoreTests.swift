// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WebSearchKeyStoreTests.swift
//  DevgenticTests
//
//  Register KC-2: the web-search API key lives in the Keychain, and the plaintext copy every earlier
//  build wrote to UserDefaults is migrated there — removed ONLY after the Keychain write succeeded.
//

import XCTest
@testable import devgentic

final class WebSearchKeyStoreTests: XCTestCase {

    override func tearDown() {
        WebSearchKeyStore.setStorageForTesting(nil)
        WebSearchKeyStore.delete()
        super.tearDown()
    }

    private func makeDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "devgentic.tests.websearch.\(name)"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    // MARK: - Round trip

    func testSaveLoadDeleteRoundTrip() {
        XCTAssertTrue(WebSearchKeyStore.save("AIza-test-key"))
        XCTAssertEqual(WebSearchKeyStore.load(), "AIza-test-key")
        XCTAssertEqual(WebSearchKeyStore.read(), .found("AIza-test-key"))
        XCTAssertTrue(WebSearchKeyStore.delete())
        XCTAssertNil(WebSearchKeyStore.load())
        XCTAssertEqual(WebSearchKeyStore.read(), .notFound)
    }

    func testSaveTrimsAndABlankValueClears() {
        XCTAssertTrue(WebSearchKeyStore.save("  padded  "))
        XCTAssertEqual(WebSearchKeyStore.load(), "padded")
        XCTAssertTrue(WebSearchKeyStore.save("   "))
        XCTAssertNil(WebSearchKeyStore.load(), "a blank save is a clear, never an empty credential")
    }

    func testDeletingAnAbsentKeyIsSuccess() {
        XCTAssertTrue(WebSearchKeyStore.delete())
    }

    // MARK: - Failure branches

    /// ⚠️ A failed write must report false AND store nothing — this store never falls back to
    /// plaintext, which is the whole reason it exists.
    func testAFailedWriteReportsFalseAndStoresNothing() {
        let stub = ProgrammableKeychain()
        stub.saveStatusOverride = errSecInteractionNotAllowed
        WebSearchKeyStore.setStorageForTesting(stub)

        XCTAssertFalse(WebSearchKeyStore.save("k"))
        XCTAssertNil(stub.store[WebSearchKeyStore.account])
    }

    func testReadDistinguishesMissingFromFailed() {
        let stub = ProgrammableKeychain()
        WebSearchKeyStore.setStorageForTesting(stub)

        XCTAssertEqual(WebSearchKeyStore.read(), .notFound)
        stub.readStatusOverride = errSecAuthFailed
        XCTAssertEqual(WebSearchKeyStore.read(), .failed(errSecAuthFailed))
        XCTAssertNil(WebSearchKeyStore.load(), "load collapses to nil — only for callers that merely send the value")
    }

    func testAFailedDeleteReportsFalseAndLeavesTheKeyInPlace() {
        let stub = ProgrammableKeychain()
        stub.store[WebSearchKeyStore.account] = "k"
        stub.deleteStatusOverride = errSecAuthFailed
        WebSearchKeyStore.setStorageForTesting(stub)

        XCTAssertFalse(WebSearchKeyStore.delete())
        XCTAssertEqual(stub.store[WebSearchKeyStore.account], "k", "left in place, as the log line says")
    }

    // MARK: - Migration from plaintext UserDefaults

    func testThePlaintextKeyIsMovedIntoTheKeychainAndRemoved() {
        let defaults = makeDefaults()
        defaults.set("AIza-plaintext", forKey: WebSearchKeyStore.legacyDefaultsKey)

        XCTAssertEqual(WebSearchKeyStore.migrateFromUserDefaults(defaults: defaults), .migrated)

        XCTAssertEqual(WebSearchKeyStore.load(), "AIza-plaintext")
        XCTAssertNil(defaults.string(forKey: WebSearchKeyStore.legacyDefaultsKey))
    }

    /// ⚠️ THE ASYMMETRY. Delete-then-write would leave the key NOWHERE on an unwritable Keychain —
    /// the one outcome worse than plaintext.
    func testAFailedKeychainWriteLeavesThePlaintextInPlace() {
        let stub = ProgrammableKeychain()
        stub.saveStatusOverride = errSecInteractionNotAllowed
        WebSearchKeyStore.setStorageForTesting(stub)
        let defaults = makeDefaults()
        defaults.set("AIza-plaintext", forKey: WebSearchKeyStore.legacyDefaultsKey)

        XCTAssertEqual(WebSearchKeyStore.migrateFromUserDefaults(defaults: defaults),
                       .leftInPlace(errSecInteractionNotAllowed))

        XCTAssertEqual(defaults.string(forKey: WebSearchKeyStore.legacyDefaultsKey), "AIza-plaintext")
        XCTAssertNil(stub.store[WebSearchKeyStore.account])
    }

    func testNothingToMigrateIsANoOp() {
        let defaults = makeDefaults()
        XCTAssertEqual(WebSearchKeyStore.migrateFromUserDefaults(defaults: defaults), .nothingToMigrate)
        XCTAssertNil(WebSearchKeyStore.load())
    }

    func testABlankPlaintextIsRemovedWithoutBeingMigrated() {
        let defaults = makeDefaults()
        defaults.set("   ", forKey: WebSearchKeyStore.legacyDefaultsKey)

        XCTAssertEqual(WebSearchKeyStore.migrateFromUserDefaults(defaults: defaults), .nothingToMigrate)

        XCTAssertNil(defaults.object(forKey: WebSearchKeyStore.legacyDefaultsKey))
        XCTAssertNil(WebSearchKeyStore.load())
    }

    /// Post-fix builds never write plaintext, so the two coexist only when an OLDER build ran after
    /// this one and the user entered a key there — the plaintext is then the more recent action.
    func testThePlaintextValueWinsOverAnExistingKeychainValue() {
        WebSearchKeyStore.save("older-keychain")
        let defaults = makeDefaults()
        defaults.set("newer-plaintext", forKey: WebSearchKeyStore.legacyDefaultsKey)

        XCTAssertEqual(WebSearchKeyStore.migrateFromUserDefaults(defaults: defaults), .migrated)
        XCTAssertEqual(WebSearchKeyStore.load(), "newer-plaintext")
    }

    func testMigrationIsIdempotent() {
        let defaults = makeDefaults()
        defaults.set("k", forKey: WebSearchKeyStore.legacyDefaultsKey)

        XCTAssertEqual(WebSearchKeyStore.migrateFromUserDefaults(defaults: defaults), .migrated)
        XCTAssertEqual(WebSearchKeyStore.migrateFromUserDefaults(defaults: defaults), .nothingToMigrate)
        XCTAssertEqual(WebSearchKeyStore.load(), "k")
    }

    // MARK: - Wiring (the coordinator needs a full MainApplicationViewModel, so these pin the source)

    /// ⚠️ THE DEFECT, STATED AS AN ABSENCE. `SettingsCoordinator` wrote the key with
    /// `UserDefaults.standard.set(apiKey, …)`. Every path must now go through the store.
    func testTheSettingsCoordinatorNoLongerWritesTheKeyToUserDefaults() throws {
        let source = try TestRepositorySource.read("Devgentic/Interfaces/Main/SettingsCoordinator.swift")
        XCTAssertFalse(source.contains("UserDefaults.standard.set(apiKey"), "the plaintext write is back")
        XCTAssertFalse(source.contains("webSearchAPIKeyDefaultsKey"), "the coordinator owns no UserDefaults key for the credential any more")
        XCTAssertTrue(source.contains("WebSearchKeyStore.save(apiKey)"))
        XCTAssertTrue(source.contains("WebSearchKeyStore.read()"))
        XCTAssertTrue(source.contains("WebSearchKeyStore.migrateFromUserDefaults()"))
        XCTAssertTrue(source.contains("WebSearchKeyStore.delete()"))
    }

    /// The migration and the plaintext purge rewrite the developer's real preferences domain, and
    /// the XCTest host runs the coordinator's `load()` in full — both must be refused there.
    func testTheCoordinatorRefusesToTouchRealPreferencesUnderXCTest() throws {
        let source = try TestRepositorySource.read("Devgentic/Interfaces/Main/SettingsCoordinator.swift")
        XCTAssertTrue(source.contains("TestHost.permits(\"migrate the web-search API key from UserDefaults into the Keychain\""))
        XCTAssertTrue(source.contains("TestHost.permits(\"remove the plaintext web-search API key from UserDefaults\""))
    }

    /// The popup must not dismiss over a failed save.
    func testThePopupRefusesToDismissWhenTheSaveFails() throws {
        let source = try TestRepositorySource.read("Devgentic/Interfaces/Shared/ChatInput/APIKeyInputPopup.swift")
        XCTAssertTrue(source.contains("guard mainViewModel.saveAndEnableWebSearch(apiKey: inputViewModel.apiKeyInput) else"))
    }
}
