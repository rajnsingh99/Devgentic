// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WebSearchKeyStoreTests.swift
//  DevgenticTests
//
//  Register KC-2: the web-search API key lives in the Keychain, never in UserDefaults.
//

import XCTest
@testable import devgentic

final class WebSearchKeyStoreTests: XCTestCase {

    override func tearDown() {
        WebSearchKeyStore.setStorageForTesting(nil)
        WebSearchKeyStore.delete()
        super.tearDown()
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

    // MARK: - Wiring (the coordinator needs a full MainApplicationViewModel, so these pin the source)

    /// ⚠️ THE DEFECT, STATED AS AN ABSENCE. `SettingsCoordinator` wrote the key with
    /// `UserDefaults.standard.set(apiKey, …)`. Every path must now go through the store.
    func testTheSettingsCoordinatorNoLongerWritesTheKeyToUserDefaults() throws {
        let source = try TestRepositorySource.read("Devgentic/Interfaces/Main/SettingsCoordinator.swift")
        XCTAssertFalse(source.contains("UserDefaults.standard.set(apiKey"), "the plaintext write is back")
        XCTAssertFalse(source.contains("webSearchAPIKeyDefaultsKey"), "the coordinator owns no UserDefaults key for the credential any more")
        XCTAssertTrue(source.contains("WebSearchKeyStore.save(apiKey)"))
        XCTAssertTrue(source.contains("WebSearchKeyStore.read()"))
        XCTAssertTrue(source.contains("WebSearchKeyStore.delete()"))
    }

    /// The popup must not dismiss over a failed save.
    func testThePopupRefusesToDismissWhenTheSaveFails() throws {
        let source = try TestRepositorySource.read("Devgentic/Interfaces/Shared/ChatInput/APIKeyInputPopup.swift")
        XCTAssertTrue(source.contains("guard mainViewModel.saveAndEnableWebSearch(apiKey: inputViewModel.apiKeyInput) else"))
    }
}
