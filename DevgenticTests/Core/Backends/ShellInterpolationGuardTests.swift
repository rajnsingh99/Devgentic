// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ShellInterpolationGuardTests.swift
//  DevgenticTests
//
//  Five tools built `zsh -c` command strings with model-supplied values interpolated into
//  them: `glob_files`, `git_tool`, `get_file_hash`, and `xcode_orchestrator` (build/test and
//  open_file). All five are now argv. This file stops a sixth appearing.
//
//  Two tests, doing different jobs:
//
//   1. A behavioural canary for `get_file_hash` — it had NO validation at all, not even an
//      existence check, so it is the cleanest demonstration that the class is really closed.
//   2. A SOURCE guard, because the per-tool behavioural tests only cover tools that exist
//      today. The invariant "no tool interpolates into a shell command string" is statically
//      checkable, and a new tool copying the old idiom is exactly how this recurs.
//
//  Note the contrast with the stderr regression, where a source-level test was rejected: there
//  the property was historical ("the pre-migration code merged the streams") and unknowable
//  from current source. This one is a property OF the current source, so it is checkable.
//

import XCTest
@testable import devgentic

final class ShellInterpolationGuardTests: XCTestCase {

    // MARK: - Behavioural: get_file_hash

    func testGetFileHashDoesNotExecuteAnInjectedPayload() async throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hash-injection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let real = scratch.appendingPathComponent("real.txt")
        try "content".write(to: real, atomically: true, encoding: .utf8)
        let canary = scratch.appendingPathComponent("PWNED")

        func hash(_ path: String) async throws -> String {
            let json = try JSONEncoder().encode(["path": path, "algorithm": "sha256"])
            let args = try JSONDecoder().decode(GetFileHashTool.Arguments.self, from: json)
            return try await GetFileHashTool().call(arguments: args)
        }

