// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SkillsIntegrationTests.swift
//  DevgenticTests
//
//  Integration tests for the Skills pipeline:
//  ProfileDetails Codable round-trip, system prompt injection, and LoadSkillTool.
//

import XCTest
@testable import devgentic

// MARK: - ProfileDetails Codable Round-Trip Tests

final class ProfileDetailsSkillCodableTests: XCTestCase {

    func testRoundTrip_agentConfigWithSkillConfig() throws {
        let skillConfig = SkillFolderConfig(
            folderURL: URL(fileURLWithPath: "/Users/test/my-skills"),
            manifests: [
                SkillManifest(
                    id: UUID(),
                    name: "code-review",
                    description: "Review PRs against team standards.",
                    folderPath: "/Users/test/my-skills/code-review",
                    resourceCount: 2,
                    hasScripts: true,
                    compatibility: "Requires Python 3.14+",
                    isEnabled: true
                ),
                SkillManifest(
                    id: UUID(),
                    name: "data-analysis",
                    description: "Analyze datasets and produce reports.",
                    folderPath: "/Users/test/my-skills/data-analysis",
                    resourceCount: 0,
                    hasScripts: false,
                    compatibility: nil,
                    isEnabled: true
                )
            ],
            lastScannedAt: Date()
        )

        let agentConfig = AgentConfig(
            llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"),
            tools: [],
            instructions: "You are a helpful assistant.",
            skillConfig: skillConfig
        )

        let details = ProfileDetails.agent(agentConfig)

        // Encode
        let encoder = JSONEncoder()
        let data = try encoder.encode(details)

        // Decode
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ProfileDetails.self, from: data)

        // Verify
        guard case .agent(let decodedConfig) = decoded else {
            XCTFail("Expected .agent case")
            return
        }

        XCTAssertNotNil(decodedConfig.skillConfig)
        XCTAssertEqual(decodedConfig.skillConfig?.manifests.count, 2)
        XCTAssertEqual(decodedConfig.skillConfig?.manifests.first?.name, "code-review")
        XCTAssertEqual(decodedConfig.skillConfig?.manifests.first?.hasScripts, true)
        XCTAssertEqual(decodedConfig.skillConfig?.manifests.first?.compatibility, "Requires Python 3.14+")
        XCTAssertEqual(decodedConfig.skillConfig?.manifests.last?.name, "data-analysis")
        XCTAssertEqual(decodedConfig.skillConfig?.folderURL.path, "/Users/test/my-skills")
        XCTAssertEqual(decodedConfig.instructions, "You are a helpful assistant.")
    }

    func testDecode_agentConfigWithoutSkillConfig_nilSkills() throws {
        // Simulate a v4 profile JSON without skillConfig (backward compatibility)
        let json: [String: Any] = [
            "schemaVersion": 4,
            "profileType": "Agent",
            // ⚠️ `ApiProvider` is a display-string enum — `.ollama.rawValue` is "Ollama (Local)",
            // not "ollama". This fixture hard-coded the case name and had been failing to decode
            // ever since; derive it so a future rawValue change updates the fixture too.
            "llmConfig": [
                "apiProvider": ApiProvider.ollama.rawValue,
                "modelName": "llama3"
            ],
            "tools": [] as [[String: Any]],
            "capabilities": [String: Any]()
        ]

        let data = try JSONSerialization.data(withJSONObject: json)

        // Migrate (v4 → v5 stamps version, but no data changes needed)
        guard case .migrated(let migratedData) = ProfileMigrator.migrateIfNeeded(data) else {
            return XCTFail("Expected a migratable blob, got a refusal")
        }
        let decoded = try JSONDecoder().decode(ProfileDetails.self, from: migratedData)

        guard case .agent(let config) = decoded else {
            XCTFail("Expected .agent case")
            return
        }

        XCTAssertNil(config.skillConfig, "Old profiles without skillConfig should decode with nil")
    }
}

// MARK: - System Prompt Injection Tests

final class SkillPromptInjectionTests: XCTestCase {

    func testSkillDiscoveryLayerInjectedInSystemPrompt() {
        let manifests: [SkillManifest] = [
            SkillManifest(
                id: UUID(),
                name: "code-review",
                description: "Review PRs against team standards.",
                folderPath: "/tmp/code-review",
                resourceCount: 0,
                hasScripts: false,
                compatibility: nil,
                isEnabled: true
            ),
            SkillManifest(
                id: UUID(),
                name: "data-analysis",
                description: "Analyze datasets and produce reports.",
                folderPath: "/tmp/data-analysis",
                resourceCount: 0,
                hasScripts: false,
                compatibility: nil,
                isEnabled: true
            )
        ]

        let context = SemanticContext(
            instructions: "You are a helpful assistant.",
            environmentFacts: EnvironmentFacts(
                osVersion: "macOS 15.4",
                shellType: "zsh",
                userName: "testuser",
                homeDirectory: "/Users/testuser",
                currentDate: "2026-04-10"
            ),
            longTermMemory: StaticGroundingMemory(ragContext: ""),
            recentHistory: nil,
            nativeHistoryTurns: nil,
            originalQuery: "Review my code",
            currentIteration: 1,
            compiledScratchpad: "",
            latestClarification: nil,
            negativeConstraints: [],
            hallucinatedTools: [],
            availableTools: [],
            userProfile: nil,
            skillManifests: manifests,
            promptLayerConfig: .agent,
            workflowContext: nil
        )

        let generator = NativeStructuredGenerator()
        let messages = generator.compileMessages(from: context)

        // Find system message
        let systemMessage = messages.first(where: { $0["role"] == "system" })
        XCTAssertNotNil(systemMessage)

        let systemContent = systemMessage!["content"] ?? ""

        // Verify skills discovery block is present
        XCTAssertTrue(systemContent.contains("<available_skills>"), "System prompt should contain <available_skills> block")
        XCTAssertTrue(systemContent.contains("code-review: Review PRs"), "Should contain code-review skill")
        XCTAssertTrue(systemContent.contains("data-analysis: Analyze datasets"), "Should contain data-analysis skill")
        XCTAssertTrue(systemContent.contains("load_skill"), "Should mention load_skill tool")
    }

