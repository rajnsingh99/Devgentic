// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillLibrarySchemaTests.swift
//  devgenticTests
//
//  The V6 skill library entities: what they persist, and the invariants the shape is supposed to
//  buy. Written against a REAL container rather than bare structs, because every property here
//  exists to survive a save/load cycle and a test on an in-memory object proves nothing about that.
//

import XCTest
import SwiftData
@testable import devgentic

final class SkillLibrarySchemaTests: XCTestCase {

    private var storeURL: URL!
    private var container: ModelContainer!

    override func setUp() async throws {
        try await super.setUp()
        storeURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("skill-library-\(UUID().uuidString).store")
        container = try ModelContainer(
            for: DevgenticSchema.schema,
            migrationPlan: DevgenticSchema.migrationPlan,
            configurations: ModelConfiguration(url: storeURL)
        )
    }

    override func tearDown() async throws {
        container = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
        }
        try await super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func insertSkill(
        name: String = "code-review",
        allowedTools: [String]? = nil,
        files: [SkillFileSD] = [],
        context: ModelContext
    ) throws -> SkillSD {
        let version = SkillVersionSD(
            note: "Initial.",
            skillDescription: "Reviews code.",
            allowedTools: allowedTools,
            body: "# \(name)\nDo the thing.",
            files: files
        )
        let skill = SkillSD(name: name, origin: .created,
                            latestVersionID: version.id, versions: [version])
        context.insert(skill)
        try context.save()
        return skill
    }

    // MARK: - Round trip

