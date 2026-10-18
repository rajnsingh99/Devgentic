// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GitFileDiffTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class GitFileDiffTests: XCTestCase {

    private func change(_ path: String = "f.txt", x: Character, y: Character,
                        kind: GitStatusEntry.Kind = .ordinary, from original: String? = nil) -> GitFileChange {
        GitFileChange(path: path, originalPath: original, indexStatus: x, worktreeStatus: y, kind: kind,
                      staged: nil, unstaged: nil, untracked: nil, isOutsideProject: false)
    }

    private func sides(_ file: GitFileChange, _ filter: GitChangesFilter, unborn: Bool = false)
        -> (GitDiffSide, GitDiffSide) {
        let s = GitDiffSide.sides(for: file, filter: filter, isUnborn: unborn)
        return (s.original, s.modified)
    }

    // MARK: - Sides per filter

    func testModifiedFileSidesFollowTheFilterTable() {
        let file = change(x: "M", y: "M")
        XCTAssertTrue(sides(file, .unstaged) == (.index(path: "f.txt"), .worktree(path: "f.txt")))
        XCTAssertTrue(sides(file, .staged) == (.head(path: "f.txt"), .index(path: "f.txt")))
        XCTAssertTrue(sides(file, .all) == (.head(path: "f.txt"), .worktree(path: "f.txt")))
    }

    /// A rename's HEAD version lives at the ORIGINAL path. Reading HEAD:<new> would fail — or worse,
    /// read an unrelated file that happens to sit at the new path in HEAD.
    func testRenameReadsHeadAtTheOriginalPath() {
        let file = change("new.txt", x: "R", y: ".", kind: .renamed(score: 100), from: "old.txt")
        XCTAssertTrue(sides(file, .staged) == (.head(path: "old.txt"), .index(path: "new.txt")))
        XCTAssertTrue(sides(file, .all) == (.head(path: "old.txt"), .worktree(path: "new.txt")))
    }

    func testCopyReadsHeadAtTheSourcePath() {
        let file = change("copy.txt", x: "C", y: ".", kind: .copied(score: 90), from: "src.txt")
        XCTAssertTrue(sides(file, .staged) == (.head(path: "src.txt"), .index(path: "copy.txt")))
    }

    /// Absent sides are decided from STATUS, so a missing version diffs as empty instead of being
    /// read and failing.
    func testAddedFileHasNoHeadSide() {
        let file = change(x: "A", y: ".")
        XCTAssertTrue(sides(file, .staged) == (.empty, .index(path: "f.txt")))
    }

    func testDeletedFromIndexHasNoIndexSide() {
        let file = change(x: "D", y: ".")
        XCTAssertTrue(sides(file, .staged) == (.head(path: "f.txt"), .empty))
    }

    func testDeletedFromWorktreeHasNoWorktreeSide() {
        let file = change(x: ".", y: "D")
        XCTAssertTrue(sides(file, .unstaged) == (.index(path: "f.txt"), .empty))
        XCTAssertTrue(sides(file, .all) == (.head(path: "f.txt"), .empty))
    }

    func testUntrackedIsAllAdditions() {
        let file = change(x: "?", y: "?", kind: .untracked)
        for filter in GitChangesFilter.allCases {
            XCTAssertTrue(sides(file, filter) == (.empty, .worktree(path: "f.txt")), "\(filter)")
        }
    }

    /// A conflicted file has no stage-0 entry (`:0:` fails mid-conflict), so every filter shows
    /// HEAD → worktree: the conflict markers.
    func testConflictNeverReadsTheIndex() {
        let file = change(x: "U", y: "U", kind: .unmerged)
        for filter in GitChangesFilter.allCases {
            XCTAssertTrue(sides(file, filter) == (.head(path: "f.txt"), .worktree(path: "f.txt")), "\(filter)")
        }
    }

    /// No commits yet: there is no HEAD to read (verified: `HEAD:` fails on an unborn branch).
    func testUnbornBranchHasNoHeadSide() {
        let file = change(x: "A", y: "M")
        XCTAssertTrue(sides(file, .all, unborn: true) == (.empty, .worktree(path: "f.txt")))
        let modified = change(x: "M", y: ".")
        XCTAssertTrue(sides(modified, .staged, unborn: true) == (.empty, .index(path: "f.txt")))
    }

    // MARK: - Collapse

    private func rows(_ spec: String) -> [DiffResult] {
        // One char per line: "=" unchanged, "+" added, "-" deleted.
        spec.enumerated().map { i, c in
            DiffResult(line: "L\(i)", type: c == "+" ? .added : c == "-" ? .deleted : .unchanged,
                       originalLineNumber: nil, modifiedLineNumber: nil)
        }
    }

    private func render(_ display: [GitDiffDisplayRow]) -> [String] {
        display.map {
            switch $0 {
            case .line(let r): return r.line
            case .gap(_, let n): return "gap\(n)"
            }
        }
    }

    func testKeepsContextAroundAChangeAndFoldsTheRest() {
        // 10 unchanged, 1 added, 10 unchanged.
        let display = GitDiffDisplayRow.collapse(rows("==========+=========="), context: 3)
        XCTAssertEqual(render(display), ["gap7", "L7", "L8", "L9", "L10", "L11", "L12", "L13", "gap7"])
    }

    /// Folding exactly one line saves nothing — it is shown instead.
    func testAOneLineGapIsShownNotFolded() {
        // changes at 0 and 8, context 3: lines 1-3 and 5-7 kept, line 4 is a 1-line gap.
        let display = GitDiffDisplayRow.collapse(rows("+=======+"), context: 3)
        XCTAssertEqual(render(display), (0...8).map { "L\($0)" })
    }

    func testAdjacentChangesShareContext() {
        let display = GitDiffDisplayRow.collapse(rows("=====+=+====="), context: 2)
        XCTAssertEqual(render(display), ["gap3", "L3", "L4", "L5", "L6", "L7", "L8", "L9", "gap3"])
    }

    func testNoChangesIsOneGap() {
        XCTAssertEqual(render(GitDiffDisplayRow.collapse(rows("======"), context: 3)), ["gap6"])
    }

    func testEmpty() {
        XCTAssertTrue(GitDiffDisplayRow.collapse([]).isEmpty)
    }

    func testGapIDsAreUnique() {
        let display = GitDiffDisplayRow.collapse(rows("========+========+========"), context: 1)
        let ids = display.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}
