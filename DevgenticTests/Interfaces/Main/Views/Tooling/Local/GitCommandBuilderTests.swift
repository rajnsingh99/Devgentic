// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GitCommandBuilderTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class GitCommandBuilderTests: XCTestCase {

    private let repoPath = "/Users/test/repo"

    /// Everything that precedes the subcommand: the repo selector plus the config neutralisers.
    /// Built from the constant rather than spelled out, so these tests stay about ROUTING —
    /// `testHardeningPrefixIsExactlyTheConfigNeutralisers` is what pins the constant itself.
    private func base(_ path: String? = nil) -> [String] {
        ["-C", path ?? repoPath] + GitCommandBuilder.hardening
    }

    private func argv(_ action: String, _ extraArgs: String = "",
                      file: StaticString = #filePath, line: UInt = #line) -> [String] {
        switch GitCommandBuilder.resolve(action: action, repoPath: repoPath, extraArgs: extraArgs) {
        case .argv(let argv): return argv
        case .error(let msg): XCTFail("expected .argv, got .error(\(msg))", file: file, line: line); return []
        }
    }

    // MARK: - Action routing

    func testResolve_Status_ReturnsStatusArgv() {
        XCTAssertEqual(argv("status"), base() + ["status", "--short"])
    }

    func testResolve_Log_DefaultArgs_UsesOneline() {
        XCTAssertEqual(argv("log"), base() + ["log"] + GitCommandBuilder.diffProgramSuppression + ["-n", "10", "--oneline"])
    }

    func testResolve_Log_CustomArgs_OverridesDefaults() {
        let result = argv("log", "-n 5 --graph")
        XCTAssertEqual(result, base() + ["log"] + GitCommandBuilder.diffProgramSuppression + ["-n", "5", "--graph"])
        XCTAssertFalse(result.contains("--oneline"), "custom args replace the defaults")
    }

    func testResolve_Diff_PassesThroughArgs() {
        XCTAssertEqual(argv("diff", "--staged"), base() + ["diff"] + GitCommandBuilder.diffProgramSuppression + ["--staged"])
    }

    func testResolve_Branch_PassesThroughArgs() {
        XCTAssertEqual(argv("branch", "--list"), base() + ["branch", "-a", "--list"])
    }

    func testResolve_StashList_FixedArgv() {
        XCTAssertEqual(argv("stash_list"), base() + ["stash", "list"])
    }

    // MARK: - Blame requires args

    func testResolve_Blame_WithArgs_ReturnsArgv() {
        XCTAssertEqual(argv("blame", "main.swift"), base() + ["blame"] + GitCommandBuilder.diffProgramSuppression + ["main.swift"])
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
        XCTAssertEqual(argv("show"), base() + ["show"] + GitCommandBuilder.diffProgramSuppression + ["HEAD", "--stat"])
    }

    func testResolve_Show_CustomArgs_OverridesHEAD() {
        let result = argv("show", "abc123")
        XCTAssertEqual(result, base() + ["show"] + GitCommandBuilder.diffProgramSuppression + ["abc123", "--stat"])
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
                       base() + ["diff"] + GitCommandBuilder.diffProgramSuppression + [";", "touch", "/tmp/pwned"],
                       "operators must survive as literal argv words, never as syntax")
    }

    func testCommandSubstitutionIsNotEvaluated() {
        XCTAssertEqual(argv("log", "$(touch /tmp/pwned)"),
                       base() + ["log"] + GitCommandBuilder.diffProgramSuppression + ["$(touch", "/tmp/pwned)"])
        XCTAssertEqual(argv("log", "`id`"), base() + ["log"] + GitCommandBuilder.diffProgramSuppression + ["`id`"])
    }

    func testPipesAndRedirectionAreNotOperators() {
        XCTAssertEqual(argv("log", "--oneline | sh"),
                       base() + ["log"] + GitCommandBuilder.diffProgramSuppression + ["--oneline", "|", "sh"])
        XCTAssertEqual(argv("log", "> /tmp/out"), base() + ["log"] + GitCommandBuilder.diffProgramSuppression + [">", "/tmp/out"])
    }

    /// The repo path was interpolated into the same string and is equally reachable. As an
    /// argv element it cannot be anything but a path.
    func testRepoPathIsAlwaysASingleArgument() {
        let hostile = #"/tmp/repo" ; touch /tmp/pwned ; echo ""#
        guard case .argv(let result) = GitCommandBuilder.resolve(
            action: "status", repoPath: hostile, extraArgs: "") else {
            return XCTFail("expected .argv")
        }
        XCTAssertEqual(result, base(hostile) + ["status", "--short"],
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

    /// Separators are the POSIX `IFS` set, not `Character.isWhitespace` (which is the UNICODE
    /// whitespace set). The difference was exploitable: a U+00A0 is invisible in the raw `args`
    /// string an operator reads, but `isWhitespace` split on it and promoted what followed into
    /// its own argv element — so `HEAD~1<NBSP>--output=…` presented as one innocuous revision
    /// name and reached git as a separate OPTION. A shell does not split there, and neither
    /// does git when handed the same bytes as one argument.
    func testUnicodeWhitespaceIsNotASeparator() {
        for separator in ["\u{00A0}", "\u{2009}", "\u{3000}", "\u{2028}", "\u{000B}",
                          "\u{000C}", "\u{0085}", "\u{1680}", "\u{202F}"] {
            let input = "HEAD~1\(separator)--output=/tmp/victim"
            XCTAssertEqual(GitCommandBuilder.tokenize(input), [input],
                           "U+\(String(separator.unicodeScalars.first!.value, radix: 16)) "
                           + "must stay inside the token, as it does for a shell and for git")
        }
    }

    func testPosixSeparatorsStillSplit() {
        XCTAssertEqual(GitCommandBuilder.tokenize("-n 5"), ["-n", "5"])
        XCTAssertEqual(GitCommandBuilder.tokenize("-n\t5"), ["-n", "5"])
        XCTAssertEqual(GitCommandBuilder.tokenize("-n\n5"), ["-n", "5"])
        XCTAssertEqual(GitCommandBuilder.tokenize("-n\r\n5"), ["-n", "5"])
    }

    /// The Unicode-split payload is now BOTH a single token and a denied option — the token
    /// keeps it out of git's option parser, and the denylist would have caught it regardless.
    /// Neither is load-bearing alone.
    func testTheUnicodePayloadIsInertEndToEnd() {
        let result = argv("diff", "HEAD~1\u{00A0}--output=/tmp/victim")
        XCTAssertEqual(result, base() + ["diff"] + GitCommandBuilder.diffProgramSuppression + ["HEAD~1\u{00A0}--output=/tmp/victim"])
        XCTAssertFalse(result.contains("--output=/tmp/victim"))
    }

    // MARK: - Option injection
    //
    // Argv closed the SHELL. It did not close git's own option parser, which is a second
    // interpreter reading the same attacker-controlled words. Each option below was confirmed
    // against /usr/bin/git before being denied, so these are regression pins on proven
    // primitives, not speculative hardening.

    private func denied(_ action: String, _ extraArgs: String,
                        file: StaticString = #filePath, line: UInt = #line) {
        guard case .error(let msg) = GitCommandBuilder.resolve(
            action: action, repoPath: repoPath, extraArgs: extraArgs) else {
            return XCTFail("`\(extraArgs)` reached git as argv — the option is still live",
                           file: file, line: line)
        }
        XCTAssertTrue(msg.contains("not permitted"), msg, file: file, line: line)
    }

    /// `git diff --output=<path>` CREATES OR TRUNCATES that file and fills it with diff output.
    /// This is the write half of the two-call RCE: plant `<repo>/.git/config`, then any later
    /// call executes the program it names.
    func testOutputOptionIsRefused_TheArbitraryFileWrite() {
        denied("diff", "--output=/tmp/victim")
        denied("diff", "--output /tmp/victim")          // space form, same option
        denied("log", "--output=/Users/alice/.zshenv")    // the `~/.zshenv` -> next zsh tool chain
        denied("show", "--output=/tmp/victim")
    }

    /// `--no-index` diffs two arbitrary paths and does NOT honour `-C`, so it reads anything
    /// this process can read regardless of which repository was named.
    func testNoIndexIsRefused_TheArbitraryFileRead() {
        denied("diff", "--no-index /dev/null /etc/hosts")
    }

    /// `git blame --contents <file>` reads an arbitrary file and echoes it into the output.
    func testBlameContentsIsRefused_TheOtherArbitraryFileRead() {
        denied("blame", "--contents /etc/hosts a.txt")
    }

    /// Both re-request a repo-nominated PROGRAM. `--ext-diff` is belt-and-braces (the config it
    /// reaches for is already emptied); `--textconv` genuinely matters, because a
    /// `.gitattributes` driver name is chosen by the repository and so cannot be neutralised by
    /// config — `--no-textconv` is the only lever, and this stops it being countermanded.
    func testExternalProgramOptionsAreRefused() {
        denied("diff", "--ext-diff")
        denied("log", "-p --ext-diff")
        denied("diff", "--textconv")
        denied("blame", "--textconv a.txt")
    }

    /// `-a` already refuses a bare branch name, but not these: `branch -a -M <new>` renames the
    /// checked-out branch. Confirmed destructive against a real repo.
    func testBranchMutationOptionsAreRefused() {
        for mutation in ["-M new", "-m new", "-C copy", "-c copy", "-d victim", "-D victim",
                         "-u origin/main", "--set-upstream-to origin/main", "--edit-description",
                         "-f", "--force", "--unset-upstream"] {
            denied("branch", mutation)
        }
    }

    /// The scoping half of the rule above. `-c` means "copy branch" to `git branch` and
    /// "combined diff" to `git log`; denying it globally would break a legitimate query.
    func testBranchOnlyDenialsDoNotLeakIntoOtherActions() {
        XCTAssertEqual(argv("log", "-c"), base() + ["log"] + GitCommandBuilder.diffProgramSuppression + ["-c"])
        XCTAssertEqual(argv("log", "-m"), base() + ["log"] + GitCommandBuilder.diffProgramSuppression + ["-m"])
    }

    /// Denial keys off the option NAME, so it cannot be dodged by attaching the value with `=`
    /// — and git does not accept abbreviated long options here (`--outp` is an error), which is
    /// what makes exact-name matching sufficient rather than merely convenient.
    func testDenialMatchesTheOptionNameNotTheWholeToken() {
        denied("diff", "--output=/tmp/a")
        denied("diff", "--no-index=/tmp/a")
    }

    /// TOK-2: a leading backslash or quote reconstructs a dash after tokenising, so any guard
    /// written against the RAW args string would be bypassed. This one runs on the tokens.
    func testDenialRunsAfterTokenisingSoEscapedDashesAreStillCaught() {
        denied("diff", #"\--output=/tmp/victim"#)
        denied("diff", #"'-''-output'=/tmp/victim"#)
    }

    /// Legitimate documented usage must still work — a security fix that breaks the tool is not
    /// a fix, and an over-broad denial would push callers back toward `execute_shell`.
    func testDocumentedArgumentsStillPass() {
        XCTAssertEqual(argv("log", "-n 5"), base() + ["log"] + GitCommandBuilder.diffProgramSuppression + ["-n", "5"])
        XCTAssertEqual(argv("log", #"--author="J Smith""#),
                       base() + ["log"] + GitCommandBuilder.diffProgramSuppression + ["--author=J Smith"])
        XCTAssertEqual(argv("blame", "path/to/file.swift"),
                       base() + ["blame"] + GitCommandBuilder.diffProgramSuppression + ["path/to/file.swift"])
        XCTAssertEqual(argv("branch", "--contains HEAD"),
                       base() + ["branch", "-a", "--contains", "HEAD"])
    }

    // MARK: - Config neutralisation

    /// The RCE this closes needs no arguments at the trigger: `.git/config` names a program in
    /// `core.fsmonitor` or `diff.external`, and a bare `status` or `diff` runs it. An args-layer
    /// denial cannot see that call, so the fix has to be config, and it has to be on EVERY
    /// action — hence a test that asserts the constant, and one that asserts every action
    /// carries it.
    func testHardeningPrefixIsExactlyTheConfigNeutralisers() {
        XCTAssertEqual(GitCommandBuilder.hardening, [
            "-c", "core.fsmonitor=",
            "-c", "diff.external=",
            "-c", "core.hooksPath=/dev/null",
            "-c", "core.pager=cat",
        ])
    }

    func testEveryActionCarriesTheHardeningPrefixBeforeItsSubcommand() {
        for action in ["status", "log", "diff", "branch", "stash_list", "show"] {
            let result = argv(action)
            XCTAssertEqual(Array(result.prefix(base().count)), base(),
                           "\(action) must be hardened")
        }
        XCTAssertEqual(Array(argv("blame", "a.txt").prefix(base().count)), base(),
                       "blame must be hardened")
    }

    /// `-c` is a PRE-subcommand global. `args` is always appended after the subcommand, so a
    /// caller cannot countermand the neutralisers — verified against git, where
    /// `-c diff.external=` wins over a later `--ext-diff` but `--no-ext-diff` does not.
    func testHardeningPrecedesTheSubcommandSoArgsCannotOverrideIt() {
        let result = argv("log", "-c core.fsmonitor=/tmp/evil.sh")
        let subcommandIndex = result.firstIndex(of: "log")
        XCTAssertNotNil(subcommandIndex)
        for (index, element) in result.enumerated() where element == "core.fsmonitor=" {
            XCTAssertLessThan(index, subcommandIndex!,
                              "the neutraliser must sit ahead of the subcommand")
        }
        XCTAssertEqual(result.last, "core.fsmonitor=/tmp/evil.sh",
                       "the caller's copy stays a post-subcommand argument, where git reads it "
                       + "as a revision and not as configuration")
    }

    // MARK: - Audit fixes (2026-07-31)

    /// Git accepts any UNAMBIGUOUS abbreviation of a long option, so an exact-match denylist only
    /// stops the spelling an honest caller would use. Reproduced before the fix:
    /// `git blame --cont <file> a.txt` resolved to `--contents` and printed the file.
    func testAbbreviatedLongOptionsAreRefused() {
        for abbreviation in ["--cont", "--conten", "--outp", "--output", "--ext", "--textc"] {
            guard case .error = GitCommandBuilder.resolve(
                action: "blame", repoPath: "/tmp", extraArgs: "\(abbreviation)=/etc/hosts a.txt"
            ) else {
                return XCTFail("'\(abbreviation)' was accepted — git resolves it to a denied option")
            }
        }
    }

    /// Prefix matching must not swallow legitimate arguments. These are not abbreviations of
    /// anything denied, and refusing them would break the tool for ordinary use.
    func testOrdinaryArgumentsSurvivePrefixMatching() {
        for ok in ["-n 5", "--oneline", "--stat", "--author=J Smith", "-S needle", "--since=2.days"] {
            guard case .argv = GitCommandBuilder.resolve(action: "log", repoPath: "/tmp", extraArgs: ok) else {
                return XCTFail("'\(ok)' was refused but is harmless")
            }
        }
    }

    /// A repo can name its own diff driver, and the driver's config key contains that name — so
    /// no fixed `-c` can empty it. `hardening` alone did NOT stop it (reproduced: a plain `diff`
    /// on a repo with `[diff "evil"] command = …` executed the program with full hardening
    /// applied). Every content-rendering action must carry the suppression flags.
    func testDiffFamilyActionsSuppressRepoNominatedPrograms() {
        for action in ["diff", "log", "show", "blame"] {
            let extra = action == "blame" ? "a.txt" : ""
            guard case .argv(let argv) = GitCommandBuilder.resolve(
                action: action, repoPath: "/tmp", extraArgs: extra
            ) else {
                return XCTFail("\(action) did not resolve")
            }
            XCTAssertTrue(argv.contains("--no-ext-diff"),
                          "\(action) is missing --no-ext-diff: a named diff driver would execute")
            XCTAssertTrue(argv.contains("--no-textconv"), "\(action) is missing --no-textconv")
        }
    }

    // MARK: - Environment (GIT_OPTIONAL_LOCKS)

    func testEnvironmentDisablesOptionalLocksAndColour() {
        let env = GitCommandBuilder.environment(inheriting: ["PATH": "/usr/bin"])
        XCTAssertEqual(env["GIT_OPTIONAL_LOCKS"], "0")
        XCTAssertEqual(env["TERM"], "dumb")
        XCTAssertEqual(env["PATH"], "/usr/bin", "the inherited environment is kept")
    }

    /// An inherited value must not win — a user shell exporting `GIT_OPTIONAL_LOCKS=1` (or a colour
    /// TERM) would otherwise reopen the race.
    func testOverridesBeatTheInheritedEnvironment() {
        let env = GitCommandBuilder.environment(inheriting: ["GIT_OPTIONAL_LOCKS": "1", "TERM": "xterm-256color"])
        XCTAssertEqual(env["GIT_OPTIONAL_LOCKS"], "0")
        XCTAssertEqual(env["TERM"], "dumb")
    }

    /// One source: the Git Changes panel uses the SAME overrides as the agent's tool.
    func testThePanelSharesTheToolsEnvironment() {
        XCTAssertEqual(GitUICommand.environmentOverrides, GitCommandBuilder.environmentOverrides)
    }

    /// ⚠️ WIRING, end to end: the real `git` tool running `status` on a repo whose index is
    /// stat-stale must leave `.git/index` untouched. Verified 2026-10-04 that a plain `git status`
    /// REWRITES it here (taking `index.lock` — the lock a user's concurrent `git commit` then
    /// trips on). Fails if the tool stops passing `GitCommandBuilder.environment()`.
    func testTheAgentsStatusDoesNotRewriteTheIndex() async throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("GitLock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }

        func git(_ args: [String]) throws {
            let run = try ProcessRunner.run(
                executable: "/usr/bin/git",
                arguments: ["-C", repo.path, "-c", "user.name=t", "-c", "user.email=t@t",
                            "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + args)
            guard run.succeeded else { throw XCTSkip("git unavailable here: \(run.standardError)") }
        }
        try git(["init", "-q", "-b", "main", "."])
        let file = repo.appendingPathComponent("f.txt")
        try "a\n".write(to: file, atomically: true, encoding: .utf8)
        try git(["add", "f.txt"])
        try git(["commit", "-q", "-m", "init"])

        // Make the index stat-stale: the file's mtime moves past what the index recorded. Git's
        // timestamps are second-granular, so step over a second boundary on each side.
        let index = repo.appendingPathComponent(".git/index")
        try await Task.sleep(for: .milliseconds(1100))
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        try await Task.sleep(for: .milliseconds(1100))
        let before = try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date

        let arguments = try JSONDecoder().decode(GitTool.Arguments.self,
                                                 from: Data(#"{"action":"status","path":"\#(repo.path)"}"#.utf8))
        let output = try await GitTool().call(arguments: arguments)
        XCTAssertFalse(output.hasPrefix("Error"), output)

        let after = try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after, "the agent's `git status` rewrote .git/index — it took index.lock")
    }

    /// No call site may build its own git environment again.
    func testNoGitCallSiteBuildsItsOwnEnvironment() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        for path in ["Devgentic/Interfaces/Main/Views/Tooling/Local/GitIntegrationTool.swift",
                     "Devgentic/Core/Backends/TextGen/GitRepositoryLocator.swift"] {
            guard let source = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
                throw XCTSkip("\(path) not reachable — running outside a checkout")
            }
            XCTAssertFalse(source.contains(#"["TERM"] = "dumb""#), "\(path) builds its own git environment")
            XCTAssertTrue(source.contains("GitCommandBuilder.environment()"), "\(path) does not use the shared environment")
        }
    }
}
