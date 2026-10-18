// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GitPorcelainParserTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class GitPorcelainParserTests: XCTestCase {

    /// NUL-terminates each record, exactly as `-z` emits them.
    private func z(_ records: String...) -> Data {
        Data(records.map { $0 + "\0" }.joined().utf8)
    }

    // A merge in progress with one conflict, then: binary edit, worktree delete, worktree edit,
    // staged rename (space ⇒ unicode), staged+unstaged edit, and three hostile untracked names.
    private lazy var fullFixture = z(
        "# branch.oid a4374b876b457543939aff1ba9b944c13303b8d5",
        "# branch.head main",
        "1 .M N... 100644 100644 100644 677273046bce3115f56c248238f3b83f77cfc239 677273046bce3115f56c248238f3b83f77cfc239 blob.bin",
        "1 .D N... 100644 100644 000000 587be6b4c3f93f93c489c0111bba5596147a26cb 587be6b4c3f93f93c489c0111bba5596147a26cb deleted.txt",
        "1 .M N... 100644 100644 100644 de980441c3ab03a8c07dda1ad27b8a11f39deb1e de980441c3ab03a8c07dda1ad27b8a11f39deb1e modified.txt",
        "2 R. N... 100644 100644 100644 428f7624d7771cd0a8bdb0dee96c97cb1f1c932a 428f7624d7771cd0a8bdb0dee96c97cb1f1c932a R100 new näme.txt",
        "old name.txt",
        "1 MM N... 100644 100644 100644 0e26ecd57b3011cf2901db42472dce8faa385865 abab8ee7bcbdf2cab130a1a331a07182f02ace10 staged.txt",
        "u UU N... 100644 100644 100644 100644 32814eeca5c53c405c14294dbc4be46f8e8c8b6e b19a1e93bec1317dc6097229e12afaffbfa74dc2 950b81b7eee953d050aa05a641f8e056c85dd1bd conflict.txt",
        "? -leading dash.txt",
        "? newdir/untracked one.txt",
        "? tab\there.txt"
    )

    // MARK: - Records

    func testFullFixtureParsesEveryRecordAndNothingIsMalformed() {
        let report = GitPorcelainParser.parse(fullFixture)
        XCTAssertEqual(report.malformedRecordCount, 0)
        XCTAssertEqual(report.entries.map(\.path), [
            "blob.bin", "deleted.txt", "modified.txt", "new näme.txt", "staged.txt",
            "conflict.txt", "-leading dash.txt", "newdir/untracked one.txt", "tab\there.txt",
        ])
    }

    func testOrdinaryRecordCarriesXY() {
        let entry = GitPorcelainParser.parse(fullFixture).entries[1]
        XCTAssertEqual(entry, GitStatusEntry(path: "deleted.txt", originalPath: nil,
                                             indexStatus: ".", worktreeStatus: "D", kind: .ordinary))
        XCTAssertFalse(entry.hasStagedChange)
        XCTAssertTrue(entry.hasUnstagedChange)
    }

    /// The rename's original path is the NEXT NUL field — consuming it is what keeps every later
    /// record aligned. Mis-handled, "old name.txt" would be read as a malformed record.
    func testRenameConsumesItsOriginalPathField() {
        let entry = GitPorcelainParser.parse(fullFixture).entries[3]
        XCTAssertEqual(entry, GitStatusEntry(path: "new näme.txt", originalPath: "old name.txt",
                                             indexStatus: "R", worktreeStatus: ".", kind: .renamed(score: 100)))
        XCTAssertTrue(entry.hasStagedChange)
        XCTAssertFalse(entry.hasUnstagedChange)
    }

    func testCopyRecord() {
        let report = GitPorcelainParser.parse(z(
            "2 C. N... 100644 100644 100644 aaaa aaaa C75 copy.txt", "src.txt"
        ))
        XCTAssertEqual(report.entries.first?.kind, .copied(score: 75))
        XCTAssertEqual(report.entries.first?.originalPath, "src.txt")
    }

    func testStagedAndUnstagedOnOnePath() {
        let entry = GitPorcelainParser.parse(fullFixture).entries[4]
        XCTAssertEqual(entry.indexStatus, "M")
        XCTAssertEqual(entry.worktreeStatus, "M")
        XCTAssertTrue(entry.hasStagedChange)
        XCTAssertTrue(entry.hasUnstagedChange)
    }

    func testUnmergedRecord() {
        let entry = GitPorcelainParser.parse(fullFixture).entries[5]
        XCTAssertEqual(entry, GitStatusEntry(path: "conflict.txt", originalPath: nil,
                                             indexStatus: "U", worktreeStatus: "U", kind: .unmerged))
    }

    /// `-z` paths are raw: no quoting, no escaping. A leading dash, a space in a subdirectory
    /// path and an embedded TAB all survive byte-for-byte.
    func testHostileUntrackedNamesSurviveVerbatim() {
        let untracked = GitPorcelainParser.parse(fullFixture).entries.filter { $0.kind == .untracked }
        XCTAssertEqual(untracked.map(\.path), ["-leading dash.txt", "newdir/untracked one.txt", "tab\there.txt"])
        XCTAssertTrue(untracked.allSatisfy { !$0.hasStagedChange && $0.hasUnstagedChange })
    }

    func testPathWithManySpacesIsNotSplit() {
        let report = GitPorcelainParser.parse(z(
            "1 .M N... 100644 100644 100644 aaaa aaaa a  b   c.txt"
        ))
        XCTAssertEqual(report.entries.first?.path, "a  b   c.txt")
    }

    func testIgnoredRecord() {
        let entry = GitPorcelainParser.parse(z("! build/out.o")).entries.first
        XCTAssertEqual(entry?.kind, .ignored)
        XCTAssertEqual(entry?.hasStagedChange, false)
        XCTAssertEqual(entry?.hasUnstagedChange, false)
    }

    // MARK: - Branch headers

    func testBranchOnNamedBranch() {
        let branch = GitPorcelainParser.parse(fullFixture).branch
        XCTAssertEqual(branch.head, "main")
        XCTAssertEqual(branch.oid, "a4374b876b457543939aff1ba9b944c13303b8d5")
        XCTAssertFalse(branch.isDetached)
        XCTAssertFalse(branch.isUnborn)
        XCTAssertNil(branch.upstream)
        XCTAssertNil(branch.ahead)
    }

    func testDetachedHead() {
        let branch = GitPorcelainParser.parse(z(
            "# branch.oid a4374b876b457543939aff1ba9b944c13303b8d5", "# branch.head (detached)"
        )).branch
        XCTAssertTrue(branch.isDetached)
        XCTAssertNil(branch.head)
        XCTAssertEqual(branch.oid, "a4374b876b457543939aff1ba9b944c13303b8d5")
    }

    func testUnbornBranch() {
        let report = GitPorcelainParser.parse(z("# branch.oid (initial)", "# branch.head main"))
        XCTAssertTrue(report.branch.isUnborn)
        XCTAssertEqual(report.branch.head, "main")
        XCTAssertEqual(report.entries, [])
    }

    func testUpstreamAndAheadBehind() {
        let branch = GitPorcelainParser.parse(z(
            "# branch.oid 9e557c43decdac286dbad031e6f5a7c16e2dd4c5", "# branch.head main",
            "# branch.upstream origin/main", "# branch.ab +1 -0"
        )).branch
        XCTAssertEqual(branch.upstream, "origin/main")
        XCTAssertEqual(branch.ahead, 1)
        XCTAssertEqual(branch.behind, 0)
    }

    /// A branch name can contain characters a naive split would trip on.
    func testBranchNameWithSlashes() {
        let branch = GitPorcelainParser.parse(z("# branch.head feature/git-ui/v2")).branch
        XCTAssertEqual(branch.head, "feature/git-ui/v2")
    }

    // MARK: - Degenerate input

    func testEmptyOutputIsACleanEmptyReport() {
        let report = GitPorcelainParser.parse(Data())
        XCTAssertEqual(report.entries, [])
        XCTAssertEqual(report.malformedRecordCount, 0)
    }

    func testUnknownHeaderIsIgnoredNotMalformed() {
        let report = GitPorcelainParser.parse(z("# stash 3", "# branch.head main"))
        XCTAssertEqual(report.malformedRecordCount, 0)
        XCTAssertEqual(report.branch.head, "main")
    }

    /// Malformed records are COUNTED, never silently dropped, and do not derail the records after.
    func testMalformedRecordsAreCountedAndParsingContinues() {
        let report = GitPorcelainParser.parse(z(
            "1 .M truncated",
            "X something unknown",
            "? ok.txt"
        ))
        XCTAssertEqual(report.malformedRecordCount, 2)
        XCTAssertEqual(report.entries.map(\.path), ["ok.txt"])
    }

    /// A rename whose original-path field is missing (truncated stream) must not crash or read
    /// past the end.
    func testTruncatedRenameIsMalformedNotACrash() {
        let data = Data("2 R. N... 100644 100644 100644 aaaa aaaa R100 new.txt".utf8)
        let report = GitPorcelainParser.parse(data)
        XCTAssertEqual(report.malformedRecordCount, 1)
        XCTAssertEqual(report.entries, [])
    }
}
