//
//  SkillFolderResilienceTests.swift
//  DevgenticTests
//
//  Created on 07/08/26.
//
//  Regression tests for the AgentSkillsSection cluster (register A11, A12).
//
//  ⚠️ Both defects were PERMANENT from the user's side — a transient scan failure deleted skill
//  folders that remounting did not bring back, and a mis-typed UUID literal produced an
//  execute_shell entry no UI could remove. Neither was recoverable by hand, which is why the fixes
//  include a data repair and not just a corrected write site.
//

import XCTest
@testable import devgentic

// MARK: - A11: a failed rescan must not delete

final class SkillFolderRescanRetentionTests: XCTestCase {

    private func manifest(name: String, folderPath: String, enabled: Bool = true) -> SkillManifest {
        SkillManifest(
            id: UUID(),
            name: name,
            description: "d",
            folderPath: folderPath,
            resourceCount: 0,
            hasScripts: false,
            compatibility: nil,
            isEnabled: enabled
        )
    }

    /// The carry-forward rule: manifests are attributed to a root folder by their `folderPath`.
    func testManifestsAreAttributedToTheirRootFolder() {
        let all = [
            manifest(name: "a", folderPath: "/Users/x/skills/alpha"),
            manifest(name: "b", folderPath: "/Users/x/skills/beta"),
            manifest(name: "c", folderPath: "/Users/x/other/gamma"),
        ]
        let carried = AgentSkillsSection.manifests(
            in: all, under: URL(fileURLWithPath: "/Users/x/skills"))

        XCTAssertEqual(carried.map(\.name), ["a", "b"])
    }

    /// ⚠️ Without the trailing separator, `/Users/x/skills` also claims `/Users/x/skills_backup`,
    /// pulling an unrelated folder's skills into the one that failed to scan.
    func testASiblingFolderWithASharedPrefixIsNotClaimed() {
        let all = [
            manifest(name: "mine", folderPath: "/Users/x/skills/alpha"),
            manifest(name: "theirs", folderPath: "/Users/x/skills_backup/alpha"),
        ]
        let carried = AgentSkillsSection.manifests(
            in: all, under: URL(fileURLWithPath: "/Users/x/skills"))

        XCTAssertEqual(carried.map(\.name), ["mine"])
    }

    func testTrailingSlashesAndRelativeSegmentsAreNormalized() {
        let all = [manifest(name: "a", folderPath: "/Users/x/skills/sub/../alpha")]

        XCTAssertEqual(
            AgentSkillsSection.manifests(in: all, under: URL(fileURLWithPath: "/Users/x/skills/")).count, 1)
        XCTAssertEqual(
            AgentSkillsSection.manifests(in: all, under: URL(fileURLWithPath: "/Users/x/skills")).count, 1)
    }

    func testAnUnrelatedFolderCarriesNothing() {
        let all = [manifest(name: "a", folderPath: "/Users/x/skills/alpha")]
        XCTAssertTrue(AgentSkillsSection.manifests(
            in: all, under: URL(fileURLWithPath: "/Volumes/External/skills")).isEmpty)
    }
}

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
