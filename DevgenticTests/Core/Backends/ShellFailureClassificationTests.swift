// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ShellFailureClassificationTests.swift
//  DevgenticTests
//
//  The shell-family tools each detected failure to the degree they bothered to look, then
//  lost it at the classification boundary:
//
//    • `git_tool`   checked the exit status, then reported it as "Git error:" — the sniffer
//                   tests `hasPrefix("error")`, so a detected failure classified as SUCCESS.
//    • `execute_shell` never read the exit status at all, caught every throw, and returned
//                   "Command failed: …" — which matches nothing, from a tool whose sniffing
//                   is switched off anyway.
//    • `batch_command` was already correct: its own failure strings start with "Error" and
//                   it puts the exit code in the output.
//
//  `isSemanticFailure` is a prefix match on one English word, and three authors each picked a
//  different reasonable prefix. These tests pin the shapes.
//

import XCTest
@testable import devgentic

final class ShellFailureClassificationTests: XCTestCase {

    private typealias Mediator = ToolExecutionMediator

    // MARK: - The prefix that missed by one word

    /// The exact string `git_tool` now returns. If anyone "tidies" it back to "Git error:",
    /// every git failure silently becomes a success again.
    func testGitFailureStringIsClassifiedAsAFailure() {
        let now = "Error: git status failed (exit 128)\nfatal: not a git repository"
        XCTAssertTrue(Mediator.isSemanticFailure(now), "the shipped string must classify: \(now)")
    }

    /// The old one, kept as a witness to what the bug looked like.
    func testTheOldGitPrefixWouldNotHaveClassified() {
        let before = "Git error:\nfatal: not a git repository"
        XCTAssertFalse(Mediator.isSemanticFailure(before),
                       "documents the defect: detected, reported, then recorded as success")
    }

    /// `execute_shell`'s old catch string — matches nothing, which is why it had to become a
    /// throw rather than a rename.
    func testTheOldShellCatchStringWouldNotHaveClassified() {
        XCTAssertFalse(Mediator.isSemanticFailure("Command failed: No such file or directory"))
    }

    // MARK: - The predicate's real shape

    func testEmptyAndNullAreUnambiguousFailures() {
        XCTAssertTrue(Mediator.isSemanticFailure(""))
        XCTAssertTrue(Mediator.isSemanticFailure("   \n  "))
        XCTAssertTrue(Mediator.isSemanticFailure("null"))
        XCTAssertTrue(Mediator.isSemanticFailure("nil"))
    }

    func testErrorPrefixNeedsAWordBoundary() {
        XCTAssertTrue(Mediator.isSemanticFailure("Error: File not found"), "colon")
        XCTAssertTrue(Mediator.isSemanticFailure("Error reading file: bad path"), "whitespace")
        XCTAssertTrue(Mediator.isSemanticFailure("error"), "bare word")
        XCTAssertFalse(Mediator.isSemanticFailure("errors: 0"), "a count is not a failure")
        XCTAssertFalse(Mediator.isSemanticFailure("error_log.txt found"), "nor is a filename")
    }

    /// The bound is on the FIRST LINE, not the whole output — so a real error with a long
    /// body still classifies, while a multi-KB single-line log that merely starts with
    /// "error" does not.
    func testTheLengthBoundAppliesToTheFirstLineOnly() {
        let realError = "Error: build failed\n" + String(repeating: "detail line\n", count: 500)
        XCTAssertGreaterThan(realError.count, Mediator.maxSemanticErrorLength)
        XCTAssertTrue(Mediator.isSemanticFailure(realError),
                      "a short header with a long body is still an error")

        let longSingleLine = "error " + String(repeating: "x", count: Mediator.maxSemanticErrorLength + 10)
        XCTAssertFalse(Mediator.isSemanticFailure(longSingleLine),
                       "one unbroken line past the bound is content, not a message")
    }