    func testASkillAndItsWholeChainSurviveASaveAndReload() throws {
        let context = ModelContext(container)
        let file = SkillFileSD(relativePath: "scripts/run.py",
                               content: Data("print('hi')".utf8), isExecutable: true)
        let skill = try insertSkill(files: [file], context: context)
        let skillID = skill.id

        // A FRESH context, so nothing is answered from the in-memory graph.
        let reread = ModelContext(container)
        let fetched = try XCTUnwrap(try reread.fetch(
            FetchDescriptor<SkillSD>(predicate: #Predicate { $0.id == skillID })).first)

        XCTAssertEqual(fetched.name, "code-review")
        XCTAssertEqual(fetched.versions.count, 1)
        let version = try XCTUnwrap(fetched.latestVersion)
        XCTAssertEqual(version.files.count, 1)
        XCTAssertEqual(version.orderedFiles.first?.relativePath, "scripts/run.py")
        XCTAssertEqual(version.orderedFiles.first?.asText, "print('hi')")
        XCTAssertTrue(try XCTUnwrap(version.orderedFiles.first).isExecutable,
                      "the executable bit must survive — a script that arrives runnable and leaves non-runnable breaks the skill after a round trip, silently")
    }

    /// ⚠️ The case V4/V5 dropped on the floor. Its loader read files with
    /// `String(contentsOf:encoding:.utf8)` and `continue`d on failure, so binaries were silently
    /// absent. Content lives in the store now, so a dropped file is one the user cannot get back.
    func testBinaryFileContentSurvivesByteExact() throws {
        let context = ModelContext(container)
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x00, 0x89, 0x50])
        try insertSkill(files: [SkillFileSD(relativePath: "assets/logo.jpg", content: bytes)], context: context)

        let reread = ModelContext(container)
        let version = try XCTUnwrap(try reread.fetch(FetchDescriptor<SkillSD>()).first?.latestVersion)
        XCTAssertEqual(version.orderedFiles.first?.content, bytes)
        XCTAssertNil(version.orderedFiles.first?.asText, "non-UTF-8 bytes must report as not-text rather than being coerced")
    }

    // MARK: - allowed-tools: the nil / empty distinction, through persistence

    /// ⚠️ Stored as JSON TEXT, not `[String]?` — below macOS 26.1 a native array persists as Binary
    /// Data and the store fails to open on 26.1+ with NSCocoaErrorDomain 134140. That is enforced
    /// structurally by `testTagsRemainsTheOnlyNonRelationshipCollectionAttribute`; this test covers
    /// the behaviour the hand-rolled encoding has to preserve.
    func testAbsentAndEmptyDeclarationsAreDifferentAfterAReload() throws {
        let context = ModelContext(container)
        try insertSkill(name: "silent", allowedTools: nil, context: context)
        try insertSkill(name: "needs-nothing", allowedTools: [], context: context)
        try insertSkill(name: "needs-read", allowedTools: ["Read"], context: context)

        let reread = ModelContext(container)
        let byName = Dictionary(uniqueKeysWithValues: try reread.fetch(FetchDescriptor<SkillSD>()).map { ($0.name, $0) })

        XCTAssertNil(try XCTUnwrap(byName["silent"]?.latestVersion).allowedTools,
                     "an absent field must stay absent")
        XCTAssertEqual(try XCTUnwrap(byName["needs-nothing"]?.latestVersion).allowedTools, [],
                       "`allowed-tools: []` is a STATEMENT — collapsing it to nil turns it into silence")
        XCTAssertEqual(try XCTUnwrap(byName["needs-read"]?.latestVersion).allowedTools, ["Read"])
    }

    /// Elements legitimately contain commas, so the encoding cannot be a delimiter join.
    func testAScopedDeclarationRoundTripsWithItsCommasIntact() throws {
        let context = ModelContext(container)
        let declared = ["Bash(git add:*, git commit:*)", "Read"]
        try insertSkill(allowedTools: declared, context: context)

        let reread = ModelContext(container)
        XCTAssertEqual(try XCTUnwrap(try reread.fetch(FetchDescriptor<SkillSD>()).first?.latestVersion).allowedTools,
                       declared)
    }

    // MARK: - Versions

    func testAddingAVersionLeavesTheEarlierOneByteIdentical() throws {
        let context = ModelContext(container)
        let skill = try insertSkill(context: context)
        let firstID = try XCTUnwrap(skill.latestVersion).id
        let firstBody = try XCTUnwrap(skill.latestVersion).body

        let second = SkillVersionSD(note: "Agent correction.", skillDescription: "Reviews code, carefully.",
                                    body: "# code-review\nDo the thing, better.")
        second.skill = skill
        skill.latestVersionID = second.id
        context.insert(second)
        try context.save()

        let reread = ModelContext(container)
        let fetched = try XCTUnwrap(try reread.fetch(FetchDescriptor<SkillSD>()).first)
        XCTAssertEqual(fetched.versions.count, 2, "history is append-only — the earlier version stays")
        let original = try XCTUnwrap(fetched.versions.first(where: { $0.id == firstID }))
        XCTAssertEqual(original.body, firstBody,
                       "⚠️ an earlier version must never be mutated: append-only history is what replaces the single .history revert slot")
        XCTAssertEqual(fetched.latestVersion?.id, second.id)
    }

    /// ⚠️ `latestVersionID` is a soft pointer, so a partial write or a restored backup can leave it
    /// naming a version that is not there. The skill must stay USABLE — vanishing from every prompt
    /// that linked it is a far worse failure than using the newest version by date.
    func testAStaleLatestPointerFallsBackToTheNewestVersion() throws {
        let context = ModelContext(container)
        let skill = try insertSkill(context: context)
        let realID = try XCTUnwrap(skill.latestVersion).id
        skill.latestVersionID = "skver_does-not-exist"
        try context.save()

        let reread = ModelContext(container)
        let fetched = try XCTUnwrap(try reread.fetch(FetchDescriptor<SkillSD>()).first)
        XCTAssertEqual(fetched.latestVersion?.id, realID,
                       "a dangling latest pointer must degrade to the newest version, not to nil")
    }

    func testDeletingASkillRemovesItsVersionsAndFiles() throws {
        let context = ModelContext(container)
        let skill = try insertSkill(files: [SkillFileSD(relativePath: "reference/a.md", content: Data("a".utf8))],
                                    context: context)
        context.delete(skill)
        try context.save()

        let reread = ModelContext(container)
        XCTAssertTrue(try reread.fetch(FetchDescriptor<SkillSD>()).isEmpty)
        XCTAssertTrue(try reread.fetch(FetchDescriptor<SkillVersionSD>()).isEmpty,
                      "versions must cascade — orphans would accumulate invisibly with no UI to reach them")
        XCTAssertTrue(try reread.fetch(FetchDescriptor<SkillFileSD>()).isEmpty,
                      "files must cascade too, and they carry the bytes")
    }

    // MARK: - Identity

    /// The change that makes the whole design work: identity describes nothing about the world, so
    /// nothing in the world can break it.
    func testTwoSkillsMayShareTheSameNameWithDistinctIdentities() throws {
        let context = ModelContext(container)
        try insertSkill(name: "code-review", context: context)
        try insertSkill(name: "code-review", context: context)

        let reread = ModelContext(container)
        let all = try reread.fetch(FetchDescriptor<SkillSD>())
        XCTAssertEqual(all.count, 2,
                       "name is NOT unique, matching the reference API — a collision is reported at resolve time, never a failed import")
        XCTAssertEqual(Set(all.map(\.id)).count, 2)
    }

    func testOriginDecodesTolerantlyForAnUnknownValue() throws {
        let context = ModelContext(container)
        let skill = try insertSkill(context: context)
        skill.originRaw = "some-future-kind"
        try context.save()

        let reread = ModelContext(container)
        XCTAssertEqual(try XCTUnwrap(try reread.fetch(FetchDescriptor<SkillSD>()).first).origin, .imported,
                       "a row written by a newer build must not make the skill vanish — the user would read that as data loss and re-import")
    }

    func testDraftAndAgentWritableDefaultToTheSafeValue() throws {
        let context = ModelContext(container)
        try insertSkill(context: context)
        let reread = ModelContext(container)
        let skill = try XCTUnwrap(try reread.fetch(FetchDescriptor<SkillSD>()).first)
        XCTAssertFalse(skill.isDraft)
        XCTAssertFalse(skill.isAgentWritable,
                       "⚠️ default-deny, and it lives on the row rather than in the body so the model cannot grant itself the permission that gates it")
    }

    // MARK: - Derived counts

    func testResourceCountAndHasScriptsAreDerivedFromTheFilesThemselves() throws {
        let context = ModelContext(container)
        try insertSkill(files: [
            SkillFileSD(relativePath: "scripts/run.py", content: Data("x".utf8)),
            SkillFileSD(relativePath: "reference/notes.md", content: Data("y".utf8))
        ], context: context)

        let reread = ModelContext(container)
        let version = try XCTUnwrap(try reread.fetch(FetchDescriptor<SkillSD>()).first?.latestVersion)
        XCTAssertEqual(version.resourceCount, 2)
        XCTAssertTrue(version.hasScripts)
        // ⚠️ `totalFileBytes` was deleted with this assertion — it had no production reader and,
        // unlike `origin`, nothing was lost by removing it: it derived from `files`, which is
        // readable. The round-trip property this test is really for is that the FILES survive,
        // which the two assertions above cover.
        XCTAssertEqual(version.orderedFiles.map(\.content.count).reduce(0, +), 2,
                       "the bundled bytes must survive the round trip")
    }

    /// Relationship arrays carry no ordering guarantee, and this order reaches export and the UI.
    ///
    /// ⚠️ ASSERTED ON AN IN-MEMORY OBJECT, and the first version of this test was VACUOUS for
    /// exactly that reason. Written against a persisted skill it passed with `orderedFiles`
    /// returning the raw array — SwiftData happened to hand the files back in path order, so the
    /// sort was never exercised and a mutation removing it survived. A guarantee the storage layer
    /// provides today by accident is not a guarantee; the only way to pin the accessor is to hand
    /// it an array that is definitely out of order.
    func testOrderedFilesSortsByPath() throws {
        let version = SkillVersionSD(
            skillDescription: "Ordering.",
            body: "b",
            files: [
                SkillFileSD(relativePath: "scripts/z.py", content: Data("z".utf8)),
                SkillFileSD(relativePath: "assets/a.png", content: Data("a".utf8)),
                SkillFileSD(relativePath: "reference/m.md", content: Data("m".utf8))
            ]
        )
        XCTAssertEqual(version.files.map(\.relativePath),
                       ["scripts/z.py", "assets/a.png", "reference/m.md"],
                       "the control: the raw array really is out of order, so the assertion below means something")
        XCTAssertEqual(version.orderedFiles.map(\.relativePath),
                       ["assets/a.png", "reference/m.md", "scripts/z.py"])
    }

    /// The persisted counterpart — CHARACTERIZATION. It records that a round trip does not lose or
    /// duplicate files; it deliberately does NOT claim to pin the sort, which the test above does.
    func testAPersistedVersionReturnsExactlyItsFiles() throws {
        let context = ModelContext(container)
        try insertSkill(files: [
            SkillFileSD(relativePath: "scripts/z.py", content: Data("z".utf8)),
            SkillFileSD(relativePath: "assets/a.png", content: Data("a".utf8)),
            SkillFileSD(relativePath: "reference/m.md", content: Data("m".utf8))
        ], context: context)

        let reread = ModelContext(container)
        let version = try XCTUnwrap(try reread.fetch(FetchDescriptor<SkillSD>()).first?.latestVersion)
        XCTAssertEqual(Set(version.orderedFiles.map(\.relativePath)),
                       ["assets/a.png", "reference/m.md", "scripts/z.py"])
        XCTAssertEqual(version.orderedFiles.count, 3)
    }
}

// MARK: - Migration capture

final class SkillLibraryMigrationCaptureTests: XCTestCase {

