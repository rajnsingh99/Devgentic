// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillFolderScannerTests.swift
//  DevgenticTests
//
//  Unit tests for SkillFolderScanner and YAMLFrontmatterParser.
//

import XCTest
@testable import devgentic

final class YAMLFrontmatterParserTests: XCTestCase {

    // MARK: - Valid Frontmatter

    func testParseValidFrontmatter() throws {
        let content = """
        ---
        name: code-review
        description: Review code for quality and security issues.
        ---

        # Code Review Skill
        Step 1: Read the file.
        """

        let frontmatter = try YAMLFrontmatterParser.parse(from: content)
        XCTAssertEqual(frontmatter.name, "code-review")
        XCTAssertEqual(frontmatter.description, "Review code for quality and security issues.")
    }

    func testParseMultiLineDescription() throws {
        let content = """
        ---
        name: content-audit
        description: >
          Review draft blog posts against the editorial checklist and output
          a structured feedback report.
        ---

        # Content Audit
        """

        let frontmatter = try YAMLFrontmatterParser.parse(from: content)
        XCTAssertEqual(frontmatter.name, "content-audit")
        XCTAssertTrue(frontmatter.description.contains("Review draft blog posts"))
        XCTAssertTrue(frontmatter.description.contains("structured feedback report"))
    }

    func testParseOptionalFields() throws {
        let content = """
        ---
        name: pdf-processing
        description: Extract text from PDFs and fill forms.
        license: Apache-2.0
        compatibility: Requires Python 3.14+ and uv
        ---
        """

        let frontmatter = try YAMLFrontmatterParser.parse(from: content)
        XCTAssertEqual(frontmatter.name, "pdf-processing")
        XCTAssertEqual(frontmatter.additionalFields["license"], "Apache-2.0")
        XCTAssertEqual(frontmatter.additionalFields["compatibility"], "Requires Python 3.14+ and uv")
    }

    // MARK: - Error Cases

    func testParseMissingDelimiter_throws() {
        let content = "name: test\ndescription: no delimiters"
        XCTAssertThrowsError(try YAMLFrontmatterParser.parse(from: content)) { error in
            XCTAssertTrue(error is SkillParseError)
        }
    }

    func testParseUnclosedFrontmatter_throws() {
        let content = "---\nname: test\ndescription: unclosed"
        XCTAssertThrowsError(try YAMLFrontmatterParser.parse(from: content)) { error in
            XCTAssertTrue(error is SkillParseError)
        }
    }

    func testParseMissingName_throws() {
        let content = "---\ndescription: no name field\n---"
        XCTAssertThrowsError(try YAMLFrontmatterParser.parse(from: content)) { error in
            XCTAssertTrue(error is SkillParseError)
        }
    }

    func testParseMissingDescription_throws() {
        let content = "---\nname: test-skill\n---"
        XCTAssertThrowsError(try YAMLFrontmatterParser.parse(from: content)) { error in
            XCTAssertTrue(error is SkillParseError)
        }
    }
}

// MARK: - Skill Folder Scanner Tests

final class SkillFolderScannerTests: XCTestCase {

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

    // MARK: - Helpers

    private func createSkill(name: String, description: String = "A test skill.", hasScripts: Bool = false, hasReferences: Bool = false) throws {
        let skillDir = tempDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)

        let skillContent = """
        ---
        name: \(name)
        description: \(description)
        ---

        # \(name) Skill
        Step 1: Do the thing.
        """
        try skillContent.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        if hasScripts {
            let scriptsDir = skillDir.appendingPathComponent("scripts")
            try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
            try "print('hello')".write(to: scriptsDir.appendingPathComponent("test.py"), atomically: true, encoding: .utf8)
        }

