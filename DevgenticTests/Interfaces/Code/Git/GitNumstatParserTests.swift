// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GitNumstatParserTests.swift
//  DevgenticTests
//
//  Fixtures are VERBATIM `git diff [--cached] --numstat -z -M` output from git 2.54
//  (Apple Git-157), same scratch repo as GitPorcelainParserTests.
//

import XCTest
@testable import devgentic

final class GitNumstatParserTests: XCTestCase {

    /// Unstaged: binary, the conflicted file TWICE (placeholder then real), delete, edit, edit.
    private let unstagedFixture = Data(
        "-\t-\tblob.bin\u{0}0\t0\tconflict.txt\u{0}4\t0\tconflict.txt\u{0}0\t1\tdeleted.txt\u{0}2\t1\tmodified.txt\u{0}1\t0\tstaged.txt\u{0}".utf8
    )

    /// Staged with `-M`: the rename arrives as `0 0 <empty>` + src + dst.
    private let cachedFixture = Data(
        "0\t0\tconflict.txt\u{0}0\t0\t\u{0}old name.txt\u{0}new näme.txt\u{0}1\t0\tstaged.txt\u{0}".utf8
    )

    /// The SAME index with `-c diff.renames=false` and NO `-M`: the rename splits into an add +
    /// a delete. This is the shape `-M` exists to prevent — kept to prove the parser's contract
    /// is the `-M` shape and to document what drops out without it.
    private let cachedWithoutRenameDetection = Data(
        "0\t0\tconflict.txt\u{0}4\t0\tnew näme.txt\u{0}0\t4\told name.txt\u{0}1\t0\tstaged.txt\u{0}".utf8
    )

    // MARK: - Shapes

    func testOrdinaryAndBinaryRecords() {
        let report = GitNumstatParser.parse(unstagedFixture)
        XCTAssertEqual(report.malformedRecordCount, 0)
        let counts = report.countsByPath()
        XCTAssertEqual(counts["modified.txt"], GitLineCounts(added: 2, deleted: 1))
        XCTAssertEqual(counts["deleted.txt"], GitLineCounts(added: 0, deleted: 1))
        XCTAssertEqual(counts["blob.bin"], .binary)
        XCTAssertTrue(counts["blob.bin"]?.isBinary == true)
    }

    /// The rename's path field is EMPTY; src and dst follow as their own NUL fields. Mis-handled,
    /// "old name.txt" and "new näme.txt" each read as malformed and staged.txt misaligns.
    func testRenameRecordConsumesBothPathFields() {
        let report = GitNumstatParser.parse(cachedFixture)
        XCTAssertEqual(report.malformedRecordCount, 0)
        XCTAssertEqual(report.entries, [
            GitNumstatEntry(path: "conflict.txt", originalPath: nil, counts: GitLineCounts(added: 0, deleted: 0)),
            GitNumstatEntry(path: "new näme.txt", originalPath: "old name.txt", counts: GitLineCounts(added: 0, deleted: 0)),
            GitNumstatEntry(path: "staged.txt", originalPath: nil, counts: GitLineCounts(added: 1, deleted: 0)),
        ])
    }

    func testRenameIsKeyedByDestination() {
        let counts = GitNumstatParser.parse(cachedFixture).countsByPath()
        XCTAssertNotNil(counts["new näme.txt"])
        XCTAssertNil(counts["old name.txt"])
    }

    func testWithoutRenameDetectionARenameIsAnAddPlusADelete() {
        let counts = GitNumstatParser.parse(cachedWithoutRenameDetection).countsByPath()
        XCTAssertEqual(counts["new näme.txt"], GitLineCounts(added: 4, deleted: 0))
        XCTAssertEqual(counts["old name.txt"], GitLineCounts(added: 0, deleted: 4))
    }

    func testTabInsidePathStaysInThePath() {
        let report = GitNumstatParser.parse(Data("3\t1\ttab\there.txt\u{0}".utf8))
        XCTAssertEqual(report.entries.first?.path, "tab\there.txt")
        XCTAssertEqual(report.entries.first?.counts, GitLineCounts(added: 3, deleted: 1))
    }

    // MARK: - Duplicate paths (captured on a conflicted file)

    func testConflictPlaceholderLosesToTheRealCount() {
        XCTAssertEqual(GitNumstatParser.parse(unstagedFixture).countsByPath()["conflict.txt"],
                       GitLineCounts(added: 4, deleted: 0))
    }

    /// The rule is explicit, not last-wins: reversed order gives the same answer.
    func testPlaceholderRuleIsOrderIndependent() {
        let reversed = Data("4\t0\tconflict.txt\u{0}0\t0\tconflict.txt\u{0}".utf8)
        XCTAssertEqual(GitNumstatParser.parse(reversed).countsByPath()["conflict.txt"],
                       GitLineCounts(added: 4, deleted: 0))
    }

    // MARK: - Degenerate input

    func testEmptyOutput() {
        let report = GitNumstatParser.parse(Data())
        XCTAssertEqual(report.entries, [])
        XCTAssertEqual(report.malformedRecordCount, 0)
    }

    func testMalformedRecordsAreCountedAndParsingContinues() {
        let report = GitNumstatParser.parse(Data("x\t1\tbad.txt\u{0}-\t3\thalf-binary.txt\u{0}notabs\u{0}2\t0\tok.txt\u{0}".utf8))
        XCTAssertEqual(report.malformedRecordCount, 3)
        XCTAssertEqual(report.entries.map(\.path), ["ok.txt"])
    }

    func testTruncatedRenameIsMalformedNotACrash() {
        let report = GitNumstatParser.parse(Data("0\t0\t\u{0}only-src.txt".utf8))
        XCTAssertEqual(report.malformedRecordCount, 1)
        XCTAssertEqual(report.entries, [])
    }
}
