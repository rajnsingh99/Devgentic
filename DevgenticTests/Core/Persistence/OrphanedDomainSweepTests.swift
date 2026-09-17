// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  OrphanedDomainSweepTests.swift
//  DevgenticTests
//
//  Register KC-0: the bundle-id rename orphaned `com.dev.devgentic`'s preferences domain with its
//  plaintext credentials intact. Verified on disk 2026-09-16 — a live Telegram bot token, a Google
//  API key and a DeepSeek key, all cleartext, in a file no reader resolves to any more.
//

import XCTest
@testable import devgentic

final class OrphanedDomainSweepTests: XCTestCase {

    /// A throwaway persistent domain. `setPersistentDomain` writes a real plist under
    /// ~/Library/Preferences/, so it is removed again in tearDown.
    private let domain = "devgentic.tests.orphaned.\(UUID().uuidString)"

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: domain)
        super.tearDown()
    }

    func testEveryCredentialKeyIsRemovedAndEverythingElseIsKept() {
        UserDefaults.standard.setPersistentDomain([
            "chatOpsBotToken": "8666000000:AAF-live",
            "webSearchAPIKey": "AIza-live",
            "deepseek_api_key": "sk-live",
            "gemini_api_key": "AIza-gemini",
            "openrouter_api_key": "sk-or-live",
            "devgentic.interfaceMode": "chat",
            "useStreamingResponse": true,
        ], forName: domain)

        XCTAssertEqual(ProviderKeyStore.purgeOrphanedLegacyDomains(domainNames: [domain]), 5)

        let remaining = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        XCTAssertEqual(Set(remaining.keys), ["devgentic.interfaceMode", "useStreamingResponse"])
        XCTAssertEqual(remaining["devgentic.interfaceMode"] as? String, "chat")
    }

    func testAnAbsentDomainIsANoOp() {
        XCTAssertEqual(ProviderKeyStore.purgeOrphanedLegacyDomains(
            domainNames: ["devgentic.tests.never.\(UUID().uuidString)"]), 0)
    }

    func testADomainWithNoCredentialsIsLeftUntouched() {
        UserDefaults.standard.setPersistentDomain(["a": 1, "b": "two"], forName: domain)
        XCTAssertEqual(ProviderKeyStore.purgeOrphanedLegacyDomains(domainNames: [domain]), 0)
        let remaining = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        XCTAssertEqual(Set(remaining.keys), ["a", "b"])
    }

    func testTheSweepIsIdempotent() {
        UserDefaults.standard.setPersistentDomain(["chatOpsBotToken": "t", "keep": 1], forName: domain)
        XCTAssertEqual(ProviderKeyStore.purgeOrphanedLegacyDomains(domainNames: [domain]), 1)
        XCTAssertEqual(ProviderKeyStore.purgeOrphanedLegacyDomains(domainNames: [domain]), 0)
        XCTAssertEqual((UserDefaults.standard.persistentDomain(forName: domain) ?? [:])["keep"] as? Int, 1)
    }

    /// The three keys found on disk, plus the `<provider>_api_key` family by NAME — and nothing
    /// matched on what a value looks like.
    func testTheCredentialsFoundOnDiskAreRecognisedByName() {
        for key in ["chatOpsBotToken", "webSearchAPIKey", "deepseek_api_key", "gemini_api_key", "anthropic_api_key"] {
            XCTAssertTrue(ProviderKeyStore.isOrphanedDomainCredentialKey(key), key)
        }
        for key in ["devgentic.interfaceMode", "useStreamingResponse", "apiKeyPopupSeen", "mcp.secrets.migrated.v1"] {
            XCTAssertFalse(ProviderKeyStore.isOrphanedDomainCredentialKey(key), key)
        }
    }

    /// One identifier, named in three places for three migrations. They must agree.
    func testTheLegacyDomainIsTheOneTheOtherMigrationsName() {
        XCTAssertEqual(ProviderKeyStore.legacyPreferenceDomains, VectorStoreService.legacyBundleIdentifiers)
        XCTAssertEqual(ProviderKeyStore.legacyPreferenceDomains, ["com.dev.devgentic"])
    }

    /// The sweep rewrites a real file in ~/Library/Preferences/, and the XCTest host runs container
    /// configuration in full — so the launch site must refuse it there.
    func testTheLaunchSiteRunsTheSweepAndRefusesItUnderXCTest() throws {
        let source = try TestRepositorySource.read("Devgentic/Interfaces/Main/Views/BackendProfile/BackendProfileStore.swift")
        XCTAssertTrue(source.contains("ProviderKeyStore.purgeOrphanedLegacyDomains()"))
        XCTAssertTrue(source.contains("TestHost.permits(\"purge plaintext credentials from orphaned preference domains\""))
    }
}
