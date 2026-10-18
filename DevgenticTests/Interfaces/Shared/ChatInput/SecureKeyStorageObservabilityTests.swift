// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SecureKeyStorageObservabilityTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
import Security
@testable import devgentic

final class SecureKeyStorageObservabilityTests: XCTestCase {

    // MARK: - KC-51: OSStatus names

    func testTheCommonStatusesHaveNames() {
        XCTAssertEqual(SecureKeyStorage.osStatusName(errSecItemNotFound),
                       "errSecItemNotFound (the item does not exist)")
        XCTAssertTrue(SecureKeyStorage.osStatusName(errSecAuthFailed).contains("errSecAuthFailed"),
                      "the locked-keychain / denied-ACL case must be recognisable")
        XCTAssertTrue(SecureKeyStorage.osStatusName(errSecInteractionNotAllowed).contains("errSecInteractionNotAllowed"))
        XCTAssertTrue(SecureKeyStorage.osStatusName(errSecMissingEntitlement).contains("errSecMissingEntitlement"))
        XCTAssertTrue(SecureKeyStorage.osStatusName(errSecDecode).contains("errSecDecode"))
    }

    func testAnUnmappedStatusDegradesToTheRawNumber() {
        // A wrong name would be worse than none: unknown codes must stay honest.
        let unmapped = OSStatus(987_654)
        XCTAssertTrue(SecureKeyStorage.osStatusName(unmapped).contains("987654"),
                      SecureKeyStorage.osStatusName(unmapped))
    }

    // MARK: - KC-24: every message carries the account and a consequence

    func testTheUpdateMessageCarriesServiceAccountAndOutcome() {
        let ok = SecureKeyStorage.updateResultMessage(status: errSecSuccess, service: "svc", account: "acct")
        XCTAssertTrue(ok.contains("svc") && ok.contains("acct"), ok)
        let bad = SecureKeyStorage.updateResultMessage(status: errSecAuthFailed, service: "svc", account: "acct")
        XCTAssertTrue(bad.contains("[SECRETS]") && bad.contains("CONSEQUENCE") && bad.contains("errSecAuthFailed"), bad)
    }

    func testTheDeleteMessageSaysTheCredentialRemains() {
        let message = SecureKeyStorage.deleteResultMessage(status: errSecInteractionNotAllowed, service: "svc", account: "acct")
        XCTAssertTrue(message.contains("svc") && message.contains("acct"), message)
        XCTAssertTrue(message.contains("REMAINS"), "the destructive half of a refused delete: \(message)")
    }

    func testTheReadFailureMessageCarriesTheAccount() {
        // KC-24's specific complaint: all four ChatOps credentials share ONE service, so a read
        // failure without the account cannot be told apart from its siblings.
        let message = SecureKeyStorage.readFailureMessage(status: errSecAuthFailed, service: "svc", account: "acct")
        XCTAssertTrue(message.contains("account 'acct'"), message)
        XCTAssertTrue(message.contains("CONSEQUENCE"), message)
    }

    // MARK: - KC-23 / KC-57: the decode-failure branch, produced for real

    /// A genuine `SecItemAdd` of bytes that are not valid UTF-8, read back through the REAL
    /// Security framework. Under the old code this returned `.failed(errSecSuccess)` and logged
    /// "OSStatus 0"; it must now return `.failed(errSecDecode)` with a log that says the item's
    /// payload could not be decoded.
    func testARealNonUTF8ItemReadsAsErrSecDecode() {
        let storage = SecureKeyStorage(bypassingTestHostRedirect: true)
        let service = "devgentic.tests.kc23.\(UUID().uuidString)"
        let account = "raw-bytes"
        defer {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ] as CFDictionary)
        }

        // 0xFF is never valid in UTF-8.
        let raw = Data([0xDE, 0xAD, 0xFF, 0xBE, 0xEF])
        let addStatus = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: raw
        ] as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            return XCTFail("could not seed the raw item in the real Keychain (OSStatus \(addStatus)) — the test environment cannot run this integration test")
        }

        guard case .failed(let status) = storage.read(service: service, account: account) else {
            return XCTFail("a non-UTF-8 item must read as .failed, not .found or .notFound")
        }
        XCTAssertEqual(status, errSecDecode,
                       "a decode failure must be errSecDecode, never errSecSuccess (KC-23)")

        // A collapsing consumer must ALSO see failure, not absence: the item exists.
        XCTAssertNil(storage.retrieve(service: service, account: account))
        XCTAssertNotEqual(storage.read(service: service, account: account), .notFound)
    }

    /// The found path through the real Keychain, so the branch above is provably not the only
    /// one this file exercises.
    func testARealUTF8ItemStillReadsAsFound() {
        let storage = SecureKeyStorage(bypassingTestHostRedirect: true)
        let service = "devgentic.tests.kc23b.\(UUID().uuidString)"
        defer {
            _ = storage.delete(service: service, account: "readable")
        }
        XCTAssertEqual(storage.save(value: "readable-value", service: service, account: "readable"), errSecSuccess)
        XCTAssertEqual(storage.read(service: service, account: "readable"), .found("readable-value"))
    }
}