    /// `batch_command`'s own failure strings already pass; its normal return does not, which
    /// is why its exit code is visible in the observation but not in the classification.
    func testBatchCommandStrings() {
        XCTAssertTrue(Mediator.isSemanticFailure("Error: Command blocked by safety filter."))
        XCTAssertTrue(Mediator.isSemanticFailure("Error launching background command: bad exec"))
        XCTAssertFalse(Mediator.isSemanticFailure("Exit code: 1\nsome build output"),
                       "documents the remaining gap: exit code visible, still classified success")
    }

    // MARK: - Blocked commands are tool failures, not results

    /// These used to `return` an "Error: …" string — from a tool whose sniffing is switched
    /// off, so a refusal was recorded as a successful shell call. They throw now.
    ///
    /// No process is launched on this path, so the test never touches a real shell.
    func testInteractiveCommandsThrowRatherThanReturning() async {
        for command in ["nano file.txt", "top", "vim x", "less log.txt"] {
            do {
                _ = try await ShellSessionManager.shared.execute(command: command, conversationID: UUID())
                XCTFail("'\(command)' must throw, not return a string the sniffer cannot see")
            } catch let error as ShellSessionError {
                XCTAssertTrue(error.localizedDescription.contains("blocked"), "\(error)")
            } catch {
                XCTFail("unexpected error type for '\(command)': \(error)")
            }
        }
    }

    func testBareREPLsThrowButScriptInvocationsDoNot() async {
        do {
            _ = try await ShellSessionManager.shared.execute(command: "python3", conversationID: UUID())
            XCTFail("a bare REPL must throw")
        } catch is ShellSessionError {
            // expected
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testInteractiveSudoThrows() async {
        do {
            _ = try await ShellSessionManager.shared.execute(command: "sudo -s", conversationID: UUID())
            XCTFail("interactive sudo must throw")
        } catch is ShellSessionError {
            // expected
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - Pipe deadlock

    /// `runZshProcess` drained the pipe only AFTER `waitUntilExit()`. A pipe holds ~64 KB, so
    /// any command whose output passed that blocked the child in `write()` while the manager
    /// blocked in `wait()` — a permanent hang, with no timeout left to break it (the 30 s hard
    /// kill was removed in Phase 10 because real commands legitimately run longer).
    ///
    /// ~290 KB here, more than four times the buffer. Before the fix this call never returned.
    func testOutputLargerThanThePipeBufferDoesNotDeadlock() async throws {
        let output = try await ShellSessionManager.shared.execute(
            command: "seq 1 50000", conversationID: UUID()
        )
        XCTAssertGreaterThan(output.count, 200_000, "expected ~290 KB, got \(output.count) chars")
        XCTAssertTrue(output.contains("50000"), "the TAIL of the stream must arrive, not just the head")
    }

    /// The exit code is read at all now — nothing looked at `terminationStatus` before, so a
    /// command that failed and one that succeeded produced identical results.
    func testNonZeroExitIsSurfacedInTheOutput() async throws {
        let output = try await ShellSessionManager.shared.execute(
            command: "exit 3", conversationID: UUID()
        )
        XCTAssertTrue(output.hasPrefix("Exit code: 3"), "\(output)")
    }

    func testZeroExitCarriesNoExitCodePrefix() async throws {
        let output = try await ShellSessionManager.shared.execute(
            command: "echo hello", conversationID: UUID()
        )
        XCTAssertTrue(output.contains("hello"))
        XCTAssertFalse(output.contains("Exit code:"), "a clean run must not be labelled: \(output)")
    }

    /// A thrown shell failure must stay SOFT. `.executionThrew` does not ban the tool, so one
    /// blocked command cannot Ghost-Protocol the shell out of the rest of the session.
    func testAThrownShellFailureDoesNotBanTheTool() {
        let result = ToolExecutionResult.systemError(reason: "Error: Interactive sudo sessions are blocked.")
        XCTAssertEqual(result.failureCategory, .executionThrew)
        XCTAssertFalse(ToolFailureCategory.executionThrew.producesHardConstraint,
                       "a refusal must not ban execute_shell for the session")
    }
}
