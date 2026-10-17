// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SearchExitStatusTests.swift
//  DevgenticTests
//
//  Invariant: a search tool reports "no matches" only when the search program said so (exit 0 or
//  1). A run that exits with an error is reported as an error, and any results it did print are
//  kept with a note that the search was incomplete.
//
//  Device run 2026-10-05: ripgrep rejected `\nfunction clamp\(.*?\)` (exit 2), `code_search_text`
//  answered "No matches found", and the agent concluded `clamp` did not exist.
//
//  Every case runs against BOTH programs. Which one a user gets depends on whether ripgrep is
//  installed, and each program's own error text is asserted, which proves the intended branch ran.
//

import XCTest
@testable import devgentic

final class SearchExitStatusTests: XCTestCase {

    private var root: URL!

    /// A pattern both programs refuse to compile.
    private let rejectedPattern = "("

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchExitStatusTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "def clamp(value, low=0, high=100):\n    return max(low, min(value, high))\n"
            .write(to: root.appendingPathComponent("src/math_utils.py"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        SearchBinary.discoveryOverride = nil
        let locked = root.appendingPathComponent("locked")
        if FileManager.default.fileExists(atPath: locked.path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Programs

    private enum Program: CaseIterable {
        case ripgrep, grep

        var label: String { self == .ripgrep ? "ripgrep" : "grep" }

        /// The program's own words for `(`, which identify the branch that ran.
        var rejectionReason: String { self == .ripgrep ? "regex parse error" : "parentheses not balanced" }
    }

    private func use(_ program: Program) throws {
        switch program {
        case .ripgrep:
            let installed = SearchBinary.ripgrepCandidates.first { FileManager.default.fileExists(atPath: $0) }
            guard let installed else { throw XCTSkip("ripgrep is not installed on this machine") }
            SearchBinary.discoveryOverride = .ripgrepAt(installed)
        case .grep:
            SearchBinary.discoveryOverride = .ripgrepUnavailable
        }
    }

    /// A directory the test user cannot read, holding a file that WOULD match.
    private func addUnreadableDirectory() throws {
        guard getuid() != 0 else { throw XCTSkip("root can read a 000 directory") }
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try "clamp here\n".write(to: locked.appendingPathComponent("x.py"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
    }

    // MARK: - Tools

    private func decode<T: Decodable>(_ type: T.Type, _ dict: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: dict))
    }

    /// The four tools that take a model-supplied pattern, through their real `call`.
    private func patternTools() -> [(name: String, run: (String) async throws -> String)] {
        let path = root.path
        return [
            ("code_search", { try await CodeSearchTool().call(arguments: self.decode(CodeSearchTool.Arguments.self, ["pattern": $0, "path": path])) }),
            ("code_search_text", { try await CodeSearchTextTool().call(arguments: self.decode(CodeSearchTextTool.Arguments.self, ["pattern": $0, "path": path])) }),
            ("code_search_symbol", { try await CodeSearchSymbolTool().call(arguments: self.decode(CodeSearchSymbolTool.Arguments.self, ["pattern": $0, "path": path])) }),
            ("code_search_files", { try await CodeSearchFilesTool().call(arguments: self.decode(CodeSearchFilesTool.Arguments.self, ["pattern": $0, "path": path])) }),
        ]
    }

    private func findDefinition(_ symbol: String) async throws -> String {
        try await FindDefinitionTool().call(arguments: decode(FindDefinitionTool.Arguments.self,
                                                              ["symbol": symbol, "path": root.path, "language": "python"]))
    }

    // MARK: - A rejected pattern is an error

    func testARejectedPatternIsAnErrorNotNoMatches() async throws {
        for program in Program.allCases {
            try use(program)
            for tool in patternTools() {
                let result = try await tool.run(rejectedPattern)
                let where_ = "\(tool.name) via \(program.label)"
                XCTAssertFalse(result.contains("No matches found"), "\(where_) reported absence for a pattern it rejected:\n\(result)")
                XCTAssertTrue(result.hasPrefix("Error: \(program.label) reported an error"), "\(where_):\n\(result)")
                XCTAssertTrue(result.contains("NOT a \"no matches\" result"), "\(where_):\n\(result)")
                XCTAssertTrue(result.contains(program.rejectionReason), "\(where_) did not quote the program's reason:\n\(result)")
            }
        }
    }

    /// `*.py` (sent 11 times in one 2026-10-06 run): a leading `*` cannot be a regex, so the error
    /// names the tool the model actually wanted. A rejected pattern without one gets no such hint.
    func testAGlobPatternIsPointedAtGlobFiles() async throws {
        for program in Program.allCases {
            try use(program)
            for tool in patternTools() {
                let where_ = "\(tool.name) via \(program.label)"
                let glob = try await tool.run("*.py")
                XCTAssertTrue(glob.hasPrefix("Error:"), "\(where_):\n\(glob)")
                XCTAssertTrue(glob.contains("use glob_files with pattern \"**/*.py\""), "\(where_):\n\(glob)")
                let regex = try await tool.run(rejectedPattern)
                XCTAssertFalse(regex.contains("glob_files"), "\(where_) gave the glob hint for a regex error:\n\(regex)")
            }
        }
    }

    /// The exact pattern from the device run. ripgrep only — grep reads a newline as a second,
    /// EMPTY pattern and matches every line, which is a separate defect.
    func testTheDeviceRunPatternReportsRipgrepsReason() async throws {
        try use(.ripgrep)
        let result = try await CodeSearchTextTool().call(arguments: decode(CodeSearchTextTool.Arguments.self,
            ["pattern": "\nfunction clamp\\(.*?\\)", "path": root.path]))
        XCTAssertFalse(result.contains("No matches found"), result)
        XCTAssertTrue(result.contains("the literal \"\\n\" is not allowed in a regex"), result)
    }

    // MARK: - Exit 0 and 1 are unchanged

    func testAGenuineMissIsStillNoMatches() async throws {
        for program in Program.allCases {
            try use(program)
            for tool in patternTools() {
                let result = try await tool.run("nomatch_zzz")
                XCTAssertTrue(result.hasPrefix("No matches found"), "\(tool.name) via \(program.label):\n\(result)")
            }
        }
    }

    func testMatchesAreReturnedWithoutAnIncompleteNote() async throws {
        for program in Program.allCases {
            try use(program)
            for tool in patternTools() {
                let result = try await tool.run("clamp")
                XCTAssertTrue(result.contains("math_utils.py"), "\(tool.name) via \(program.label):\n\(result)")
                XCTAssertFalse(result.contains("Search incomplete"), "\(tool.name) via \(program.label):\n\(result)")
            }
        }
    }

    // MARK: - Exit 2 with results keeps them

    func testAnUnreadableDirectoryKeepsTheMatchesAndSaysTheSearchWasIncomplete() async throws {
        try addUnreadableDirectory()
        for program in Program.allCases {
            try use(program)
            for tool in patternTools() {
                let result = try await tool.run("clamp")
                let where_ = "\(tool.name) via \(program.label)"
                XCTAssertTrue(result.contains("math_utils.py"), "\(where_) dropped the matches it found:\n\(result)")
                XCTAssertTrue(result.contains("[Search incomplete: \(program.label) reported an error"), "\(where_):\n\(result)")
                XCTAssertTrue(result.contains("Permission denied"), "\(where_):\n\(result)")
            }
        }
    }

    /// Exit 2, nothing printed: "nothing found in the readable paths" looks exactly like a bad
    /// pattern, so it is reported as an error rather than as absence.
    func testAnUnreadableDirectoryWithNoMatchIsNotReportedAsAbsence() async throws {
        try addUnreadableDirectory()
        for program in Program.allCases {
            try use(program)
            for tool in patternTools() {
                let result = try await tool.run("nomatch_zzz")
                XCTAssertFalse(result.contains("No matches found"), "\(tool.name) via \(program.label):\n\(result)")
                XCTAssertTrue(result.contains("Permission denied"), "\(tool.name) via \(program.label):\n\(result)")
            }
        }
    }

    // MARK: - find_definition

    func testFindDefinitionReportsARejectedSymbolWithAHint() async throws {
        for program in Program.allCases {
            try use(program)
            let result = try await findDefinition("clamp(")
            XCTAssertFalse(result.contains("No definition found"), "\(program.label):\n\(result)")
            XCTAssertTrue(result.hasPrefix("Error: \(program.label) reported an error"), "\(program.label):\n\(result)")
            XCTAssertTrue(result.contains(program.rejectionReason), "\(program.label):\n\(result)")
            XCTAssertTrue(result.contains("pass a bare identifier"), "\(program.label):\n\(result)")
        }
    }

    func testFindDefinitionStillFindsAndStillMisses() async throws {
        for program in Program.allCases {
            try use(program)
            let found = try await findDefinition("clamp")
            XCTAssertTrue(found.hasPrefix("Definitions for 'clamp'"), "\(program.label):\n\(found)")
            XCTAssertFalse(found.contains("Search incomplete"), "\(program.label):\n\(found)")

            let missed = try await findDefinition("no_such_symbol")
            XCTAssertTrue(missed.hasPrefix("No definition found"), "\(program.label):\n\(missed)")
        }
    }

    /// The identifier hint is only true when the symbol carries regex syntax — here the error is
    /// an unreadable directory, and the symbol is a plain identifier.
    func testFindDefinitionErrorWithoutRegexSyntaxHasNoHint() async throws {
        try addUnreadableDirectory()
        for program in Program.allCases {
            try use(program)
            let result = try await findDefinition("no_such_symbol")
            XCTAssertFalse(result.contains("No definition found"), "\(program.label):\n\(result)")
            XCTAssertTrue(result.contains("Permission denied"), "\(program.label):\n\(result)")
            XCTAssertFalse(result.contains("pass a bare identifier"), "\(program.label):\n\(result)")
        }
    }

    func testFindDefinitionKeepsDefinitionsFromAnIncompleteSearch() async throws {
        try addUnreadableDirectory()
        for program in Program.allCases {
            try use(program)
            let result = try await findDefinition("clamp")
            XCTAssertTrue(result.hasPrefix("Definitions for 'clamp'"), "\(program.label):\n\(result)")
            XCTAssertTrue(result.contains("[Search incomplete"), "\(program.label):\n\(result)")
        }
    }

    // MARK: - The interpreter

    private func run(_ exitCode: Int32, out: String = "", err: String = "") -> ProcessRunner.Result {
        ProcessRunner.Result(standardOutput: out, standardError: err, exitCode: exitCode,
                             outputComplete: true, standardOutputElidedBytes: 0)
    }

    private func interpret(_ result: ProcessRunner.Result) -> SearchRunReport {
        SearchRunReport.interpret(result, program: "ripgrep", tool: "test")
    }

    func testExitZeroAndOneAreTrusted() {
        XCTAssertEqual(interpret(run(0, out: "a.py:1:x\n")), .output("a.py:1:x\n", incompleteNote: nil))
        XCTAssertEqual(interpret(run(1)), .noMatches)
        XCTAssertEqual(interpret(run(1, out: "  \n")), .noMatches)
    }

    func testAnyOtherExitWithoutOutputFails() {
        for code: Int32 in [2, 15, -1] {
            guard case .failed(let message) = interpret(run(code, err: "boom")) else {
                return XCTFail("exit \(code) without output must fail")
            }
            XCTAssertTrue(message.contains("exit \(code)"), message)
            XCTAssertTrue(message.contains("boom"), message)
        }
    }

    func testAFailureWithoutStderrSaysSo() {
        guard case .failed(let message) = interpret(run(2)) else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("ripgrep gave no reason."), message)
    }

    func testAnErrorFloodIsCapped() {
        let flood = (1...100).map { "rg: /p/\($0): Permission denied (os error 13)" }.joined(separator: "\n")
        guard case .failed(let message) = interpret(run(2, err: flood)) else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("/p/6:"), message)
        XCTAssertFalse(message.contains("/p/7:"), message)
        XCTAssertTrue(message.contains("(+94 more lines)"), message)
    }

    /// ripgrep aligns a caret under the offending character; trimming the line would move it.
    func testTheCaretLineKeepsItsIndentation() {
        let err = "rg: regex parse error:\n    (?:()\n    ^\nerror: unclosed group\n"
        guard case .failed(let message) = interpret(run(2, err: err)) else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("\n    (?:()\n    ^\n"), message)
    }
}
