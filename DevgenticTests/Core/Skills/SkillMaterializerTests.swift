// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SkillMaterializerTests.swift
//  devgenticTests
//
//  Writing a stored skill back out as a real folder — the inverse of ingest, and the only place a
//  skill name becomes a filesystem path again.
//
//  ⚠️ THE TRAVERSAL TEST IN HERE INHERITED A REAL DEFECT. The old importer derived a directory name
//  from an untrusted archive's frontmatter and handed it to `removeItem`, so `name: ../../../../victim`
//  deleted `/victim` — verified empirically at the time, not reasoned about. That code is gone with
//  the promote half, and this is where the same shape could reappear, so the check moved here with it.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class SkillMaterializerTests: XCTestCase {

    private var container: ModelContainer!
    private var work: URL!

    override func setUp() async throws {
        try await super.setUp()
        work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        container = try ModelContainer(for: DevgenticSchema.schema,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    override func tearDown() async throws {
        container = nil
        if let work { try? FileManager.default.removeItem(at: work) }
        try await super.tearDown()
    }

    private func version(
        description: String = "Does a thing.",
        allowedTools: [String]? = nil,
        body: String = "# skill\nDo it.",
        files: [SkillFileSD] = []
    ) -> SkillVersionSD {
        let version = SkillVersionSD(skillDescription: description, allowedTools: allowedTools,
                                     body: body, files: files)
        container.mainContext.insert(version)
        return version
    }

    // MARK: - Round trip

    /// ⚠️ The property that makes the library safe to adopt: what goes in comes back out. An escape
    /// hatch that loses fidelity is not one.
    func testWritesAFolderThatIngestReadsBackIdentically() throws {
        let files = [
            SkillFileSD(relativePath: "scripts/run.sh", content: Data("echo hi".utf8), isExecutable: true),
            SkillFileSD(relativePath: "reference/notes.md", content: Data("notes".utf8))
        ]
        files.forEach { container.mainContext.insert($0) }
        let source = version(description: "Reviews code.", allowedTools: ["Read", "Bash(git status:*)"],
                             body: "# code-review\nStep one.", files: files)

        let folder = try SkillMaterializer.write(version: source, name: "code-review",
                                                 allowedTools: source.allowedTools, into: work)
        let readBack = try SkillIngest.readSkillDirectory(at: folder)

        XCTAssertEqual(readBack.name, "code-review")
        XCTAssertEqual(readBack.description, "Reviews code.")
        XCTAssertEqual(readBack.allowedTools, ["Read", "Bash(git status:*)"],
                       "a scoped declaration must survive the round trip with its inner comma intact")
        XCTAssertEqual(readBack.body, "# code-review\nStep one.")
        XCTAssertEqual(Set(readBack.files.map(\.relativePath)), ["scripts/run.sh", "reference/notes.md"])
        XCTAssertTrue(try XCTUnwrap(readBack.files.first { $0.relativePath == "scripts/run.sh" }).isExecutable,
                      "a script that arrives runnable and leaves non-runnable breaks the skill after a round trip, silently")
    }

    /// ⚠️ A description containing a colon is ordinary prose and a YAML trap. The rebuilt SKILL.md
    /// has to be readable by the app's own parser, or export produces a file the app cannot import.
    func testADescriptionWithYAMLPunctuationSurvives() throws {
        let tricky = "Reviews code: carefully, and reports [findings] with #hashes"
        let source = version(description: tricky)

        let folder = try SkillMaterializer.write(version: source, name: "tricky", allowedTools: nil, into: work)
        XCTAssertEqual(try SkillIngest.readSkillDirectory(at: folder).description, tricky)
    }

    /// The counterpart: ordinary prose must come back byte-exact, not wrapped in quotes it never had.
    /// Four transforms in this codebase have corrupted content by shape-matching it.
    func testOrdinaryProseIsNotQuoted() {
        let plain = "Generate weekly status reports from recent work."
        XCTAssertEqual(SkillMaterializer.yamlScalar(plain), plain)
    }

    // MARK: - The traversal boundary

    /// ⚠️ THE INHERITED ATTACK. A name is validated at ingest and at creation, so a stored one
    /// "should already be" safe — which is precisely the assumption that failed last time. This is
    /// the moment it becomes a path, so this is where it is checked.
    func testAHostileNameCannotEscapeTheDestination() throws {
        let canary = work.deletingLastPathComponent().appendingPathComponent("materializer-canary.txt")
        try "do not touch".write(to: canary, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: canary) }

        let source = version()
        for hostile in ["../escape", "../../../../victim", "/absolute", "a/b"] {
            XCTAssertThrowsError(
                try SkillMaterializer.write(version: source, name: hostile, allowedTools: nil, into: work),
                "'\(hostile)' must be refused before it becomes a path"
            )
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: canary.path),
                      "nothing outside the destination may be created, moved or removed")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [],
                       "and nothing partial may be left inside it either")
    }

    /// ⚠️ A path that would be silently NORMALISED is refused, not written.
    ///
    /// This is the case the relative-path check uniquely catches — and finding it took a mutation,
    /// because for an obvious traversal like `../../x` the prefix check is what actually refuses:
    /// `appendingPathComponent` keeps the result under the root either way. `a/./b` would land at
    /// `a/b` and `/etc/x` at `etc/x`, so the exported tree would stop matching the stored paths. The
    /// round trip is the whole promise of export; a quietly renamed file breaks it.
    func testAPathThatWouldBeSilentlyNormalisedIsRefused() throws {
        for sneaky in ["a/./b.txt", "/etc/passwd", "a//b.txt"] {
            let file = SkillFileSD(relativePath: sneaky, content: Data("x".utf8))
            container.mainContext.insert(file)
            let source = version(files: [file])
            XCTAssertThrowsError(try SkillMaterializer.write(version: source, name: "ok-name",
                                                            allowedTools: nil, into: work),
                                 "'\(sneaky)' must be refused rather than written somewhere else")
        }
    }

    /// ⚠️ A stored file path is data too. Ingest validates on the way in, but this is where one
    /// becomes a real write under a directory the user chose.
    func testAHostileFilePathIsRefused() throws {
        let file = SkillFileSD(relativePath: "../../escaped.txt", content: Data("x".utf8))
        container.mainContext.insert(file)
        let source = version(files: [file])

        XCTAssertThrowsError(try SkillMaterializer.write(version: source, name: "ok-name",
                                                        allowedTools: nil, into: work)) { error in
            guard case SkillMaterializeError.unsafePath = error else {
                return XCTFail("expected unsafePath, got \(error)")
            }
        }
    }
}
