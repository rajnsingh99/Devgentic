// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPConfigBlobIntegrityTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class MCPConfigBlobIntegrityTests: XCTestCase {

    private var keychain: ProgrammableKeychain!
    private var container: ModelContainer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        keychain = ProgrammableKeychain()
        MCPSecretStore.setBackingForTesting(keychain)
        container = try ModelContainer(
            for: MCPToolItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        MCPToolStore.shared.configureContainer(container)
    }

    override func tearDown() {
        MCPSecretStore.setBackingForTesting(nil)
        MCPToolStore.blobIntegrityLogSinkForTesting = nil
        container = nil
        keychain = nil
        super.tearDown()
    }

    private func insertSource(name: String, blob: Data?) throws -> MCPToolItem {
        let item = MCPToolItem(id: UUID(), serverName: name, mcpConfigData: blob)
        container.mainContext.insert(item)
        try container.mainContext.save()
        return item
    }

    // MARK: - KC-37: updateTool over an unreadable blob

    /// An edit whose previous env-key set is UNKNOWABLE must not purge anything — and must say
    /// so. The `try?` that used to compute `previousEnvKeys` turned an undecodable blob into an
    /// empty key set and skipped the purge in complete silence, leaving the secret orphaned with
    /// nothing pointing at it.
    func testUpdatingASourceWithAnUndecodableBlobPurgesNothingButLogsTheSkip() throws {
        var logged: [String] = []
        MCPToolStore.blobIntegrityLogSinkForTesting = { logged.append($0) }

        let item = try insertSource(name: "Acme", blob: Data("not json at all".utf8))
        let envAccount = "\(item.id.uuidString)::env.GITHUB_TOKEN"
        keychain.store[envAccount] = "ghp_live_secret"

        // The user's edit drops the env key — but the OLD key set cannot be read to know that.
        MCPToolStore.shared.updateTool(
            id: item.id,
            serverName: "Acme",
            serverDefinition: ServerDefinition(command: "npx", args: ["-y", "@acme/mcp"], envKeys: nil),
            secrets: MCPRuntimeSecrets(),
            newTools: [])

        XCTAssertEqual(keychain.store[envAccount], "ghp_live_secret",
                       "an unknowable previous key set must purge NOTHING — deleting on an "
                       + "uncertain read is the KC-1 hazard")
        XCTAssertEqual(logged.count, 1, "the skipped purge must be logged, not silent: \(logged)")
        XCTAssertTrue(logged.first?.contains("UNDECODABLE") == true, logged.first ?? "no message")
        XCTAssertTrue(logged.first?.contains(item.id.uuidString) == true, logged.first ?? "no message")
        XCTAssertTrue(logged.first?.contains("CONSEQUENCE") == true, logged.first ?? "no message")
    }

    /// The nil-blob twin: the row exists but carries no configuration at all, so the same
    /// unknowable-key-set skip applies and must be stated. (This is the row shape the KC-38
    /// addTool defect could create: secrets written, blob never persisted.)
    func testUpdatingASourceWithNoBlobPurgesNothingButLogsTheSkip() throws {
        var logged: [String] = []
        MCPToolStore.blobIntegrityLogSinkForTesting = { logged.append($0) }

        let item = try insertSource(name: "Acme", blob: nil)
        let envAccount = "\(item.id.uuidString)::env.GITHUB_TOKEN"
        keychain.store[envAccount] = "ghp_live_secret"

        MCPToolStore.shared.updateTool(
            id: item.id,
            serverName: "Acme",
            serverDefinition: ServerDefinition(command: "npx", args: ["-y", "@acme/mcp"], envKeys: nil),
            secrets: MCPRuntimeSecrets(),
            newTools: [])

        XCTAssertEqual(keychain.store[envAccount], "ghp_live_secret")
        XCTAssertEqual(logged.count, 1, "a MISSING blob must be logged the same as an undecodable one: \(logged)")
        XCTAssertTrue(logged.first?.contains("MISSING") == true, logged.first ?? "no message")
    }

    /// The healthy path is unchanged: a decodable blob still drives the real purge of keys the
    /// user removed, or this guard would have made removed env secrets impossible to drop.
    func testUpdatingADecodableBlobStillPurgesTheRemovedEnvKey() throws {
        var logged: [String] = []
        MCPToolStore.blobIntegrityLogSinkForTesting = { logged.append($0) }

        let original = ServerDefinition(command: "npx", args: ["-y", "@acme/mcp"], envKeys: ["GITHUB_TOKEN"])
        let blob = BlobVersioning.stamped(try JSONEncoder().encode(original), version: MCPToolItem.configBlobVersion)
        let item = try insertSource(name: "Acme", blob: blob)
        let envAccount = "\(item.id.uuidString)::env.GITHUB_TOKEN"
        keychain.store[envAccount] = "ghp_live_secret"

        MCPToolStore.shared.updateTool(
            id: item.id,
            serverName: "Acme",
            serverDefinition: ServerDefinition(command: "npx", args: ["-y", "@acme/mcp"], envKeys: nil),
            secrets: MCPRuntimeSecrets(),
            newTools: [])

        XCTAssertNil(keychain.store[envAccount],
                     "a readable previous key set that the edit removed must still be purged")
        XCTAssertTrue(logged.isEmpty, "nothing is skipped, so nothing is logged: \(logged)")
    }

    // MARK: - KC-38: deleteTool over a missing blob, and the addTool row that creates one

    /// Deleting a source whose blob is nil cannot name its env-var secrets (the names lived in
    /// the blob), so they are left in the Keychain with nothing referencing them. The row still
    /// gets deleted — the user asked for that — but the orphaning must be stated. Only the
    /// UNDECODABLE case said so before; the nil case returned an empty key set in silence.
    func testDeletingASourceWithNoBlobLogsItsOrphanedEnvSecrets() throws {
        var logged: [String] = []
        MCPToolStore.blobIntegrityLogSinkForTesting = { logged.append($0) }

        let item = try insertSource(name: "Acme", blob: nil)
        let envAccount = "\(item.id.uuidString)::env.GITHUB_TOKEN"
        keychain.store[envAccount] = "ghp_live_secret"

        MCPToolStore.shared.deleteTool(toolSource: item.toToolSource())

        let remaining = try container.mainContext.fetch(FetchDescriptor<MCPToolItem>())
        XCTAssertTrue(remaining.isEmpty, "the user asked for deletion; the row must go")
        XCTAssertEqual(keychain.store[envAccount], "ghp_live_secret",
                       "with no blob the env key cannot be named, so the secret must be left — "
                       + "not guessed at")
        XCTAssertEqual(logged.count, 1, "the orphaning must be logged, not silent: \(logged)")
        XCTAssertTrue(logged.first?.contains("MISSING") == true, logged.first ?? "no message")
        XCTAssertTrue(logged.first?.contains(item.id.uuidString) == true, logged.first ?? "no message")
    }

    /// ⚠️ THE DEFECT, STATED AS AN ABSENCE. `addTool` used to build the row's blob with
    /// `try? JSONEncoder(...)` — AFTER `persistSecrets` had already written the env values. An
    /// encoder failure therefore created exactly the row the test above is about: secrets in the
    /// Keychain, no blob to name them, unidentifiable on delete. The definition must be encoded
    /// BEFORE any secret is written, and a failure must refuse the add.
    ///
    /// A plain `ServerDefinition` cannot be made to fail `JSONEncoder`, so this is a wiring pin —
    /// the same shape `MCPServerAddFlowTests` uses for KC-5, where the failure also cannot be
    /// forced through a real value.
    func testAddToolEncodesTheDefinitionBeforeAnySecretIsWritten() throws {
        let source = try TestRepositorySource.read(
            "Devgentic/Interfaces/Main/Views/Tooling/Mcp/MCPToolStore.swift")
        let bodyStart = try XCTUnwrap(source.range(of: "func addTool("),
                                      "addTool not found — the store was restructured; re-derive this pin")
        let bodyEnd = try XCTUnwrap(source.range(of: "func isServerNameTaken(",
                                                 range: bodyStart.upperBound..<source.endIndex))
        let body = String(source[bodyStart.lowerBound..<bodyEnd.lowerBound])

        XCTAssertFalse(body.contains("try? JSONEncoder"),
                       "addTool must not build mcpConfigData with try? — a nulled blob after "
                       + "persistSecrets creates a source whose env secrets cannot be identified "
                       + "on delete")

        let encodeGuard = try XCTUnwrap(body.range(of: "do {"),
                                        "the definition must be encoded in a do/catch that can refuse the add")
        let persistCall = try XCTUnwrap(body.range(of: "persistSecrets("))
        XCTAssertLessThan(encodeGuard.lowerBound, persistCall.lowerBound,
                          "the definition must be encoded BEFORE any secret is written — "
                          + "otherwise a failed encode orphans what persistSecrets just stored")
    }
}
