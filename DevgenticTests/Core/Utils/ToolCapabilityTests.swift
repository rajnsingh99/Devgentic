// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ToolCapabilityTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class ToolCapabilityTests: XCTestCase {

    // MARK: - The set matches the code

    /// The three shapes by which a tool's own argument becomes a running program. Each is
    /// anchored on `arguments.` — the tool's decoded argument struct — which is what separates
    /// "the model wrote this program" from the many sites that run a CONSTANT command through a
    /// shell (`ps -eo …`, `ioreg …`), which are not this capability and must not be flagged.
    private static let interpreterSites: [(label: String, pattern: String)] = [
        ("zsh -c <argument>",        #""-c"\s*,\s*arguments\."#),
        // ⚠️ DELEGATION, added 2026-09-22. The scan above is syntactic: it looks for a tool
        // handing ITS OWN argument to an interpreter, on one line. That premise held while every
        // shell tool spawned its own process — and broke the moment `batch_command` was split by
        // intent and the execution was centralised, because `run_command` and
        // `start_background_task` now reach `/bin/zsh` through a shared core instead of inline.
        //
        // The scan reported exactly that, correctly: three shell tools vanished from its view
        // while remaining every bit as dangerous. Following the one call shape they share keeps
        // the guarantee — "a tool that can reach a shell must declare it" — rather than narrowing
        // it to "a tool that reaches a shell ON THIS LINE".
        // `runForegroundOutcome` since D-17 (2026-09-27): `run_command` needs the outcome, not
        // the flattened string, to report a timeout or a stop as one.
        ("shared shell core",        #"(BatchCommandTool|Self)\.(runForeground(Outcome)?|startBackground)\("#),
        ("NSAppleScript(<argument>)", #"NSAppleScript\(source:\s*arguments\."#),
    ]

    func testEveryToolThatRunsItsOwnArgumentDeclaresTheCapability() throws {
        let toolsRoot = try Self.toolsRoot()
        var found: [String: String] = [:]      // tool name -> the shape that flagged it

        for file in try Self.swiftFiles(under: toolsRoot) {
            let source = try String(contentsOf: file, encoding: .utf8)
            var currentTool: String?

            for line in source.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }

                // Track which tool we are inside. Every DevgenticTool declares `let name = "…"`
                // as the first property, so the nearest one above a match owns it.
                if let name = Self.declaredToolName(in: trimmed) { currentTool = name }

                for site in Self.interpreterSites where Self.matches(site.pattern, trimmed) {
                    guard let tool = currentTool else {
                        return XCTFail("\(file.lastPathComponent): found `\(site.label)` before any "
                                       + "`let name = …` — cannot attribute it to a tool")
                    }
                    found[tool] = site.label
                }
            }
        }

        XCTAssertFalse(found.isEmpty, "the scan matched nothing — the patterns or the path are wrong")

        for (tool, shape) in found {
            XCTAssertTrue(ToolCapability.executesArbitraryCode(tool), """
                `\(tool)` runs its own argument (\(shape)) but is not in \
                `ToolCapability.arbitraryCodeExecution`. Anything reading that set — today the \
                permission banner's risk badge — will treat it as an ordinary tool. Add it, or \
                stop passing the argument to an interpreter.
                """)
        }
    }

    /// The other direction: a name in the set that no longer runs anything is just as wrong, and
    /// is how `disk_usage` would have lingered after being converted to argv. Nothing reads the
    /// set for a tool that cannot execute, so a stale entry silently over-warns forever.
    func testTheSetContainsNothingThatNoLongerExecutes() throws {
        let toolsRoot = try Self.toolsRoot()
        var executing: Set<String> = []

        for file in try Self.swiftFiles(under: toolsRoot) {
            let source = try String(contentsOf: file, encoding: .utf8)
            var currentTool: String?
            for line in source.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                if let name = Self.declaredToolName(in: trimmed) { currentTool = name }
                if Self.interpreterSites.contains(where: { Self.matches($0.pattern, trimmed) }),
                   let tool = currentTool {
                    executing.insert(tool)
                }
            }
        }

        XCTAssertEqual(ToolCapability.arbitraryCodeExecution, executing,
                       "the set and the source disagree — a name was added or a tool was fixed "
                       + "without the other being updated")
    }

    // MARK: - Classification

    /// The regression this whole change exists for: `batch_command` is the same `/bin/zsh -c` as
    /// `execute_shell`, and used to fall through to `.moderate` — a pencil icon and the word
    /// "Modifies" — because it was absent from a hand-written list.
    func testArbitraryCodeToolsAllClassifyDestructive() {
        for tool in ToolCapability.arbitraryCodeExecution {
            XCTAssertEqual(HITLRiskTier.classify(toolName: tool), .destructive, tool)
        }
        XCTAssertEqual(HITLRiskTier.classify(toolName: "batch_command"), .destructive)
    }

    /// Capability is not the same question as damage. `delete_file` is destructive and is
    /// deliberately not in the set: it does one bounded thing to a named path, and its arguments
    /// CAN be validated. The set is about arguments that cannot be bounded at all.
    func testDestructiveIsWiderThanArbitraryCode() {
        XCTAssertEqual(HITLRiskTier.classify(toolName: "delete_file"), .destructive)
        XCTAssertFalse(ToolCapability.executesArbitraryCode("delete_file"))
        XCTAssertEqual(HITLRiskTier.classify(toolName: "batch_move_files"), .destructive)
        XCTAssertEqual(HITLRiskTier.classify(toolName: "batch_move_files"), .destructive)
    }

    func testOrdinaryToolsAreUnaffected() {
        XCTAssertEqual(HITLRiskTier.classify(toolName: "read_file"), .safe)
        XCTAssertEqual(HITLRiskTier.classify(toolName: "write_file"), .moderate)
        // `.safe` since 2026-09-25: `git` is read-only by construction (mutating arguments are
        // refused before dispatch), and the Library already defaulted it to no confirmation.
        XCTAssertEqual(HITLRiskTier.classify(toolName: "git"), .safe)
        XCTAssertEqual(HITLRiskTier.classify(toolName: "some_unknown_mcp_tool"), .moderate)
        XCTAssertFalse(ToolCapability.executesArbitraryCode("git"))
        // Converted to argv on 2026-07-31; it interpolated a tool argument into `zsh -c` before
        // that, and belongs out of the set now precisely because the code changed.
        XCTAssertFalse(ToolCapability.executesArbitraryCode("get_disk_usage"))
        XCTAssertFalse(ToolCapability.executesArbitraryCode("disk_usage"))
    }

    /// The tool-side view of the same fact, so a reader looking at a tool gets the same answer
    /// as the banner does. Derived, not restated — there is only one set.
    func testToolsReportTheCapabilityThemselves() {
        XCTAssertTrue(RunCommandTool().executesArbitraryCode)
        XCTAssertTrue(BatchCommandTool().executesArbitraryCode)
        XCTAssertTrue(RunAppleScriptTool().executesArbitraryCode)
        XCTAssertFalse(GitTool().executesArbitraryCode)
        XCTAssertFalse(DiskUsageTool().executesArbitraryCode)
    }

    // MARK: - Helpers

    private static func toolsRoot() throws -> URL {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // …/Core/Utils
            .deletingLastPathComponent()    // …/Core
            .deletingLastPathComponent()    // …/DevgenticTests
            .deletingLastPathComponent()    // repo root
        let root = repoRoot.appendingPathComponent("Devgentic/Interfaces/Main/Views/Tooling")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw XCTSkip("tool sources not reachable from \(repoRoot.path) — running outside a checkout")
        }
        return root
    }

    private static func swiftFiles(under root: URL) throws -> [URL] {
        (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? [])
            .sorted { $0.path < $1.path }
    }

    private static func declaredToolName(in line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"^let name = "([a-z0-9_]+)""#),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }

    private static func matches(_ pattern: String, _ line: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }
}
