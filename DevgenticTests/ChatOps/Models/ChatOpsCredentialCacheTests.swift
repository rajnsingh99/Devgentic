// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsCredentialCacheTests.swift
//  DevgenticTests
//
//  Registers KC-29 + KC-47. Every credential getter used to issue an uncached synchronous
//  `SecItemCopyMatching` per access — the Settings pane evaluates several credentials per
//  keystroke, and the notification path reads them too. The fix memoizes one value per account
//  behind ONE rule that must never be broken:
//
//      a FAILED read is never memoized.
//
//  That rule is KC-8's lesson applied prospectively: a cache that stores "absent" off a locked
//  Keychain read hides a live credential for the rest of the process. The test that pins it
//  drives a failing backend, reads twice, clears the failure, and asserts the NEXT read goes to
//  the Keychain again and sees the value.
//

import XCTest
@testable import devgentic

@MainActor
final class ChatOpsCredentialCacheTests: XCTestCase {

    private var keychain: ProgrammableKeychain!
    private var config: ChatOpsConfigManager!

    override func setUp() {
        super.setUp()
        keychain = ProgrammableKeychain()
        config = ChatOpsConfigManager.shared
        ChatOpsConfigManager.setKeychainForTesting(keychain)
        config.refreshCredentialCache()
    }

    override func tearDown() {
        keychain.saveStatusOverride = nil
        keychain.deleteStatusOverride = nil
        keychain.readStatusOverride = nil
        config.reset()
        config.resetDiscord()
        config.resetSlack()
        ChatOpsConfigManager.setKeychainForTesting(nil)
        super.tearDown()
    }

    func testRepeatedGetterReadsHitTheBackendOnce() {
        _ = config.botToken
        _ = config.botToken
        _ = config.botToken
        XCTAssertEqual(keychain.readCount, 1,
                       "the second and third reads must be served from the cache (KC-29/KC-47)")
    }

    func testAStoredValueIsCachedOnTheFoundPathToo() {
        keychain.store[AppSettings.chatOpsBotTokenKey] = "direct"
        config.refreshCredentialCache()
        _ = config.botToken
        _ = config.botToken
        XCTAssertEqual(keychain.readCount, 1,
                       "the .found arm must also populate the cache — an absent token exercises the .notFound arm only")
    }

    func testEachAccountIsCachedIndependently() {
        _ = config.botToken
        _ = config.discordBotToken
        _ = config.botToken
        _ = config.slackAppToken
        XCTAssertEqual(keychain.readCount, 3, "three distinct accounts, three backend reads")
    }

    func testAWriteThroughPopulatesTheCacheWithoutABackendRead() {
        let readsBeforeStore = keychain.readCount
        config.storeBotToken("fresh-token")
        XCTAssertEqual(keychain.readCount, readsBeforeStore, "the write must populate the cache itself")
        XCTAssertEqual(config.botToken, "fresh-token")
        XCTAssertEqual(keychain.readCount, readsBeforeStore, "the getter must be served by the cache")
    }

    func testAClearPopulatesTheCacheAsAbsent() {
        config.storeBotToken("token")
        let readsBeforeClear = keychain.readCount
        config.clearBotToken()
        XCTAssertNil(config.botToken)
        XCTAssertEqual(keychain.readCount, readsBeforeClear, "the clear must update the cache, not just the Keychain")
    }

    func testAFailedReadIsNeverMemoized() {
        keychain.store[AppSettings.chatOpsBotTokenKey] = "live-token"
        keychain.readStatusOverride = errSecAuthFailed

        XCTAssertNil(config.botToken, "a failed read reports absent for THIS read only")
        let readsWhileFailing = keychain.readCount
        _ = config.botToken
        XCTAssertEqual(keychain.readCount, readsWhileFailing + 1,
                       "a failed read must NOT enter the cache — every read retries (the KC-8 shape)")

        keychain.readStatusOverride = nil
        XCTAssertEqual(config.botToken, "live-token",
                       "a recovered Keychain must be observed on the very next read")
    }

    func testARefusedSaveInvalidatesTheCache() {
        _ = config.botToken // populate
        keychain.saveStatusOverride = errSecAuthFailed
        config.storeBotToken("doomed")
        let readsBeforeVerify = keychain.readCount
        _ = config.botToken
        XCTAssertEqual(keychain.readCount, readsBeforeVerify + 1,
                       "after an uncertain save the cache must not claim anything")
    }

    func testRefreshCredentialCacheForcesABackendRead() {
        config.storeBotToken("token")
        keychain.store[AppSettings.chatOpsBotTokenKey] = "changed-behind-our-back"
        XCTAssertEqual(config.botToken, "token", "the cache holds until refreshed")
        config.refreshCredentialCache()
        XCTAssertEqual(config.botToken, "changed-behind-our-back",
                       "the migration (and tests) write through the backend outside this cache")
    }
}
