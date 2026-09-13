// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ChatOpsKeychainMigrationTests.swift
//  devgenticTests
//
//  The bundle-identifier rename, and what it does to five credentials.
//
//  ⚠️⚠️ THE FAILURE THIS PINS. `ChatOpsConfigManager.keychainService` is
//  `Bundle.main.bundleIdentifier`, and commit `2faad1c` changed that identifier from
//  `com.dev.devgentic` to `app.devgentic.macos`. A Keychain item is addressed by (service, account),
//  so on the first launch after that build every ChatOps credential became unreachable at once:
//  all five reads returned nothing, all three bridges declined to start, and the Settings UI offered
//  "Start Pairing" as though the user had never paired. Nothing was deleted — the items were still
//  there under a name no code asked for — so three live third-party bot tokens would have sat in the
//  user's Keychain forever.
//
//  ⚠️ THE STUB DISTINGUISHES SERVICES, which the one in `ProviderKeyStorageTests` deliberately does
//  not (it keys on `account` alone, because nothing it tests varies the service). A migration test
//  that could not tell two services apart would pass against a no-op migration.
//

import XCTest
@testable import devgentic

final class ChatOpsKeychainMigrationTests: XCTestCase {

    /// The identifier shipped before `2faad1c`. Must match
    /// `ChatOpsConfigManager.legacyKeychainServices`.
    private let legacyService = "com.dev.devgentic"

    /// What the running test bundle resolves `keychainService` to. Read from the same expression
    /// production uses, so the test cannot disagree with it about which service is "current".
    private var currentService: String { Bundle.main.bundleIdentifier ?? "app.devgentic.macos" }

    private let telegram = AppSettings.chatOpsBotTokenKey
    private let discord  = AppSettings.chatOpsDiscordBotTokenKey
    private let slackBot = AppSettings.chatOpsSlackBotTokenKey
    private let slackApp = AppSettings.chatOpsSlackAppTokenKey

    // MARK: - The migration itself

    func testCredentialsUnderThePreviousBundleIdentifierAreMovedForward() {
        let keychain = ServiceAwareStubKeychain()
        keychain.put("tg-token", service: legacyService, account: telegram)
        keychain.put("dc-token", service: legacyService, account: discord)
        keychain.put("sl-bot",   service: legacyService, account: slackBot)
        keychain.put("sl-app",   service: legacyService, account: slackApp)

        let migrated = ChatOpsConfigManager.migrateCredentialsFromLegacyServices(keychain: keychain)

        XCTAssertEqual(migrated, 4, "all four ChatOps credentials should migrate")
        XCTAssertEqual(keychain.value(service: currentService, account: telegram), "tg-token")
        XCTAssertEqual(keychain.value(service: currentService, account: discord), "dc-token")
        XCTAssertEqual(keychain.value(service: currentService, account: slackBot), "sl-bot")
        XCTAssertEqual(keychain.value(service: currentService, account: slackApp), "sl-app")

        for account in [telegram, discord, slackBot, slackApp] {
            XCTAssertNil(
                keychain.value(service: legacyService, account: account),
                """
                `\(account)` was copied forward but the old item survives. A live third-party bot \
                token left under a service nothing reads is a credential the user cannot find to \
                revoke.
                """
            )
        }
    }

    func testMigrationIsIdempotent() {
        let keychain = ServiceAwareStubKeychain()
        keychain.put("tg-token", service: legacyService, account: telegram)

        XCTAssertEqual(ChatOpsConfigManager.migrateCredentialsFromLegacyServices(keychain: keychain), 1)
        XCTAssertEqual(ChatOpsConfigManager.migrateCredentialsFromLegacyServices(keychain: keychain), 0,
                       "a second run has nothing left to move")
        XCTAssertEqual(keychain.value(service: currentService, account: telegram), "tg-token")
    }

    /// ⚠️ A CURRENT VALUE ALWAYS WINS. If the user re-paired after the rename, the fresh token is
    /// the real one and a stale legacy copy must never overwrite it.
    func testACurrentCredentialIsNeverOverwrittenByALegacyOne() {
        let keychain = ServiceAwareStubKeychain()
        keychain.put("stale-old", service: legacyService, account: telegram)
        keychain.put("fresh-new", service: currentService, account: telegram)

        _ = ChatOpsConfigManager.migrateCredentialsFromLegacyServices(keychain: keychain)

        XCTAssertEqual(keychain.value(service: currentService, account: telegram), "fresh-new",
                       "the re-paired token must survive")
        XCTAssertNil(keychain.value(service: legacyService, account: telegram),
                     "the superseded copy should be swept rather than left in the user's Keychain")
    }

    // MARK: - The destructive branches

    /// ⚠️⚠️ THE WHOLE SAFETY ARGUMENT FOR USING `read` RATHER THAN `retrieve`. `retrieve` collapses
    /// "the Keychain refused to answer" into nil, which here reads as "nothing is stored under the
    /// current service" — and the response to that is to copy a legacy value forward and DELETE it.
    /// A locked or re-signed Keychain would then destroy the only copy, with no user action
    /// involved at any point. This is the same class of defect as register B2.
    func testAnUnreadableCurrentServiceNeverTriggersAMigration() {
        let keychain = ServiceAwareStubKeychain()
        keychain.put("tg-token", service: legacyService, account: telegram)
        keychain.failReads(forService: currentService, with: errSecInteractionNotAllowed)

        let migrated = ChatOpsConfigManager.migrateCredentialsFromLegacyServices(keychain: keychain)

        XCTAssertEqual(migrated, 0, "an unreadable current service must not be treated as empty")
        XCTAssertEqual(keychain.value(service: legacyService, account: telegram), "tg-token",
                       "the only surviving copy of the credential must not be deleted")
        XCTAssertEqual(keychain.deleteCallCount, 0, "nothing may be deleted on an unreadable Keychain")
    }

