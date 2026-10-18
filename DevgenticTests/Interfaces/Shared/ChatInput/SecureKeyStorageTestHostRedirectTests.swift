// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SecureKeyStorageTestHostRedirectTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class SecureKeyStorageTestHostRedirectTests: XCTestCase {

    /// Throwaway service, so the assertions against the real Keychain can never collide with a
    /// production item on the developer's machine.
    private let service = "com.devgentic.tests.redirect.\(UUID().uuidString)"
    private let account = "credential"

    /// The real login Keychain, reached by the named opt-in.
    private let real = SecureKeyStorage(bypassingTestHostRedirect: true)

    override func tearDown() {
        _ = real.delete(service: service, account: account)
        _ = SecureKeyStorage().delete(service: service, account: account)
        super.tearDown()
    }

    func testThisProcessIsRecognisedAsATestHost() {
        XCTAssertTrue(TestHost.isRunning, "precondition for everything below")
    }

    /// ⚠️ THE INVARIANT. A write through the default store must be invisible to the real Keychain.
    func testADefaultStoreNeverWritesTheLoginKeychain() {
        XCTAssertEqual(SecureKeyStorage().save(value: "sentinel", service: service, account: account), errSecSuccess)
        XCTAssertEqual(real.read(service: service, account: account), .notFound,
                       "the write reached the developer's login Keychain — the redirect is cut")
        XCTAssertEqual(SecureKeyStorage().read(service: service, account: account), .found("sentinel"),
                       "…but it must still round-trip, or every store's tests become vacuous")
    }

    /// The other direction: a real item is not readable through the default store, so a test can
    /// never observe — let alone delete — a credential the developer actually holds.
    func testADefaultStoreNeverReadsOrDeletesTheLoginKeychain() {
        XCTAssertEqual(real.save(value: "real-only", service: service, account: account), errSecSuccess)
        XCTAssertEqual(SecureKeyStorage().read(service: service, account: account), .notFound)
        XCTAssertEqual(SecureKeyStorage().delete(service: service, account: account), errSecItemNotFound)
        XCTAssertEqual(real.read(service: service, account: account), .found("real-only"),
                       "a delete through the default store must not touch the real item")
    }

    /// Every production store holds its own `SecureKeyStorage()`; the pairing service's write must
    /// be visible to the config manager's read, so the stand-in has to be process-wide.
    func testTheRedirectIsProcessWideNotPerInstance() {
        _ = SecureKeyStorage().save(value: "v", service: service, account: account)
        XCTAssertEqual(SecureKeyStorage().retrieve(service: service, account: account), "v")
    }

    /// Callers branch on `errSecItemNotFound` (`ProviderKeyStore.delete`, `MCPSecretStore.clear`);
    /// the stand-in must answer the way the Security framework does.
    func testDeleteStatusesMirrorTheRealKeychain() {
        XCTAssertEqual(SecureKeyStorage().delete(service: service, account: "never-saved"), errSecItemNotFound)
        _ = SecureKeyStorage().save(value: "v", service: service, account: account)
        XCTAssertEqual(SecureKeyStorage().delete(service: service, account: account), errSecSuccess)
        XCTAssertEqual(SecureKeyStorage().delete(service: service, account: account), errSecItemNotFound)
    }

    /// The KC-54 case end to end: `ProviderKeyStore.save` with NO stub installed — exactly as the
    /// nine tests call it — must not create an item in the PRODUCTION service.
    func testProviderKeyStoreWritesNeverReachTheProductionService() {
        let profileID = UUID()
        defer { ProviderKeyStore.delete(for: profileID) }

        XCTAssertTrue(ProviderKeyStore.save("sk-ant-sentinel", for: profileID))
        XCTAssertEqual(real.read(service: ProviderKeyStore.service, account: profileID.uuidString), .notFound,
                       "a test wrote into the developer's real com.devgentic.provider service")
        XCTAssertEqual(ProviderKeyStore.load(for: profileID), "sk-ant-sentinel")
    }

    /// ⚠️ THE DRIFT TEST. The opt-in exists for one test file. If it ever appears in production
    /// source, some store has quietly rejoined the login Keychain under XCTest — for every test
    /// that touches it.
    func testNoProductionSourceBypassesTheRedirect() throws {
        let root = try TestRepositorySource.root()
        let sourceRoot = root.appendingPathComponent("Devgentic")
        guard let files = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil) else {
            return XCTFail("cannot enumerate \(sourceRoot.path)")
        }
        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            scanned += 1
            // Code only: the declaring file's own doc comment names the opt-in to warn against it.
            let code = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            if code.contains("bypassingTestHostRedirect: true") {
                offenders.append(url.path.replacingOccurrences(of: root.path + "/", with: ""))
            }
        }
        XCTAssertGreaterThan(scanned, 100, "the scan found almost no sources — wrong root?")
        XCTAssertEqual(offenders, [], "production code opts out of the test-host Keychain redirect")
    }
}
