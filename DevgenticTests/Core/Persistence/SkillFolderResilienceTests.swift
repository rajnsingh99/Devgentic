// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SkillFolderResilienceTests.swift
//  DevgenticTests
//
//  Created on 07/08/26.
//
//  Regression test for register A12 — the `execute_shell` sourceId repair.
//
//  ⚠️ The defect was PERMANENT from the user's side: a mis-typed UUID literal produced an
//  execute_shell entry no UI could remove. That is why the fix is a data repair in the profile-blob
//  migration ladder and not just a corrected write site.
//

import XCTest
@testable import devgentic

// ⚠️ A11 (a failed rescan must not delete skill folders) WAS TESTED HERE AND IS GONE (V6).
//
// Not because it stopped mattering — it was a permanent, unrecoverable data loss — but because the
// mechanism cannot occur any more. It required a database index over folders that a scan could
// disagree with; Devgentic owns skill content now, nothing rescans, and there is no folder whose
// absence could delete anything. `AgentSkillsSection.manifestsAttributed(...)`, the function those
// tests pinned, went with the registry.
//
// The surviving half below is unrelated to skills storage and still live.

// MARK: - A12: repairing execute_shell records already on disk

final class ExecuteShellSourceIdMigrationTests: XCTestCase {

    private let builtIn = ToolSource.builtInSourceID.uuidString

    /// The literal the shipped code used. Pinned here because the whole defect is that it looks
    /// like a UUID and is not one — `S`, `K`, `I`, `L`, `U`, `T`, `O`, `H` are not hex digits.
    private let bogusLiteral = "00000000-SKIL-AUTO-SHEL-000000000000"

    func testTheOriginalSentinelLiteralNeverParsed() {
        XCTAssertNil(UUID(uuidString: bogusLiteral),
                     "if this ever parses, the migration's premise is wrong")
        XCTAssertNotNil(UUID(uuidString: builtIn))
    }

    private func agentBlob(version: Int, tools: [[String: Any]]) throws -> Data {
        let json: [String: Any] = [
            "schemaVersion": version,
            "profileType": "Agent",
            "llmConfig": ["apiProvider": "ollama", "modelName": "llama3"],
            "tools": tools,
        ]
        return try JSONSerialization.data(withJSONObject: json)
    }

    private func migratedTools(from data: Data) throws -> [[String: Any]] {
        guard case .migrated(let out) = ProfileMigrator.migrateIfNeeded(data) else {
            XCTFail("expected a migrated outcome")
            return []
        }
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: out) as? [String: Any])
        return json["tools"] as? [[String: Any]] ?? []
    }

    /// The common case: one auto-added copy carrying a random id.
    func testARandomSourceIdIsRepairedToTheBuiltInSource() throws {
        let blob = try agentBlob(version: 6, tools: [[
            "name": "execute_shell",
            "isEnabled": true,
            "requiresConfirmation": true,
            "sourceId": UUID().uuidString,
        ]])

        let tools = try migratedTools(from: blob)
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["sourceId"] as? String, builtIn)
        XCTAssertEqual(tools[0]["requiresConfirmation"] as? Bool, true)
    }

    /// ⚠️ The collision case. A user who ticked the row in the Tool Library has BOTH records; after
    /// the rewrite they would collide on `(name, sourceId)`, so the step must collapse them — and
    /// the user's own settings must win, since the auto-added copy records only that an import ran.
    func testDuplicatesCollapseAndTheUsersOwnSettingsWin() throws {
        let blob = try agentBlob(version: 6, tools: [
            [   // auto-added, random id
                "name": "execute_shell",
                "isEnabled": true,
                "requiresConfirmation": true,
                "sourceId": UUID().uuidString,
            ],
            [   // the row the user ticked, with their own confirmation preference
                "name": "execute_shell",
                "isEnabled": true,
                "requiresConfirmation": false,
                "sourceId": builtIn,
            ],
        ])

        let tools = try migratedTools(from: blob)
        let shell = tools.filter { ($0["name"] as? String) == "execute_shell" }
        XCTAssertEqual(shell.count, 1, "the duplicate must be collapsed, not left to collide")
        XCTAssertEqual(shell[0]["sourceId"] as? String, builtIn)
        XCTAssertEqual(shell[0]["requiresConfirmation"] as? Bool, false,
                       "the user's Tool Library choice must survive the repair")
    }

    /// A shell record predating the field must not be silently relaxed to auto-run.
    func testAMissingConfirmationFlagDefaultsToAsk() throws {
        let blob = try agentBlob(version: 6, tools: [[
            "name": "execute_shell",
            "isEnabled": true,
            "sourceId": UUID().uuidString,
        ]])

        let tools = try migratedTools(from: blob)
        XCTAssertEqual(tools[0]["requiresConfirmation"] as? Bool, true)
    }

    func testAnAlreadyCorrectRecordIsLeftAlone() throws {
        let blob = try agentBlob(version: 6, tools: [[
            "name": "execute_shell",
            "isEnabled": false,
            "requiresConfirmation": false,
            "sourceId": builtIn,
        ]])

        let tools = try migratedTools(from: blob)
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["sourceId"] as? String, builtIn)
        XCTAssertEqual(tools[0]["isEnabled"] as? Bool, false, "an untouched record keeps its state")
        XCTAssertEqual(tools[0]["requiresConfirmation"] as? Bool, false)
    }

    /// Other tools legitimately carry MCP source ids; the step must not touch them.
    func testOtherToolsKeepTheirSourceIds() throws {
        let mcpSource = UUID().uuidString
        let blob = try agentBlob(version: 6, tools: [
            ["name": "search_web", "isEnabled": true, "sourceId": mcpSource],
            ["name": "execute_shell", "isEnabled": true, "sourceId": UUID().uuidString],
        ])

        let tools = try migratedTools(from: blob)
        let search = try XCTUnwrap(tools.first { ($0["name"] as? String) == "search_web" })
        XCTAssertEqual(search["sourceId"] as? String, mcpSource)
    }

    func testAProfileWithNoToolsIsUnaffected() throws {
        let blob = try agentBlob(version: 6, tools: [])
        XCTAssertTrue(try migratedTools(from: blob).isEmpty)
    }

    /// The ladder's own invariant: every step stamps the version it produced.
    func testTheStepStampsTheCurrentSchemaVersion() throws {
        let blob = try agentBlob(version: 6, tools: [[
            "name": "execute_shell", "isEnabled": true, "sourceId": UUID().uuidString,
        ]])
        guard case .migrated(let out) = ProfileMigrator.migrateIfNeeded(blob) else {
            return XCTFail("expected a migrated outcome")
        }
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: out) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, ProfileMigrator.currentVersion)
    }
}
