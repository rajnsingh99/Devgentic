// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GitChangesSnapshotTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class GitChangesSnapshotTests: XCTestCase {

    static func z(_ records: String...) -> Data {
        Data(records.map { $0 + "\0" }.joined().utf8)
    }

    static let statusFixture = z(
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
    static let unstagedFixture = Data(
        "-\t-\tblob.bin\u{0}0\t0\tconflict.txt\u{0}4\t0\tconflict.txt\u{0}0\t1\tdeleted.txt\u{0}2\t1\tmodified.txt\u{0}1\t0\tstaged.txt\u{0}".utf8
    )
    static let stagedFixture = Data(
        "0\t0\tconflict.txt\u{0}0\t0\t\u{0}old name.txt\u{0}new näme.txt\u{0}1\t0\tstaged.txt\u{0}".utf8
    )

    private func build(prefix: String = "",
                       status: Data = statusFixture,
                       untracked: [String: UntrackedFileInfo]? = nil,
                       operation: GitInProgressOperation? = nil) -> GitChangesSnapshot {
        let report = GitPorcelainParser.parse(status)
        let info = untracked ?? Dictionary(uniqueKeysWithValues:
            GitChangesSnapshot.untrackedPathsToMeasure(report).map { ($0, UntrackedFileInfo.lines(2)) })
        return GitChangesSnapshot.build(
            repoRoot: "/repo", status: report,
            unstaged: GitNumstatParser.parse(Self.unstagedFixture).countsByPath(),
            staged: GitNumstatParser.parse(Self.stagedFixture).countsByPath(),
            untrackedInfo: info, projectPrefix: prefix,
            inProgressOperation: operation, isTruncated: false)
    }

    private func file(_ path: String, in snapshot: GitChangesSnapshot) -> GitFileChange? {
        snapshot.files.first { $0.path == path }
    }

    // MARK: - Merge

    func testConflictsSortFirstOtherwiseGitOrderIsKept() {
        XCTAssertEqual(build().files.map(\.path), [
            "conflict.txt", "blob.bin", "deleted.txt", "modified.txt", "new näme.txt", "staged.txt",
            "-leading dash.txt", "newdir/untracked one.txt", "tab\there.txt",
        ])
    }

    func testCountsAttachToTheSideThatChanged() {
        let snapshot = build()
        let modified = file("modified.txt", in: snapshot)
        XCTAssertNil(modified?.staged, "nothing staged — the X column is '.'")
        XCTAssertEqual(modified?.unstaged, GitLineCounts(added: 2, deleted: 1))

        let both = file("staged.txt", in: snapshot)
        XCTAssertEqual(both?.staged, GitLineCounts(added: 1, deleted: 0))
        XCTAssertEqual(both?.unstaged, GitLineCounts(added: 1, deleted: 0))

        let renamed = file("new näme.txt", in: snapshot)
        XCTAssertEqual(renamed?.originalPath, "old name.txt")
        XCTAssertEqual(renamed?.staged, GitLineCounts(added: 0, deleted: 0), "rename keyed by destination")
        XCTAssertNil(renamed?.unstaged)
    }

    func testConflictTakesTheRealCountNotThePlaceholder() {
        XCTAssertEqual(file("conflict.txt", in: build())?.unstaged, GitLineCounts(added: 4, deleted: 0))
    }

    func testBinaryAndUntracked() {
        let snapshot = build()
        XCTAssertEqual(file("blob.bin", in: snapshot)?.isBinary, true)
        let untracked = file("newdir/untracked one.txt", in: snapshot)
        XCTAssertEqual(untracked?.untracked, .lines(2))
        XCTAssertNil(untracked?.staged)
        XCTAssertNil(untracked?.unstaged)
    }

    /// A path status listed but nobody measured (vanished between calls) is shown as unreadable,
    /// never dropped.
    func testUnmeasuredUntrackedIsUnreadableNotDropped() {
        let snapshot = build(untracked: [:])
        XCTAssertEqual(file("-leading dash.txt", in: snapshot)?.untracked, .unreadable)
    }

    func testStatusGlyphs() {
        let snapshot = build()
        XCTAssertEqual(file("conflict.txt", in: snapshot)?.statusGlyph, "U")
        XCTAssertEqual(file("deleted.txt", in: snapshot)?.statusGlyph, "D")
        XCTAssertEqual(file("new näme.txt", in: snapshot)?.statusGlyph, "R")
        XCTAssertEqual(file("staged.txt", in: snapshot)?.statusGlyph, "M")
        XCTAssertEqual(file("tab\there.txt", in: snapshot)?.statusGlyph, "?")
    }

    // MARK: - Filters and totals

    func testFilters() {
        let snapshot = build()
        XCTAssertEqual(snapshot.files(for: .staged).map(\.path), ["conflict.txt", "new näme.txt", "staged.txt"])
        XCTAssertEqual(snapshot.files(for: .unstaged).map(\.path), [
            "conflict.txt", "blob.bin", "deleted.txt", "modified.txt", "staged.txt",
            "-leading dash.txt", "newdir/untracked one.txt", "tab\there.txt",
        ])
        XCTAssertEqual(snapshot.files(for: .all).count, 9)
    }

    func testTotals() {
        let snapshot = build()
        // staged: conflict 0/0, rename 0/0, staged.txt 1/0
        XCTAssertEqual(snapshot.totals(for: .staged), GitLineTotals(added: 1, deleted: 0))
        // unstaged: conflict 4/0, binary 0, deleted 0/1, modified 2/1, staged.txt 1/0, 3 untracked × 2
        XCTAssertEqual(snapshot.totals(for: .unstaged), GitLineTotals(added: 13, deleted: 2))
        XCTAssertEqual(snapshot.totals(for: .all), GitLineTotals(added: 14, deleted: 2))
    }

    func testCleanTree() {
        let snapshot = build(status: Self.z("# branch.oid abc", "# branch.head main"))
        XCTAssertTrue(snapshot.isClean)
        XCTAssertEqual(snapshot.totals(), GitLineTotals(added: 0, deleted: 0))
    }

    // MARK: - Untracked cap

    func testUntrackedBeyondTheLimitAreCountedNotListed() {
        let limit = GitChangesSnapshot.untrackedLimit
        let records = (0..<(limit + 2)).map { String(format: "? u%04d.txt", $0) }
        let data = Data((["# branch.head main"] + records).map { $0 + "\0" }.joined().utf8)
        let report = GitPorcelainParser.parse(data)

        XCTAssertEqual(GitChangesSnapshot.untrackedPathsToMeasure(report).count, limit,
                       "measuring must stop at the cap, or the cap protects nothing")
        let snapshot = build(status: data)
        XCTAssertEqual(snapshot.files.count, limit)
        XCTAssertEqual(snapshot.untrackedOverflowCount, 2)
        XCTAssertFalse(snapshot.isClean)
    }

    /// Tracked changes are never subject to the untracked cap.
    func testTheCapCountsOnlyUntracked() {
        let limit = GitChangesSnapshot.untrackedLimit
        let untracked = (0..<limit).map { String(format: "? u%04d.txt", $0) }
        let data = Data((["# branch.head main"] + untracked + ["1 .M N... 100644 100644 100644 aa aa tracked.txt"])
            .map { $0 + "\0" }.joined().utf8)
        let snapshot = build(status: data)
        XCTAssertNotNil(file("tracked.txt", in: snapshot))
        XCTAssertEqual(snapshot.untrackedOverflowCount, 0)
    }

    // MARK: - Project scope

    func testRowsOutsideASubfolderProjectAreMarkedNotDropped() {
        let snapshot = build(prefix: "newdir/")
        XCTAssertEqual(snapshot.files.count, 9)
        XCTAssertEqual(snapshot.files.filter { !$0.isOutsideProject }.map(\.path), ["newdir/untracked one.txt"])
    }

    func testProjectAtRepoRootMarksNothingOutside() {
        XCTAssertTrue(build(prefix: "").files.allSatisfy { !$0.isOutsideProject })
    }

    func testProjectPrefix() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("GitPrefix-\(UUID().uuidString)")
        let sub = base.appendingPathComponent("a b/c")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // git reports the REAL path. The temp dir lives under /var, a symlink to /private/var.
        let realRoot = base.resolvingSymlinksInPath().path

        XCTAssertEqual(GitChangesSnapshot.projectPrefix(projectPath: base, repoRoot: realRoot), "")
        XCTAssertEqual(GitChangesSnapshot.projectPrefix(projectPath: sub, repoRoot: realRoot), "a b/c/")
        // A sibling whose name merely STARTS with the root's name is not inside it.
        XCTAssertEqual(GitChangesSnapshot.projectPrefix(projectPath: URL(fileURLWithPath: realRoot + "-sibling"),
                                                         repoRoot: realRoot), "")
    }

    // MARK: - Untracked measurement

    func testClassify() {
        XCTAssertEqual(UntrackedFileInfo.classify(Data()), .lines(0))
        XCTAssertEqual(UntrackedFileInfo.classify(Data("a\nb\n".utf8)), .lines(2))
        XCTAssertEqual(UntrackedFileInfo.classify(Data("a\nb".utf8)), .lines(2), "unterminated last line counts")
        XCTAssertEqual(UntrackedFileInfo.classify(Data([0x61, 0x00, 0x62])), .binary)
        var late = Data(repeating: 0x61, count: UntrackedFileInfo.binarySniffLength)
        late.append(0)
        XCTAssertEqual(UntrackedFileInfo.classify(late), .lines(1), "NUL past the sniff window is not binary")
    }

    func testMeasureRefusesLargeFilesWithoutReading() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GitBig-\(UUID().uuidString)")
        try Data(repeating: 0x61, count: UntrackedFileInfo.byteLimit + 1).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(UntrackedFileInfo.measure(url), .tooLarge)
        XCTAssertEqual(UntrackedFileInfo.measure(url.appendingPathExtension("missing")), .unreadable)
    }

    // MARK: - In-progress operations

    func testInProgressDetection() {
        let gitDir = "/repo/.git"
        XCTAssertNil(GitInProgressOperation.detect(gitDir: gitDir) { _ in false })
        XCTAssertEqual(GitInProgressOperation.detect(gitDir: gitDir) { $0 == "/repo/.git/MERGE_HEAD" }, .merge)
        XCTAssertEqual(GitInProgressOperation.detect(gitDir: gitDir) { $0 == "/repo/.git/rebase-apply" }, .rebase)
        // A rebase stopped on a cherry-pick has both markers; the rebase is the operation.
        XCTAssertEqual(GitInProgressOperation.detect(gitDir: gitDir) {
            $0 == "/repo/.git/rebase-merge" || $0 == "/repo/.git/CHERRY_PICK_HEAD"
        }, .rebase)
    }
}
