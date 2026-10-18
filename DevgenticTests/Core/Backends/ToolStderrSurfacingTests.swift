// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ToolStderrSurfacingTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
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