        if hasReferences {
            let refDir = skillDir.appendingPathComponent("reference")
            try FileManager.default.createDirectory(at: refDir, withIntermediateDirectories: true)
            try "# Checklist\n- Item 1".write(to: refDir.appendingPathComponent("checklist.md"), atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Scan Tests

    func testScanValidFolder_returnsManifests() throws {
        try createSkill(name: "code-review", description: "Review code quality.")
        try createSkill(name: "data-analysis", description: "Analyze datasets.")

        let manifests = try SkillFolderScanner.scan(rootFolder: tempDir)
        XCTAssertEqual(manifests.count, 2)

        let names = Set(manifests.map(\.name))
        XCTAssertTrue(names.contains("code-review"))
        XCTAssertTrue(names.contains("data-analysis"))
    }

    func testScanEmptyFolder_returnsEmpty() throws {
        let manifests = try SkillFolderScanner.scan(rootFolder: tempDir)
        XCTAssertTrue(manifests.isEmpty)
    }

    func testScanFolderWithoutSKILLmd_skipsInvalid() throws {
        // Create a directory without SKILL.md
        let invalidDir = tempDir.appendingPathComponent("no-skill")
        try FileManager.default.createDirectory(at: invalidDir, withIntermediateDirectories: true)
        try "just a readme".write(to: invalidDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        // Create a valid skill
        try createSkill(name: "valid-skill")

        let manifests = try SkillFolderScanner.scan(rootFolder: tempDir)
        XCTAssertEqual(manifests.count, 1)
        XCTAssertEqual(manifests.first?.name, "valid-skill")
    }

    func testScanNonexistentFolder_throws() {
        let bogusURL = tempDir.appendingPathComponent("does-not-exist")
        XCTAssertThrowsError(try SkillFolderScanner.scan(rootFolder: bogusURL))
    }

    // MARK: - Manifest Fields

    func testManifest_hasScripts_true() throws {
        try createSkill(name: "scripted-skill", hasScripts: true)

        let manifests = try SkillFolderScanner.scan(rootFolder: tempDir)
        XCTAssertEqual(manifests.count, 1)
        XCTAssertTrue(manifests.first!.hasScripts)
    }

    func testManifest_hasScripts_false() throws {
        try createSkill(name: "no-scripts-skill")

        let manifests = try SkillFolderScanner.scan(rootFolder: tempDir)
        XCTAssertFalse(manifests.first!.hasScripts)
    }

    func testManifest_resourceCount() throws {
        try createSkill(name: "full-skill", hasScripts: true, hasReferences: true)

        let manifests = try SkillFolderScanner.scan(rootFolder: tempDir)
        // 1 script + 1 reference = 2
        XCTAssertEqual(manifests.first!.resourceCount, 2)
    }


    // MARK: - Load Full Package

    func testLoadFullPackage_includesBodyAndResources() throws {
        try createSkill(name: "load-test", description: "Test loading.", hasScripts: true, hasReferences: true)

        let manifests = try SkillFolderScanner.scan(rootFolder: tempDir)
        let package = try SkillFolderScanner.loadFullPackage(for: manifests.first!)

        // Body should contain the markdown content after frontmatter
        XCTAssertTrue(package.body.contains("# load-test Skill"))
        XCTAssertTrue(package.body.contains("Step 1: Do the thing."))

        // Resources
        XCTAssertEqual(package.resources.count, 2)
        let scriptResource = package.resources.first(where: { $0.type == .script })
        XCTAssertNotNil(scriptResource)
        XCTAssertTrue(scriptResource!.content.contains("print('hello')"))
    }

    // MARK: - Name Validation

    func testNameValidation_uppercaseRejected() throws {
        let skillDir = tempDir.appendingPathComponent("Bad-Name")
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let content = "---\nname: Bad-Name\ndescription: Invalid.\n---"
        try content.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let manifests = try SkillFolderScanner.scan(rootFolder: tempDir)
        XCTAssertTrue(manifests.isEmpty, "Uppercase names should be rejected")
    }

    func testNameValidation_consecutiveHyphensRejected() throws {
        let skillDir = tempDir.appendingPathComponent("bad--name")
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let content = "---\nname: bad--name\ndescription: Invalid.\n---"
        try content.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let manifests = try SkillFolderScanner.scan(rootFolder: tempDir)
        XCTAssertTrue(manifests.isEmpty, "Consecutive hyphens should be rejected")
    }

    /// ⚠️ FLIPPED 2026-09-14 — this used to assert the mismatch was REJECTED.
    ///
    /// The agentskills.io "name must equal its folder name" rule was dropped. It earned its keep
    /// while a folder path was the skill's identity; under the V6 library identity is an opaque
    /// `skill_…` and the folder is discarded at ingest, so the rule only refused packages that
    /// Anthropic's own Skills API accepts (SKILL.md need sit only at the root or a top-level
    /// folder). The SHAPE check is untouched and is the one carrying the security weight — see
    /// `testNameValidation_*` above, which still reject traversal, uppercase and stray punctuation.
    func testNameValidation_mismatchWithDirectoryIsNowAccepted() throws {
        let skillDir = tempDir.appendingPathComponent("dir-name")
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let content = "---\nname: different-name\ndescription: Mismatched.\n---"
        try content.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let manifests = try SkillFolderScanner.scan(rootFolder: tempDir)
        XCTAssertEqual(manifests.map(\.name), ["different-name"],
                       "the frontmatter names the skill; the directory is only where it happened to live")
    }
}

// MARK: - Skill Models Tests

final class SkillModelsTests: XCTestCase {

    func testSkillManifest_codableRoundTrip() throws {
        let manifest = SkillManifest(
            id: UUID(),
            name: "test-skill",
            description: "A test skill for unit testing.",
            folderPath: "/tmp/skills/test-skill",
            resourceCount: 3,
            hasScripts: true,
            compatibility: "Requires Python 3.14+",
            isEnabled: true
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(SkillManifest.self, from: data)

        XCTAssertEqual(decoded.name, manifest.name)
        XCTAssertEqual(decoded.description, manifest.description)
        XCTAssertEqual(decoded.folderPath, manifest.folderPath)
        XCTAssertEqual(decoded.resourceCount, manifest.resourceCount)
        XCTAssertEqual(decoded.hasScripts, manifest.hasScripts)
        XCTAssertEqual(decoded.compatibility, manifest.compatibility)
    }

    func testSkillFolderConfig_codableRoundTrip() throws {
        let config = SkillFolderConfig(
            folderURL: URL(fileURLWithPath: "/tmp/skills"),
            manifests: [
                SkillManifest(
                    id: UUID(),
                    name: "code-review",
                    description: "Review code quality.",
                    folderPath: "/tmp/skills/code-review",
                    resourceCount: 1,
                    hasScripts: false,
                    compatibility: nil,
                    isEnabled: true
                )
            ],
            lastScannedAt: Date()
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SkillFolderConfig.self, from: data)

        XCTAssertEqual(decoded.folderURL, config.folderURL)
        XCTAssertEqual(decoded.manifests.count, 1)
        XCTAssertEqual(decoded.manifests.first?.name, "code-review")
    }
}
