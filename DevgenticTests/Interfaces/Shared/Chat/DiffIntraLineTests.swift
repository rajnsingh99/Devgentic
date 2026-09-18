// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DiffIntraLineTests.swift
//  DevgenticTests
//
//  Covers DiffUtility's intra-line refinement: modified line pairs (a deletion paired
//  with an addition) carry character-level `segments` marking the actual edit, so the
//  renderers can highlight `1` → `2` instead of tinting both whole lines.
//

import XCTest
@testable import devgentic

final class DiffIntraLineTests: XCTestCase {

    // MARK: - Helpers

    private func diff(_ original: String, _ modified: String) -> [DiffResult] {
        DiffUtility.generateDiff(original: original, modified: modified)
    }

    private func emphasizedText(of segments: [DiffSegment]?) -> [String] {
        (segments ?? []).filter(\.isEmphasized).map(\.text)
    }

    /// Segments must always reconstruct the line they refine.
    private func assertReconstructs(_ results: [DiffResult], file: StaticString = #filePath, line: UInt = #line) {
        for result in results {
            if let segments = result.segments {
                XCTAssertEqual(segments.map(\.text).joined(), result.line,
                               "Segments must concatenate back to the line", file: file, line: line)
            }
        }
    }

    // MARK: - The core case

    func testSingleTokenChangeEmphasizesJustTheToken() {
        let results = diff("let x = 1", "let x = 2")

        let deleted = results.first { $0.type == .deleted }
        let added = results.first { $0.type == .added }
        XCTAssertEqual(emphasizedText(of: deleted?.segments), ["1"])
        XCTAssertEqual(emphasizedText(of: added?.segments), ["2"])
        assertReconstructs(results)
    }

    func testEditInsideALargerFile() {
        let original = "func a() {}\nlet value = 10\nfunc b() {}"
        let modified = "func a() {}\nlet value = 99\nfunc b() {}"
        let results = diff(original, modified)

        XCTAssertEqual(results.filter { $0.type == .unchanged }.count, 2)
        XCTAssertEqual(emphasizedText(of: results.first { $0.type == .deleted }?.segments), ["10"])
        XCTAssertEqual(emphasizedText(of: results.first { $0.type == .added }?.segments), ["99"])
        assertReconstructs(results)
    }

    // MARK: - Gap merging

    /// Two nearby edits separated by ≤2 unchanged chars merge into one run — no confetti.
    func testScatteredEditsMergeSmallGaps() {
        let results = diff("foo(a, b)", "foo(x, y)")

        XCTAssertEqual(emphasizedText(of: results.first { $0.type == .deleted }?.segments), ["a, b"])
        XCTAssertEqual(emphasizedText(of: results.first { $0.type == .added }?.segments), ["x, y"])
        assertReconstructs(results)
    }

    /// Edits separated by a WIDE unchanged stretch stay separate runs.
    func testDistantEditsStaySeparateRuns() {
        let results = diff("alpha SHARED-MIDDLE-SECTION omega", "ALPHA SHARED-MIDDLE-SECTION OMEGA")

        let deleted = emphasizedText(of: results.first { $0.type == .deleted }?.segments)
        XCTAssertEqual(deleted.count, 2, "Two distant edits must not merge across the shared middle")
        assertReconstructs(results)
    }

    // MARK: - The similarity gate

    /// Fully different lines are NOT a modification — no segments, plain rows.
    func testCompletelyDifferentLinesGetNoSegments() {
        let results = diff("import java.util.Arrays;", "private void reticulate() {")

        XCTAssertNil(results.first { $0.type == .deleted }?.segments)
        XCTAssertNil(results.first { $0.type == .added }?.segments)
    }

    // MARK: - Pairing rules

    func testUnpairedDeletionGetsNoSegments() {
        let results = diff("keep\ngone\nkeep2", "keep\nkeep2")
        XCTAssertNil(results.first { $0.type == .deleted }?.segments)
    }

    func testUnchangedRowsNeverGetSegments() {
        for result in diff("same\nold line here\nsame2", "same\nnew line here\nsame2")
        where result.type == .unchanged {
            XCTAssertNil(result.segments)
        }
    }

    /// k-th deletion pairs with k-th addition inside a change block.
    func testPairingIsPositional() {
        let results = diff("first old AAA\nsecond old BBB", "first new AAA\nsecond new BBB")

        let deletions = results.filter { $0.type == .deleted }
        let additions = results.filter { $0.type == .added }
        XCTAssertEqual(emphasizedText(of: deletions.first?.segments), ["old"])
        XCTAssertEqual(emphasizedText(of: additions.first?.segments), ["new"])
        XCTAssertEqual(emphasizedText(of: deletions.last?.segments), ["old"])
        XCTAssertEqual(emphasizedText(of: additions.last?.segments), ["new"])
    }

    /// Pure insertion/deletion diffs (the `1...0` guard territory) have no pairs at all.
    func testPureInsertionDiffHasNoSegments() {
        let results = diff("line1\nline2", "line1\nline2\nline3\nline4")
        for result in results {
            XCTAssertNil(result.segments)
        }
    }

    // MARK: - Character safety and bounds

    /// Refinement works on grapheme clusters — an emoji swap emphasizes the emoji, whole.
    func testEmojiGraphemesAreNeverSplit() {
        let results = diff("let s = \"👍 ok\"", "let s = \"👎 ok\"")

        XCTAssertEqual(emphasizedText(of: results.first { $0.type == .deleted }?.segments), ["👍"])
        XCTAssertEqual(emphasizedText(of: results.first { $0.type == .added }?.segments), ["👎"])
        assertReconstructs(results)
    }

    /// Cores past the LCS cap fall back to ONE contiguous emphasized span per side.
    func testLongCoresFallBackToSingleSpan() {
        let prefix = String(repeating: "p", count: 300)
        let suffix = String(repeating: "s", count: 300)
        let oldCore = String(repeating: "a", count: 450)
        let newCore = String(repeating: "b", count: 450)
        let results = diff(prefix + oldCore + suffix, prefix + newCore + suffix)

        let deleted = results.first { $0.type == .deleted }?.segments
        XCTAssertEqual(deleted?.filter(\.isEmphasized).count, 1, "Capped refinement = one span")
        XCTAssertEqual(deleted?.filter(\.isEmphasized).first?.text, oldCore)
        assertReconstructs(results)
    }
}
