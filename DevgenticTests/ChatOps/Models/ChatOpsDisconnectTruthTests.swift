// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsDisconnectTruthTests.swift
//  DevgenticTests
//
//  Register KC-33. A failed Keychain read collapses `config.botToken` to nil, which used to make
//  the disconnect farewell silently skip AND leave the bridge reporting a clean, verified
//  disconnect — while the farewell was the user's only notice that the bot was gone. The fix:
//  every disconnect captures the credential state BEFORE the reset, logs the summary's truth
//  (KC-12), and on an unreadable credential leaves the bridge in `.error`, never `.disconnected`.
//
//  No farewell path is exercised here: a locked Keychain yields a nil token (farewell skipped),
//  and the healthy path deliberately stores a token without an authorized chat id for the same
//  reason — these tests must never touch the network.
//

import XCTest
@testable import devgentic

@MainActor
final class ChatOpsDisconnectTruthTests: XCTestCase {

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

    func testAHealthyDisconnectIsStillClean() {
        config.storeBotToken("token")
        config.connectionState = .connected(chatID: 3)

        let expectation = expectation(description: "disconnect")
        Task { @MainActor in
            await ChatOpsPairingService().disconnect()
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)

        XCTAssertEqual(config.connectionState, .disconnected,
                       "an intact disconnect must stay clean — the fix adds truth to failures only")
        XCTAssertNil(config.botToken)
    }

    func testAnUnreadableCredentialNeverReportsACleanDisconnect() {
        keychain.readStatusOverride = errSecAuthFailed
        keychain.deleteStatusOverride = errSecAuthFailed
        config.connectionState = .connected(chatID: 3)

        let expectation = expectation(description: "disconnect")
        Task { @MainActor in
            await ChatOpsPairingService().disconnect()
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)

        guard case .error(let message) = config.connectionState else {
            return XCTFail("a disconnect that could not verify its wipe must be .error, got \(config.connectionState)")
        }
        XCTAssertTrue(message.contains("Do not re-pair"),
                      "the unreadable message's advice holds: nothing was verified, re-pairing could destroy an intact credential: \(message)")
    }

    func testDiscordDisconnectSurfacesTheUnreadableCase() {
        keychain.readStatusOverride = errSecInteractionNotAllowed
        keychain.deleteStatusOverride = errSecInteractionNotAllowed
        config.discordConnectionState = .connected(chatID: 3)

        let expectation = expectation(description: "disconnect")
        Task { @MainActor in
            await DiscordPairingService().disconnect()
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)

        guard case .error = config.discordConnectionState else {
            return XCTFail("Discord must surface the unverified wipe, got \(config.discordConnectionState)")
        }
    }

    func testSlackDisconnectFoldsBothCredentialsAndAnyUnreadableIsEnough() {
        keychain.readStatusOverride = errSecInteractionNotAllowed
        keychain.deleteStatusOverride = errSecInteractionNotAllowed
        config.slackConnectionState = .connected(chatID: 3)

        let expectation = expectation(description: "disconnect")
        Task { @MainActor in
            await SlackPairingService().disconnect()
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)

        guard case .error = config.slackConnectionState else {
            return XCTFail("Slack must surface the unverified wipe, got \(config.slackConnectionState)")
        }
    }

    func testARefusedDeleteKeepsTheBridgeInErrorWithTheNamedCredential() {
        // Not unreadable — READABLE, but the delete refuses. KC-12's summary drives the state;
        // the disconnect must not downgrade it.
        config.storeBotToken("live-token")
        keychain.deleteStatusOverride = errSecAuthFailed

        let expectation = expectation(description: "disconnect")
        Task { @MainActor in
            await ChatOpsPairingService().disconnect()
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)

        guard case .error(let message) = config.connectionState else {
            return XCTFail("a refused delete must stay .error, got \(config.connectionState)")
        }
        XCTAssertTrue(message.contains("NOT fully disconnected"), message)
    }
}