    /// ⚠️ A FAILED WRITE MUST NOT DELETE THE SOURCE. The user is asked to re-pair either way, but
    /// leaving the legacy item in place means a retry after the Keychain becomes writable recovers
    /// it — deleting it makes the loss permanent. A login-item launch before first unlock is the
    /// ordinary way a write fails, and that is exactly when this sweep runs.
    func testAFailedWriteLeavesTheLegacyCredentialIntact() {
        let keychain = ServiceAwareStubKeychain()
        keychain.put("tg-token", service: legacyService, account: telegram)
        keychain.saveStatus = errSecIO

        let migrated = ChatOpsConfigManager.migrateCredentialsFromLegacyServices(keychain: keychain)

        XCTAssertEqual(migrated, 0)
        XCTAssertEqual(keychain.value(service: legacyService, account: telegram), "tg-token",
                       "the source must survive a failed write so a later retry can recover it")
        XCTAssertEqual(keychain.deleteCallCount, 0)
    }

    func testNothingHappensWhenThereIsNothingToMigrate() {
        let keychain = ServiceAwareStubKeychain()
        XCTAssertEqual(ChatOpsConfigManager.migrateCredentialsFromLegacyServices(keychain: keychain), 0)
        XCTAssertEqual(keychain.deleteCallCount, 0)
    }

    // MARK: - Coverage drift

    /// ⚠️ THE MIGRATION'S COVERAGE IS A HARDCODED LIST, so a credential added to
    /// `ChatOpsConfigManager` without being added to `credentialAccounts` is a credential the NEXT
    /// rename silently drops. This reads the real source and fails when the two disagree.
    func testEveryKeychainBackedCredentialIsCoveredByTheMigration() throws {
        let source = try ChatOpsSecurityTierMatrixTests.readSource("Devgentic/ChatOps/Models/ChatOpsConfig.swift")

        // Every account key handed to the Keychain anywhere in the file.
        var used = Set<String>()
        for line in source.split(separator: "\n") where line.contains("account: AppSettings.") {
            guard let range = line.range(of: "account: AppSettings.") else { continue }
            let rest = line[range.upperBound...]
            let key = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            used.insert(String(key))
        }
        XCTAssertFalse(used.isEmpty, "precondition: the file stores credentials by AppSettings key")

        // Everything listed in the migration's coverage array.
        guard let listStart = source.range(of: "credentialAccounts = ["),
              let listEnd = source.range(of: "]", range: listStart.upperBound..<source.endIndex) else {
            return XCTFail("Could not find `credentialAccounts` in ChatOpsConfig.swift")
        }
        let listBody = source[listStart.upperBound..<listEnd.lowerBound]
        let covered = Set(
            listBody.split(separator: ",").compactMap { entry -> String? in
                guard let r = entry.range(of: "AppSettings.") else { return nil }
                return String(entry[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        )

        let missing = used.subtracting(covered)
        XCTAssertTrue(missing.isEmpty, """
            These Keychain-backed credentials are NOT in `ChatOpsConfigManager.credentialAccounts`, \
            so the next bundle-identifier change loses them silently: \(missing.sorted()).
            Add them to the list in the same change that adds the credential.
            """)
    }

    /// The outgoing identifier must stay listed. Dropping it re-opens the original defect for every
    /// user who has not yet launched the new build.
    func testThePreviousBundleIdentifierIsStillListedAsLegacy() throws {
        let source = try ChatOpsSecurityTierMatrixTests.readSource("Devgentic/ChatOps/Models/ChatOpsConfig.swift")
        XCTAssertTrue(source.contains("\"com.dev.devgentic\""), """
            `com.dev.devgentic` is no longer in `legacyKeychainServices`. Every install that has not \
            yet run a build containing the migration still holds its credentials under that service; \
            removing it strands them permanently.
            """)
    }

    // MARK: - Stub

    /// A Keychain that, unlike the one in `ProviderKeyStorageTests`, keys on (service, account) —
    /// without which a migration test cannot fail against a no-op migration.
    private final class ServiceAwareStubKeychain: KeychainAccessing, @unchecked Sendable {
        private var stored: [String: String] = [:]
        private var failingService: (service: String, status: OSStatus)?
        var saveStatus: OSStatus = errSecSuccess
        var deleteStatus: OSStatus = errSecSuccess
        private(set) var deleteCallCount = 0

        private func key(_ service: String, _ account: String) -> String { "\(service)|\(account)" }

        func put(_ value: String, service: String, account: String) {
            stored[key(service, account)] = value
        }

        func value(service: String, account: String) -> String? {
            stored[key(service, account)]
        }

        func failReads(forService service: String, with status: OSStatus) {
            failingService = (service, status)
        }

        func save(value: String, service: String, account: String) -> OSStatus {
            guard saveStatus == errSecSuccess else { return saveStatus }
            stored[key(service, account)] = value
            return errSecSuccess
        }

        func read(service: String, account: String) -> KeychainReadOutcome {
            if let failingService, failingService.service == service {
                return .failed(failingService.status)
            }
            if let v = stored[key(service, account)] { return .found(v) }
            return .notFound
        }

        func delete(service: String, account: String) -> OSStatus {
            deleteCallCount += 1
            guard deleteStatus == errSecSuccess else { return deleteStatus }
            stored[key(service, account)] = nil
            return errSecSuccess
        }
    }
}
