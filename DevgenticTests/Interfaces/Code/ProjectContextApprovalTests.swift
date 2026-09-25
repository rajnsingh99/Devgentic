// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProjectContextApprovalTests.swift
//  devgenticTests
//
//  `update_project_context` was the ONE write in Code mode that ran unreviewed — and the only
//  write in the app that outlives its conversation.
//
//  ⚠️⚠️ WHY THIS FILE EXISTS. Every other mutating tool parks on an approval banner. This one
//  dispatched silently, and it writes `.devgentic/context.md`, which is injected into the system
//  prompt of EVERY future conversation for that project. Field-observed 2026-09-20: a small model
//  wrote "These classes contain methods like `greeting()` and `farewell()`" about a file
//  containing neither, twice in one run. The false claim survived a restart, survived a new
//  conversation, and then steered a later edit onto the wrong anchor — the model went looking for
//  greeting-shaped text because its own project memory promised it.
//
//  ⚠️ The control is NOT "verify the model's claims". A small model will keep being wrong; that is
//  the premise. The control is that a human sees the sentence rendered as a diff against their own
//  file, where a false statement about their own code is obvious at a glance.
//

import XCTest
@testable import devgentic

final class ProjectContextApprovalTests: XCTestCase {

    private let project = "/Users/someone/Projects/java"
    private var contextFile: String { UpdateProjectContextTool.contextFilePath(inProject: project) }

    /// The exact paragraph from the incident.
    private let poisonedContent = """
        ## Project Context

        ### Conventions & Patterns
        - **Module Pattern:** These classes contain methods like `greeting()` and `farewell()`.
        """

    // MARK: - It must ask

    func testTheInjectedContextToolRequiresConfirmation() {
        // ⚠️ THE REGRESSION GUARD. This was `false` at the `AgentConnect` call site, as a bare
        // literal, with nothing in `CodeToolPreset` showing that Code mode had a mutating tool the
        // user never saw. Flipping it back makes project memory writable without review again.
        XCTAssertTrue(
            CodeToolPreset.injectedToolRequiresConfirmation("update_project_context"),
            "update_project_context writes the only file that persists into future conversations. "
            + "Dispatching it unreviewed is how a false claim about the user's code became "
            + "permanent project memory."
        )
    }

    func testOtherToolsAreNotSweptIntoConfirmation() {
        // The policy answers for injected tools only, and must not start demanding approval for
        // reads — a banner on `read_file` would train the user to click Allow without looking,
        // which costs exactly the protection this change buys.
        for tool in ["read_file", "final_answer", "ask_user", "project_tree"] {
            XCTAssertFalse(CodeToolPreset.injectedToolRequiresConfirmation(tool),
                           "'\(tool)' does not mutate anything; asking about it devalues the banner.")
        }
    }

    // MARK: - It must be previewable, against the right file

    func testItPreviewsAsAWriteToTheProjectContextFile() {
        let change = FileChange.parse(
            toolName: "update_project_context",
            arguments: .object(["content": .string(poisonedContent)]),
            previewPath: contextFile
        )

        guard case .write(let path, let content, let append)? = change else {
            return XCTFail("update_project_context must render a real diff, not raw JSON — "
                           + "got \(String(describing: change))")
        }
        XCTAssertEqual(path, contextFile)
        XCTAssertEqual(content, poisonedContent)
        XCTAssertFalse(append, "The tool overwrites wholesale. Previewing an append would show the "
                       + "existing context as retained when it is being replaced entirely.")
    }

    func testThePreviewedPathIsThePathTheToolWrites() {
        // ⚠️⚠️ The one failure worse than no preview: a confident diff of file A while file B is
        // overwritten. Both sides derive from `UpdateProjectContextTool.contextFilePath`, and this
        // asserts the preview did not acquire its own copy of the path-building logic.
        guard case .write(let previewed, _, _)? = FileChange.parse(
            toolName: "update_project_context",
            arguments: .object(["content": .string("x")]),
            previewPath: contextFile
        ) else { return XCTFail("Expected a write preview.") }

        XCTAssertEqual(previewed, UpdateProjectContextTool.contextFilePath(inProject: project))
        XCTAssertTrue(previewed.hasSuffix("/.devgentic/context.md"),
                      "Project memory must live at .devgentic/context.md; got \(previewed)")
    }

    func testTheIncidentSentenceIsVisibleInWhatWouldBeDiffed() {
        // Not asserting rendering — asserting that the text a human needs to catch actually
        // reaches the preview. `WriteFilePreview` diffs this against the file on disk.
        guard case .write(_, let content, _)? = FileChange.parse(
            toolName: "update_project_context",
            arguments: .object(["content": .string(poisonedContent)]),
            previewPath: contextFile
        ) else { return XCTFail("Expected a write preview.") }

        XCTAssertTrue(content.contains("greeting()"),
                      "The false claim must be present in the previewed content, or approving it "
                      + "is no better informed than approving the JSON was.")
    }

    // MARK: - Failing safe