    private var captureURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        captureURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pending-skill-import-\(UUID().uuidString).json")
        SkillLibraryMigration.captureURLOverride = captureURL
    }

    override func tearDown() async throws {
        SkillLibraryMigration.captureURLOverride = nil
        try? FileManager.default.removeItem(at: captureURL)
        try await super.tearDown()
    }

    /// ⚠️ THE GUARD THAT WAS MISSING, and its absence was found on a real machine rather than in a
    /// test. `captureLegacyFolderPaths` runs inside `willMigrate`, so any test opening a pre-V6
    /// store writes the capture file — and `SchemaMigrationTests` migrates a fixture containing a
    /// `SkillManifestSD` row. An ordinary test run left a real pending-import file in the
    /// developer's Application Support pointing at `/tmp/skills/fixture-skill`, which the next real
    /// launch would have tried to import, failed, and retried forever.
    ///
    /// A per-test override could never have caught it: the write happens somewhere no test calls.
    func testTheCaptureFileIsRedirectedAwayFromApplicationSupportInTests() {
        SkillLibraryMigration.captureURLOverride = nil
        defer { SkillLibraryMigration.captureURLOverride = captureURL }

        let resolved = SkillLibraryMigration.captureURL.path
        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Devgentic/pending-skill-import.json").path

        XCTAssertNotEqual(resolved, real,
                          "a test run must never write the real pending-import file — the next real launch would act on it")
        XCTAssertTrue(TestHost.isRunning, "the control: this assertion only means something inside the test host")
    }

