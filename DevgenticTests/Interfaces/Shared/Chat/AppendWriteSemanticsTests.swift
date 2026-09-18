// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AppendWriteSemanticsTests.swift
//  DevgenticTests
//
//  Regression family for the append-mode blindspot (2026-07-25): `write_file` with
//  `append: true` carries only the appended FRAGMENT in `content`. Both viewer surfaces
//  treated it as the full post-write file, rendering a diff that claimed the whole file
//  was deleted and one line added — the inverse of an append.
//
//  Covers: the timeline row's resolver (fragment → snapshot + fragment reconstruction,
//  no-affordance without a snapshot, the tool's append alias/coercion matrix) and
//  FileChange.parse (append flag threaded to the HITL preview).
//

import XCTest
@testable import devgentic

final class AppendWriteSemanticsTests: XCTestCase {

    // MARK: - Fixtures

    private func writeRow(params: String, preWrite: String?, name: String = "write_file") -> ToolExecutionData {
        var data = ToolExecutionData(id: UUID(), name: name, params: params, output: "ok",
                                     isSuccess: true, isExecuting: false)
        data.preWriteContent = preWrite
        return data
    }

    private let file = "/Users/alice/Desktop/EmployeeManagementSystem.java"

    // MARK: - Timeline resolver: append reconstruction

    /// The exact logged scenario: append of "\nRaj Singh" onto a full file must open
    /// snapshot + fragment, NOT the 9-char fragment.
    func testAppendReconstructsPostWriteContent() {
        let pre = "class EmployeeManagementSystem {}\n"
        let row = writeRow(
            params: #"{"append":true,"content":"\nRaj Singh","path":"\#(file)"}"#,
            preWrite: pre
        )

        let action = TimelineFileViewerAction.resolve(data: row)
        XCTAssertEqual(action?.inlineContent, pre + "\nRaj Singh",
                       "Append mode opens the POST-WRITE file: snapshot + fragment")
        XCTAssertEqual(action?.preWriteContent, pre)
        XCTAssertEqual(action?.fileName, "EmployeeManagementSystem.java")
    }

    /// Diff sanity for the reconstructed pair: one added line, zero deletions — not
    /// "everything removed".
    func testAppendDiffShowsOnlyTheAddition() throws {
        let pre = "line1\nline2\nline3\n"
        let row = writeRow(
            params: #"{"append":true,"content":"Raj Singh","path":"\#(file)"}"#,
            preWrite: pre
        )
        let action = try XCTUnwrap(TimelineFileViewerAction.resolve(data: row))

        let counts = DiffUtility.changeCounts(original: action.preWriteContent ?? "",
                                              modified: try XCTUnwrap(action.inlineContent))
        XCTAssertEqual(counts.deleted, 0, "An append must not report ANY deletions")
        XCTAssertGreaterThan(counts.added, 0)
    }

    /// Without the snapshot the post-write file can't be represented — no affordance
    /// beats a lying one.
    func testAppendWithoutSnapshotGetsNoAffordance() {
        let row = writeRow(
            params: #"{"append":true,"content":"Raj Singh","path":"\#(file)"}"#,
            preWrite: nil
        )
        XCTAssertNil(TimelineFileViewerAction.resolve(data: row))
    }

    /// Appending to a file that didn't exist: snapshot is "" and the reconstruction is
    /// just the fragment (an all-added diff — correct for a created file).
    func testAppendToNewFileUsesEmptyBaseline() {
        let row = writeRow(
            params: #"{"append":true,"content":"first line","path":"\#(file)"}"#,
            preWrite: ""
        )
        let action = TimelineFileViewerAction.resolve(data: row)
        XCTAssertEqual(action?.inlineContent, "first line")
        XCTAssertEqual(action?.preWriteContent, "")
    }

    // MARK: - Timeline resolver: flag parsing matrix (mirrors WriteFileTool's decoder)

    func testAppendFlagAliasesAndCoercions() {
        let pre = "existing\n"
        let variants = [
            #"{"append":true,"content":"x","path":"\#(file)"}"#,
            #"{"isAppend":true,"content":"x","path":"\#(file)"}"#,
            #"{"shouldAppend":true,"content":"x","path":"\#(file)"}"#,
            #"{"appending":true,"content":"x","path":"\#(file)"}"#,
            #"{"append":"true","content":"x","path":"\#(file)"}"#,
        ]
        for params in variants {
            let action = TimelineFileViewerAction.resolve(data: writeRow(params: params, preWrite: pre))
            XCTAssertEqual(action?.inlineContent, pre + "x", "Variant must be treated as append: \(params)")
        }
    }

    func testExplicitFalseAndAbsentAppendStayFullContent() {
        let pre = "old file\n"
        for params in [
            #"{"append":false,"content":"whole new file","path":"\#(file)"}"#,
            #"{"content":"whole new file","path":"\#(file)"}"#,
        ] {
            let action = TimelineFileViewerAction.resolve(data: writeRow(params: params, preWrite: pre))
            XCTAssertEqual(action?.inlineContent, "whole new file",
                           "Non-append writes open the content as the full file: \(params)")
            XCTAssertEqual(action?.preWriteContent, pre)
        }
    }

    /// `overwrite_file` has no append semantics — an append-looking key must not trigger
    /// reconstruction.
    func testOverwriteIgnoresAppendKey() {
        let action = TimelineFileViewerAction.resolve(data: writeRow(
            params: #"{"append":true,"content":"full","file_path":"\#(file)"}"#,
            preWrite: "old",
            name: "overwrite_file"
        ))
        XCTAssertEqual(action?.inlineContent, "full")
    }

    // MARK: - HITL FileChange.parse: the approval banner gets the flag too

    func testFileChangeParsesAppendFlag() {
        let change = FileChange.parse(toolName: "write_file", arguments: .object([
            "path": .string("/tmp/a.txt"),
            "content": .string("frag"),
            "append": .bool(true)
        ]))
        XCTAssertEqual(change, .write(path: "/tmp/a.txt", content: "frag", append: true))
    }

    func testFileChangeParsesAppendCoercions() {
        for value in [JSONValue.string("true"), .number(1)] {
            let change = FileChange.parse(toolName: "write_file", arguments: .object([
                "path": .string("/tmp/a.txt"),
                "content": .string("frag"),
                "isAppend": value
            ]))
            XCTAssertEqual(change, .write(path: "/tmp/a.txt", content: "frag", append: true),
                           "Coercion failed for \(value)")
        }
    }

    func testFileChangeDefaultsToNonAppend() {
        let change = FileChange.parse(toolName: "write_file", arguments: .object([
            "path": .string("/tmp/a.txt"),
            "content": .string("whole file")
        ]))
        XCTAssertEqual(change, .write(path: "/tmp/a.txt", content: "whole file", append: false))
    }
}
