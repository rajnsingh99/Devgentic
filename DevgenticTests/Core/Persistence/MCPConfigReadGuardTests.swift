// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPConfigReadGuardTests.swift
//  devgenticTests
//
//  Covers G22: `mcpConfigData` was the last blob column read with a bare `try?`, which made an
//  UNREADABLE configuration indistinguishable from an ABSENT one. Both produced
//  `serverDefinition == nil`; the server then failed to connect with no command, URL or auth
//  scheme, and nothing in the log said the stored bytes were the problem rather than the server.
//
//  The two cases need opposite responses — an absent config means "finish setting this up", an
//  unreadable one means "do NOT delete this, its Keychain secrets are keyed off envKeys inside
//  the blob" — so the test that matters is that they are now *distinguishable*.
//

import XCTest
@testable import devgentic

@MainActor
final class MCPConfigReadGuardTests: XCTestCase {

    private func item(named name: String, config: Data?) -> MCPToolItem {
        MCPToolItem(id: UUID(), serverName: name, mcpConfigData: config)
    }

    // MARK: - The three states are distinguishable

    func testReadableConfigurationDecodesAndIsNotFlagged() throws {
        let definition = ServerDefinition(
            command: "/usr/bin/env",
            args: ["npx", "-y", "@modelcontextprotocol/server-filesystem"],
            envKeys: ["API_TOKEN"]
        )
        let blob = BlobVersioning.stamped(
            try JSONEncoder().encode(definition),
            version: MCPToolItem.configBlobVersion
        )

        let source = item(named: "filesystem", config: blob).toToolSource()

        XCTAssertFalse(source.isConfigurationUnreadable)
        XCTAssertEqual(source.serverDefinition?.command, "/usr/bin/env")
        XCTAssertEqual(source.serverDefinition?.envKeys, ["API_TOKEN"])
    }

    func testAbsentConfigurationIsNotFlaggedAsUnreadable() {
        // A row that has never been configured. `serverDefinition` is nil, but nothing is wrong
        // with the stored bytes — there are none. Flagging this would send the user hunting for
        // corruption that does not exist.
        let source = item(named: "half-configured", config: nil).toToolSource()

        XCTAssertFalse(source.isConfigurationUnreadable)
        XCTAssertNil(source.serverDefinition)
    }

    func testUnreadableConfigurationIsFlaggedAndDistinctFromAbsent() {
        let garbage = Data("{ not json at all".utf8)

        let unreadable = item(named: "corrupt", config: garbage).toToolSource()
        let absent = item(named: "empty", config: nil).toToolSource()

        XCTAssertTrue(unreadable.isConfigurationUnreadable)
        XCTAssertNil(unreadable.serverDefinition)

        // The whole point of G22: these two used to be the same observation.
        XCTAssertNotEqual(unreadable.isConfigurationUnreadable, absent.isConfigurationUnreadable)
    }

    /// Well-formed JSON of the WRONG shape is the realistic corruption, not random bytes. It is NOT
    /// caught by the decode guard and must not be reported as unreadable: every property of
    /// `ServerDefinition` is optional or defaulted, so such JSON decodes cleanly into an all-nil
    /// definition. There is no decoding error to catch.
    ///
    /// The bytes really were readable, so `isConfigurationUnreadable` staying false is correct — the
    /// flag's advice ("do not delete, Keychain secrets are keyed off envKeys in this blob") would be
    /// wrong here. What makes the case safe is that a definition with neither `command` nor `url`
    /// cannot build a transport, so `MCPClientService.connect` throws `.invalidJSONConfiguration`
    /// rather than failing obscurely, and `toToolSource` logs the condition at load.
    func testWellFormedJSONOfTheWrongShapeDecodesEmptyRatherThanFailing() {
        let wrongShape = Data(#"{"schemaVersion":1,"somethingElse":true}"#.utf8)

        let source = item(named: "shape-drift", config: wrongShape).toToolSource()

        XCTAssertFalse(source.isConfigurationUnreadable)
        XCTAssertNotNil(source.serverDefinition)
        // The property that makes it unusable — and the one the connect path guards on.
        XCTAssertNil(source.serverDefinition?.command)
        XCTAssertNil(source.serverDefinition?.url)
    }

    /// The connect path's own precondition, asserted here so the two stay in step: a definition
    /// with neither transport is the exact input `MCPClientService` rejects.
    func testATransportlessDefinitionIsTheCaseTheConnectPathRejects() {
        let transportless = ServerDefinition()

        XCTAssertNil(transportless.command)
        XCTAssertNil(transportless.url)
    }

    // MARK: - The bytes are not touched

    /// The read guard must never "repair" by writing. An unreadable blob stays byte-identical so a
    /// build that understands the shape can still read it — the same rule as every other column.
    func testAnUnreadableConfigurationIsLeftByteIdenticalOnDisk() {
        let garbage = Data("{ not json at all".utf8)
        let row = item(named: "corrupt", config: garbage)

        _ = row.toToolSource()
        _ = row.toToolSource()

        XCTAssertEqual(row.mcpConfigData, garbage)
    }

    // MARK: - Child tools are unaffected

    /// A server whose config is unreadable still lists the tools it discovered previously; those
    /// live in their own rows. Dropping them too would turn one bad column into total loss.
    func testChildToolsSurviveAnUnreadableConfiguration() {
        let row = item(named: "corrupt", config: Data("nope".utf8))
        row.tools.append(
            MCPToolDefinitionModel(name: "read_file", toolDescription: "Reads a file")
        )

        let source = row.toToolSource()

        XCTAssertTrue(source.isConfigurationUnreadable)
        XCTAssertEqual(source.tools.map(\.name), ["read_file"])
    }
}
