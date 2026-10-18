// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  LocalInferenceLoggingTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest

final class LocalInferenceLoggingTests: XCTestCase {

    private func sources() throws -> [(name: String, lines: [String])] {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let dir = repoRoot.appendingPathComponent("Devgentic/Core/LocalInference")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            throw XCTSkip("sources not reachable — running outside a checkout")
        }
        return try names.filter { $0.hasSuffix(".swift") }.sorted().map { name in
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            return (name, text.components(separatedBy: "\n"))
        }
    }

    private func logCalls(_ lines: [String], levels: [String]) -> [(Int, String)] {
        lines.enumerated().compactMap { index, line in
            levels.contains { line.contains("logger.\($0)(") } ? (index + 1, line) : nil
        }
    }

    func testEveryLineIsTagged() throws {
        let files = try sources()
        XCTAssertFalse(files.isEmpty)
        var total = 0
        for file in files {
            for (number, line) in logCalls(file.lines, levels: ["debug", "info", "notice", "warning", "error"]) {
                total += 1
                XCTAssertTrue(line.contains("(\"[LOCAL-COORD]") || line.contains("(\"[LOCAL-RESIDENCY]"),
                              "\(file.name):\(number) is not tagged [LOCAL-COORD] / [LOCAL-RESIDENCY]: \(line)")
            }
        }
        XCTAssertGreaterThan(total, 40, "the scan found too few log lines — is it reading the right files?")
    }

    func testEveryWarningAndErrorStatesItsConsequence() throws {
        for file in try sources() {
            for (number, line) in logCalls(file.lines, levels: ["warning", "error"]) {
                XCTAssertTrue(line.contains("CONSEQUENCE"), "\(file.name):\(number) names a problem but not its effect: \(line)")
            }
        }
    }
}
