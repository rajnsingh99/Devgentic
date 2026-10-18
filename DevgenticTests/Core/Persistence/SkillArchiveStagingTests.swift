// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillArchiveStagingTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class SkillArchiveStagingTests: XCTestCase {

    private var work: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let work { try? FileManager.default.removeItem(at: work) }
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    @discardableResult
    private func makeSkillFolder(name: String, in parent: URL? = nil, withScripts: Bool = false) throws -> URL {
        let dir = (parent ?? work).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        ---
        name: \(name)
        description: A packaged skill named \(name).
        ---

        # \(name)
        Do the thing.
        """.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        if withScripts {
            let scripts = dir.appendingPathComponent("scripts", isDirectory: true)
            try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
            try "print('x')".write(to: scripts.appendingPathComponent("run.py"), atomically: true, encoding: .utf8)
        }
        return dir
    }

    /// Real archive, via the same `ditto --keepParent` the exporter uses.
    private func zip(_ source: URL, named: String = "package.zip", keepParent: Bool = true) throws -> URL {
        let output = work.appendingPathComponent(named)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        var arguments = ["-c", "-k", "--sequesterRsrc"]
        if keepParent { arguments.append("--keepParent") }
        arguments.append(contentsOf: [source.path, output.path])
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try XCTSkipIf(process.terminationStatus != 0, "ditto unavailable in this environment")
        return output
    }

    /// Stages into a caller-owned directory, exactly as `SkillIngest.readArchive` does.
    @discardableResult
    private func stage(_ zipURL: URL) throws -> URL {
        let staging = work.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        return try SkillArchiveStaging.stageValidated(zipAt: zipURL, into: staging)
    }

    // MARK: - Happy path

    func testStagesAZippedSkillFolder() throws {
        let folder = try makeSkillFolder(name: "packaged-skill", withScripts: true)
        let contentRoot = try stage(try zip(folder))

        let scan = try SkillFolderScanner.scanDetailed(rootFolder: contentRoot)
        XCTAssertEqual(scan.manifests.map(\.name), ["packaged-skill"])
    }

    /// ⚠️ Nothing is promoted and nothing is retained — the caller owns the staging directory. That
    /// is the whole V6 contract: a skill's bytes go into the store, not into a folder that can later
    /// move, be renamed, or disagree with the database.
    func testStagingLeavesNothingBehindOutsideTheCallersDirectory() throws {
        let folder = try makeSkillFolder(name: "leaves-nothing")
        let staging = work.appendingPathComponent("owned", isDirectory: true)
        _ = try SkillArchiveStaging.stageValidated(zipAt: try zip(folder), into: staging)

        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path),
                      "the caller's directory is where everything went")
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Devgentic/Skills/leaves-nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: appSupport.path),
                       "⚠️ nothing may reach the real install root — that path no longer exists as a concept")
    }

    // MARK: - Behaviours inherited from the deleted promote half

    /// A zip of a skill's CONTENTS (SKILL.md at the root) rather than of its folder. The installer
    /// used to handle this by renaming the staging directory to the declared name; ingest handles it
    /// by not caring what the directory is called.
    func testAContentsOnlyArchiveStillIngests() throws {
        let folder = try makeSkillFolder(name: "contents-only")
        let archive = try zip(folder, named: "contents.zip", keepParent: false)

        let outcome = try SkillIngest.readArchive(at: archive)
        XCTAssertEqual(outcome.skills.map(\.name), ["contents-only"])
    }

    func testAnArchiveWithNoSkillFileIsReported() throws {
        let plain = work.appendingPathComponent("not-a-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try "nothing here".write(to: plain.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)

        let outcome = try SkillIngest.readArchive(at: try zip(plain))
        XCTAssertTrue(outcome.skills.isEmpty)
        XCTAssertFalse(outcome.rejected.isEmpty, "a refusal the user cannot see is the same as a silent drop")
    }

    /// ⚠️ The round trip that matters: what the app exports, the app must be able to read back.
    /// An escape hatch that loses fidelity is not one.
    func testExportThenIngestRoundTrips() throws {
        let folder = try makeSkillFolder(name: "round-trip", withScripts: true)
        let destination = work.appendingPathComponent("exported.zip")
        try SkillPackageExporter.export(skillAt: folder.path, to: destination)

        let outcome = try SkillIngest.readArchive(at: destination)
        XCTAssertEqual(outcome.skills.map(\.name), ["round-trip"])
        XCTAssertEqual(outcome.skills.first?.files.map(\.relativePath), ["scripts/run.py"])
    }

    // MARK: - Refusals

    /// ⚠️ THE ONE THAT MATTERS. A genuine escape attempt: the archive carries a link pointing at a
    /// file outside the package. Refused wholesale — not filtered — because a legitimate skill has
    /// no reason to ship a link.
    func testArchiveContainingASymlinkIsRefusedEntirely() throws {
        let secret = work.appendingPathComponent("secret.txt")
        try "PRIVATE".write(to: secret, atomically: true, encoding: .utf8)

        let folder = try makeSkillFolder(name: "sneaky")
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("stolen.txt"),
            withDestinationURL: secret
        )
        let archive = try zip(folder)

        let staging = work.appendingPathComponent("symlink-staging", isDirectory: true)
        XCTAssertThrowsError(try SkillArchiveStaging.stageValidated(zipAt: archive, into: staging)) { error in
            guard case SkillArchiveError.containsSymlink = error else {
                return XCTFail("expected containsSymlink, got \(error)")
            }
        }
        // ⚠️ The refusal must also reach the path the UI actually calls, or the archive would be
        // refused by a function nobody consults. `read(contentsOf:)` is that path: it turns the
        // throw into a REPORTED rejection, so the user is told rather than seeing nothing happen.
        let outcome = SkillIngest.read(contentsOf: archive)
        XCTAssertTrue(outcome.skills.isEmpty, "a package with a symlink must contribute NOTHING")
        XCTAssertEqual(outcome.rejected.count, 1)
        XCTAssertTrue(try XCTUnwrap(outcome.rejected.first).reason.contains("symbolic link"),
                      "the reason has to say what was wrong, or it is a silent drop with extra steps")
    }


    /// The charset is what makes traversal unrepresentable. Pinned directly, so a future relaxation
    /// of the name rules has to confront this.
    func testShapeValidatorRejectsEveryPathSeparatorForm() {
        for bad in ["../x", "a/b", "..", ".", "/abs", "a\\b", "Upper", "has space", "trailing-", "-leading", "double--hyphen"] {
            XCTAssertThrowsError(try SkillFolderScanner.validateSkillNameShape(bad),
                                 "'\(bad)' must be rejected — it is either a path form or outside the spec charset")
        }
        XCTAssertNoThrow(try SkillFolderScanner.validateSkillNameShape("code-review-2"))
    }


    /// An oversized package is refused before anything is read out of it.
    ///
    /// ⚠️ This does NOT discriminate the extracted-size enforcement added for audit finding #8 —
    /// mutation testing showed it stays green with that check removed, because this archive declares
    /// its sizes HONESTLY and the cheap pre-flight (`unzip -l`) catches it first. The enforcement
    /// exists for a DISHONEST archive, whose central directory under-reports; forging one is beyond
    /// what is reasonable to build here, so the enforcement logic is covered directly by
    /// `testExtractedSizeBudgetRefusesATreeThatExceedsTheCap` instead. Do not cite this test as
    /// proof that a lying archive is caught.
    func testAnOversizedPackageIsRefusedOnWhatActuallyExtracted() throws {
        let folder = try makeSkillFolder(name: "oversized")
        // Incompressible data, so the archive cannot quietly shrink below the budget.
        let chunk = Data((0..<(4 * 1024 * 1024)).map { _ in UInt8.random(in: 0...255) })
        var written = 0
        var index = 0
        while written <= SkillArchiveStaging.maxUncompressedBytes {
            try chunk.write(to: folder.appendingPathComponent("blob-\(index).bin"))
            written += chunk.count
            index += 1
        }

        let archive = try zip(folder, named: "big.zip")

        let staging = work.appendingPathComponent("oversized-staging", isDirectory: true)
        XCTAssertThrowsError(try SkillArchiveStaging.stageValidated(zipAt: archive, into: staging)) { error in
            guard case SkillArchiveError.tooLarge = error else {
                return XCTFail("expected tooLarge, got \(error)")
            }
        }
    }


    /// ⚠️ Covers the enforcement the integration test above cannot reach: the check that measures
    /// what ACTUALLY landed on disk, rather than trusting the sizes the archive declared. This is
    /// the only defence against an archive whose central directory under-reports, and it is
    /// mutation-discriminated (remove the check and this goes red).
    func testExtractedSizeBudgetRefusesATreeThatExceedsTheCap() throws {
        let tree = work.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)

        let chunk = Data(repeating: 0xAB, count: 4 * 1024 * 1024)
        var written = 0
        var index = 0
        while written <= SkillArchiveStaging.maxUncompressedBytes {
            try chunk.write(to: tree.appendingPathComponent("blob-\(index).bin"))
            written += chunk.count
            index += 1
        }

        XCTAssertThrowsError(try SkillArchiveStaging.enforceExtractedSizeBudget(under: tree)) { error in
            guard case SkillArchiveError.tooLarge = error else {
                return XCTFail("expected tooLarge, got \(error)")
            }
        }
    }


    func testExtractedSizeBudgetAllowsAnOrdinaryPackage() throws {
        let tree = work.appendingPathComponent("small", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try "tiny".write(to: tree.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        XCTAssertNoThrow(try SkillArchiveStaging.enforceExtractedSizeBudget(under: tree))
    }


    /// Real `unzip -l` output. The trailer is the only line that summarises; everything above it is
    /// a file entry.
    func testParsesTheTotalsLineFromARealListing() {
        let listing = """
        Archive:  /tmp/x/archive.zip
          Length      Date    Time    Name
        ---------  ---------- -----   ----
              412  09-14-2026 10:02   my-skill/SKILL.md
             1024  09-14-2026 10:02   my-skill/reference/notes.md
        ---------                     -------
             1436                     2 files
        """
        let totals = SkillArchiveStaging.parseListingTotals(listing)
        XCTAssertEqual(totals?.bytes, 1436)
        XCTAssertEqual(totals?.entries, 2)
    }


    /// ⚠️ THE CASE THAT MOTIVATED EXTRACTING THIS. A forward scan locks onto the first line that
    /// contains digits and the word "file" — and a FILENAME can satisfy both. It would then read
    /// that entry's size as the archive total and wave through an oversized package. Scanning from
    /// the end finds the trailer, which is the only line that actually summarises.
    func testAFilenameContainingTheWordFileDoesNotDefeatTheParse() {
        let listing = """
        Archive:  /tmp/x/archive.zip
          Length      Date    Time    Name
        ---------  ---------- -----   ----
               64  09-14-2026 10:02   my-skill/report-file-2.txt
        999999999  09-14-2026 10:02   my-skill/huge.bin
        ---------                     -------
        999999999                     2 files
        """
        let totals = SkillArchiveStaging.parseListingTotals(listing)
        XCTAssertEqual(totals?.bytes, 999_999_999,
                       "the archive TOTAL must win over an entry line that happens to look like a trailer")
        XCTAssertEqual(totals?.entries, 2)
    }


    /// Unrecognised shapes must be an explicit "cannot read this archive", never a guess — a wrong
    /// budget silently admits an oversized package.
    func testUnparseableListingsReturnNil() {
        XCTAssertNil(SkillArchiveStaging.parseListingTotals(""))
        XCTAssertNil(SkillArchiveStaging.parseListingTotals("Archive:  /tmp/x.zip\nnothing useful here"))
        XCTAssertNil(SkillArchiveStaging.parseListingTotals("caution: filename not matched: *.zip"),
                     "a line with 'file' but only one number is not a trailer")
    }


    /// A single-entry archive still says "1 file", singular.
    func testSingularFileTrailerParses() {
        let listing = """
        ---------                     -------
              412                     1 file
        """
        XCTAssertEqual(SkillArchiveStaging.parseListingTotals(listing)?.entries, 1)
    }


    func testBudgetConstantsAreBoundedAndPositive() {
        XCTAssertGreaterThan(SkillArchiveStaging.maxUncompressedBytes, 0)
        XCTAssertGreaterThan(SkillArchiveStaging.maxEntries, 0)
        XCTAssertLessThanOrEqual(SkillArchiveStaging.maxUncompressedBytes, 1_024 * 1_024 * 1_024,
                                 "the ceiling exists to stop a zip bomb; a gigabyte-scale limit stops nothing")
    }


    func testExportRefusesAMissingFolder() {
        XCTAssertThrowsError(
            try SkillPackageExporter.export(skillAt: "/tmp/definitely-not-here-\(UUID().uuidString)",
                                            to: work.appendingPathComponent("x.zip"))
        ) { error in
            guard case SkillExportError.sourceMissing = error else {
                return XCTFail("expected sourceMissing, got \(error)")
            }
        }
    }
}
