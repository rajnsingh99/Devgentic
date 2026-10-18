// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GitChangesAccessibilityTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class GitChangesAccessibilityTests: XCTestCase {

    private func change(_ x: Character, _ y: Character, kind: GitStatusEntry.Kind = .ordinary,
                        staged: GitLineCounts? = nil, unstaged: GitLineCounts? = nil,
                        untracked: UntrackedFileInfo? = nil, from original: String? = nil,
                        outside: Bool = false) -> GitFileChange {
        GitFileChange(path: "src/a.swift", originalPath: original, indexStatus: x, worktreeStatus: y,
                      kind: kind, staged: staged, unstaged: unstaged, untracked: untracked,
                      isOutsideProject: outside)
    }

    func testEveryGlyphHasAWord() {
        XCTAssertEqual(change("A", ".").statusDescription, "added")
        XCTAssertEqual(change(".", "M").statusDescription, "modified")
        XCTAssertEqual(change(".", "D").statusDescription, "deleted")
        XCTAssertEqual(change("R", ".", kind: .renamed(score: 100)).statusDescription, "renamed")
        XCTAssertEqual(change("C", ".", kind: .copied(score: 90)).statusDescription, "copied")
        XCTAssertEqual(change("T", ".").statusDescription, "type changed")
        XCTAssertEqual(change("U", "U", kind: .unmerged).statusDescription, "conflicted")
        XCTAssertEqual(change("?", "?", kind: .untracked).statusDescription, "untracked")
    }

    func testRowSummarySpeaksCountsAsWords() {
        let file = change(".", "M", unstaged: GitLineCounts(added: 3, deleted: 1))
        XCTAssertEqual(file.accessibilitySummary(for: .all),
                       "src/a.swift, modified, 3 lines added, 1 line deleted")
    }

    func testRowSummaryFollowsTheFilter() {
        let file = change("M", "M", staged: GitLineCounts(added: 1, deleted: 0),
                          unstaged: GitLineCounts(added: 2, deleted: 2))
        XCTAssertEqual(file.accessibilitySummary(for: .staged), "src/a.swift, modified, 1 line added, 0 lines deleted")
        XCTAssertEqual(file.accessibilitySummary(for: .unstaged), "src/a.swift, modified, 2 lines added, 2 lines deleted")
    }

    func testRowSummaryForRenameAndOutsideProject() {
        let file = change("R", ".", kind: .renamed(score: 100), staged: GitLineCounts(added: 0, deleted: 0),
                          from: "old/a.swift", outside: true)
        XCTAssertEqual(file.accessibilitySummary(for: .all),
                       "src/a.swift, renamed, from old/a.swift, 0 lines added, 0 lines deleted, outside the project")
    }

    func testRowSummaryForUntrackedAndBinary() {
        XCTAssertEqual(change("?", "?", kind: .untracked, untracked: .lines(1)).accessibilitySummary(for: .all),
                       "src/a.swift, untracked, 1 line")
        XCTAssertEqual(change("?", "?", kind: .untracked, untracked: .tooLarge).accessibilitySummary(for: .all),
                       "src/a.swift, untracked, too large to count")
        XCTAssertEqual(change(".", "M", unstaged: .binary).accessibilitySummary(for: .all),
                       "src/a.swift, modified, binary")
    }

    /// One key per plural form — singular must not read "1 lines".
    func testSpokenTotalsUseTheSingularForOne() {
        XCTAssertEqual(GitLineTotals.spoken(GitLineTotals(added: 1, deleted: 1)), "1 line added, 1 line deleted")
        XCTAssertEqual(GitLineTotals.spoken(GitLineTotals(added: 0, deleted: 12)), "0 lines added, 12 lines deleted")
    }

    func testDiffRowsSayWhatTheyAre() {
        func row(_ line: String, _ type: LineChangeType) -> DiffResult {
            DiffResult(line: line, type: type, originalLineNumber: nil, modifiedLineNumber: nil)
        }
        XCTAssertEqual(DiffLineRow.spokenLabel(row("let x = 1", .added)), "Added: let x = 1")
        XCTAssertEqual(DiffLineRow.spokenLabel(row("let x = 0", .deleted)), "Removed: let x = 0")
        XCTAssertEqual(DiffLineRow.spokenLabel(row("}", .unchanged)), "}")
        XCTAssertEqual(DiffLineRow.spokenLabel(row("", .added)), "Added: blank line")
    }
}
