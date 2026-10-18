// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillsIntegrationTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

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

    func testCall_invalidSkillName_returnsError() async throws {
        let manifest = try createSkillOnDisk(name: "real-skill")
        let tool = LoadSkillTool(manifests: [manifest])

        let args = LoadSkillTool.Arguments.mock(skillName: "nonexistent")
        let result = try await tool.call(arguments: args)

        XCTAssertTrue(result.contains("Error"))
        XCTAssertTrue(result.contains("nonexistent"))
        XCTAssertTrue(result.contains("real-skill"))
    }

    /// A manifest straight from a folder scan carries no library version. Only resolution produces
    /// a loadable manifest, so the tool refuses this one instead of reading the folder.
    func testCall_unversionedManifest_isRefused() async throws {
        let manifest = try createSkillOnDisk(name: "scanned-skill")
        XCTAssertNil(manifest.versionID, "precondition: a scan does not version")
        let tool = LoadSkillTool(manifests: [manifest])

        let result = try await tool.call(arguments: .mock(skillName: "scanned-skill"))

        XCTAssertTrue(result.contains("Error loading skill"), result)
        XCTAssertTrue(result.contains("was not resolved from the skill library"), result)
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
