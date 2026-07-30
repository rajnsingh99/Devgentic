//
//  ToolStderrSurfacingTests.swift
//  DevgenticTests
//
//  The `ProcessRunner` migration replaced 27 hand-rolled subprocess reads. Five of the sites it
//  touched had previously pointed BOTH streams at one pipe (`process.standardError = outPipe`),
//  so the single read they did returned stdout and stderr together. Rewritten as
//  `ProcessRunner.run(process).standardOutput` they compiled, passed the entire suite, and
//  silently stopped reporting stderr — `xcode_orchestrator` handed back builds with the
//  compiler errors removed, `dns_lookup` returned blank for every failed lookup.
//
//  Nothing in the suite could have caught it. `ProcessRunnerTests` proves the TYPE keeps both
//  streams, which stayed true the whole time; the defect was in what each call site asked for.
//  No test invoked a migrated tool at all, so the gap was between the two.
//
//  This file closes it from the other end — through the tool's own `call`, so the assertion is
//  about what the AGENT receives, which is the thing that was wrong.
//
//  A source-level check was considered and rejected: "the pre-migration code merged the
//  streams" is a fact about history, and today's source has no memory of it. Reading stdout
//  alone is correct at plenty of sites (`pwd`, hashing), so there is no static invariant to
//  assert. It has to be behavioural.
//
//  Coverage is partial, and named rather than implied:
//    ✅ preview_file       `/usr/bin/head` on a missing path — stderr, empty stdout, offline
//    ❌ xcode_orchestrator needs a real `xcodebuild` run
//    ❌ dns_lookup         needs the network
//    ❌ run_mac_shortcut   needs the `shortcuts` CLI and a named shortcut to exist
//    ❌ get_wifi_info      depends on whether this machine still ships the `airport` stub
//

import XCTest
@testable import devgentic

final class ToolStderrSurfacingTests: XCTestCase {

    private func previewArguments(path: String) throws -> PreviewFileTool.Arguments {
        // Arguments declares its own decoder, which suppresses the memberwise init.
        try JSONDecoder().decode(
            PreviewFileTool.Arguments.self,
            from: Data(#"{"path":"\#(path)"}"#.utf8)
        )
    }

    /// THE regression, at the layer that was broken. `head` writes "No such file or directory"
    /// to stderr and exits non-zero with EMPTY stdout, so a stdout-only read renders an
    /// unreadable file as a successful preview of nothing — the agent is told the file is
    /// empty rather than absent, and those call for opposite next moves.
    func testPreviewFileSurfacesTheReasonAFileCouldNotBeRead() async throws {
        let missing = "/nonexistent-\(UUID().uuidString)/nope.txt"
        let output = try await PreviewFileTool().call(arguments: previewArguments(path: missing))

        XCTAssertTrue(
            output.lowercased().contains("no such file"),
            "the failure reason must reach the agent, not be dropped with stderr:\n\(output)"
        )
    }

    /// The other half: a readable file must still come back clean, with no stderr marker
    /// bolted on. `combinedOutput` omits the `[stderr]` section when stderr is empty, and this
    /// is what stops the fix from being "append noise to every successful call".
    func testPreviewFileReturnsCleanOutputWhenNothingGoesWrong() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("preview-\(UUID().uuidString).txt")
        try "alpha\nbeta\ngamma".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let output = try await PreviewFileTool().call(arguments: previewArguments(path: url.path))

        XCTAssertTrue(output.contains("alpha"))
        XCTAssertTrue(output.contains("gamma"))
        XCTAssertFalse(output.contains("[stderr]"), "no empty stderr section on a clean run:\n\(output)")
    }
}
