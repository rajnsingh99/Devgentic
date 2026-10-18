// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AppProviderKeyStoreTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
final class AppProviderKeyStoreTests: XCTestCase {

    private let testAccount = "test_provider_unit"
    private let sampleKey = "sk-ant-test-key-12345678"

    override func tearDown() {
        AppProviderKeyStore.delete(forAccount: testAccount)
        AppProviderKeyStore.deleteEndpoint(forAccount: testAccount)
        super.tearDown()
    }

    func testSaveAndLoadKey() {
        XCTAssertFalse(AppProviderKeyStore.shared.hasKey(forAccount: testAccount))

        let saved = AppProviderKeyStore.save(sampleKey, forAccount: testAccount)
        XCTAssertTrue(saved)

        XCTAssertTrue(AppProviderKeyStore.shared.hasKey(forAccount: testAccount))
        XCTAssertEqual(AppProviderKeyStore.load(forAccount: testAccount), sampleKey)
    }

    func testMaskKey() {
        AppProviderKeyStore.save(sampleKey, forAccount: testAccount)

        let masked = AppProviderKeyStore.shared.maskedKey(forAccount: testAccount)
        XCTAssertNotNil(masked)
        XCTAssertTrue(masked!.starts(with: "sk-a"))
        XCTAssertTrue(masked!.hasSuffix("5678"))
        XCTAssertTrue(masked!.contains("••••"))
    }

    func testDeleteKey() {
        AppProviderKeyStore.save(sampleKey, forAccount: testAccount)
        XCTAssertTrue(AppProviderKeyStore.shared.hasKey(forAccount: testAccount))

        let deleted = AppProviderKeyStore.delete(forAccount: testAccount)
        XCTAssertTrue(deleted)
        XCTAssertFalse(AppProviderKeyStore.shared.hasKey(forAccount: testAccount))
        XCTAssertNil(AppProviderKeyStore.load(forAccount: testAccount))
    }

    func testSaveEmptyKeyDeletes() {
        AppProviderKeyStore.save(sampleKey, forAccount: testAccount)
        XCTAssertTrue(AppProviderKeyStore.shared.hasKey(forAccount: testAccount))

        AppProviderKeyStore.save("   ", forAccount: testAccount)
        XCTAssertFalse(AppProviderKeyStore.shared.hasKey(forAccount: testAccount))
    }

    func testSaveAndLoadEndpoint() {
        XCTAssertNil(AppProviderKeyStore.loadEndpoint(forAccount: testAccount))

        let sampleEndpoint = "https://custom-proxy.internal.corp/v1"
        let saved = AppProviderKeyStore.saveEndpoint(sampleEndpoint, forAccount: testAccount)
        XCTAssertTrue(saved)
        XCTAssertEqual(AppProviderKeyStore.loadEndpoint(forAccount: testAccount), sampleEndpoint)
        XCTAssertEqual(AppProviderKeyStore.shared.endpoint(forAccount: testAccount), sampleEndpoint)

        AppProviderKeyStore.deleteEndpoint(forAccount: testAccount)
        XCTAssertNil(AppProviderKeyStore.loadEndpoint(forAccount: testAccount))
    }
}
