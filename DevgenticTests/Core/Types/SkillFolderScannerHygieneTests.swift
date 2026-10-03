// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillFolderScannerHygieneTests.swift
//  devgenticTests
//
//  The S0 hygiene fixes in `SkillFolderScanner`: deterministic scan order (a real regression
//  test), and the symlinked-resource-subdirectory behaviour (CHARACTERIZATION only — see the
//  note above those tests; they pass with and without the guard).
//
//  Kept separate from `SkillFolderScannerTests` so the fixtures here (symlinks, deliberate
//  out-of-order names) cannot quietly change what those tests are asserting.
//

import XCTest
@testable import devgentic

final class SkillFolderScannerHygieneTests: XCTestCase {

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

    @discardableResult
    private func createSkill(name: String, in root: URL? = nil) throws -> URL {
        let skillDir = (root ?? tempDir).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let content = """
        ---
        name: \(name)
        description: A test skill named \(name).
        ---

        # \(name)
        Do the thing.
        """
        try content.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return skillDir
    }

    // MARK: - Deterministic order

    /// Scan order reaches the model. `<available_skills>` renders the manifest array in the order
    /// it was built, so filesystem order — which is neither alphabetical nor stable across
    /// machines — used to decide the bytes of the system prompt. Two users with byte-identical
    /// skill folders sent different prompts, and a re-import could reorder one user's own prompt
    /// and invalidate the KV-cache prefix.
    ///
    /// Created deliberately out of order, because creation order is what an unsorted
    /// `contentsOfDirectory` is most likely to echo back on a fresh directory.
    func testScanOrder_IsAlphabeticalRegardlessOfCreationOrder() throws {
        for name in ["zebra-tool", "alpha-tool", "middle-tool", "beta-tool"] {
            try createSkill(name: name)
        }

        let names = try SkillFolderScanner.scan(rootFolder: tempDir).map(\.name)

        XCTAssertEqual(names, ["alpha-tool", "beta-tool", "middle-tool", "zebra-tool"],
                       "skills must scan in a stable, machine-independent order — this order is prompt bytes")
    }

    func testScanOrder_IsStableAcrossRepeatedScans() throws {
        for name in ["gamma", "alpha", "delta", "beta"] {
            try createSkill(name: name)
        }

        let first = try SkillFolderScanner.scan(rootFolder: tempDir).map(\.name)
        let second = try SkillFolderScanner.scan(rootFolder: tempDir).map(\.name)

        XCTAssertEqual(first, second, "two scans of an unchanged folder must produce the same order")
    }

    // MARK: - Recursive discovery