    func testNoPreviewPathMeansNoPreview() {
        // A non-Code profile, or a Code profile with no folder chosen. Inventing a path would draw
        // a diff against a file this run is not going to write.
        XCTAssertNil(
            FileChange.parse(
                toolName: "update_project_context",
                arguments: .object(["content": .string(poisonedContent)]),
                previewPath: nil),
            "With no resolved project there is no file to diff against; fall back to the JSON view."
        )
    }

    func testPreviewPathIsIgnoredForToolsThatNameTheirOwnTarget() {
        // ⚠️ `previewPath` must never override an argument-supplied path. If it did, an edit to
        // one file would be previewed against another whenever both were present.
        guard case .write(let path, _, _)? = FileChange.parse(
            toolName: "create_new_file",
            arguments: .object(["file_path": .string("/Users/someone/Projects/java/New.java"),
                                "content": .string("x")]),
            previewPath: contextFile
        ) else { return XCTFail("create_new_file must still preview from its own argument.") }

        XCTAssertEqual(path, "/Users/someone/Projects/java/New.java")
    }

    // MARK: - The preview reads content the way the tool does

    func testEveryContentAliasThePreviewAcceptsIsOneTheToolDecodes() {
        // ⚠️⚠️ The `file_path` lesson, applied to `content`. The preview first reused the library
        // tools' `contentKeys`, which carries `string` (this decoder REJECTS it) and omits
        // `markdown`/`context` (it accepts both). Previewing a key the tool cannot decode draws a
        // diff for a call that is about to fail; missing one shows raw JSON for a call that works.
        //
        // Drives the REAL decoder rather than restating the list, so a divergence cannot hide.
        for alias in UpdateProjectContextTool.contentArgumentAliases {
            let json = Data(#"{"\#(alias)":"payload-\#(alias)"}"#.utf8)
            let decoded = try? JSONDecoder().decode(UpdateProjectContextTool.Arguments.self, from: json)
            XCTAssertEqual(decoded?.content, "payload-\(alias)",
                           "The tool does not decode '\(alias)', but the preview offers it.")

            guard case .write(_, let previewed, _)? = FileChange.parse(
                toolName: "update_project_context",
                arguments: .object([alias: .string("payload-\(alias)")]),
                previewPath: contextFile
            ) else {
                return XCTFail("'\(alias)' decodes for the tool but produced no preview, so this "
                               + "call would be approved as raw JSON.")
            }
            XCTAssertEqual(previewed, decoded?.content,
                           "For '\(alias)' the preview shows different text than the tool will write.")
        }
    }

    func testAliasPriorityMatchesTheDecoder() {
        // Several aliases at once: first match in the shared list wins, on BOTH sides. If they
        // disagreed the banner would diff one string while the tool wrote another.
        let arguments: [String: JSONValue] = [
            "content": .string("winner"),
            "markdown": .string("loser"),
            "body": .string("loser"),
        ]
        let json = Data(#"{"content":"winner","markdown":"loser","body":"loser"}"#.utf8)
        let decoded = try? JSONDecoder().decode(UpdateProjectContextTool.Arguments.self, from: json)

        guard case .write(_, let previewed, _)? = FileChange.parse(
            toolName: "update_project_context",
            arguments: .object(arguments),
            previewPath: contextFile
        ) else { return XCTFail("Expected a write preview.") }

        XCTAssertEqual(previewed, decoded?.content)
        XCTAssertEqual(previewed, "winner")
    }

    // MARK: - The hint must not become an editable argument

    func testPreviewPathIsNotCarriedInTheArguments() {
        // ⚠️⚠️ The banner makes every top-level STRING argument editable, and this tool derives its
        // own destination from the run's project — it never reads a path argument. So a path
        // placed in `arguments` would be edited by the user, silently ignored by the tool, and the
        // write would land somewhere other than what was approved. It is a preview hint and must
        // stay outside the argument dictionary.
        let confirmation = PendingToolConfirmation(
            toolName: "update_project_context",
            params: #"{"content":"x"}"#,
            arguments: .object(["content": .string("x")]),
            previewPath: contextFile
        )

        guard case .object(let dict)? = confirmation.arguments else {
            return XCTFail("Expected structured arguments.")
        }
        for (key, value) in dict {
            if case .string(let s) = value {
                XCTAssertNotEqual(s, self.contextFile,
                                  "'\(key)' carries the resolved context path into the editable "
                                  + "argument list, where an edit would be silently discarded.")
            }
        }
        XCTAssertEqual(confirmation.previewPath, contextFile)
    }

    func testAPersistedConfirmationWithoutTheFieldStillDecodes() {
        // G1 park/resume persists confirmations. A run parked before this field existed must still
        // come back — losing it would strand the user's approval banner on restart.
        let legacy = Data(#"{"id":"\#(UUID().uuidString)","toolName":"update_project_context","params":"{}","risk":"moderate"}"#.utf8)
        let decoded = try? JSONDecoder().decode(PendingToolConfirmation.self, from: legacy)

        XCTAssertNotNil(decoded, "A confirmation persisted before `previewPath` existed must decode.")
        XCTAssertNil(decoded?.previewPath)
    }
}
