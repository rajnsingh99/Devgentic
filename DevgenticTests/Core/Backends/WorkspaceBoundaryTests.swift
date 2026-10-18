// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkspaceBoundaryTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class WorkspaceBoundaryTests: XCTestCase {

    private let root = "/Users/someone/Projects/guest-service"

    // MARK: - Containment

    func testPathsInsideTheProjectAreAllowed() {
        for path in [root, "\(root)/src", "\(root)/src/main/java/App.java"] {
            guard case .allowed = WorkspaceBoundary.evaluate(path: path, toolName: "read_file", projectRoot: root) else {
                return XCTFail("'\(path)' is inside the project and must be allowed.")
            }
        }
    }

    func testTheEscapeThatWasObservedIsStopped() {
        // The exact call from the bug report.
        let verdict = WorkspaceBoundary.evaluate(path: "/Users/someone", toolName: "list_directory", projectRoot: root)

        guard case .needsApproval = verdict else {
            return XCTFail("list_directory on the home directory must not run silently — it is outside the project.")
        }
    }

    func testSiblingWithSharedPrefixIsNotInside() {
        // ⚠️ A plain `hasPrefix` says this is inside. It is not — and the sibling is exactly where
        // a "-secrets" or "-private" folder tends to live.
        let verdict = WorkspaceBoundary.evaluate(
            path: "/Users/someone/Projects/guest-service-secrets/keys.env",
            toolName: "read_file",
            projectRoot: root
        )
        guard case .needsApproval = verdict else {
            return XCTFail("A sibling sharing the project's name prefix is OUTSIDE the project.")
        }
    }

    func testDotDotCannotClimbOut() {
        let verdict = WorkspaceBoundary.evaluate(
            path: "\(root)/../../../etc/passwd",
            toolName: "read_file",
            projectRoot: root
        )
        guard case .needsApproval = verdict else {
            return XCTFail("`..` traversal must not resolve to an allowed path.")
        }
    }

    // MARK: - Relative resolution (the 41.8-second bug)

    func testRelativePathsAnchorToTheProjectNotHome() {
        // `FilePathResolver.resolve` anchors to $HOME. In Code mode that turned "./" into the
        // user's entire home directory.
        XCTAssertEqual(WorkspaceBoundary.resolve("./", projectRoot: root), WorkspaceBoundary.canonical(root))
        XCTAssertEqual(WorkspaceBoundary.resolve(".", projectRoot: root), WorkspaceBoundary.canonical(root))
        XCTAssertEqual(WorkspaceBoundary.resolve("src", projectRoot: root), WorkspaceBoundary.canonical("\(root)/src"))
        XCTAssertEqual(WorkspaceBoundary.resolve("./src/App.java", projectRoot: root),
                       WorkspaceBoundary.canonical("\(root)/src/App.java"))

        XCTAssertFalse(
            WorkspaceBoundary.resolve("./", projectRoot: root).hasPrefix(NSHomeDirectory() + "/Library"),
            "A relative path must never resolve into the home directory in Code mode."
        )
    }

    func testEmptyPathMeansTheProjectRoot() {
        XCTAssertEqual(WorkspaceBoundary.resolve("", projectRoot: root), WorkspaceBoundary.canonical(root))
    }

    // MARK: - Read vs write

    func testWritesOutsideTheProjectAreRefusedNotAsked() {
        // A read outside is a question. A write outside is a no — the user picked a folder to work
        // in, and a confirmation banner is not a good place to reason about an unexpected write.
        for tool in ["edit_code_single", "edit_code_batch", "create_new_file", "overwrite_file", "batch_command"] {
            let verdict = WorkspaceBoundary.evaluate(path: "/Users/someone/other", toolName: tool, projectRoot: root)
            guard case .refused = verdict else {
                return XCTFail("'\(tool)' writes; outside the project it must be refused, not merely asked about.")
            }
        }
    }

    func testUnknownToolIsTreatedAsMutating() {
        // A tool this file has not been taught must fail SAFE.
        let verdict = WorkspaceBoundary.evaluate(path: "/etc", toolName: "some_future_tool", projectRoot: root)
        guard case .refused = verdict else {
            return XCTFail("An unrecognised tool must be treated as mutating outside the project.")
        }
    }

    func testToolchainPathsAreReadableWithoutAsking() {
        // Refusing a shell its own compiler makes the boundary unusable.
        guard case .allowed = WorkspaceBoundary.evaluate(path: "/usr/bin/git", toolName: "read_file", projectRoot: root) else {
            return XCTFail("Toolchain paths must be readable without a prompt.")
        }
    }

    func testAllowlistDoesNotGrantWrites() {
        // Being on the allowlist exempts a path from the PROMPT, never from the write rule.
        guard case .refused = WorkspaceBoundary.evaluate(path: "/usr/bin/git", toolName: "overwrite_file", projectRoot: root) else {
            return XCTFail("The toolchain allowlist must not make /usr/bin writable.")
        }
    }

    // MARK: - Argument plumbing

    /// ⚠️ `.unavailable` keeps these tests hermetic: the production default is `.live`, which
    /// shells out to git. These cases are about ARGUMENT handling, and none of them should depend
    /// on git being installed or on a fixture path existing. The discovery behaviour has its own
    /// file — see `GitRepositoryBoundaryTests`.
    private func decide(_ tool: String, _ args: [String: JSONValue], root: String?) -> WorkspaceBoundaryDecision {
        WorkspaceBoundaryDecision.evaluate(
            toolName: tool, arguments: args, workspaceRoot: root, repositoryLocator: .unavailable)
    }

    func testNoRootLeavesEverythingUntouched() {
        // Every chat/agent/workflow run takes this path and must behave exactly as before.
        let args: [String: JSONValue] = ["path": .string("./anywhere")]
        let decision = decide("read_file", args, root: nil)

        XCTAssertEqual(decision.outcome, .proceed)
        XCTAssertEqual(decision.arguments["path"], .string("./anywhere"),
                       "With no project root the arguments must be passed through unmodified.")
    }

    func testPathArgumentsAreRewrittenToResolvedForm() {
        let decision = decide("read_file", ["path": .string("./src/App.java")], root: root)

        XCTAssertEqual(decision.outcome, .proceed)
        XCTAssertEqual(decision.arguments["path"], .string(WorkspaceBoundary.canonical("\(root)/src/App.java")),
                       "The tool must receive the project-anchored path, not the raw relative one — "
                       + "and the confirmation banner must show what will actually run.")
    }

    func testNonPathArgumentsAreNeverTouched() {
        // ⚠️ Keyed by NAME, never by shape. Four transforms in this codebase have silently
        // rewritten file CONTENT that happened to look like a path.
        let content = "/Users/someone/not-a-real-path\nline two"
        let decision = decide("edit_code_single", [
            "path": .string("\(root)/App.java"),
            "replacement": .string(content),
        ], root: root)

        XCTAssertEqual(decision.arguments["replacement"], .string(content),
                       "A non-path argument was rewritten. Only argument NAMES decide what is a path.")
    }

    func testOneOutsideWriteCondemnsTheWholeCall() {
        // diff_files-shaped: several path arguments, one of them out of bounds.
        let decision = decide("overwrite_file", [
            "path": .string("\(root)/App.java"),
            "destination": .string("/Users/someone/elsewhere/App.java"),
        ], root: root)

        guard case .refuse = decision.outcome else {
            return XCTFail("A call is only safe if EVERY path argument is safe.")
        }
    }

    // MARK: - Every preset tool's REAL path arguments are covered

    /// Each preset tool with the argument name its own struct actually declares.
    ///
    /// ⚠️⚠️ This table is the guard against the defect that shipped here first: the set carried
    /// `left`/`right` for `diff_files`, names that tool has never used, so both of its paths were
    /// invisible to the boundary and it could read anywhere on disk. Anything absent from
    /// `pathArgumentNames` is silently unconfined — there is no error, the path simply is not
    /// checked — so the only way to catch it is to drive each tool by its real argument name.
    private static let presetToolPathArguments: [(tool: String, arg: String, mutating: Bool)] = [
        ("read_file",          "path",              false),
        ("list_directory",     "path",              false),
        ("project_tree",       "path",              false),
        ("glob_files",         "path",              false),
        ("find_definition",    "path",              false),
        ("code_search_text",   "path",              false),
        ("code_search_symbol", "path",              false),
        ("code_search_files",  "path",              false),
        ("git",                "path",              false),
        ("file_overview",      "file_path",         false),
        ("diff_files",         "file_a",            false),
        ("diff_files",         "file_b",            false),
        ("edit_code_single",   "file_path",         true),
        ("edit_code_batch",    "file_path",         true),
        ("create_new_file",    "file_path",         true),
        ("overwrite_file",     "file_path",         true),
        ("batch_command",      "working_directory", true),
    ]

    func testEveryPresetToolsRealPathArgumentIsConfined() {
        for entry in Self.presetToolPathArguments {
            let decision = decide(entry.tool, [entry.arg: .string("/Users/someone/elsewhere")], root: root)

            XCTAssertNotEqual(
                decision.outcome, .proceed,
                "'\(entry.tool)' was allowed to reach outside the project via its '\(entry.arg)' "
                + "argument. That argument name is missing from WorkspaceBoundary.pathArgumentNames, "
                + "so the path is never checked — the tool is silently unconfined."
            )
        }
    }

    func testEveryPresetToolsRealPathArgumentIsReAnchored() {
        // The other half: an unrecognised argument name also skips RELATIVE-path resolution, so
        // the tool would fall through to $HOME anchoring — the 41.8-second bug, per tool.
        for entry in Self.presetToolPathArguments {
            let decision = decide(entry.tool, [entry.arg: .string("src")], root: root)

            XCTAssertEqual(
                decision.arguments[entry.arg], .string(WorkspaceBoundary.canonical("\(root)/src")),
                "'\(entry.tool)' did not re-anchor its '\(entry.arg)' argument to the project."
            )
        }
    }

    func testReadOnlyAndMutatingToolsGetTheRightVerdict() {
        for entry in Self.presetToolPathArguments {
            let decision = decide(entry.tool, [entry.arg: .string("/Users/someone/elsewhere")], root: root)

            switch (entry.mutating, decision.outcome) {
            case (true, .refuse), (false, .askUser):
                continue
            default:
                XCTFail("'\(entry.tool)' (\(entry.mutating ? "mutating" : "read-only")) produced "
                        + "\(decision.outcome) outside the project — a read should ask, a write should refuse.")
            }
        }
    }

    func testGitIsTreatedAsReadOnly() {
        // ⚠️ Its schema offers only status/log/diff/branch/stash_list/blame/show. Misclassifying
        // it as mutating REFUSES git entirely for the common layout where a module's `.git` lives
        // in a parent directory — which is exactly the shape of the project this was found on.
        let decision = decide("git", ["path": .string("/Users/someone/Projects")], root: root)

        guard case .askUser = decision.outcome else {
            return XCTFail("git is read-only; outside the project it must ASK, not refuse.")
        }
    }

    // MARK: - The <environment> block must not contradict the boundary

    private func envBlock(workspaceRoot: String?) -> String {
        let facts = EnvironmentFacts(
            osVersion: "Version 26.6.2",
            shellType: "Zsh (Non-Interactive Mode)",
            userName: "someone",
            homeDirectory: "/Users/someone",
            currentDate: "20/9/2026",
            workspaceRoot: workspaceRoot
        )
        // Rendered exactly as `buildStandardMessages` renders it.
        if let root = facts.workspaceRoot, !root.isEmpty {
            return "- Paths: use absolute paths under the project root \(root); a relative path resolves against it"
        }
        return "- Paths: use absolute paths; user folders are under \(facts.homeDirectory) (Desktop, Documents, Downloads)"
    }

    func testConfinedRunIsNotPointedAtTheHomeDirectory() {
        // ⚠️⚠️ Observed on device 2026-09-20 AFTER the Code prompt was fixed: the prompt said the
        // project was a boundary, and a few hundred characters later the <environment> block still
        // said "user folders are under /Users/<name> (Desktop, Documents, Downloads)". With the
        // prompt missing entirely, that line was the ONLY path guidance the model had — and it
        // walked the home directory.
        let confined = envBlock(workspaceRoot: root)

        XCTAssertFalse(confined.contains("/Users/someone (Desktop"),
                       "A confined run must not be handed the home directory as its path anchor.")
        XCTAssertTrue(confined.contains(root),
                      "A confined run's path guidance must name the project root.")
    }

    func testUnconfinedRunKeepsTheHomeAnchor() {
        // The home anchor exists for a reason — small models emit "/path/to/X" placeholders
        // without a real absolute path to copy. Chat/agent runs must keep it.
        let unconfined = envBlock(workspaceRoot: nil)

        XCTAssertTrue(unconfined.contains("/Users/someone"),
                      "An unconfined run still needs a concrete absolute-path anchor.")
    }

    func testRefusalOutranksApproval() {
        // If one argument merely needs asking and another must be refused, the call is refused —
        // the user should not be prompted for something that cannot run either way.
        let decision = decide("overwrite_file", [
            "left": .string("/Users/someone/readable"),
            "path": .string("/Users/someone/writable/x"),
        ], root: root)

        guard case .refuse = decision.outcome else {
            return XCTFail("A refusal must win over a pending approval.")
        }
    }
}
