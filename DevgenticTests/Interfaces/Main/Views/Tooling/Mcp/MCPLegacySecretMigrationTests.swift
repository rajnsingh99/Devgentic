// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPLegacySecretMigrationTests.swift
//  devgenticTests
//
//  Register KC-6 — the unattended launch migration that could destroy what it was migrating.
//
//  ⚠️⚠️ THE FAILURE THIS PINS. `migrateLegacySecretsIfNeeded` lifts inline `env` / `authentication`
//  values out of a pre-Phase-1 `mcpConfigData` blob into the Keychain, then REWRITES that blob into
//  the new shape — which carries only env KEY NAMES and no secret material. Every
//  `MCPSecretStore.store` return was discarded, so a Keychain write that failed left the secret in
//  NEITHER place: erased from the blob, never written to the Keychain, unrecoverable.
//
//  ⚠️ And the launch most likely to fail is the FIRST ONE AFTER AN UPDATE — exactly when a re-signed
//  binary makes macOS re-prompt for Keychain access, and an unattended login-item launch has nobody
//  there to answer the prompt.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class MCPLegacySecretMigrationTests: XCTestCase {

    private var keychain: ProgrammableKeychain!
    private var container: ModelContainer!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        keychain = ProgrammableKeychain()
        MCPSecretStore.setBackingForTesting(keychain)

        // ⚠️ A scratch suite, never `.standard`. The migration flag lives in UserDefaults, and
        // writing it into the real domain would both pollute the developer's preferences and make
        // this test pass vacuously on the second run.
        suiteName = "devgentic.tests.mcpmigration.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)

        container = try ModelContainer(
            for: MCPToolItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        MCPToolStore.shared.configureContainer(container, migrateLegacySecrets: false)
    }

    override func tearDown() {
        MCPSecretStore.setBackingForTesting(nil)
        defaults.removePersistentDomain(forName: suiteName)
        keychain = nil; container = nil; defaults = nil; suiteName = nil
        super.tearDown()
    }

    /// Inserts one pre-migration source whose secrets are still inline in the blob.
    @discardableResult
    private func insertLegacySource() throws -> (id: UUID, originalBlob: Data) {
        let legacyJSON = """
        {"command":"npx","args":["-y","@acme/mcp"],"env":{"GITHUB_TOKEN":"ghp_live_secret"},\
        "authentication":{"token":"bearer_live_secret"}}
        """
        let blob = Data(legacyJSON.utf8)
        let item = MCPToolItem(id: UUID(), serverName: "Acme", mcpConfigData: blob)
        container.mainContext.insert(item)
        try container.mainContext.save()
        return (item.id, blob)
    }

    // MARK: - The guarantee

    func testAFailedKeychainWriteLeavesTheLegacyBlobIntactAndRetriesNextLaunch() throws {
        let (_, originalBlob) = try insertLegacySource()
        keychain.saveStatusOverride = errSecAuthFailed   // denied ACL prompt on the post-update launch

        MCPToolStore.shared.migrateLegacySecretsIfNeeded(defaults: defaults)

        let items = try container.mainContext.fetch(FetchDescriptor<MCPToolItem>())
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].mcpConfigData, originalBlob,
                       "the blob is the ONLY remaining copy of a secret whose Keychain write failed — it must be left byte-intact")
        XCTAssertFalse(defaults.bool(forKey: "mcp.secrets.migrated.v1"),
                       "the one-shot flag must stay unset so the migration is retried")
    }

    /// The inverse: a working Keychain must still migrate, or the guard above would have
    /// disabled the feature rather than protected it.
    func testASuccessfulMigrationRewritesTheBlobAndStoresTheSecrets() throws {
        let (id, originalBlob) = try insertLegacySource()

        MCPToolStore.shared.migrateLegacySecretsIfNeeded(defaults: defaults)

        let items = try container.mainContext.fetch(FetchDescriptor<MCPToolItem>())
        XCTAssertNotEqual(items[0].mcpConfigData, originalBlob, "a successful migration must rewrite the blob")

        XCTAssertEqual(keychain.store["\(id.uuidString)::env.GITHUB_TOKEN"], "ghp_live_secret")
        XCTAssertEqual(keychain.store["\(id.uuidString)::auth.bearer"], "bearer_live_secret")
        XCTAssertTrue(defaults.bool(forKey: "mcp.secrets.migrated.v1"),
                      "a clean migration should set the one-shot flag")

        // The rewritten blob must carry key NAMES only — no secret material.
        let rewritten = String(data: items[0].mcpConfigData ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(rewritten.contains("GITHUB_TOKEN"), "env key names survive")
        XCTAssertFalse(rewritten.contains("ghp_live_secret"), "the env VALUE must not remain in the blob")
        XCTAssertFalse(rewritten.contains("bearer_live_secret"), "the token must not remain in the blob")
    }

    /// A secret that could not be written must not be half-migrated either: the bearer token
    /// failing must not leave the env value's blob rewritten.
    func testAPartialFailureDoesNotHalfMigrateTheSource() throws {
        let (id, originalBlob) = try insertLegacySource()
        keychain.saveStatusOverride = errSecIO

        MCPToolStore.shared.migrateLegacySecretsIfNeeded(defaults: defaults)

        let items = try container.mainContext.fetch(FetchDescriptor<MCPToolItem>())
        XCTAssertEqual(items[0].mcpConfigData, originalBlob)
        XCTAssertNil(keychain.store["\(id.uuidString)::env.GITHUB_TOKEN"])
        XCTAssertFalse(defaults.bool(forKey: "mcp.secrets.migrated.v1"))
    }

    /// The flag short-circuits the whole pass — pinned so the guard above cannot be reached by
    /// accident on a machine that has already migrated.
    func testTheMigrationIsSkippedOnceTheFlagIsSet() throws {
        let (_, originalBlob) = try insertLegacySource()
        defaults.set(true, forKey: "mcp.secrets.migrated.v1")

        MCPToolStore.shared.migrateLegacySecretsIfNeeded(defaults: defaults)

        let items = try container.mainContext.fetch(FetchDescriptor<MCPToolItem>())
        XCTAssertEqual(items[0].mcpConfigData, originalBlob, "an already-migrated install must not be touched")
        XCTAssertTrue(keychain.store.isEmpty)
    }
}
