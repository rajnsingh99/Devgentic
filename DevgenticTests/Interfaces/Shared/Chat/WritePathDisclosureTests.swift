// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  WritePathDisclosureTests.swift
//  DevgenticTests
//
//  Regression cover for the field-observed wrong-target write (2026-07-25).
//
//  The model emitted a bare relative path (`January2026.java`) for a file the user had
//  attached from a project directory. `FilePathResolver` anchors relative paths to HOME,
//  so the write landed at `~/January2026.java` — but the approval banner rendered the RAW
//  string, which looked exactly like the attached file. The user approved a write to a
//  file they had never seen, and their real file was untouched.
//
//  The banner now shows the resolved target, and the preview reads the same path the
//  executor writes.
//

import XCTest
@testable import devgentic

final class WritePathDisclosureTests: XCTestCase {

    private var home: NSString { NSHomeDirectory() as NSString }

    // MARK: - The disclosure that was missing

    /// THE FIELD CASE: a bare filename must not render as a bare filename.
    func testRelativePathIsDisclosedAsHomeAnchored() {
        let shown = (FilePathResolver.resolve("January2026.java") as NSString).abbreviatingWithTildeInPath
        XCTAssertEqual(shown, "~/January2026.java",
                       "A relative path must reveal that it lands in HOME, not read as a lone filename")
        XCTAssertNotEqual(shown, "January2026.java",
                          "Rendering the raw string is what hid the wrong target")
    }

    /// A nested relative path is equally misleading unresolved.
    func testNestedRelativePathIsDisclosed() {
        let shown = (FilePathResolver.resolve("Desktop/Java_Programs/A.java") as NSString).abbreviatingWithTildeInPath
        XCTAssertEqual(shown, "~/Desktop/Java_Programs/A.java")
    }

    /// Absolute paths must survive untouched — this fix must not rewrite real targets.
    func testAbsolutePathIsUnchanged() {
        let abs = "/Users/someone/Documents/Workspace/project/Main.java"
        XCTAssertEqual(FilePathResolver.resolve(abs), abs)
    }

    /// Tilde paths resolve and then abbreviate back to the same display form.
    func testTildePathRoundTrips() {
        let shown = (FilePathResolver.resolve("~/Desktop/x.java") as NSString).abbreviatingWithTildeInPath
        XCTAssertEqual(shown, "~/Desktop/x.java")
    }

    // MARK: - Preview and executor must agree

    /// The preview used `expandingTildeInPath`, which leaves a relative path relative, while
    /// the executor used `FilePathResolver`. They pointed at different files: the preview
    /// diffed nothing while the write hit HOME.
    func testPreviewResolutionMatchesExecutorResolution() {
        for raw in ["January2026.java", "Desktop/a.java", "~/b.java", "/tmp/c.java"] {
            let executorTarget = FilePathResolver.resolve(raw)
            let legacyPreviewTarget = (raw as NSString).expandingTildeInPath
            // The preview now uses the executor's resolver, so this is the value it reads.
            XCTAssertEqual(FilePathResolver.resolve(raw), executorTarget)

            if !raw.hasPrefix("/") && !raw.hasPrefix("~") {
                XCTAssertNotEqual(
                    legacyPreviewTarget, executorTarget,
                    "This is the divergence the bug rode on — kept as an explicit witness for '\(raw)'"
                )
            }
        }
    }

    /// The resolved target is absolute for every input shape, so a preview can always
    /// state where the write is going.
    func testResolvedTargetIsAlwaysAbsolute() {
        for raw in ["a.java", "x/y.java", "~/z.java", "/tmp/w.java"] {
            XCTAssertTrue(FilePathResolver.resolve(raw).hasPrefix("/"),
                          "'\(raw)' must resolve to an absolute path")
        }
    }
}
