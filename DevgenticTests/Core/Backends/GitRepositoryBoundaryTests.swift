// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GitRepositoryBoundaryTests.swift
//  devgenticTests
//
//  The workspace boundary must confine what `git_tool` ACTS ON, not merely what it was HANDED.
//
//  ⚠️⚠️ WHY THIS FILE EXISTS. Every other preset tool acts on its path argument: `read_file(p)`
//  reads exactly `p`, so validating `p` is the whole job. `git -C <dir>` does not operate on
//  `<dir>` — it walks UP from `<dir>` to the nearest `.git` and operates on whatever it finds.
//
//  Field-observed 2026-09-20: a Code session rooted at `…/cp-dsa/java` ran `git_tool(status)`
//  with a path that was absolute, canonical and provably inside the project. The repository lives
//  at `…/cp-dsa`, one level ABOVE the project, so the output covered sibling folders the user had
//  never pointed the agent at — and the boundary had nothing to object to, because the ARGUMENT
//  was perfectly compliant. Argument validation structurally cannot catch this.
//
//  These tests use an injected locator rather than a real repository on disk. A test that had to
//  `git init` a fixture would be asserting git's discovery behaviour; what needs asserting is
//  OURS — that the discovered root is run through the same policy as any other path.
//

import XCTest
@testable import devgentic

final class GitRepositoryBoundaryTests: XCTestCase {

    private let project = "/Users/someone/Projects/monorepo/module"
    private let parentRepo = "/Users/someone/Projects/monorepo"

    private func decide(
        _ tool: String,
        path: String,
        repository: String?
    ) -> WorkspaceBoundaryDecision {
        WorkspaceBoundaryDecision.evaluate(
            toolName: tool,
            arguments: ["path": .string(path)],
            workspaceRoot: project,
            repositoryLocator: .fixed(repository)
        )
    }

    // MARK: - The escape

    func testCompliantPathIntoAParentRepositoryAsksTheUser() {
        // ⚠️ THE REGRESSION GUARD. Path inside the project, repository outside it. Before the
        // discovery check this returned `.proceed` and git reported on the whole parent checkout.
        let decision = decide("git_tool", path: project, repository: parentRepo)

        guard case .askUser(let reason) = decision.outcome else {
            return XCTFail(
                "git_tool resolved to the repository at \(parentRepo), which is outside the "
                + "project, and the boundary allowed it. The path argument was compliant — this is "
                + "exactly the case argument validation cannot see."
            )
        }
        XCTAssertTrue(reason.contains(parentRepo),
                      "The prompt must name the repository the user is being asked to approve, "
                      + "not just the path that was passed. Got: \(reason)")
    }

    func testTheReasonNamesBothPathAndRepository() {
        // The user is approving something the arguments do not show. If the banner repeated only
        // the in-project path, "Allow" would look like approving a read inside their own project.
        guard case .askUser(let reason) = decide("git_tool", path: project, repository: parentRepo).outcome else {
            return XCTFail("Expected an approval prompt.")
        }
        XCTAssertTrue(reason.contains(project),
                      "The prompt must say which path git walked up FROM. Got: \(reason)")
    }

    // MARK: - Not an escape

    func testRepositoryInsideTheProjectProceedsSilently() {
        // The ordinary case: the project IS the repository. No prompt, or every git call in a
        // normal single-repo project would park the run on a banner.
        XCTAssertEqual(decide("git_tool", path: project, repository: project).outcome, .proceed)
    }

    func testRepositoryInASubfolderProceeds() {
        // A nested repo below the root is still inside the boundary.
        XCTAssertEqual(
            decide("git_tool", path: project + "/vendor/lib", repository: project + "/vendor/lib").outcome,
            .proceed
        )
    }

    func testNotARepositoryProceeds() {
        // Nil locator result means "no repository here" or "git unavailable". Nothing to confine —
        // git_tool reports "not a git repository" itself, which is the honest message. Prompting
        // here would ask the user to approve access to a repository that does not exist.
        XCTAssertEqual(decide("git_tool", path: project, repository: nil).outcome, .proceed)
    }

    func testSiblingDirectoryIsNotTreatedAsInside() {
        // ⚠️ A prefix check says `/…/monorepo/module-secrets` is inside `/…/monorepo/module`.
        // The discovered root goes through `isWithin`, which compares path COMPONENTS — this
        // asserts the discovery path inherited that, rather than doing its own string compare.
        guard case .askUser = decide("git_tool", path: project, repository: project + "-secrets").outcome else {
            return XCTFail("A sibling directory sharing a name prefix must not count as inside the project.")
        }
    }

    // MARK: - Interaction with the argument check

    func testAnOutsidePathDoesNotProduceTwoPrompts() {
        // The path itself is outside → the argument check already asked. Running discovery as well
        // would park the run on a second banner for one tool call.
        let decision = decide("git_tool", path: "/Users/someone/Projects/other", repository: "/Users/someone/Projects/other")

        guard case .askUser(let reason) = decision.outcome else {
            return XCTFail("git_tool is read-only; outside the project it must ASK.")
        }
        XCTAssertFalse(reason.contains("walking up from"),
                       "The argument check already produced a verdict; the discovery check must "
                       + "not overwrite it with a second, differently-worded prompt.")
    }

    func testDiscoveryNeverEscalatesToRefusal() {
        // git_tool is read-only, and the boundary's policy is that reads outside the project ASK
        // while writes are REFUSED. A parent-repo layout is legitimate and common — the user can
        // say yes. Refusing would contradict the policy and break every monorepo module.
        if case .refuse = decide("git_tool", path: project, repository: parentRepo).outcome {
            XCTFail("A read-only tool reaching a parent repository must ask, never refuse.")
        }
    }

    // MARK: - Scope

    func testOnlyGitToolGetsTheDiscoveryCheck() {
        // ⚠️ The locator returns a path for ANY tool here. Nothing but git_tool may consult it —
        // `read_file` acts on its argument, and asking about a repository it never touches would
        // be a prompt the user cannot make sense of.
        for tool in ["read_file", "list_directory", "codebase_map", "diff_files", "edit_code_single"] {
            XCTAssertEqual(
                WorkspaceBoundaryDecision.evaluate(
                    toolName: tool,
                    arguments: ["path": .string(project)],
                    workspaceRoot: project,
                    repositoryLocator: .fixed(parentRepo)
                ).outcome,
                .proceed,
                "'\(tool)' acts on the path it was given; it must not be judged by which "
                + "repository that path happens to live in."
            )
        }
    }

    func testNoWorkspaceRootSkipsDiscoveryEntirely() {
        // Every chat, agent and workflow run takes this path. It must behave exactly as it did
        // before the boundary existed — and must not spawn git.
        let decision = WorkspaceBoundaryDecision.evaluate(
            toolName: "git_tool",
            arguments: ["path": .string("/anywhere")],
            workspaceRoot: nil,
            repositoryLocator: .fixed(parentRepo)
        )
        XCTAssertEqual(decision.outcome, .proceed)
        XCTAssertEqual(decision.arguments["path"], .string("/anywhere"),
                       "With no project root the arguments must pass through unmodified.")
    }

    func testMissingPathArgumentIsNotADiscoveryFailure() {
        // `path` is required by the schema, but a model can omit it. The tool returns its own
        // error; the boundary must not invent a prompt about a repository it never located.
        let decision = WorkspaceBoundaryDecision.evaluate(
            toolName: "git_tool",
            arguments: ["action": .string("status")],
            workspaceRoot: project,
            repositoryLocator: .fixed(parentRepo)
        )
        XCTAssertEqual(decision.outcome, .proceed)
    }
}