    func testNoPendingFileMeansNothingToImport() {
        XCTAssertTrue(SkillLibraryMigration.peekPendingImports().isEmpty)
    }

    func testPendingImportsRoundTripAndTheFileIsCleared() throws {
        let refs = [
            SkillLibraryMigration.LegacySkillRef(folderPath: "/tmp/skills/a", name: "a"),
            SkillLibraryMigration.LegacySkillRef(folderPath: "/tmp/skills/b", name: "b")
        ]
        try JSONEncoder().encode(refs).write(to: captureURL)

        XCTAssertEqual(SkillLibraryMigration.peekPendingImports(), refs)
        XCTAssertTrue(FileManager.default.fileExists(atPath: captureURL.path),
                      "⚠️ peek must NOT clear — a crash between ingesting and re-linking would otherwise delete the only record of how to connect them")

        SkillLibraryMigration.setPendingImports([refs[1]])
        XCTAssertEqual(SkillLibraryMigration.peekPendingImports(), [refs[1]],
                       "a failed folder is written back so the next launch retries it")

        SkillLibraryMigration.setPendingImports([])
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureURL.path),
                       "an empty remainder removes the file")
    }

    /// A corrupt hint must cost nothing. It is a convenience, not a record of truth.
    func testACorruptPendingFileIsDiscardedRatherThanThrowing() throws {
        try Data("not json at all".utf8).write(to: captureURL)
        XCTAssertTrue(SkillLibraryMigration.peekPendingImports().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: captureURL.path),
                      "⚠️ an unreadable file is LEFT IN PLACE rather than deleted — a fix to this build can still recover it, and deleting a file we failed to parse destroys the user's only record")
    }
}