        _ = try await hash(#"\#(real.path)" ; touch \#(canary.path) ; echo ""#)
        XCTAssertFalse(FileManager.default.fileExists(atPath: canary.path),
                       "the path reached a shell — injection is still open")

        _ = try await hash("$(touch \(canary.path))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: canary.path))

        // …and it still hashes a real file. A security fix that breaks the tool is not a fix.
        let good = try await hash(real.path)
        XCTAssertTrue(good.contains("SHA256:"), good)
        XCTAssertFalse(good.contains("real.txt\n"), "shasum's filename column must be stripped")
    }

    /// The shell form piped through `awk`, so a missing file produced an empty pipe and the
    /// tool reported a blank hash as though it had succeeded.
    func testGetFileHashReportsAMissingFileInsteadOfABlankHash() async throws {
        let json = try JSONEncoder().encode([
            "path": "/nonexistent-\(UUID().uuidString)/x.txt", "algorithm": "sha256"
        ])
        let args = try JSONDecoder().decode(GetFileHashTool.Arguments.self, from: json)
        let result = try await GetFileHashTool().call(arguments: args)

        XCTAssertTrue(result.hasPrefix("Error:"), "a missing file is not a successful hash: \(result)")
    }

    // MARK: - Structural: no new tool may reintroduce the idiom

    /// Scans the tool sources for a shell command string built by interpolation.
    ///
    /// The allowlist has exactly one entry and it is justified in the source it points at:
    /// `ShellSessionManager` IS `execute_shell`, so the caller's command reaching a shell is
    /// its purpose. Anything else matching this shape is a tool exposing a shell it did not
    /// intend to expose.
    func testNoToolBuildsAShellCommandStringByInterpolation() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)          // …/DevgenticTests/Core/Backends/<this>
            .deletingLastPathComponent()                        // …/Core/Backends
            .deletingLastPathComponent()                        // …/Core
            .deletingLastPathComponent()                        // …/DevgenticTests
            .deletingLastPathComponent()                        // repo root
        let toolsRoot = repoRoot.appendingPathComponent("Devgentic/Interfaces/Main/Views/Tooling")

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: toolsRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw XCTSkip("tool sources not reachable from \(repoRoot.path) — running outside a checkout")
        }

        let allowed = ["ShellSessionManager.swift"]   // see the comment at its interpolation site
        // A SHELL command string being assembled: `cmd = "…\(…)…"`, or a zsh helper called
        // with one, or the string handed STRAIGHT to `-c` without ever being named.
        //
        // `inlineDashC` was added 2026-07-31 because the name-based patterns missed a live
        // injection for the whole of the original sweep: `disk_usage` wrote
        //     process.arguments = ["-c", "find \"\(searchPath)\" … | head -\(topN)"]
        // which names no variable at all, so `assignment` could never match it. Match the SINK
        // (`-c` followed by an interpolated literal), not the variable name — a name is a
        // convention an author can decline to follow, whereas every shell invocation must pass
        // through `-c`.
        //
        // KNOWN LIMIT: these run per LINE, so a multi-line (`"""`) command string is invisible
        // to them. There is one such site — `MacOSUtilityTools` set_brightness — and it
        // interpolates a Double already clamped to 0.0...1.0 by the guard above it, so it is
        // safe by validation rather than by this test. A multi-line-aware guard is the honest
        // next step here; it is not written yet.
        //
        // `script` is deliberately NOT matched by these patterns, and the reason recorded on
        // 2026-07-30 was WRONG: it claimed no AppleScript under Tooling is built from a String
        // argument. Several are — `run_applescript` takes an entire script as its argument by
        // design, and `apple_notes`/`manage_safari_tabs`
        // interpolate String arguments into AppleScript source. AppleScript reaches a shell via
        // `do shell script`, so that IS a live surface; it simply needs its own rule (escaping
        // is the mitigation there, not argv) rather than being folded into a shell-string
        // guard. Tracked separately — do not read this exclusion as "AppleScript is clean".
        let assignment = try NSRegularExpression(
            pattern: #"\b(cmd|command|shellCommand|chainedCommand)\s*(=|\+=)\s*".*\\\("#)
        let zshCall = try NSRegularExpression(pattern: #"ProcessRunner\.zsh\(".*\\\("#)
        let inlineDashC = try NSRegularExpression(pattern: #""-c"\s*,\s*".*\\\("#)

        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: toolsRoot, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []

        var scannedFiles = 0
        for file in files where !allowed.contains(file.lastPathComponent) {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            scannedFiles += 1
            for (index, line) in source.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                let range = NSRange(trimmed.startIndex..., in: trimmed)
                if assignment.firstMatch(in: trimmed, range: range) != nil
                    || zshCall.firstMatch(in: trimmed, range: range) != nil
                    || inlineDashC.firstMatch(in: trimmed, range: range) != nil {
                    offenders.append("\(file.lastPathComponent):\(index + 1)  \(trimmed.prefix(100))")
                }
            }
        }

        // A source-scan test that reaches zero files PASSES, and reports nothing wrong while
        // checking nothing at all — a renamed directory or a changed bundle layout would
        // silently retire this guard. The floor is deliberately well under the real count
        // (~30 files) so it pins "the scan happened" without breaking on every added tool.
        XCTAssertGreaterThan(scannedFiles, 20,
                             "the guard scanned \(scannedFiles) files — it is not reading the tool tree")

        XCTAssertTrue(offenders.isEmpty, """
            A tool is building a shell command string by interpolation. Model-supplied values \
            in a `zsh -c` string are command injection — pass them as argv instead \
            (see GitCommandBuilder or GlobFilesTool). If the tool genuinely IS a shell, add it \
            to `allowed` with a comment saying why.
            \(offenders.joined(separator: "\n"))
            """)
    }

    /// The guard is worthless if its pattern matches nothing, so prove it fires on the shape it
    /// is meant to catch. Without this, a typo'd regex silently passes forever.
    func testTheGuardActuallyMatchesTheOffendingShape() throws {
        let assignment = try NSRegularExpression(
            pattern: #"\b(cmd|command|shellCommand|chainedCommand)\s*(=|\+=)\s*".*\\\("#)
        let offending = #"cmd = "md5 -q \"\(expandedPath)\"""#
        let safe = #"process.arguments = ["-q", expandedPath]"#

        XCTAssertNotNil(assignment.firstMatch(in: offending, range: NSRange(offending.startIndex..., in: offending)),
                        "the guard must match the exact idiom that was removed")
        XCTAssertNil(assignment.firstMatch(in: safe, range: NSRange(safe.startIndex..., in: safe)),
                     "and must not fire on the argv form that replaced it")
    }

    /// Same proof for the pattern that was missing while `disk_usage` was live.
    func testTheInlineDashCGuardMatchesTheShapeThatWasMissed() throws {
        let inlineDashC = try NSRegularExpression(pattern: #""-c"\s*,\s*".*\\\("#)
        // Verbatim from MacOSUtilityTools before the fix.
        let offending = #"process.arguments = ["-c", "find \"\(searchPath)\" -type f | head -\(topN)"]"#
        let safe = #"process.arguments = ["-c", arguments.command]"#   // execute_shell: no literal

        XCTAssertNotNil(inlineDashC.firstMatch(in: offending, range: NSRange(offending.startIndex..., in: offending)),
                        "the guard must match the idiom that hid disk_usage for a whole sweep")
        XCTAssertNil(inlineDashC.firstMatch(in: safe, range: NSRange(safe.startIndex..., in: safe)),
                     "and must not fire where the command is a bare variable")
    }

    // MARK: - Behavioural: disk_usage

    /// `disk_usage` was NOT part of the original five. It built
    ///     ["-c", "find \"\(searchPath)\" … | head -\(topN)"]
    /// so a `path` closing the double quote ran its own command — the same class the sweep
    /// existed to close, in a tool a shell-withholding profile has no reason to suspect.
    func testDiskUsageDoesNotExecuteAnInjectedPayload() async throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskusage-injection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let real = scratch.appendingPathComponent("real.txt")
        try String(repeating: "x", count: 4096).write(to: real, atomically: true, encoding: .utf8)
        let canary = scratch.appendingPathComponent("PWNED")

        func largest(_ path: String) async throws -> String {
            let json = try JSONEncoder().encode(["action": "largest_files", "path": path])
            let args = try JSONDecoder().decode(DiskUsageTool.Arguments.self, from: json)
            return try await DiskUsageTool().call(arguments: args)
        }

        _ = try await largest(#"\#(scratch.path)" ; touch \#(canary.path) ; echo ""#)
        XCTAssertFalse(FileManager.default.fileExists(atPath: canary.path),
                       "the path reached a shell — injection is still open")

        _ = try await largest("$(touch \(canary.path))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: canary.path))

        // …and it still reports the largest files. A security fix that breaks the tool is not
        // a fix — the sort/limit moved from `sort -rh | head` into Swift and must still work.
        let good = try await largest(scratch.path)
        XCTAssertTrue(good.contains("real.txt"), good)
        XCTAssertTrue(good.contains("Largest files"), good)
    }

    // MARK: - Behavioural: apple_notes AppleScript escaping

    /// AppleScript is the OTHER route to a shell (`do shell script`). `apple_notes` escaped
    /// every interpolated value except the `list` action's folder, which was raw — so a folder
    /// name closing the string literal could append its own statement.
    ///
    /// This tests the escaper rather than the tool, because calling the tool launches Notes.app.
    func testAppleScriptEscapingNeutralisesAStringLiteralBreakout() {
        let payload = #"legit" & (do shell script "touch /tmp/PWNED") & ""#
        let escaped = AppleNotesTool.escapeAppleScript(payload)

        // Not "contains no quote" — escaping produces `\"`, which still contains one. The
        // property is that no quote survives WITHOUT its escape, since that is the character
        // that would end the literal and let the rest be read as AppleScript statements.
        let characters = Array(escaped)
        let unescapedQuote = characters.indices.contains {
            characters[$0] == "\"" && ($0 == 0 || characters[$0 - 1] != "\\")
        }
        XCTAssertFalse(unescapedQuote, "a quote survived unescaped and can close the literal: \(escaped)")

        XCTAssertEqual(escaped, #"legit\" & (do shell script \"touch /tmp/PWNED\") & \""#)

        // Backslash first, or an escape introduced later would itself be escaped.
        XCTAssertEqual(AppleNotesTool.escapeAppleScript(#"a\"b"#), #"a\\\"b"#)
        // A raw newline ends an AppleScript statement, so it must not survive either.
        XCTAssertEqual(AppleNotesTool.escapeAppleScript("a\nb"), #"a\nb"#)
        XCTAssertEqual(AppleNotesTool.escapeAppleScript("a\rb"), #"a\rb"#)
    }

    /// One escaper, so the tools cannot drift. The failure mode being prevented is a tool that
    /// escapes MOST of its interpolations: `apple_notes` escaped its title, body and search
    /// term and missed the `list` folder, and `manage_safari_tabs` escaped nothing at all.
    func testEveryAppleScriptToolSharesOneEscaper() {
        let payload = #"x" & (do shell script "id") & ""#
        XCTAssertEqual(AppleNotesTool.escapeAppleScript(payload),
                       AppleScriptEscaping.escapeStringLiteral(payload),
                       "apple_notes must delegate rather than keep a private copy")
    }

    /// `manage_safari_tabs` open: a `"` in the url closed the literal AND the enclosing `tell`
    /// block, so the rest of the value was parsed as script — `do shell script "…"` included.
    func testSafariUrlEscapingClosesTheTellBlockBreakout() {
        let hostile = "http://x\"\nend tell\ndo shell script \"touch /tmp/PWNED\"\ntell application \"Safari\"\nset _ to \"y"
        let escaped = AppleScriptEscaping.escapeStringLiteral(hostile)

        XCTAssertFalse(escaped.contains("\n"), "a raw newline would end the statement: \(escaped)")
        let characters = Array(escaped)
        let unescapedQuote = characters.indices.contains {
            characters[$0] == "\"" && ($0 == 0 || characters[$0 - 1] != "\\")
        }
        XCTAssertFalse(unescapedQuote, "a quote survived unescaped: \(escaped)")
    }

    // MARK: - Structural: search tools must end option parsing

    /// Argv stops the SHELL, not the callee's own option parser. A model-supplied `pattern`
    /// beginning with `-` is read by grep/ripgrep as a flag — confirmed against /usr/bin/grep,
    /// where a pattern of `-f <path>` made grep take its pattern LIST from that file, and
    /// ripgrep's `--pre` names a preprocessor COMMAND it executes. `--` is the fix, and it is
    /// easy to add to one call site and forget the fallback branch beside it, so this asserts
    /// every search site has one.
    func testEverySearchToolPassesAnEndOfOptionsSeparator() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let toolsRoot = repoRoot.appendingPathComponent("Devgentic/Interfaces/Main/Views/Tooling")
        guard FileManager.default.fileExists(atPath: toolsRoot.path) else {
            throw XCTSkip("tool sources not reachable — running outside a checkout")
        }

        // ⚠️ EXACT counts, and only argv-CONSTRUCTING shapes. This test used to count every line
        // containing the literal `"--"` and assert `>=` a minimum, which made it unable to fail
        // on a real regression (verified 2026-09-06):
        //
        //   - The raw counts were 6 / 3 / 1 against minimums of 4 / 2 / 1, so TWO separators
        //     could be deleted from `CodingAssistantTools.swift` and the test still passed.
        //   - One match in each of the two larger files was not a separator at all:
        //     `if !line.isEmpty && !line.hasPrefix("--")` parses ripgrep's group separator out of
        //     the tool's OUTPUT. A guard against option injection was being satisfied, in part,
        //     by output-parsing code.
        //
        // Counting only `+= ["--"` and `.append("--")` and requiring equality means removing any
        // one separator fails, and an unrelated `"--"` string elsewhere in the file cannot mask
        // it. Invariant 12 (`architecture_readme.md` §7).
        let expected: [String: Int] = [
            "CodingAssistantTools.swift": 5,       // code_search rg+grep, find_definition rg+grep, +1
            "CodingAssistantSplitTools.swift": 2,  // shared runner rg+grep
            "FileUtilityTools.swift": 1,           // grep_files
        ]

        // `args += ["--", …]` or `args.append("--")`. Nothing else counts.
        let constructing = try NSRegularExpression(
            pattern: #"(\+=\s*\[\s*"--"|\.append\(\s*"--"\s*\))"#)

        for (name, expectedCount) in expected {
            let url = toolsRoot.appendingPathComponent("Local/\(name)")
            let source = try String(contentsOf: url, encoding: .utf8)
            let separators = source.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .filter { line in
                    constructing.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
                }
                .count
            XCTAssertEqual(separators, expectedCount,
                "\(name) builds \(separators) `--` separators into argv, expected exactly "
                + "\(expectedCount). FEWER: a search argv lost its end-of-options marker, so a "
                + "`-`-leading model pattern reaches the binary's own option parser (invariant 12). "
                + "MORE: a new search branch was added — confirm it separates BEFORE the "
                + "model-supplied value, then raise this number deliberately.")
        }
    }

    /// The count above is only meaningful if it is counting the right thing. This pins the two
    /// known non-separator uses so a future reader cannot "helpfully" fold them back into the
    /// scan — they parse ripgrep's OUTPUT and have nothing to do with option injection.
    func testTheSeparatorScanIgnoresOutputParsing() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let toolsRoot = repoRoot.appendingPathComponent("Devgentic/Interfaces/Main/Views/Tooling")
        guard FileManager.default.fileExists(atPath: toolsRoot.path) else {
            throw XCTSkip("tool sources not reachable — running outside a checkout")
        }

        for name in ["CodingAssistantTools.swift", "CodingAssistantSplitTools.swift"] {
            let source = try String(contentsOf: toolsRoot.appendingPathComponent("Local/\(name)"),
                                    encoding: .utf8)
            XCTAssertTrue(source.contains(#"!line.hasPrefix("--")"#),
                "\(name): the output-parsing use of `\"--\"` is gone. If it was removed, drop this "
                + "assertion; if it was RENAMED into something the separator scan matches, the "
                + "count in testEverySearchToolPassesAnEndOfOptionsSeparator is now inflated by it.")
        }
    }
}
