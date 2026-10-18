// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsCredentialWriteTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
final class ChatOpsCredentialWriteTests: XCTestCase {

    private var keychain: ProgrammableKeychain!
    private var config: ChatOpsConfigManager!

    override func setUp() {
        super.setUp()
        keychain = ProgrammableKeychain()
        config = ChatOpsConfigManager.shared
        ChatOpsConfigManager.setKeychainForTesting(keychain)
    }

    override func tearDown() {
        // Leave the shared manager exactly as found: no overrides, no stored credentials,
        // no error state, and the real (test-host-redirected) backend back in place.
        keychain.saveStatusOverride = nil
        keychain.deleteStatusOverride = nil
        keychain.readStatusOverride = nil
        config.reset()
        config.resetDiscord()
        config.resetSlack()
        ChatOpsConfigManager.setKeychainForTesting(nil)
        super.tearDown()
    }

    // MARK: - KC-11: the explicit writes return the OSStatus

    func testStoringATokenReturnsSuccessAndIsReadable() {
        XCTAssertEqual(config.storeBotToken("token-1"), errSecSuccess)
        XCTAssertEqual(config.botToken, "token-1")
    }

    func testARefusedSaveReturnsTheFailureAndStoresNothing() {
        keychain.saveStatusOverride = errSecAuthFailed
        XCTAssertEqual(config.storeBotToken("token-1"), errSecAuthFailed,
                       "the caller must be able to SEE that the save failed")
        XCTAssertNil(config.botToken,
                     "a refused save must leave the credential stored nowhere")
        XCTAssertTrue(keychain.store.isEmpty)
    }

    func testEveryCredentialHasAStatusReturningStore() {
        keychain.saveStatusOverride = errSecInteractionNotAllowed
        XCTAssertEqual(config.storeDiscordBotToken("d"), errSecInteractionNotAllowed)
        XCTAssertEqual(config.storeSlackBotToken("s"), errSecInteractionNotAllowed)
        XCTAssertEqual(config.storeSlackAppToken("a"), errSecInteractionNotAllowed)

        keychain.saveStatusOverride = nil
        XCTAssertEqual(config.storeDiscordBotToken("d"), errSecSuccess)
        XCTAssertEqual(config.storeSlackBotToken("s"), errSecSuccess)
        XCTAssertEqual(config.storeSlackAppToken("a"), errSecSuccess)
        XCTAssertEqual(config.discordBotToken, "d")
        XCTAssertEqual(config.slackBotToken, "s")
        XCTAssertEqual(config.slackAppToken, "a")
    }

    func testAClearReturnsSuccessAndRemovesTheCredential() {
        config.storeBotToken("token-1")
        XCTAssertEqual(config.clearBotToken(), errSecSuccess)
        XCTAssertNil(config.botToken)
    }

    func testAClearOfAnAbsentCredentialReturnsNotFoundNotSuccess() {
        // Distinguishable, and deliberately NOT folded into success: only `recordClear`
        // (and the summary) may treat it as "already cleared".
        XCTAssertEqual(config.clearBotToken(), errSecItemNotFound)
    }

    func testARefusedClearReturnsTheFailureAndKeepsTheCredential() {
        config.storeBotToken("live-token")
        keychain.deleteStatusOverride = errSecAuthFailed
        XCTAssertEqual(config.clearBotToken(), errSecAuthFailed)
        XCTAssertEqual(keychain.store[AppSettings.chatOpsBotTokenKey], "live-token",
                       "a refused delete must leave the credential in place")
    }

    func testThePropertySetterDelegatesToTheExplicitWrites() {
        config.botToken = "via-setter"
        XCTAssertEqual(config.botToken, "via-setter")
        config.botToken = nil
        XCTAssertNil(config.botToken)

        // The setter cannot return the status — the point of KC-11 is that the METHOD can,
        // and a failing save through the setter must at least store nothing.
        keychain.saveStatusOverride = errSecAuthFailed
        config.botToken = "doomed"
        XCTAssertNil(config.botToken)
    }

    // MARK: - KC-12: the reset functions tell the truth about the wipe

