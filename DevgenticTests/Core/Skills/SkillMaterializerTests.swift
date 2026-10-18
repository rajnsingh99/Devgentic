// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillMaterializerTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
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

    /// ⚠️ THE QUOTE SWAP. `yamlScalar` used to `replacingOccurrences(of: "\"", with: "'")` — not an
    /// escape, a SUBSTITUTION — so a description carrying a double quote came back altered. Fifth
    /// instance of this codebase's content-rewritten-by-a-transform class, in the one file whose
    /// contract is round-trip fidelity.
    ///
    /// **Mutation check:** restore the swap and this goes red.
    func testADescriptionWithADoubleQuoteRoundTrips() throws {
        let tricky = #"Reviews "legacy" code: carefully"#
        let source = version(description: tricky)

        let folder = try SkillMaterializer.write(version: source, name: "quoted", allowedTools: nil, into: work)
        XCTAssertEqual(try SkillIngest.readSkillDirectory(at: folder).description, tricky)
    }

    /// The other half of the encoding: an apostrophe is doubled on the way out and halved on the way
    /// back. Ship `yamlScalar` without `unquote`'s collapse and this returns `user''s`.
    func testADescriptionWithAnApostropheRoundTrips() throws {
        let tricky = "Reviews the user's code: carefully"
        let source = version(description: tricky)

        let folder = try SkillMaterializer.write(version: source, name: "apostrophe", allowedTools: nil, into: work)
        XCTAssertEqual(try SkillIngest.readSkillDirectory(at: folder).description, tricky)
    }

    /// ⚠️ A backslash made the OLD double-quoted output a scanner error in any spec-conformant YAML
    /// reader, so export could produce a SKILL.md that only this app could load. In a single-quoted
    /// scalar a backslash is literal, which is the point.
    func testADescriptionWithABackslashRoundTrips() throws {
        let tricky = #"Matches \d+ patterns: numbers"#
        let source = version(description: tricky)

        let folder = try SkillMaterializer.write(version: source, name: "backslash", allowedTools: nil, into: work)
        XCTAssertEqual(try SkillIngest.readSkillDirectory(at: folder).description, tricky)
    }

    /// ⚠️⚠️ A LEADING YAML INDICATOR, AND A LESSON ABOUT WHAT TO ASSERT ON.
    ///
    /// `needsQuotes` omitted `#`, `-` and `?`, so a description beginning with one was emitted BARE.
    /// Verified against a spec-conformant parser (PyYAML) rather than reasoned about:
    ///
    ///     description: #1 priority triage      ->  None          (`#` opens a comment)
    ///     description: - first read the diff   ->  ScannerError
    ///     description: ? maybe reviews code    ->  ScannerError
    ///
    /// ⚠️ THIS ASSERTS ON THE EMITTED BYTES, NOT ON A ROUND TRIP, and the first version of this test
    /// did the opposite and was VACUOUS — it passed with the fix reverted. Two reasons, both worth
    /// keeping: `YAMLFrontmatterParser` is a naive line-based reader that splits on the first colon
    /// and treats none of these characters specially, so the app's own round trip cannot see the
    /// defect at all; and the sample strings contained `": "`, which triggered quoting through a
    /// different predicate. The defect is export fidelity to OTHER tools, so the assertion has to be
    /// about what we WRITE.
    ///
    /// **Mutation check:** remove `#-?` from the indicator set and every case below goes red.
    func testADescriptionBeginningWithAYAMLIndicatorIsQuoted() {
        for tricky in ["#1 priority triage", "- first read the diff", "? maybe reviews code"] {
            let emitted = SkillMaterializer.yamlScalar(tricky)
            XCTAssertTrue(emitted.hasPrefix("'") && emitted.hasSuffix("'"),
                          "'\(tricky)' must be quoted — unquoted it is a comment or a scanner error in any spec YAML reader")
        }
    }

    /// The control that makes the assertion above meaningful: quoting is not blanket. Ordinary prose
    /// with no indicator and no colon still comes back bare, so the predicate is still a predicate.
    func testALeadingOrdinaryWordIsStillUnquoted() {
        XCTAssertEqual(SkillMaterializer.yamlScalar("Reviews code carefully"), "Reviews code carefully")
    }

    /// And the app's own parser still reads the quoted form back exactly — the encoding is reversible
    /// in both directions, which is what makes over-quoting free.
    func testTheQuotedIndicatorFormStillRoundTripsThroughOurParser() throws {
        for tricky in ["#1 priority triage", "- first read the diff", "? maybe reviews code"] {
            let source = version(description: tricky)
            let folder = try SkillMaterializer.write(version: source, name: "indicator",
                                                    allowedTools: nil, into: work)
            XCTAssertEqual(try SkillIngest.readSkillDirectory(at: folder).description, tricky)
            try FileManager.default.removeItem(at: folder)
        }
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

    // MARK: - SKILL.md is written LAST

    /// ⚠️⚠️ THE ORDERING IS LOAD-BEARING, AND THIS IS THE ONLY THING GUARDING IT.
    ///
    /// SKILL.md used to be written FIRST, before the bundled files. `SkillRuntimeFiles.materialize`
    /// decides "already projected" by testing whether SKILL.md exists, so a write that threw on a
    /// bundled file left behind a directory holding SKILL.md and nothing else — and the NEXT call
    /// returned it as complete. Written last, its presence means every file already landed.
    ///
    /// **Mutation check:** move the SKILL.md write back above the file loop and this goes red.
    func testAFailedWriteLeavesNoSKILLmdBehind() throws {
        let bad = SkillFileSD(relativePath: "a/./bad.txt", content: Data("x".utf8))
        container.mainContext.insert(bad)
        let source = version(files: [bad])

        XCTAssertThrowsError(try SkillMaterializer.write(version: source, name: "half-written",
                                                        allowedTools: nil, into: work))

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: work.appendingPathComponent("half-written/SKILL.md").path),
            "SKILL.md is the completeness sentinel — present after a failed write, it tells the next caller a broken projection is finished")
    }

    /// The other half: on success it IS there, so the sentinel is not simply never written.
    /// Without this, deleting the SKILL.md write entirely would leave the test above green.
    func testASuccessfulWriteDoesProduceSKILLmd() throws {
        let file = SkillFileSD(relativePath: "scripts/run.py", content: Data("print(1)".utf8))
        container.mainContext.insert(file)
        let source = version(files: [file])

        let folder = try SkillMaterializer.write(version: source, name: "complete",
                                                 allowedTools: nil, into: work)

        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("SKILL.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("scripts/run.py").path))
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
