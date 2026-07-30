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
        // with one.
        //
        // `script` is deliberately NOT in this list. AppleScript is a separate surface — it can
        // reach a shell via `do shell script`, so it is worth watching — but it has different
        // semantics and would need a different rule. Checked by hand on 2026-07-30: the only
        // two interpolated AppleScripts in the tree (`AudioMediaTools:41`,
        // `DeviceControlTools:145`) both insert a range-clamped Int, and no AppleScript is
        // built from a String argument anywhere under Tooling. Widening this pattern to
        // `script` today would only produce two false positives; if AppleScript ever takes a
        // string argument, it needs its own guard rather than this one.
        let assignment = try NSRegularExpression(
            pattern: #"\b(cmd|command|shellCommand|chainedCommand)\s*(=|\+=)\s*".*\\\("#)
        let zshCall = try NSRegularExpression(pattern: #"ProcessRunner\.zsh\(".*\\\("#)

        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: toolsRoot, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []

        for file in files where !allowed.contains(file.lastPathComponent) {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (index, line) in source.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                let range = NSRange(trimmed.startIndex..., in: trimmed)
                if assignment.firstMatch(in: trimmed, range: range) != nil
                    || zshCall.firstMatch(in: trimmed, range: range) != nil {
                    offenders.append("\(file.lastPathComponent):\(index + 1)  \(trimmed.prefix(100))")
                }
            }
        }

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
}