    func testACompleteResetReportsAllClearedAndDisconnects() {
        config.storeBotToken("token-1")
        config.connectionState = .connected(chatID: 7)

        let summary = config.reset()

        XCTAssertTrue(summary.allCleared)
        XCTAssertTrue(summary.failures.isEmpty)
        XCTAssertEqual(config.connectionState, .disconnected)
        XCTAssertNil(config.botToken)
    }

    func testARefusedDeleteLeavesTheBridgeInErrorNotDisconnected() {
        config.storeBotToken("live-token")
        keychain.deleteStatusOverride = errSecAuthFailed

        let summary = config.reset()

        XCTAssertFalse(summary.allCleared)
        XCTAssertEqual(summary.failures.count, 1)
        XCTAssertEqual(summary.failures[0].label, "the Telegram bot token")
        XCTAssertEqual(summary.failures[0].status, errSecAuthFailed)
        guard case .error(let message) = config.connectionState else {
            return XCTFail("a failed credential wipe must surface .error, got \(config.connectionState)")
        }
        XCTAssertTrue(message.contains("NOT fully disconnected"),
                      "the message must say the disconnect is incomplete: \(message)")
        XCTAssertTrue(message.contains("the Telegram bot token"),
                      "the message must name what is still stored: \(message)")
    }

    func testADeleteReportingNotFoundIsNotAFailure() {
        // Nothing was ever stored; the reset must still report a clean disconnect.
        // ⚠️ This is the asymmetry pin: treating errSecItemNotFound as a failure would
        // refuse every disconnect on a never-paired integration.
        let summary = config.reset()
        XCTAssertTrue(summary.allCleared)
        XCTAssertEqual(config.connectionState, .disconnected)
    }

    func testDiscordResetReportsARefusedDelete() {
        config.storeDiscordBotToken("live-discord")
        keychain.deleteStatusOverride = errSecInteractionNotAllowed

        let summary = config.resetDiscord()

        XCTAssertEqual(summary.failures.map(\.label), ["the Discord bot token"])
        guard case .error = config.discordConnectionState else {
            return XCTFail("Discord must surface the failed wipe, got \(config.discordConnectionState)")
        }
    }

    func testSlackResetFoldsTwoCredentialsAndOneFailureIsEnough() {
        config.storeSlackBotToken("bot")
        config.storeSlackAppToken("app")
        // One refused delete: Slack is an outage, not a half-finished disconnect.
        keychain.deleteStatusOverride = errSecAuthFailed
        var summary = config.resetSlack()
        XCTAssertEqual(summary.failures.count, 2, "both deletes were refused")
        XCTAssertEqual(Set(summary.failures.map(\.label)),
                       Set(["the Slack bot token", "the Slack app token"]))
        guard case .error = config.slackConnectionState else {
            return XCTFail("Slack must surface the failed wipe, got \(config.slackConnectionState)")
        }

        // Both intact, delete refused → both reported. Nothing about one success may
        // mask the other failure.
        config.storeSlackBotToken("bot")
        config.storeSlackAppToken("app")
        keychain.deleteStatusOverride = nil
        summary = config.resetSlack()
        XCTAssertTrue(summary.allCleared)
        XCTAssertEqual(config.slackConnectionState, .disconnected)
    }

    // MARK: - The two messages must never collapse

    func testTheSaveFailedAndUnreadableMessagesStayDistinct() {
        // credentialSaveFailedMessage: NOTHING was stored — retrying is the right advice.
        XCTAssertTrue(ChatOpsConfigManager.credentialSaveFailedMessage.contains("nothing was paired"),
                      ChatOpsConfigManager.credentialSaveFailedMessage)
        // unreadableMessage: the credential IS stored and intact — re-pairing would destroy it.
        XCTAssertTrue(ChatOpsPairingRestore.unreadableMessage.contains("Do not re-pair"),
                      ChatOpsPairingRestore.unreadableMessage)
        XCTAssertNotEqual(ChatOpsConfigManager.credentialSaveFailedMessage,
                          ChatOpsPairingRestore.unreadableMessage)
    }

    func testTheClearFailedMessageNamesItsCredentials() {
        let message = ChatOpsConfigManager.clearFailedMessage(labels: ["the Slack app token"])
        XCTAssertTrue(message.contains("the Slack app token"), message)
        XCTAssertTrue(message.contains("NOT fully disconnected"), message)
    }
}
