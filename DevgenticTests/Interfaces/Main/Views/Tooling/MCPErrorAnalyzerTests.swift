// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPErrorAnalyzerTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class MCPErrorAnalyzerTests: XCTestCase {

    // MARK: - Helpers

    private func makeError(_ message: String) -> Error {
        NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - T2a: Command Not Found

    func testAnalyze_CommandNotFound_ReturnsExecutableNotFound() {
        let result = MCPErrorAnalyzer.analyze(error: makeError("zsh: command not found: npx"))
        XCTAssertEqual(result.title, "Executable Not Found")
        XCTAssertTrue(result.message.contains("npx"), "Should extract command name 'npx'")
    }

    // MARK: - T2b: No Such File or Directory

    func testAnalyze_NoSuchFileOrDirectory_ReturnsFilePathInvalid() {
        let result = MCPErrorAnalyzer.analyze(error: makeError("No such file or directory: /usr/local/bin/mcp-server"))
        XCTAssertEqual(result.title, "File Path Invalid")
    }

    // MARK: - T2c: Errno 2

    func testAnalyze_Errno2_ReturnsFilePathInvalid() {
        let result = MCPErrorAnalyzer.analyze(error: makeError("FileNotFoundError: [Errno 2] No such file"))
        XCTAssertEqual(result.title, "File Path Invalid")
    }

    // MARK: - T2d: Unsatisfiable Package

    func testAnalyze_Unsatisfiable_ReturnsPackageNotFound() {
        let result = MCPErrorAnalyzer.analyze(error: makeError("error: package 'mcp-server-xyz' is unsatisfiable"))
        XCTAssertEqual(result.title, "Package Not Found")
    }

    // MARK: - T2e: Connection Refused

    func testAnalyze_ConnectionRefused_ReturnsConnectionRefused() {
        let result = MCPErrorAnalyzer.analyze(error: makeError("Connection refused (os error 111)"))
        XCTAssertEqual(result.title, "Connection Refused")
    }

    // MARK: - T2f: Timeout

    func testAnalyze_TimedOut_ReturnsConnectionTimedOut() {
        let result = MCPErrorAnalyzer.analyze(error: makeError("The request timed out after 30 seconds"))
        XCTAssertEqual(result.title, "Connection Timed Out")
    }

    // MARK: - T2g: Unknown Error

    func testAnalyze_UnknownError_ReturnsConnectionFailed() {
        let result = MCPErrorAnalyzer.analyze(error: makeError("something completely unexpected happened"))
        XCTAssertEqual(result.title, "Connection Failed")
    }

    // MARK: - T2h: Mixed Case (Bug — case-sensitive .contains)

    func testAnalyze_MixedCaseCommandNotFound_StillMatches() {
        let result = MCPErrorAnalyzer.analyze(error: makeError("Command Not Found: uvx"))
        XCTAssertEqual(result.title, "Executable Not Found", "Case-insensitive matching should catch mixed-case errors")
    }

    // MARK: - T2i: Embedded Keyword with Context

    func testAnalyze_EmbeddedCommandNotFound_ExtractsCommandName() {
        let result = MCPErrorAnalyzer.analyze(error: makeError("The process raised an error: command not found: npx"))
        XCTAssertEqual(result.title, "Executable Not Found")
        XCTAssertTrue(result.message.contains("npx"), "Should extract 'npx' even when keyword is embedded in longer message")
    }
}