    /// ⚠️ THE LAYOUT THAT USED TO IMPORT AS ZERO SKILLS. `repo/skills/<name>/SKILL.md` is what
    /// Anthropic's own plugins ship and what a user gets by cloning any skills repository. Under the
    /// old depth-1 rule it produced no skills and one "No SKILL.md file" skip for `skills/`, which
    /// reads as "this repo has no skills in it".
    func testFindsSkillsNestedUnderASkillsDirectory() throws {
        let skillsDir = tempDir.appendingPathComponent("skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        try createSkill(name: "code-review", in: skillsDir)
        try createSkill(name: "data-analysis", in: skillsDir)

        let result = try SkillFolderScanner.scanDetailed(rootFolder: tempDir)

        XCTAssertEqual(result.manifests.map(\.name), ["code-review", "data-analysis"])
        XCTAssertTrue(result.skipped.isEmpty,
                      "`skills/` contributed every skill — reporting it as skipped would be a lie")
    }

    /// The plugin layout, four levels down.
    func testFindsSkillsInAPluginLayout() throws {
        let nested = tempDir
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent("my-plugin", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try createSkill(name: "deep-skill", in: nested)

        let result = try SkillFolderScanner.scanDetailed(rootFolder: tempDir)

        XCTAssertEqual(result.manifests.map(\.name), ["deep-skill"])
    }

    /// The original depth-1 layout must keep working — this is strictly additive.
    func testStillFindsSkillsDirectlyBelowTheRoot() throws {
        try createSkill(name: "alpha")
        try createSkill(name: "beta")

        XCTAssertEqual(try SkillFolderScanner.scan(rootFolder: tempDir).map(\.name), ["alpha", "beta"])
    }

    /// ⚠️ A skill's OWN subdirectories are resources, not nested skills. Descending into a found
    /// skill would let a stray SKILL.md under `reference/` register as a second skill — and it is
    /// also what keeps the walk bounded on real folders.
    func testDoesNotDescendIntoAFoundSkill() throws {
        let skill = try createSkill(name: "parent")
        let nested = skill.appendingPathComponent("reference", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let decoy = nested.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
        try "---\nname: child\ndescription: A decoy.\n---\n\nBody."
            .write(to: decoy.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let result = try SkillFolderScanner.scanDetailed(rootFolder: tempDir)

        XCTAssertEqual(result.manifests.map(\.name), ["parent"],
                       "a SKILL.md inside a skill's resources must not become a second skill")
    }

    /// A directory tree with no skills anywhere must still be REPORTED as skipped, or the user
    /// cannot tell a wrong folder from an empty one.
    func testATopLevelDirectoryWithNoSkillsAnywhereIsReportedSkipped() throws {
        let docs = tempDir.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs.appendingPathComponent("nested", isDirectory: true),
                                                withIntermediateDirectories: true)
        try createSkill(name: "real")

        let result = try SkillFolderScanner.scanDetailed(rootFolder: tempDir)

        XCTAssertEqual(result.manifests.map(\.name), ["real"])
        XCTAssertEqual(result.skipped.map(\.directoryName), ["docs"])
    }

    /// Beyond the depth bound the walk stops. A skill buried deeper than any real layout is not
    /// found — deliberately, because the alternative is an unbounded walk of a user-chosen folder.
    func testStopsAtTheDepthBound() throws {
        var deep: URL = tempDir
        for level in 0...(SkillFolderScanner.maxScanDepth + 1) {
            deep = deep.appendingPathComponent("level-\(level)", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try createSkill(name: "too-deep", in: deep)

        XCTAssertTrue(try SkillFolderScanner.scan(rootFolder: tempDir).isEmpty,
                      "a skill below the depth bound must not be found — the bound is what makes the walk safe")
    }

    /// Noise directories are never descended into. A user pointing at a checkout is an ordinary
    /// mistake, and `node_modules` is where an unbounded walk goes to die.
    func testIgnoresNoiseDirectories() throws {
        for noise in ["node_modules", ".git", "__MACOSX"] {
            let dir = tempDir.appendingPathComponent(noise, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try createSkill(name: "hidden-skill", in: dir)
        }
        try createSkill(name: "real")

        let result = try SkillFolderScanner.scanDetailed(rootFolder: tempDir)

        XCTAssertEqual(result.manifests.map(\.name), ["real"],
                       "nothing inside a noise directory may be imported")
        XCTAssertFalse(result.skipped.contains { $0.directoryName == ".git" },
                       "an ignored directory is not 'skipped' — it was never a candidate")
    }

    /// A symlinked directory is not followed: a walk that follows them can cycle, and can leave the
    /// folder the user actually chose.
    func testDoesNotFollowSymlinkedDirectories() throws {
        let outside = tempDir.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try createSkill(name: "elsewhere", in: outside)

        let bait = tempDir.appendingPathComponent("collection", isDirectory: true)
        try FileManager.default.createDirectory(at: bait, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bait.appendingPathComponent("link"),
                                                   withDestinationURL: outside)

        let names = try SkillFolderScanner.scan(rootFolder: tempDir).map(\.name)

        XCTAssertEqual(names, ["elsewhere"],
                       "found once via the real path under `outside/`, never a second time through the symlink")
    }

    // MARK: - Symlinked resource subdirectory (CHARACTERIZATION, not regression)

    /// ⚠️ READ THIS BEFORE TRUSTING THE TWO TESTS BELOW.
    ///
    /// These were written believing a symlinked resource directory (`reference -> ~/.ssh`) was
    /// followed and its contents read into the model's context. **Mutation testing disproved it:**
    /// both tests pass against the exact pre-guard code, because the protection is Foundation's,
    /// not ours — verified directly on macOS 26:
    ///
    ///   - `resourceValues(forKeys: [.isDirectoryKey])` does NOT resolve a symlink; a symlink to a
    ///     directory reports `isDirectory == false`.
    ///   - `contentsOfDirectory(at:)` on a symlinked directory returns ZERO entries.
    ///
    /// So these do NOT discriminate the guard in `validFiles`, and they must not be cited as
    /// proof that it works. What they DO pin is the platform behaviour the scanner relies on: if a
    /// future Foundation, or a rewrite onto `enumerator(at:)` or `opendir`, starts following
    /// symlinked directories, these go red and the guard becomes load-bearing for real.
    ///
    /// Kept deliberately, and labelled, rather than deleted — an unlabelled vacuous test is worse
    /// than no test, but a labelled characterization test is how the assumption stays checked.
    func testSymlinkedResourceSubdirectory_ContributesNothing() throws {
        let outside = tempDir.appendingPathComponent("outside-the-skill")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "PRIVATE-KEY-MATERIAL".write(to: outside.appendingPathComponent("id_rsa"), atomically: true, encoding: .utf8)

        let skillDir = try createSkill(name: "exfil")
        try FileManager.default.createSymbolicLink(
            at: skillDir.appendingPathComponent("reference"),
            withDestinationURL: outside
        )

        let manifests = try SkillFolderScanner.scan(rootFolder: tempDir)
        guard let exfil = manifests.first(where: { $0.name == "exfil" }) else {
            return XCTFail("the skill itself must still scan — a symlinked resource dir is not fatal to it")
        }

        XCTAssertEqual(exfil.resourceCount, 0,
                       "a symlinked resource directory must contribute no counted resources")
    }

    /// Same characterization caveat as above: this passes with or without the guard.
    ///
    /// ⚠️ Comment corrected — `hasScripts` no longer GRANTS anything. It used to append
    /// `execute_shell` to the profile automatically (`autoAddShellToolIfNeeded`); S4 demoted that to
    /// an offer the user answers (`offerShellToolIfNeeded`, covered by
    /// `SkillAllowedToolsWiringTests`). The flag is still worth pinning — it decides whether the
    /// user is PROMPTED for shell access — but a comment claiming an automatic grant would send the
    /// next reader looking for code that is gone.
    func testSymlinkedScriptsDirectory_DoesNotSetHasScripts() throws {
        let outside = tempDir.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "print('x')".write(to: outside.appendingPathComponent("run.py"), atomically: true, encoding: .utf8)

        let skillDir = try createSkill(name: "sneaky")
        try FileManager.default.createSymbolicLink(
            at: skillDir.appendingPathComponent("scripts"),
            withDestinationURL: outside
        )

        let manifests = try SkillFolderScanner.scan(rootFolder: tempDir)
        let sneaky = manifests.first { $0.name == "sneaky" }

        XCTAssertEqual(sneaky?.hasScripts, false,
                       "hasScripts drives a shell-tool grant; a symlink must not be able to set it")
    }

    /// The guard must not cost the ordinary case. A real `reference/` directory keeps working.
    func testRealResourceDirectory_StillLoads() throws {
        let skillDir = try createSkill(name: "normal")
        let refDir = skillDir.appendingPathComponent("reference")
        try FileManager.default.createDirectory(at: refDir, withIntermediateDirectories: true)
        try "# Checklist\n- Item".write(to: refDir.appendingPathComponent("checklist.md"), atomically: true, encoding: .utf8)

        let manifests = try SkillFolderScanner.scan(rootFolder: tempDir)
        guard let normal = manifests.first(where: { $0.name == "normal" }) else {
            return XCTFail("expected the skill to scan")
        }

        XCTAssertEqual(normal.resourceCount, 1, "a genuine resource directory must still be counted")
    }
}
