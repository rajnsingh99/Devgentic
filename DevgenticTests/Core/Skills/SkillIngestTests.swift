// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SkillIngestTests.swift
//  devgenticTests
//
//  Reading skills off disk into memory, and refusing what must not reach the database.
//
//  ⚠️ Two groups of tests here have a shared point: the things V4/V5 DROPPED SILENTLY. It indexed
//  five hardcoded subdirectories and only captured files that decoded as UTF-8, which was survivable
//  while the disk stayed authoritative. Under V6 a dropped file is one the user permanently loses,
//  so "does every file arrive, byte-exact" is a correctness test, not a thoroughness one.
//

import XCTest
@testable import devgentic

final class SkillIngestTests: XCTestCase {

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

    @discardableResult
    private func makeSkill(
        name: String,
        frontmatterExtra: String = "",
        description: String = "Does a thing.",
        in root: URL? = nil
    ) throws -> URL {
        let dir = (root ?? tempDir).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let content = """
        ---
        name: \(name)
        description: \(description)\(frontmatterExtra.isEmpty ? "" : "\n\(frontmatterExtra)")
        ---

        # \(name)
        Step one.
        """
        try content.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return dir
    }

    private func write(_ data: Data, to relativePath: String, in dir: URL, executable: Bool = false) throws {
        let url = dir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    // MARK: - The basics

    func testReadsNameDescriptionBodyAndDeclaration() throws {
        let dir = try makeSkill(name: "code-review", frontmatterExtra: "allowed-tools: [Read, Grep]")
        let skill = try SkillIngest.readSkillDirectory(at: dir)

        XCTAssertEqual(skill.name, "code-review")
        XCTAssertEqual(skill.description, "Does a thing.")
        XCTAssertEqual(skill.allowedTools, ["Read", "Grep"])
        XCTAssertTrue(skill.body.hasPrefix("# code-review"))
        XCTAssertFalse(skill.body.contains("---"), "the frontmatter must not survive into the body")
    }

    // MARK: - What V4/V5 dropped

    /// ⚠️ THE UPGRADE. The old loader read five hardcoded subdirectories — `reference`,
    /// `references`, `templates`, `scripts`, `assets`. A skill with a `data/` directory, or files
    /// nested two levels down, contributed nothing and nobody was told.
    func testCapturesFilesAtAnyDepthAndInAnyDirectory() throws {
        let dir = try makeSkill(name: "deep-skill")
        try write(Data("a".utf8), to: "scripts/run.py", in: dir)
        try write(Data("b".utf8), to: "data/set/values.csv", in: dir)
        try write(Data("c".utf8), to: "notes.md", in: dir)

        let skill = try SkillIngest.readSkillDirectory(at: dir)
        XCTAssertEqual(Set(skill.files.map(\.relativePath)),
                       ["scripts/run.py", "data/set/values.csv", "notes.md"],
                       "every regular file under the skill belongs to the skill — the old five-directory allowlist lost the rest")
    }

    /// ⚠️ The old loader called `String(contentsOf:encoding:.utf8)` and `continue`d on failure, so
    /// a PNG or a PDF inside a skill simply ceased to exist. Content lives in the store now.
    func testCapturesBinaryFilesByteExact() throws {
        let dir = try makeSkill(name: "binary-skill")
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46])
        try write(bytes, to: "assets/logo.jpg", in: dir)

