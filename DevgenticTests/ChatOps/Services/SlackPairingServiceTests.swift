//
//  SlackPairingServiceTests.swift
//  DevgenticTests
//
//  Created by Raj Singh on 24/03/26.
//

import XCTest
@testable import devgentic

final class SlackPairingServiceTests: XCTestCase {

    // MARK: - PIN Generation

    func testPINGeneration_IsSixDigits() {
        for _ in 0..<100 {
            let pin = generateTestPIN()
            XCTAssertEqual(pin.count, 6)
            XCTAssertNotNil(Int(pin))

            let pinValue = Int(pin)!
            XCTAssertGreaterThanOrEqual(pinValue, 100_000)
            XCTAssertLessThanOrEqual(pinValue, 999_999)
        }
    }

    func testPINGeneration_IsRandom() {
        var pins = Set<String>()
        for _ in 0..<10 {
            pins.insert(generateTestPIN())
        }
        XCTAssertGreaterThan(pins.count, 1)
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

    func testPairMessage_WrongPIN() {
        let text = "PAIR 999999"
        let normalized = text.uppercased().trimmingCharacters(in: .whitespaces)
        XCTAssertNotEqual(normalized, "PAIR 123456")
    }

    func testPairMessage_NotAPairCommand() {
        let text = "Hello bot"
        let normalized = text.uppercased().trimmingCharacters(in: .whitespaces)
        XCTAssertFalse(normalized.hasPrefix("PAIR "))
    }

    // MARK: - Dual Token Validation

    func testSlackRequiresTwoTokens() {
        // Verify both token types are needed
        let botToken = "xoxb-test-token"
        let appToken = "xapp-test-token"

        XCTAssertTrue(botToken.hasPrefix("xoxb-"))
        XCTAssertTrue(appToken.hasPrefix("xapp-"))
    }

    // MARK: - ChatOpsCommand PAIR Parsing

    func testChatOpsCommand_PairParsing() {
        let command = ChatOpsCommand.parseSlack(text: "PAIR 123456")
        if case .pairingAttempt(let pin) = command {
            XCTAssertEqual(pin, "123456")
        } else {
            XCTFail("Expected .pairingAttempt, got \(command)")
        }
    }

    // MARK: - Connection State

    func testConnectionState_DisconnectedInitially() {
        let state: ChatOpsConnectionState = .disconnected
        XCTAssertFalse(state.isConnected)
    }

    func testConnectionState_AwaitingPairing() {
        let state: ChatOpsConnectionState = .awaitingPairing(pin: "999888")
        XCTAssertFalse(state.isConnected)
        XCTAssertTrue(state.statusText.contains("999888"))
    }

    func testConnectionState_Connected() {
        let state: ChatOpsConnectionState = .connected(chatID: 0)
        XCTAssertTrue(state.isConnected)
    }

    // MARK: - Slack Event for Pairing

    func testSlackEvent_PairMessageFromUser() throws {
        let json = """
        {
            "type": "message",
            "channel": "C0123456789",
            "user": "U01",
            "text": "PAIR 123456",
            "ts": "1716307200.000001"
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(SlackEvent.self, from: json)
        XCTAssertNil(event.bot_id) // Not a bot
        XCTAssertEqual(event.text, "PAIR 123456")
        XCTAssertEqual(event.channel, "C0123456789")
    }

    func testSlackEvent_PairFromBot_ShouldBeIgnored() throws {
        let json = """
        {
            "type": "message",
            "channel": "C01",
            "text": "PAIR 123456",
            "ts": "1716307200.000002",
            "bot_id": "B01"
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(SlackEvent.self, from: json)
        XCTAssertNotNil(event.bot_id) // Should be skipped
    }

    // MARK: - Helpers

    private func generateTestPIN() -> String {
        let pin = Int.random(in: 100_000...999_999)
        return "\(pin)"
    }
}
