// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPServerLifecycleTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class MCPServerLifecycleTests: XCTestCase {

    // MARK: - Transport persistence

    /// Every server saved before the transport picker existed was streaming, so absence
    /// must decode to `.streamableHTTP` — not to whatever the enum's first case happens
    /// to be, and not fail the decode and take the whole server with it.
    func testServerDefinition_LegacyJSONWithoutTransport_DefaultsToStreamable() throws {
        // Genuinely legacy: predates both the transport picker AND the auth field, so
        // neither key is present. Both must default rather than fail the decode — a throw
        // here would make the whole server undecodable and drop it from the library.
        let json = #"{"url":"https://mcp.example.com/sse"}"#
        let definition = try JSONDecoder().decode(ServerDefinition.self, from: Data(json.utf8))
        XCTAssertEqual(definition.transport, .streamableHTTP)
        XCTAssertEqual(definition.auth, .none)
        XCTAssertEqual(definition.url, "https://mcp.example.com/sse")
    }

    func testServerDefinition_TransportRoundTrips() throws {
        for mode in MCPTransportMode.allCases {
            let original = ServerDefinition(url: "https://mcp.example.com", transport: mode)
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(ServerDefinition.self, from: data)
            XCTAssertEqual(decoded.transport, mode, "Round-trip failed for \(mode)")
        }
    }

    func testServerDefinition_DefaultIsStreamable() {
        XCTAssertEqual(ServerDefinition(url: "https://example.com").transport, .streamableHTTP)
    }

    /// Local servers are stdio; the field exists but must not disturb their round-trip.
    func testServerDefinition_LocalProcess_StillRoundTrips() throws {
        let original = ServerDefinition(command: "npx", args: ["-y", "server"], envKeys: ["API_KEY"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ServerDefinition.self, from: data)
        XCTAssertEqual(decoded.command, "npx")
        XCTAssertEqual(decoded.args, ["-y", "server"])
        XCTAssertEqual(decoded.envKeys, ["API_KEY"])
    }

    /// Only the streaming mode can carry server→client push.
    func testTransportModes_ExplanationsDistinguishStreaming() {
        XCTAssertTrue(MCPTransportMode.streamableHTTP.explanation.lowercased().contains("required"))
        XCTAssertTrue(MCPTransportMode.httpNoStreaming.explanation.lowercased().contains("not work"))
        XCTAssertNotEqual(MCPTransportMode.streamableHTTP.displayName, MCPTransportMode.httpNoStreaming.displayName)
    }

    // MARK: - ToolSource enablement

    /// `isEnabled` defaults to true, so any mapping layer that forgets to pass it through
    /// silently re-enables servers the user switched off. This pins the default and the
    /// explicit value.
    func testToolSource_EnablementDefaultsToTrueButIsSettable() {
        let enabled = ToolSource(
            id: UUID(), type: .mcp, serverName: "S", tools: [], serverDefinition: nil
        )
        XCTAssertTrue(enabled.isEnabled, "Existing sources must keep working")

        let disabled = ToolSource(
            id: UUID(), type: .mcp, serverName: "S", tools: [], serverDefinition: nil, isEnabled: false
        )
        XCTAssertFalse(disabled.isEnabled)
    }

    // MARK: - Status summary (drives the composer banner)

    private func status(active: Int, total: Int, failed: Int, disabled: Int) -> MCPConnectionCoordinator.Status {
        MCPConnectionCoordinator.Status(active: active, total: total, failed: failed, disabled: disabled)
    }

    func testStatus_AllConnected_IsAllActive() {
        let s = status(active: 3, total: 3, failed: 0, disabled: 0)
        XCTAssertTrue(s.allActive)
        XCTAssertTrue(s.hasAny)
    }

    func testStatus_PartiallyConnected_IsNotAllActive() {
        XCTAssertFalse(status(active: 2, total: 3, failed: 1, disabled: 0).allActive)
    }

    /// Nothing configured at all — the banner renders nothing rather than "0/0".
    func testStatus_NothingConfigured_HasNothingToShow() {
        XCTAssertFalse(status(active: 0, total: 0, failed: 0, disabled: 0).hasAny)
    }

    /// Everything switched off still counts as "has any": the user should be told their
    /// tools are absent by their own earlier choice, which is easy to forget.
    func testStatus_AllDisabled_StillReportsSomething() {
        let s = status(active: 0, total: 0, failed: 0, disabled: 2)
        XCTAssertTrue(s.hasAny)
        XCTAssertTrue(s.allActive, "0 of 0 enabled servers are connected — vacuously true, and must not read as a failure")
    }

    func testStatus_IsEquatable() {
        XCTAssertEqual(status(active: 1, total: 2, failed: 1, disabled: 0),
                       status(active: 1, total: 2, failed: 1, disabled: 0))
        XCTAssertNotEqual(status(active: 1, total: 2, failed: 1, disabled: 0),
                          status(active: 2, total: 2, failed: 0, disabled: 0))
    }
}
