// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GitUICommandTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class GitUICommandTests: XCTestCase {

    private let root = "/repo"

    private var all: [GitInvocation] {
        [
            GitUICommand.locate(directory: root),
            GitUICommand.status(repoRoot: root),
            GitUICommand.numstat(repoRoot: root, staged: false),
            GitUICommand.numstat(repoRoot: root, staged: true),
            GitUICommand.blob(repoRoot: root, side: .head, path: "a.txt"),
            GitUICommand.blob(repoRoot: root, side: .index, path: "a.txt"),
            GitUICommand.blobSize(repoRoot: root, side: .head, path: "a.txt"),
            GitUICommand.blobSize(repoRoot: root, side: .index, path: "a.txt"),
        ]
    }

    /// `-C <dir>` then the hardening `-c` pairs, BEFORE the subcommand — `-c` is a global option and
    /// only takes effect in that position.
    func testEveryCommandIsHardenedBeforeTheSubcommand() {
        let hardening = GitCommandBuilder.hardening
        for invocation in all {
            XCTAssertEqual(Array(invocation.arguments.prefix(2)), ["-C", root], "\(invocation.arguments)")
            XCTAssertEqual(Array(invocation.arguments.dropFirst(2).prefix(hardening.count)), hardening,
                           "\(invocation.arguments)")
        }
    }

    func testEveryCommandDisablesOptionalLocksAndColour() {
        for invocation in all {
            XCTAssertEqual(invocation.environment["GIT_OPTIONAL_LOCKS"], "0", "\(invocation.arguments)")
            XCTAssertEqual(invocation.environment["TERM"], "dumb", "\(invocation.arguments)")
        }
    }

    func testDiffCommandsSuppressRepoNominatedPrograms() {
        for staged in [false, true] {
            let args = GitUICommand.numstat(repoRoot: root, staged: staged).arguments
            for flag in GitCommandBuilder.diffProgramSuppression {
                XCTAssertTrue(args.contains(flag), "\(flag) missing from \(args)")
            }
        }
    }

    func testNumstatPinsRenameDetectionAndNulSeparation() {
        let unstaged = GitUICommand.numstat(repoRoot: root, staged: false).arguments
        let staged = GitUICommand.numstat(repoRoot: root, staged: true).arguments
        for args in [unstaged, staged] {
            XCTAssertTrue(args.contains("-M"))
            XCTAssertTrue(args.contains("-z"))
            XCTAssertTrue(args.contains("--numstat"))
        }
        XCTAssertFalse(unstaged.contains("--cached"))
        XCTAssertTrue(staged.contains("--cached"))
    }

    func testStatusListsEveryUntrackedFile() {
        let args = GitUICommand.status(repoRoot: root).arguments
        XCTAssertTrue(args.contains("--porcelain=v2"))
        XCTAssertTrue(args.contains("-z"))
        XCTAssertTrue(args.contains("--branch"))
        XCTAssertTrue(args.contains("--untracked-files=all"), "default mode collapses an untracked dir to one `dir/` row")
    }

    func testLocateAsksForRootAndGitDir() {
        let args = GitUICommand.locate(directory: "/repo/sub").arguments
        XCTAssertEqual(Array(args.prefix(2)), ["-C", "/repo/sub"])
        XCTAssertEqual(Array(args.suffix(3)), ["rev-parse", "--show-toplevel", "--absolute-git-dir"])
    }

    /// `:<path>` misreads `0:x.txt` as stage 0 of `x.txt` (verified on git 2.54). `:0:` makes the
    /// rest unambiguously a path.
    func testIndexBlobUsesAnExplicitStage() {
        XCTAssertEqual(GitUICommand.blob(repoRoot: root, side: .index, path: "0:x.txt").arguments.suffix(3),
                       ["cat-file", "blob", ":0:0:x.txt"])
        XCTAssertEqual(GitUICommand.blob(repoRoot: root, side: .head, path: "dir/a b.txt").arguments.suffix(3),
                       ["cat-file", "blob", "HEAD:dir/a b.txt"])
    }

    /// The size query names the SAME object as the fetch it guards — including the explicit stage.
    func testSizeQueryNamesTheSameObjectAsTheFetch() {
        for side in [GitUICommand.BlobSide.head, .index] {
            let size = GitUICommand.blobSize(repoRoot: root, side: side, path: "0:x.txt").arguments
            let blob = GitUICommand.blob(repoRoot: root, side: side, path: "0:x.txt").arguments
            XCTAssertEqual(Array(size.suffix(2)).first, "-s")
            XCTAssertEqual(size.last, blob.last, "\(side)")
        }
    }
}
