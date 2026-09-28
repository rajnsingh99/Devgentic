// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SecureKeyStorageTests.swift
//  DevgenticTests
//
//  Integration tests for SecureKeyStorage — exercises real Keychain APIs.
//  Uses a unique service/account per test run to avoid cross-contamination.
//
//  ⚠️ These are the ONLY tests that should touch the real login Keychain, and they opt in by name:
//  under XCTest every plain `SecureKeyStorage()` is redirected to an in-memory store (registers
//  KC-54/55), which is exactly what these tests must NOT exercise — their job is the `SecItem*`
//  query dictionaries. The throwaway service keeps them away from every production item.
//

import XCTest
@testable import devgentic

final class SecureKeyStorageTests: XCTestCase {

    private let storage = SecureKeyStorage(bypassingTestHostRedirect: true)
    private let testService = "com.devgentic.tests.keychain.\(UUID().uuidString)"
    private let testAccount = "test-api-key"

    override func tearDown() {
        // Cleanup: remove any test keys
        _ = storage.delete(service: testService, account: testAccount)
        super.tearDown()
    }

    // MARK: - Save & Retrieve

    func testSaveAndRetrieve() {
        let status = storage.save(value: "my-secret-key", service: testService, account: testAccount)
        XCTAssertEqual(status, errSecSuccess, "Save should succeed")

        let retrieved = storage.retrieve(service: testService, account: testAccount)
        XCTAssertEqual(retrieved, "my-secret-key")
    }

    func testUpdateExistingKey() {
        _ = storage.save(value: "old-key", service: testService, account: testAccount)
        let updateStatus = storage.save(value: "new-key", service: testService, account: testAccount)
        XCTAssertEqual(updateStatus, errSecSuccess)

        let retrieved = storage.retrieve(service: testService, account: testAccount)
        XCTAssertEqual(retrieved, "new-key", "Should retrieve updated value")
    }

    func testRetrieveNonExistentKey() {
        let result = storage.retrieve(service: testService, account: "nonexistent-account")
        XCTAssertNil(result, "Should return nil for non-existent keychain entry")
    }

    // MARK: - Delete

    func testDeleteExistingKey() {
        _ = storage.save(value: "to-delete", service: testService, account: testAccount)
        let deleteStatus = storage.delete(service: testService, account: testAccount)
        XCTAssertEqual(deleteStatus, errSecSuccess)

        let retrieved = storage.retrieve(service: testService, account: testAccount)
        XCTAssertNil(retrieved, "Should not find deleted key")
    }

    func testDeleteNonExistentKeyReturnsNotFound() {
        let status = storage.delete(service: testService, account: "never-saved")
        XCTAssertEqual(status, errSecItemNotFound)
    }

    // MARK: - Edge Cases

    func testSaveEmptyString() {
        let status = storage.save(value: "", service: testService, account: testAccount)
        XCTAssertEqual(status, errSecSuccess)

        let retrieved = storage.retrieve(service: testService, account: testAccount)
        XCTAssertEqual(retrieved, "")
    }

    func testSaveUnicodeValue() {
        let unicodeValue = "🔑日本語키"
        let status = storage.save(value: unicodeValue, service: testService, account: testAccount)
        XCTAssertEqual(status, errSecSuccess)

        let retrieved = storage.retrieve(service: testService, account: testAccount)
        XCTAssertEqual(retrieved, unicodeValue)
    }

    func testSaveLongValue() {
        let longValue = String(repeating: "x", count: 10_000)
        let status = storage.save(value: longValue, service: testService, account: testAccount)
        XCTAssertEqual(status, errSecSuccess)

        let retrieved = storage.retrieve(service: testService, account: testAccount)
        XCTAssertEqual(retrieved, longValue)
    }

    // MARK: - Labels (KC-25 / KC-30)

    /// The item's (label, description) as the real Keychain reports them — what Keychain Access
    /// shows in its Name and Kind columns.
    private func storedLabelAndDescription() -> (label: String?, description: String?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testService,
            kSecAttrAccount as String: testAccount,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any] else { return (nil, nil) }
        return (attributes[kSecAttrLabel as String] as? String,
                attributes[kSecAttrDescription as String] as? String)
    }

    func testANewItemIsLabelledSoItCanBeFoundInKeychainAccess() {
        XCTAssertEqual(storage.save(value: "labelled", service: testService, account: testAccount), errSecSuccess)

        let stored = storedLabelAndDescription()
        XCTAssertEqual(stored.label, "Devgentic — \(testService) — \(testAccount)")
        XCTAssertEqual(stored.description, "Devgentic credential")
    }

    /// Items written before KC-25 have no label. The update path must add one, or every credential
    /// an existing install already holds stays unfindable forever.
    func testAnUnlabelledItemGainsItsLabelOnTheNextWrite() {
        let bareAdd: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testService,
            kSecAttrAccount as String: testAccount,
            kSecValueData as String: Data("pre-KC-25".utf8),
        ]
        XCTAssertEqual(SecItemAdd(bareAdd as CFDictionary, nil), errSecSuccess)
        XCTAssertNotEqual(storedLabelAndDescription().description, "Devgentic credential",
                          "precondition: the item starts without this app's labelling")

        XCTAssertEqual(storage.save(value: "rewritten", service: testService, account: testAccount), errSecSuccess)

        let stored = storedLabelAndDescription()
        XCTAssertEqual(stored.label, "Devgentic — \(testService) — \(testAccount)")
        XCTAssertEqual(stored.description, "Devgentic credential")
        XCTAssertEqual(storage.retrieve(service: testService, account: testAccount), "rewritten")
    }
}
