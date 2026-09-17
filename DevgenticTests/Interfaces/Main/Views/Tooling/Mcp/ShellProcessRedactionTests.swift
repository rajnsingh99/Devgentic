// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ShellProcessRedactionTests.swift
//  DevgenticTests
//
//  Registers KC-16 and KC-17: nothing `ShellProcess` logs may carry a secret. The log is what a
//  bug-report bundle carries, and a bug report is what gets pasted into a public issue.
//
//  ⚠️ Both tests go through the real object — one through the stored `commandLine` the log lines
//  quote, one through a real child process writing to stderr — because a unit test of
//  `MCPRedaction` alone says nothing about whether `ShellProcess` calls it.
//

import XCTest
@testable import devgentic

final class ShellProcessRedactionTests: XCTestCase {

    private let secret = "sk-live-0123456789abcdefABCDEF"

    override func tearDown() {
        ShellProcess.stderrLogSinkForTesting = nil
        super.tearDown()
    }

    // MARK: - KC-16: the stored command line

    func testTheStoredCommandLineNeverCarriesASecretArgument() throws {
        let arguments = ["--api-key", secret, "--token=xoxb-9876543210-abc", "Authorization: Bearer \(secret)", "--verbose"]
        let process = try ShellProcess(command: "/bin/echo", arguments: arguments)

        XCTAssertFalse(process.commandLine.contains(secret), process.commandLine)
        XCTAssertFalse(process.commandLine.contains("xoxb-9876543210-abc"), process.commandLine)
        XCTAssertTrue(process.commandLine.hasPrefix("/bin/echo --api-key \(MCPRedaction.redactedPlaceholder)"), process.commandLine)
        XCTAssertTrue(process.commandLine.hasSuffix("--verbose"), "ordinary arguments stay readable")
        XCTAssertEqual(process.process.arguments, arguments, "the live argv must be untouched — redaction is for the log only")
    }

    // MARK: - KC-17: child stderr

    func testChildStderrIsRedactedBeforeItIsLogged() throws {
        let logged = expectation(description: "a stderr line reached the log sink")
        logged.assertForOverFulfill = false
        let lines = LineBox()
        ShellProcess.stderrLogSinkForTesting = { line in
            lines.append(line)
            logged.fulfill()
        }

        let process = try ShellProcess(
            command: "/bin/sh",
            arguments: ["-c", "echo 'Authorization: Bearer \(secret)' 1>&2"]
        )
        try process.run()
        wait(for: [logged], timeout: 10)
        process.process.waitUntilExit()

        let joined = lines.joined()
        XCTAssertFalse(joined.contains(secret), joined)
        XCTAssertTrue(joined.contains("[STDERR] Authorization: \(MCPRedaction.redactedPlaceholder)"), joined)
    }
}

/// Lines collected from the readability handler's thread.
private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.withLock { lines.append(line) }
    }

    func joined() -> String {
        lock.withLock { lines.joined(separator: "\n") }
    }
}