        let skill = try SkillIngest.readSkillDirectory(at: dir)
        XCTAssertEqual(skill.files.first?.content, bytes)
    }

    /// A script that arrives runnable and leaves non-runnable breaks after a round trip, silently.
    func testPreservesTheExecutableBit() throws {
        let dir = try makeSkill(name: "exec-skill")
        try write(Data("#!/bin/sh\necho hi".utf8), to: "scripts/run.sh", in: dir, executable: true)
        try write(Data("plain".utf8), to: "reference/notes.md", in: dir)

        let skill = try SkillIngest.readSkillDirectory(at: dir)
        let byPath = Dictionary(uniqueKeysWithValues: skill.files.map { ($0.relativePath, $0) })
        XCTAssertTrue(try XCTUnwrap(byPath["scripts/run.sh"]).isExecutable)
        XCTAssertFalse(try XCTUnwrap(byPath["reference/notes.md"]).isExecutable)
    }

    // MARK: - Exclusions

    func testSkillFileItselfIsNotABundledFile() throws {
        let dir = try makeSkill(name: "no-self")
        let skill = try SkillIngest.readSkillDirectory(at: dir)
        XCTAssertFalse(skill.files.contains { $0.relativePath == "SKILL.md" },
                       "SKILL.md becomes the body and the frontmatter — storing it again would let the two disagree")
    }

    func testHiddenFilesAndNoiseDirectoriesAreNotCaptured() throws {
        let dir = try makeSkill(name: "noisy")
        try write(Data("x".utf8), to: ".DS_Store", in: dir)
        try write(Data("y".utf8), to: "node_modules/pkg/index.js", in: dir)
        try write(Data("z".utf8), to: "reference/real.md", in: dir)

        let skill = try SkillIngest.readSkillDirectory(at: dir)
        XCTAssertEqual(skill.files.map(\.relativePath), ["reference/real.md"])
    }

    /// ⚠️ CHARACTERIZATION, not a regression test — and the distinction is the whole point.
    ///
    /// This passes with the explicit symlink branch in `collectFiles` REMOVED (verified by
    /// mutation), because Foundation does not resolve a symlink for `isRegularFile`, so the file
    /// falls out at the regular-file check instead. The behaviour asserted below is real and worth
    /// pinning; the claim that *our* guard produces it would have been false.
    ///
    /// The session had already made exactly this error once, about this exact API, calling a
    /// symlinked resource directory a live vulnerability when `contentsOfDirectory` returns nothing
    /// for one. "A filter exists at level N, therefore level N-1 is unguarded" is an inference, not
    /// a finding.
    func testSymlinksAreNeitherFollowedNorCaptured() throws {
        let dir = try makeSkill(name: "linky")
        let secret = tempDir.appendingPathComponent("secret.txt")
        try Data("classified".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("link.txt"), withDestinationURL: secret)

        let skill = try SkillIngest.readSkillDirectory(at: dir)
        XCTAssertTrue(skill.files.isEmpty)
        XCTAssertFalse(skill.files.contains { $0.content == Data("classified".utf8) })
    }

    // MARK: - Refusals

    /// ⚠️ THE OPPOSITE of what this asserted before 2026-09-14. The agentskills.io "name must equal
    /// its folder name" rule was dropped: under the V6 library identity is an opaque `skill_…` and
    /// the folder is a transport detail discarded at ingest. Anthropic's Skills API requires only
    /// that SKILL.md sit at the root or a top-level folder, so `my-skill-v2/` declaring
    /// `name: my-skill` is a valid package there and used to be refused here.
    func testTheFolderNameNeedNotMatchTheSkillName() throws {
        let dir = tempDir.appendingPathComponent("my-skill-v2")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: my-skill\ndescription: d\n---\n\nBody"
            .write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let skill = try SkillIngest.readSkillDirectory(at: dir)
        XCTAssertEqual(skill.name, "my-skill", "the FRONTMATTER names the skill")
        XCTAssertEqual(skill.sourceLabel, "my-skill-v2", "the folder is only what to call it in a message")
    }

    /// ⚠️ The shape check runs BEFORE the name is used to build anything. An earlier build derived
    /// a directory from this value and reached `removeItem` with it.
    func testATraversalNameIsRefusedOnShapeNotFilteredLater() throws {
        let dir = tempDir.appendingPathComponent("evil")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: ../../../../victim\ndescription: d\n---\n\nBody"
            .write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try SkillIngest.readSkillDirectory(at: dir)) { error in
            guard case SkillIngestError.invalidName = error else {
                return XCTFail("expected invalidName, got \(error)")
            }
        }
    }

    func testAnOverlongDescriptionIsRefused() throws {
        let long = String(repeating: "a", count: SkillLibraryLimits.maxDescriptionChars + 1)
        let dir = try makeSkill(name: "verbose", description: long)
        XCTAssertThrowsError(try SkillIngest.readSkillDirectory(at: dir)) { error in
            guard case SkillIngestError.descriptionTooLong = error else {
                return XCTFail("expected descriptionTooLong, got \(error)")
            }
        }
    }

    /// ⚠️ REJECT, never truncate. A skill imported without the files that pushed it over the cap
    /// looks complete in the library and fails later, somewhere unrelated.
    func testTooManyFilesRejectsTheSkillRatherThanImportingPartOfIt() throws {
        let dir = try makeSkill(name: "many-files")
        for index in 0...SkillLibraryLimits.maxFilesPerVersion {
            try write(Data("x".utf8), to: "data/f\(index).txt", in: dir)
        }
        XCTAssertThrowsError(try SkillIngest.readSkillDirectory(at: dir)) { error in
            guard case SkillIngestError.tooManyFiles = error else {
                return XCTFail("expected tooManyFiles, got \(error)")
            }
        }
    }

    func testAFolderWithNoSkillFileIsRefused() throws {
        let dir = tempDir.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertThrowsError(try SkillIngest.readSkillDirectory(at: dir)) { error in
            guard case SkillIngestError.noSkillFile = error else {
                return XCTFail("expected noSkillFile, got \(error)")
            }
        }
    }

    // MARK: - Path safety

    func testUnsafeRelativePathsAreRejected() {
        XCTAssertFalse(SkillIngest.isSafeRelativePath("../escape.txt"))
        XCTAssertFalse(SkillIngest.isSafeRelativePath("a/../../b.txt"))
        XCTAssertFalse(SkillIngest.isSafeRelativePath("/absolute.txt"))
        XCTAssertFalse(SkillIngest.isSafeRelativePath(""))
        XCTAssertFalse(SkillIngest.isSafeRelativePath("a//b.txt"))
        XCTAssertTrue(SkillIngest.isSafeRelativePath("scripts/run.py"))
        XCTAssertTrue(SkillIngest.isSafeRelativePath("a/b/c/d.txt"))
    }

    // MARK: - Bare markdown

    /// A bare file has no directory to agree with, so the frontmatter is the only claim about the
    /// name — the one import shape where the name is not visible in the path the user picked.
    func testBareMarkdownTakesItsNameFromTheFrontmatterNotTheFilename() throws {
        let file = tempDir.appendingPathComponent("whatever-i-called-it.md")
        try "---\nname: weekly-status\ndescription: Weekly reports.\n---\n\n# Do it"
            .write(to: file, atomically: true, encoding: .utf8)

        let skill = try SkillIngest.readBareMarkdown(at: file)
        XCTAssertEqual(skill.name, "weekly-status")
        XCTAssertTrue(skill.files.isEmpty)
        XCTAssertEqual(skill.sourceLabel, "whatever-i-called-it.md")
    }

    func testBareMarkdownWithoutFrontmatterIsRefused() throws {
        let file = tempDir.appendingPathComponent("plain.md")
        try "# Just a heading".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try SkillIngest.readBareMarkdown(at: file)) { error in
            guard case SkillIngestError.invalidFrontmatter = error else {
                return XCTFail("expected invalidFrontmatter, got \(error)")
            }
        }
    }

    // MARK: - Trees, and partial success

    func testReadsEverySkillUnderANestedLayout() throws {
        let skillsDir = tempDir.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        try makeSkill(name: "alpha", in: skillsDir)
        try makeSkill(name: "beta", in: skillsDir)

        let outcome = SkillIngest.readTree(at: tempDir)
        XCTAssertEqual(Set(outcome.skills.map(\.name)), ["alpha", "beta"],
                       "repo/skills/<name>/SKILL.md is the layout every skills repository ships")
    }

    /// ⚠️ One bad skill must not cost the user the other nineteen — and it must not vanish either.
    /// Silently dropping it is how the old importer made a repo look emptier than it was.
    func testOneBrokenSkillIsReportedAndTheRestStillImport() throws {
        try makeSkill(name: "good-one")
        let broken = tempDir.appendingPathComponent("broken-one")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try "---\nname: broken-one\n---\n\nNo description."
            .write(to: broken.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let outcome = SkillIngest.readTree(at: tempDir)
        XCTAssertEqual(outcome.skills.map(\.name), ["good-one"])
        XCTAssertEqual(outcome.rejected.count, 1)
        XCTAssertEqual(outcome.rejected.first?.label, "broken-one")
        XCTAssertFalse(try XCTUnwrap(outcome.rejected.first).reason.isEmpty,
                       "a rejection the user cannot act on is the same as a silent drop")
    }

    /// A folder that simply is not a skill is not a failure worth reporting.
    func testAnUnrelatedFolderIsNotReportedAsAFailure() throws {
        try makeSkill(name: "real-skill")
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("just-a-folder"), withIntermediateDirectories: true)

        let outcome = SkillIngest.readTree(at: tempDir)
        XCTAssertEqual(outcome.skills.map(\.name), ["real-skill"])
        XCTAssertTrue(outcome.rejected.isEmpty,
                      "only a folder that TRIED to be a skill and failed is worth a message")
    }

    // MARK: - Dispatch

    func testDispatchHandlesASkillDirectoryDirectly() throws {
        let dir = try makeSkill(name: "direct")
        let outcome = SkillIngest.read(contentsOf: dir)
        XCTAssertEqual(outcome.skills.map(\.name), ["direct"])
    }

    func testDispatchHandlesABareMarkdownFile() throws {
        let file = tempDir.appendingPathComponent("solo.md")
        try "---\nname: solo\ndescription: d\n---\n\nBody".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(SkillIngest.read(contentsOf: file).skills.map(\.name), ["solo"])
    }

    func testDispatchReportsSomethingItCannotRead() {
        let outcome = SkillIngest.read(contentsOf: tempDir.appendingPathComponent("nope.xyz"))
        XCTAssertTrue(outcome.skills.isEmpty)
        XCTAssertEqual(outcome.rejected.count, 1)
    }

    func testDispatchRefusesAnUnsupportedFileTypeWithAUsefulMessage() throws {
        let file = tempDir.appendingPathComponent("notes.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        let outcome = SkillIngest.read(contentsOf: file)
        XCTAssertTrue(outcome.skills.isEmpty)
        XCTAssertTrue(try XCTUnwrap(outcome.rejected.first).reason.contains(".zip"),
                      "the message should say what IS accepted, not only that this was not")
    }
}
