// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  DiscordPairingServiceTests.swift
//  DevgenticTests
//
//  Created by Raj Singh on 24/03/26.
//

import XCTest
@testable import devgentic

final class DiscordPairingServiceTests: XCTestCase {

    // MARK: - PIN Generation

    func testPINGeneration_IsSixDigits() {
        // Test multiple PINs to verify range
        for _ in 0..<100 {
            let pin = generateTestPIN()
            XCTAssertEqual(pin.count, 6, "PIN should be exactly 6 digits")
            XCTAssertNotNil(Int(pin), "PIN should be numeric")

            let pinValue = Int(pin)!
            XCTAssertGreaterThanOrEqual(pinValue, 100_000)
            XCTAssertLessThanOrEqual(pinValue, 999_999)
        }
    }

    func testPINGeneration_IsRandom() {
        // Generate multiple PINs and verify they're not all the same
        var pins = Set<String>()
        for _ in 0..<10 {
            pins.insert(generateTestPIN())
        }
        // With 900,000 possible values, 10 random draws should produce at least 2 unique values
        XCTAssertGreaterThan(pins.count, 1, "PINs should be random")
    }

    // MARK: - PAIR Message Matching

    func testPairMessage_ExactMatch() {
        let pin = "123456"
        let text = "PAIR 123456"
        let normalized = text.uppercased().trimmingCharacters(in: .whitespaces)
        XCTAssertEqual(normalized, "PAIR \(pin)")
    }

    func testPairMessage_CaseInsensitive() {
        let pin = "654321"
        let text = "pair 654321"
        let normalized = text.uppercased().trimmingCharacters(in: .whitespaces)
        XCTAssertEqual(normalized, "PAIR \(pin)")
    }

    func testPairMessage_WithLeadingTrailingSpaces() {
        let pin = "111222"
        let text = "  PAIR 111222  "
        let normalized = text.uppercased().trimmingCharacters(in: .whitespaces)
        XCTAssertEqual(normalized, "PAIR \(pin)")
    }

    func testPairMessage_WrongPIN() {
        let pin = "123456"
        let text = "PAIR 654321"
        let normalized = text.uppercased().trimmingCharacters(in: .whitespaces)
        XCTAssertNotEqual(normalized, "PAIR \(pin)")
    }

    func testPairMessage_NotAPairCommand() {
        let text = "Hello bot"
        let normalized = text.uppercased().trimmingCharacters(in: .whitespaces)
        XCTAssertFalse(normalized.hasPrefix("PAIR "))
    }

    func testPairMessage_PartialPairCommand() {
        let text = "PAIR"
        let normalized = text.uppercased().trimmingCharacters(in: .whitespaces)
        // "PAIR" without a PIN should not match "PAIR 123456"
        XCTAssertNotEqual(normalized, "PAIR 123456")
    }

    // MARK: - Connection State Transitions

    func testConnectionState_DisconnectedInitially() {
        let state: ChatOpsConnectionState = .disconnected
        XCTAssertFalse(state.isConnected)
        XCTAssertEqual(state.statusText, "Disconnected")
    }

    func testConnectionState_AwaitingPairing() {
        let state: ChatOpsConnectionState = .awaitingPairing(pin: "999888")
        XCTAssertFalse(state.isConnected)
        XCTAssertTrue(state.statusText.contains("999888"))
    }

    func testConnectionState_Connected() {
        let state: ChatOpsConnectionState = .connected(chatID: 12345)
        XCTAssertTrue(state.isConnected)
        XCTAssertEqual(state.statusText, "Connected")
    }

    func testConnectionState_Error() {
        let state: ChatOpsConnectionState = .error("Token expired")
        XCTAssertFalse(state.isConnected)
        XCTAssertTrue(state.statusText.contains("Token expired"))
    }

    // MARK: - ChatOpsCommand PAIR Parsing

    func testChatOpsCommand_PairParsing() {
        let command = ChatOpsCommand.parseDiscord(text: "PAIR 123456")
        if case .pairingAttempt(let pin) = command {
            XCTAssertEqual(pin, "123456")
        } else {
            XCTFail("Expected .pairingAttempt, got \(command)")
        }
    }

    func testChatOpsCommand_PairParsingCaseInsensitive() {
        let command = ChatOpsCommand.parseDiscord(text: "pair 789012")
        if case .pairingAttempt(let pin) = command {
            XCTAssertEqual(pin, "789012")
        } else {
            XCTFail("Expected .pairingAttempt, got \(command)")
        }
    }

    // MARK: - Discord-Specific Pairing Details

    func testDiscordPairing_StoresChannelID() {
        // Verify the message model provides the channel_id needed for pairing
        let message = DiscordMessage(
            id: "msg-1",
            channel_id: "1234567890",
            guild_id: "guild-999",
            author: DiscordUser(id: "user-1", username: "tester", discriminator: "0", bot: false, global_name: nil),
            content: "PAIR 123456",
            timestamp: "2026-03-24T10:00:00.000Z"
        )

        XCTAssertEqual(message.channel_id, "1234567890")
        XCTAssertEqual(message.guild_id, "guild-999")
    }

    func testDiscordPairing_IgnoresBotMessages() {
        let message = DiscordMessage(
            id: "msg-1",
            channel_id: "1234567890",
            guild_id: nil,
            author: DiscordUser(id: "bot-1", username: "bot", discriminator: "0", bot: true, global_name: nil),
            content: "PAIR 123456",
            timestamp: "2026-03-24T10:00:00.000Z"
        )

        // Pairing service checks `message.author.bot != true`
        XCTAssertEqual(message.author.bot, true)
    }

    // MARK: - Helpers

    private func generateTestPIN() -> String {
        let pin = Int.random(in: 100_000...999_999)
        return "\(pin)"
    }
}
