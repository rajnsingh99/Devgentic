// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeEditPreviewTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class CodeEditPreviewTests: XCTestCase {

    private let path = "/Users/someone/Projects/app/src/App.java"

    private func args(_ pairs: [String: JSONValue]) -> JSONValue { .object(pairs) }

    // MARK: - Coverage: no mutating preset tool may be unpreviewable

    /// Preset tools that CHANGE the project, derived rather than hand-listed.
    ///
    /// ⚠️ Derived from `WorkspaceBoundary.readOnlyToolNames` on purpose: adding a new writing
    /// tool to `CodeToolPreset` then makes this test fail until it has a preview, instead of
    /// silently shipping another tool that approves through a JSON blob.
    private var mutatingPresetTools: [String] {
        CodeToolPreset.defaultTools
            .map(\.name)
            .filter { !WorkspaceBoundary.readOnlyToolNames.contains($0) }
            .filter { !Self.changesSomethingOtherThanAFile.contains($0) }
            .sorted()
    }

    /// Tools that change something real but not a FILE, so there is no before/after to diff.
    ///
    /// Named with a reason each, rather than a growing chain of `.filter { $0 != … }`. The
    /// distinction this set draws is narrow on purpose: NOT "harmless", but "nothing to show in a
    /// diff". Anything that writes a path belongs in the preview, and the default for a name
    /// neither list has been taught is still to demand one.
    private static let changesSomethingOtherThanAFile: Set<String> = [
        // Run a shell command. What they write is not knowable from their arguments, which is
        // exactly why they confirm on their raw command text. `batch_command`'s intent split.
        "run_command",
        "start_background_task",
        // Ends a background process this agent started. Changes machine state, touches no file.
        "stop_background_task",
    ]

    func testEveryMutatingPresetToolProducesAPreview() {
        // Minimal plausible arguments per tool — enough for `parse` to succeed.
        let sample: [String: JSONValue] = [
            "edit_code_single": .object([
                "file_path": .string(path),
                "old_string": .string("a"), "new_string": .string("b"),
            ]),
            "edit_code_batch": .object([
                "file_path": .string(path),
                "edits": .array([.object(["old_string": .string("a"), "new_string": .string("b")])]),
            ]),
            "create_new_file": .object(["file_path": .string(path), "content": .string("x")]),
            "overwrite_file": .object(["file_path": .string(path), "content": .string("x")]),
        ]

        for tool in mutatingPresetTools {
            guard let arguments = sample[tool] else {
                return XCTFail(
                    "'\(tool)' mutates the project but this test has no sample arguments for it — "
                    + "it was added to CodeToolPreset without a banner preview. Approving it would "
                    + "show raw JSON, which is how a method deletion got approved once already."
                )
            }
            XCTAssertNotNil(
                FileChange.parse(toolName: tool, arguments: arguments),
                "'\(tool)' produced no FileChange, so its approval banner falls back to raw JSON."
            )
        }
    }

    // MARK: - Search-and-replace

    func testEditCodeSingleCarriesItsHunk() {
        let change = FileChange.parse(toolName: "edit_code_single", arguments: args([
            "file_path": .string(path),
            "old_string": .string("public static void greetRaj() {"),
            "new_string": .string("public static void farewell() {"),
        ]))

        guard case .replace(let p, let hunks)? = change else {
            return XCTFail("edit_code_single must parse as .replace, got \(String(describing: change))")
        }
        XCTAssertEqual(p, path)
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks.first?.oldString, "public static void greetRaj() {")
        XCTAssertEqual(hunks.first?.newString, "public static void farewell() {")
    }

    func testEditCodeBatchKeepsEveryHunkInOrder() {
        // Order matters: the preview applies hunks sequentially, so a reordered list would
        // preview a post-state the tool never produces.
        let change = FileChange.parse(toolName: "edit_code_batch", arguments: args([
            "file_path": .string(path),
            "edits": .array([
                .object(["old_string": .string("one"), "new_string": .string("1")]),
                .object(["old_string": .string("two"), "new_string": .string("2")]),
                .object(["old_string": .string("three"), "new_string": .string("3")]),
            ]),
        ]))

        guard case .replace(_, let hunks)? = change else {
            return XCTFail("edit_code_batch must parse as .replace")
        }
        XCTAssertEqual(hunks.map(\.oldString), ["one", "two", "three"])
        XCTAssertEqual(hunks.map(\.newString), ["1", "2", "3"])
    }

    func testTheEditThatBrokeTheFileIsPreviewable() {
        // The exact call from the incident: `old_string` is a whole method body. The point is
        // not that parse succeeds, but that a preview EXISTS — rendered against the file, this
        // is visibly "greetRaj disappears", which is refusable at a glance.
        let change = FileChange.parse(toolName: "edit_code_batch", arguments: args([
            "file_path": .string(path),
            "edits": .array([.object([
                "old_string": .string("    public static void greetRaj() {\n        System.out.println(\"Hello Raj!!\");\n    }"),
                "new_string": .string("\n    public static void farewell() {\n        System.out.println(\"Goodbye Raj!!\");\n    }"),
            ])]),
        ]))

        guard case .replace(_, let hunks)? = change else {
            return XCTFail("The edit that deleted greetRaj() must render a preview, not raw JSON.")
        }
        XCTAssertTrue(hunks[0].oldString.contains("greetRaj"),
                      "The removed method must be visible in the preview's search text.")
    }

    // MARK: - Full-content writes reuse the existing case

    func testCreateAndOverwriteMapToWrite() {
        for tool in ["create_new_file", "overwrite_file"] {
            let change = FileChange.parse(toolName: tool, arguments: args([
                "file_path": .string(path),
                "content": .string("hello"),
            ]))
            guard case .write(let p, let content, let append)? = change else {
                return XCTFail("\(tool) must parse as .write, got \(String(describing: change))")
            }
            XCTAssertEqual(p, path)
            XCTAssertEqual(content, "hello")
            XCTAssertFalse(append, "Neither tool appends — previewing one as an append would "
                           + "show the existing content as retained when it is being replaced.")
        }
    }

    // MARK: - Failing safe

    func testUndecodableBatchFallsBackToJSONRatherThanAFalsePreview() {
        // ⚠️ A batch whose edits can't be read must return nil so the banner shows raw JSON.
        // Returning a partial `.replace` would render a confident diff that omits real changes —
        // strictly worse than the JSON it replaced, because it looks authoritative.
        let change = FileChange.parse(toolName: "edit_code_batch", arguments: args([
            "file_path": .string(path),
            "edits": .array([
                .object(["old_string": .string("ok"), "new_string": .string("fine")]),
                .object(["oldString": .string("wrong key"), "new_string": .string("x")]),
            ]),
        ]))

        XCTAssertNil(change, "A batch with an undecodable edit must not preview a partial change set.")
    }

    func testEmptyBatchIsNotPreviewed() {
        let change = FileChange.parse(toolName: "edit_code_batch", arguments: args([
            "file_path": .string(path),
            "edits": .array([]),
        ]))
        XCTAssertNil(change, "An empty edit list has nothing to show; a '0 changes' diff would mislead.")
    }

    func testMissingPathIsNotPreviewed() {
        for tool in ["edit_code_single", "create_new_file", "overwrite_file"] {
            XCTAssertNil(
                FileChange.parse(toolName: tool, arguments: args(["content": .string("x")])),
                "\(tool) with no file path must not produce a preview naming the wrong file."
            )
        }
    }

    func testReadOnlyToolsAreNotPreviewedAsChanges() {
        // A read must never render as a file mutation in an approval banner.
        for tool in ["read_file", "list_directory", "project_tree", "git", "diff_files"] {
            XCTAssertNil(
                FileChange.parse(toolName: tool, arguments: args(["path": .string(path)])),
                "'\(tool)' only reads; previewing it as a change would misrepresent what Allow does."
            )
        }
    }
}
