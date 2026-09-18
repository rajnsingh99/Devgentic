// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SlackSocketClientTests.swift
//  DevgenticTests
//
//  Created by Raj Singh on 24/03/26.
//

import XCTest
@testable import devgentic

final class SlackSocketClientTests: XCTestCase {

    // MARK: - Envelope Acknowledgment Format

    func testSocketAck_CorrectFormat() throws {
        let ack = SlackSocketAck(envelope_id: "env-test-123")
        let data = try JSONEncoder().encode(ack)
        let decoded = try JSONDecoder().decode(SlackSocketAck.self, from: data)

        XCTAssertEqual(decoded.envelope_id, "env-test-123")
    }

    func testSocketAck_JSONShape() throws {
        let ack = SlackSocketAck(envelope_id: "abc-def")
        let data = try JSONEncoder().encode(ack)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: String]

        XCTAssertEqual(dict.count, 1)
        XCTAssertEqual(dict["envelope_id"], "abc-def")
    }

    // MARK: - Socket Mode Event Types

    func testSocketPayload_EventsAPIType() throws {
        let json = """
        { "type": "events_api", "envelope_id": "env-1" }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(SlackSocketPayload.self, from: json)
        XCTAssertEqual(payload.type, "events_api")
        XCTAssertEqual(payload.envelope_id, "env-1")
    }

    func testSocketPayload_InteractiveType() throws {
        let json = """
        { "type": "interactive", "envelope_id": "env-2" }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(SlackSocketPayload.self, from: json)
        XCTAssertEqual(payload.type, "interactive")
    }

    func testSocketPayload_SlashCommandsType() throws {
        let json = """
        { "type": "slash_commands", "envelope_id": "env-3" }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(SlackSocketPayload.self, from: json)
        XCTAssertEqual(payload.type, "slash_commands")
    }

    func testSocketPayload_DisconnectType() throws {
        let json = """
        { "type": "disconnect" }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(SlackSocketPayload.self, from: json)
        XCTAssertEqual(payload.type, "disconnect")
        XCTAssertNil(payload.envelope_id)
    }

    func testSocketPayload_HelloType() throws {
        let json = """
        { "type": "hello" }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(SlackSocketPayload.self, from: json)
        XCTAssertEqual(payload.type, "hello")
    }

    // MARK: - Retry Handling

    func testSocketPayload_RetryAttempt() throws {
        let json = """
        { "type": "events_api", "envelope_id": "env-4", "retry_attempt": 2, "retry_reason": "timeout" }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(SlackSocketPayload.self, from: json)
        XCTAssertEqual(payload.retry_attempt, 2)
        XCTAssertEqual(payload.retry_reason, "timeout")
    }

    // MARK: - Connection Open Response

    func testConnectionOpen_ReturnsWSURL() throws {
        let json = """
        { "ok": true, "url": "wss://wss-primary.slack.com/link/?ticket=abc" }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(SlackConnectionOpenResponse.self, from: json)
        XCTAssertTrue(response.ok)
        XCTAssertTrue(response.url!.hasPrefix("wss://"))
    }
}
