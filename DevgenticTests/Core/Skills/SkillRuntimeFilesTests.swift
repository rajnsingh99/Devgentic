// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillRuntimeFilesTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class SkillRuntimeFilesTests: XCTestCase {

    private var container: ModelContainer!
    private var store: SkillStore!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer(for: DevgenticSchema.schema,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        store = SkillStore.shared
        store.setContainerForTesting(container)
    }

    override func tearDown() async throws {
        store?.setContainerForTesting(nil)
        store = nil
        container = nil
        try? FileManager.default.removeItem(at: SkillRuntimeFiles.root)
        try await super.tearDown()
    }

    private func seed(_ name: String, files: [IngestedFile]) throws -> SkillSD {
        try store.create(name: name, description: "d", body: "# \(name)\nRun `scripts/run.py`.",
                         allowedTools: ["Bash"], files: files).get()
    }

    private func script(_ path: String, _ body: String, executable: Bool = true) -> IngestedFile {
        IngestedFile(relativePath: path, content: Data(body.utf8), isExecutable: executable)
    }

    // MARK: - The file exists

    /// ⚠️ THE REGRESSION. Before this, the path named in the instructions resolved to nothing.
    func testABundledScriptIsWrittenWhereTheInstructionsSayItIs() throws {
        let skill = try seed("analyzer", files: [script("scripts/run.py", "print('hi')")])
        let version = try XCTUnwrap(skill.latestVersion)

        let root = try XCTUnwrap(SkillRuntimeFiles.materialize(version: version, name: skill.name),
                                 "a skill that bundles files must get a directory")

        let onDisk = root.appendingPathComponent("scripts/run.py")
        XCTAssertTrue(FileManager.default.fileExists(atPath: onDisk.path),
                      "the instructions say `scripts/run.py`; that path must resolve")
        XCTAssertEqual(try String(contentsOf: onDisk, encoding: .utf8), "print('hi')")
    }

    /// A script that cannot be executed is a script that cannot be run — the offered shell tool
    /// would fail with "permission denied" instead of "no such file", which is no better.
    func testAnExecutableBundledFileIsWrittenExecutable() throws {
        let skill = try seed("analyzer", files: [script("scripts/run.sh", "#!/bin/sh\necho hi")])
        let root = try XCTUnwrap(SkillRuntimeFiles.materialize(version: try XCTUnwrap(skill.latestVersion),
                                                               name: skill.name))

        let attrs = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent("scripts/run.sh").path)
        let perms = try XCTUnwrap(attrs[.posixPermissions] as? NSNumber).uint16Value
        XCTAssertEqual(perms & 0o111, 0o111, "the executable bit the skill recorded must survive")
    }

    func testAFileThatIsNotExecutableStaysThatWay() throws {
        let skill = try seed("reader", files: [script("reference/notes.md", "notes", executable: false)])
        let root = try XCTUnwrap(SkillRuntimeFiles.materialize(version: try XCTUnwrap(skill.latestVersion),
                                                               name: skill.name))
        let attrs = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent("reference/notes.md").path)
        let perms = try XCTUnwrap(attrs[.posixPermissions] as? NSNumber).uint16Value
        XCTAssertEqual(perms & 0o111, 0, "nothing should become executable by being materialised")
    }

    // MARK: - What it must NOT do

    /// ⚠️ Naming a directory for a skill that bundles nothing would invite the model to go looking
    /// for files that do not exist.
    func testASkillWithNoBundledFilesGetsNoDirectory() throws {
        let skill = try seed("plain", files: [])
        XCTAssertNil(SkillRuntimeFiles.materialize(version: try XCTUnwrap(skill.latestVersion),
                                                   name: skill.name))
    }

    /// Versions are immutable, so a second call is the same answer — and must not cost a second
    /// write. Repeated `load_skill` calls in one conversation are the common case.
    func testMaterialisingTwiceReturnsTheSamePlace() throws {
        let skill = try seed("analyzer", files: [script("scripts/run.py", "print('hi')")])
        let version = try XCTUnwrap(skill.latestVersion)

        let first = try XCTUnwrap(SkillRuntimeFiles.materialize(version: version, name: skill.name))
        let second = try XCTUnwrap(SkillRuntimeFiles.materialize(version: version, name: skill.name))
        XCTAssertEqual(first, second)
    }

    /// ⚠️⚠️ THE DEFECT: a failed materialisation used to poison the reuse check, and the SECOND
    /// call was less honest than the first.
    ///
    /// `SkillMaterializer.write` wrote SKILL.md before the bundled files, so a throw mid-loop left
    /// the directory holding SKILL.md alone. This function reads exactly that file to decide
    /// "already projected", so the next call returned a directory whose `scripts/run.py` did not
    /// exist — and returned it silently, where the first call had at least returned nil.
    /// `LoadSkillTool` then told the model the bundled files were on disk.
    ///
    /// **Mutation check:** move the SKILL.md write back above the file loop and the second
    /// assertion goes red.
    func testAFailedMaterialisationIsNotReportedAsCompleteOnTheNextCall() throws {
        // ⚠️ INSERTED DIRECTLY, not through `store.create` — and the reason is a second fix landing
        // on this one. `SkillStore` now REFUSES an unsafe bundled path at the door, so this fixture
        // is no longer constructible through the store at all; the seeded version of this test began
        // failing on `.get()` before it reached a single assertion.
        //
        // That is the store fix working, not a regression here. What it leaves behind is exactly the
        // state this test is about: a GRANDFATHERED row, written under an earlier and narrower rule,
        // which `addVersion` deliberately carries forward rather than bricking the skill over. Such a
        // row still makes `SkillMaterializer.write` throw, so the projection can still fail — and a
        // failure must still not be reported as a complete projection on the next call.
        //
        // `orderedFiles` sorts "a/./bad.txt" before "scripts/run.py", so the write throws before any
        // bundled file lands — the same state a disk-full or sandbox denial produces.
        let bad = SkillFileSD(relativePath: "a/./bad.txt", content: Data("x".utf8))
        let good = SkillFileSD(relativePath: "scripts/run.py", content: Data("print('hi')".utf8))
        let version = SkillVersionSD(skillDescription: "d", body: "Run scripts/run.py",
                                     files: [bad, good])
        let skill = SkillSD(name: "partial", latestVersionID: version.id, versions: [version])
        container.mainContext.insert(skill)
        try container.mainContext.save()

        XCTAssertNil(SkillRuntimeFiles.materialize(version: version, name: skill.name),
                     "the write threw, so the first call must report failure")
        XCTAssertNil(SkillRuntimeFiles.materialize(version: version, name: skill.name),
                     "and so must the second — a path to a tree with no bundled files in it is worse than nil, because the caller hands it to the model")
    }

    /// ⚠️ Keyed by VERSION, not by skill: a profile pinning an older snapshot must not be handed the
    /// files of `latest`. Two versions of one skill are two directories.
    func testTwoVersionsOfOneSkillProjectToDifferentDirectories() throws {
        let skill = try seed("analyzer", files: [script("scripts/run.py", "v1")])
        let v1 = try XCTUnwrap(skill.latestVersion)
        let firstRoot = try XCTUnwrap(SkillRuntimeFiles.materialize(version: v1, name: skill.name))

        _ = try store.addVersion(toSkillWithID: skill.id, description: "d", body: "b",
                                 allowedTools: ["Bash"],
                                 files: [script("scripts/run.py", "v2")], note: "n").get()
        let v2 = try XCTUnwrap(skill.latestVersion)
        let secondRoot = try XCTUnwrap(SkillRuntimeFiles.materialize(version: v2, name: skill.name))

        XCTAssertNotEqual(firstRoot, secondRoot, "a pinned version must not read the latest one's files")
        XCTAssertEqual(try String(contentsOf: firstRoot.appendingPathComponent("scripts/run.py"), encoding: .utf8), "v1")
        XCTAssertEqual(try String(contentsOf: secondRoot.appendingPathComponent("scripts/run.py"), encoding: .utf8), "v2")
    }
}