    func testNoSkills_noDiscoveryBlock() {
        let context = SemanticContext(
            instructions: "You are a helpful assistant.",
            environmentFacts: EnvironmentFacts(
                osVersion: "macOS 15.4",
                shellType: "zsh",
                userName: "testuser",
                homeDirectory: "/Users/testuser",
                currentDate: "2026-04-10"
            ),
            longTermMemory: StaticGroundingMemory(ragContext: ""),
            recentHistory: nil,
            nativeHistoryTurns: nil,
            originalQuery: "Hello",
            currentIteration: 1,
            compiledScratchpad: "",
            latestClarification: nil,
            negativeConstraints: [],
            hallucinatedTools: [],
            availableTools: [],
            userProfile: nil,
            skillManifests: nil,
            promptLayerConfig: .agent,
            workflowContext: nil
        )

        let generator = NativeStructuredGenerator()
        let messages = generator.compileMessages(from: context)

        let systemContent = messages.first(where: { $0["role"] == "system" })?["content"] ?? ""
        XCTAssertFalse(systemContent.contains("<available_skills>"), "No skills = no discovery block")
    }
}

// MARK: - LoadSkillTool Tests

final class LoadSkillToolTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func createSkillOnDisk(name: String, body: String = "Step 1: Do the thing.", hasScripts: Bool = false) throws -> SkillManifest {
        let skillDir = tempDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)

        let content = """
        ---
        name: \(name)
        description: A test skill.
        ---

        \(body)
        """
        try content.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        if hasScripts {
            let scriptsDir = skillDir.appendingPathComponent("scripts")
            try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
            try "print('validate')".write(to: scriptsDir.appendingPathComponent("validate.py"), atomically: true, encoding: .utf8)
        }

        return try SkillFolderScanner.parseManifest(
            from: skillDir.appendingPathComponent("SKILL.md"),
            folderPath: skillDir.path
        )
    }

    func testCall_validSkillName_returnsBody() async throws {
        let manifest = try createSkillOnDisk(name: "test-skill", body: "# Process\n1. Read the file.\n2. Analyze it.")
        let tool = LoadSkillTool(manifests: [manifest])

        let args = LoadSkillTool.Arguments.mock(skillName: "test-skill")
        let result = try await tool.call(arguments: args)

        XCTAssertTrue(result.contains("# Skill: test-skill"))
        XCTAssertTrue(result.contains("# Process"))
        XCTAssertTrue(result.contains("Read the file"))
    }

    func testCall_invalidSkillName_returnsError() async throws {
        let manifest = try createSkillOnDisk(name: "real-skill")
        let tool = LoadSkillTool(manifests: [manifest])

        let args = LoadSkillTool.Arguments.mock(skillName: "nonexistent")
        let result = try await tool.call(arguments: args)

        XCTAssertTrue(result.contains("Error"))
        XCTAssertTrue(result.contains("nonexistent"))
        XCTAssertTrue(result.contains("real-skill"))
    }

    func testCall_withResources_includesResourceContent() async throws {
        let manifest = try createSkillOnDisk(name: "scripted-skill", hasScripts: true)
        let tool = LoadSkillTool(manifests: [manifest])

        let args = LoadSkillTool.Arguments.mock(skillName: "scripted-skill", includeResources: true)
        let result = try await tool.call(arguments: args)

        XCTAssertTrue(result.contains("# Skill Resources"))
        XCTAssertTrue(result.contains("validate.py"))
        XCTAssertTrue(result.contains("print('validate')"))
    }

    func testCall_withoutResources_excludesResourceContent() async throws {
        let manifest = try createSkillOnDisk(name: "scripted-skill", hasScripts: true)
        let tool = LoadSkillTool(manifests: [manifest])

        let args = LoadSkillTool.Arguments.mock(skillName: "scripted-skill", includeResources: false)
        let result = try await tool.call(arguments: args)

        XCTAssertFalse(result.contains("# Skill Resources"))
    }
}

// MARK: - Test Helpers

extension LoadSkillTool.Arguments {
    /// Creates a mock Arguments instance for testing without going through JSON decoding.
    static func mock(skillName: String, includeResources: Bool? = nil) -> LoadSkillTool.Arguments {
        let json: [String: Any] = {
            var dict: [String: Any] = ["skill_name": skillName]
            if let include = includeResources {
                dict["include_resources"] = include
            }
            return dict
        }()
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(LoadSkillTool.Arguments.self, from: data)
    }
}
