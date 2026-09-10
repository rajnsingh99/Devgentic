// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  GlobFilesInjectionTests.swift
//  DevgenticTests
//
//  `glob_files` built a `zsh -c` string with the caller's pattern interpolated inside double
//  quotes — `-name "\(pattern)"`. A pattern containing a double quote closes that quote and
//  everything after it is shell syntax:
//
//      pattern = a" ; touch /tmp/pwned ; echo "
//      →  find "…" -type f -name "a" ; touch /tmp/pwned ; echo "" ! -path …
//
//  `pattern` and `path` are TOOL ARGUMENTS. They come from the model, so anything that can
//  influence the model — a fetched web page, a file it was told to read, a poisoned dependency
//  manifest — could reach a shell through this tool. It is enabled on profiles that
//  deliberately withhold `execute_shell`, which is exactly where this matters.
//
//  The fix is structural: `find` is invoked through `execve` argv, so a pattern is one
//  argument whatever characters it contains and there is no parser to break out of. These
//  tests fire real payloads and assert the side effect never happens — a quoting-based fix
//  would pass some of them and fail others, which is the point of testing it this way rather
//  than asserting on the constructed string.
//

import XCTest
@testable import devgentic

final class GlobFilesInjectionTests: XCTestCase {

    private var scratch: URL!
    private var canary: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glob-injection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try "swift".write(to: scratch.appendingPathComponent("Real.swift"), atomically: true, encoding: .utf8)
        canary = scratch.appendingPathComponent("PWNED")
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        try super.tearDownWithError()
    }

    private func glob(pattern: String, path: String? = nil) async throws -> String {
        // Arguments declares its own decoder, so there is no memberwise init.
        let json = try JSONEncoder().encode([
            "pattern": pattern,
            "path": path ?? scratch.path
        ])
        let args = try JSONDecoder().decode(GlobFilesTool.Arguments.self, from: json)
        return try await GlobFilesTool().call(arguments: args)
    }

    private var canaryExists: Bool { FileManager.default.fileExists(atPath: canary.path) }

    // MARK: - Payloads that used to execute

    /// The headline case: break out of the double quotes and append a command.
    func testAQuoteEscapePayloadDoesNotExecute() async throws {
        _ = try await glob(pattern: #"a" ; touch \#(canary.path) ; echo ""#)
        XCTAssertFalse(canaryExists, "the pattern reached a shell — injection is still open")
    }

    /// Command substitution, which needs no quote break at all if the string ever reaches a
    /// shell that performs it.
    func testCommandSubstitutionDoesNotExecute() async throws {
        _ = try await glob(pattern: "$(touch \(canary.path))")
        XCTAssertFalse(canaryExists)
        _ = try await glob(pattern: "`touch \(canary.path)`")
        XCTAssertFalse(canaryExists)
    }

    /// A separator does not need quotes to escape from, only a shell to be parsed by.
    func testSemicolonAndPipePayloadsDoNotExecute() async throws {
        _ = try await glob(pattern: "; touch \(canary.path)")
        XCTAssertFalse(canaryExists)
        _ = try await glob(pattern: "x | touch \(canary.path)")
        XCTAssertFalse(canaryExists)
        _ = try await glob(pattern: "x && touch \(canary.path)")
        XCTAssertFalse(canaryExists)
    }

    /// `path` was interpolated into the same string and is just as reachable. It is checked
    /// with `fileExists` first, so the payload is appended to a directory that does exist.
    func testThePathArgumentIsAlsoNotAShellString() async throws {
        _ = try await glob(pattern: "*.swift", path: #"\#(scratch.path)" ; touch \#(canary.path) ; echo ""#)
        XCTAssertFalse(canaryExists)
    }

    /// The `/`-containing branch builds a different predicate (`-path`) and needs its own case;
    /// fixing one branch and leaving another is how this kind of bug half-survives a fix.
    func testThePathPatternBranchIsAlsoSafe() async throws {
        _ = try await glob(pattern: #"src/a" ; touch \#(canary.path) ; echo ""#)
        XCTAssertFalse(canaryExists)
    }

    /// So does the `**` branch, which rewrites the pattern before using it.
    func testTheRecursiveBranchIsAlsoSafe() async throws {
        _ = try await glob(pattern: #"**/a" ; touch \#(canary.path) ; echo ""#)
        XCTAssertFalse(canaryExists)
    }

    // MARK: - It still works

    /// A security fix that breaks the feature is not a fix. These are the ordinary shapes the
    /// tool's own schema advertises.
    func testOrdinaryPatternsStillMatch() async throws {
        let simple = try await glob(pattern: "*.swift")
        XCTAssertTrue(simple.contains("Real.swift"), simple)

        let recursive = try await glob(pattern: "**/*.swift")
        XCTAssertTrue(recursive.contains("Real.swift"), recursive)
    }

    func testANonMatchingPatternReportsNothingFound() async throws {
        let result = try await glob(pattern: "*.nonexistent")
        XCTAssertTrue(result.contains("No files found"), result)
    }

    /// Metacharacters that are legitimate GLOB syntax must still reach `find` intact — the fix
    /// must not have quietly sanitised the feature away.
    func testGlobMetacharactersStillReachFind() async throws {
        try "x".write(to: scratch.appendingPathComponent("a1.txt"), atomically: true, encoding: .utf8)
        try "x".write(to: scratch.appendingPathComponent("b2.txt"), atomically: true, encoding: .utf8)

        let result = try await glob(pattern: "a?.txt")
        XCTAssertTrue(result.contains("a1.txt"), result)
        XCTAssertFalse(result.contains("b2.txt"), "the ? wildcard must still be a wildcard")
    }

    /// Pruning is what replaced `! -path`, and it has to keep excluding the same noise.
    func testHeavyDirectoriesAreStillExcluded() async throws {
        let nested = scratch.appendingPathComponent("node_modules/pkg")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "x".write(to: nested.appendingPathComponent("Hidden.swift"), atomically: true, encoding: .utf8)

        let result = try await glob(pattern: "**/*.swift")
        XCTAssertTrue(result.contains("Real.swift"))
        XCTAssertFalse(result.contains("Hidden.swift"), "node_modules must be pruned: \(result)")
    }
}
