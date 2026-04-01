//
//  DiscordGatewayClientTests.swift
//  DevgenticTests
//
//  Created by Raj Singh on 24/03/26.
//

import XCTest
@testable import devgentic

final class DiscordGatewayClientTests: XCTestCase {

    // MARK: - Heartbeat Interval Extraction

    func testHelloPayload_ExtractsHeartbeatInterval() throws {
        let json = """
        { "heartbeat_interval": 41250 }
        """.data(using: .utf8)!

        let hello = try JSONDecoder().decode(DiscordHelloPayload.self, from: json)
        XCTAssertEqual(hello.heartbeat_interval, 41250)
    }

    func testHelloPayload_CustomInterval() throws {
        let json = """
        { "heartbeat_interval": 30000 }
        """.data(using: .utf8)!

        let hello = try JSONDecoder().decode(DiscordHelloPayload.self, from: json)
        XCTAssertEqual(hello.heartbeat_interval, 30000)
    }

    // MARK: - IDENTIFY Payload Construction

    func testIdentifyPayload_CorrectIntents() throws {
        let payload = DiscordIdentifyPayload(
            token: "test-bot-token",
            intents: DiscordIdentifyPayload.defaultIntents,
            properties: .default
        )

        XCTAssertEqual(payload.token, "test-bot-token")
        XCTAssertEqual(payload.intents, 33281)
        XCTAssertEqual(payload.properties.os, "macos")
        XCTAssertEqual(payload.properties.browser, "devgentic")
        XCTAssertEqual(payload.properties.device, "devgentic")
    }

    func testIdentifyPayload_Serialization() throws {
        let payload = DiscordIdentifyPayload(
            token: "my-token",
            intents: DiscordIdentifyPayload.defaultIntents,
            properties: .default
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(DiscordIdentifyPayload.self, from: data)

        XCTAssertEqual(decoded.token, "my-token")
        XCTAssertEqual(decoded.intents, 33281)
    }

    // MARK: - Connection Properties CodingKeys

    func testConnectionProperties_UsesDollarPrefixKeys() throws {
        let props = DiscordConnectionProperties.default
        let data = try JSONEncoder().encode(props)
        let json = String(data: data, encoding: .utf8)!

        XCTAssertTrue(json.contains("$os"))
        XCTAssertTrue(json.contains("$browser"))
        XCTAssertTrue(json.contains("$device"))
    }

    // MARK: - Gateway Opcodes

    func testGatewayOpcodes_CorrectRawValues() {
        XCTAssertEqual(DiscordGatewayOpcode.dispatch.rawValue, 0)
        XCTAssertEqual(DiscordGatewayOpcode.heartbeat.rawValue, 1)
        XCTAssertEqual(DiscordGatewayOpcode.identify.rawValue, 2)
        XCTAssertEqual(DiscordGatewayOpcode.resume.rawValue, 6)
        XCTAssertEqual(DiscordGatewayOpcode.reconnect.rawValue, 7)
        XCTAssertEqual(DiscordGatewayOpcode.invalidSession.rawValue, 9)
        XCTAssertEqual(DiscordGatewayOpcode.hello.rawValue, 10)
        XCTAssertEqual(DiscordGatewayOpcode.heartbeatAck.rawValue, 11)
    }

    // MARK: - Resume Payload

    func testResumePayload_Serialization() throws {
        let payload = DiscordResumePayload(
            token: "bot-token",
            session_id: "session-123",
            seq: 42
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(DiscordResumePayload.self, from: data)

        XCTAssertEqual(decoded.token, "bot-token")
        XCTAssertEqual(decoded.session_id, "session-123")
        XCTAssertEqual(decoded.seq, 42)
    }

    // MARK: - Gateway Intents Calculation

    func testIntents_GuildsBit() {
        XCTAssertEqual(1 << 0, 1) // GUILDS
    }

    func testIntents_GuildMessagesBit() {
        XCTAssertEqual(1 << 9, 512) // GUILD_MESSAGES
    }

    func testIntents_MessageContentBit() {
        XCTAssertEqual(1 << 15, 32768) // MESSAGE_CONTENT
    }

    func testIntents_CombinedValue() {
        let combined = (1 << 0) | (1 << 9) | (1 << 15)
        XCTAssertEqual(combined, 33281)
        XCTAssertEqual(combined, DiscordIdentifyPayload.defaultIntents)
    }
}
