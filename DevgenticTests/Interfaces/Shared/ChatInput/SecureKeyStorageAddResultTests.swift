// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SecureKeyStorageAddResultTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class SecureKeyStorageAddResultTests: XCTestCase {

    // MARK: - The message (pure — both texts pinnable)

    func testASuccessfulAddSaysSo() {
        let message = SecureKeyStorage.addResultMessage(
            status: errSecSuccess, service: "svc", account: "acct")
        XCTAssertTrue(message.contains("Added"), "success text must say the item was ADDED: \(message)")
        XCTAssertTrue(message.contains("svc"), "success text carries the service: \(message)")
        XCTAssertTrue(message.contains("acct"), "success text carries the account: \(message)")
    }

    func testAFailedAddNamesTheConsequence() {
        let message = SecureKeyStorage.addResultMessage(
            status: errSecAuthFailed, service: "svc", account: "acct")
        XCTAssertTrue(message.contains("[SECRETS]"), "failure text is tagged for the secrets category: \(message)")
        XCTAssertTrue(message.contains("svc"), "failure text names the service: \(message)")
        XCTAssertTrue(message.contains("acct"), "failure text names the account: \(message)")
        XCTAssertTrue(message.contains(SecureKeyStorage.osStatusName(errSecAuthFailed)),
                      "failure text carries the NAMED OSStatus (KC-51): \(message)")
        XCTAssertTrue(message.contains("CONSEQUENCE"), "failure text states the consequence: \(message)")
        XCTAssertTrue(message.contains("NOWHERE"), "failure text must say the credential is stored nowhere: \(message)")
    }

    func testTheTwoOutcomesDoNotShareAText() {
        let success = SecureKeyStorage.addResultMessage(status: errSecSuccess, service: "s", account: "a")
        let failure = SecureKeyStorage.addResultMessage(status: errSecDuplicateItem, service: "s", account: "a")
        XCTAssertNotEqual(success, failure)
    }

    // MARK: - The wiring (real Keychain, throwaway service)

    /// The ONLY deterministic way to reach the `SecItemAdd` branch: a real Keychain and a
    /// service that has never seen this account, so `SecItemUpdate` misses and the add runs.
    /// Under the XCTest host the default `SecureKeyStorage()` redirects to memory BEFORE this
    /// branch — which is exactly why the opt-in exists.
    func testAFirstTimeSaveLogsThroughTheSinkOnTheRealKeychain() {
        let storage = SecureKeyStorage(bypassingTestHostRedirect: true)
        let service = "devgentic.tests.kc9.\(UUID().uuidString)"
        let account = "add-result"
        defer {
            _ = storage.delete(service: service, account: account)
            SecureKeyStorage.addResultLogSinkForTesting = nil
        }

        var logged: [String] = []
        SecureKeyStorage.addResultLogSinkForTesting = { logged.append($0) }

        XCTAssertEqual(storage.save(value: "first-write", service: service, account: account),
                       errSecSuccess)
        XCTAssertEqual(logged.count, 1, "the FIRST save takes the add branch and must log it")
        XCTAssertTrue(logged[0].contains("Added"), "a successful add logs the added text: \(logged)")

        logged.removeAll()
        XCTAssertEqual(storage.save(value: "second-write", service: service, account: account),
                       errSecSuccess)
        XCTAssertTrue(logged.isEmpty, "the SECOND save takes the update branch, which logs elsewhere — the sink must not double-report")
    }
}
