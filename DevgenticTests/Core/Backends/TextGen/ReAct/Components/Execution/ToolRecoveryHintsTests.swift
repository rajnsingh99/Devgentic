// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ToolRecoveryHintsTests.swift
//  DevgenticTests
//
//  `ToolRecoveryHints.enrich` runs on EVERY failed tool call — both the semantic-failure branch
//  and the thrown-error branch of `ToolExecutionMediator.executePreparedTool` — and it REWRITES
//  the observation the model then reasons on. Until now it had no tests at all.
//
//  Its own header states five safety guarantees, and each is load-bearing in a different way:
//  self-exclusion stops a retry loop, available-intersection stops the tool inventing a call the
//  model cannot make, and the empty-suggestion fallback is explicitly there because "inventing a
//  suggestion for a tool the model can't call would cause hallucination — the exact failure mode
//  we're trying to prevent." A guard written to prevent hallucination, which was itself unverified.
//

import XCTest
@testable import devgentic

final class ToolRecoveryHintsTests: XCTestCase {

    /// Every tool the registry can suggest, as far as these tests are concerned.
    private let allTools: Set<String> = [
        "list_directory", "glob_files", "codebase_map", "code_search", "code_search_text",
        "read_file", "file_overview", "preview_file", "overwrite_file", "edit_code_single",
        "edit_code", "edit_code_batch", "move_file", "copy_file", "delete_file", "create_file",
        "create_new_file",
    ]

    // MARK: - Enrichment happens when it should

    func testEnrich_MatchingToolAndPattern_AppendsSuggestions() {
        let original = "Error: File not found at '/tmp/missing.txt'"
        let enriched = ToolRecoveryHints.enrich(
            toolName: "read_file",
            originalError: original,
            availableToolNames: allTools
        )

        XCTAssertTrue(enriched.hasPrefix(original),
                      "the original error must be preserved verbatim, not replaced: \(enriched)")
        XCTAssertTrue(enriched.contains("Try these available tools to recover:"))
        XCTAssertTrue(enriched.contains("list_directory"))
        XCTAssertTrue(enriched.contains("Do NOT retry the same call"),
                      "the anti-retry instruction is the point of the hint")
    }

    // MARK: - Enrichment must NOT happen

    func testEnrich_UnregisteredTool_ReturnsOriginalUnchanged() {
        // MCP tools and anything not in the registry must pass through untouched — `enrich` is
        // called on every failure, so a false match would corrupt unrelated observations.
        let original = "Error: File not found"
        XCTAssertEqual(
            ToolRecoveryHints.enrich(toolName: "some_mcp_tool",
                                     originalError: original,
                                     availableToolNames: allTools),
            original
        )
    }

    func testEnrich_RegisteredToolButUnrecognisedError_ReturnsOriginalUnchanged() {
        let original = "Error: the disk caught fire"
        XCTAssertEqual(
            ToolRecoveryHints.enrich(toolName: "read_file",
                                     originalError: original,
                                     availableToolNames: allTools),
            original
        )
    }

    /// The anti-hallucination guard, quoted from the source: suggesting a tool the model cannot
    /// call is the failure this whole mechanism exists to prevent.
    func testEnrich_NoSuggestedToolAvailable_ReturnsOriginalUnchanged() {
        let original = "Error: File not found at '/tmp/x'"
        let enriched = ToolRecoveryHints.enrich(
            toolName: "read_file",
            originalError: original,
            availableToolNames: ["execute_shell"]   // none of read_file's suggestions
        )
        XCTAssertEqual(enriched, original,
                       "suggesting a tool the model cannot call is worse than no suggestion")
    }

    func testEnrich_OnlySuggestsToolsThatAreAvailable() {
        let enriched = ToolRecoveryHints.enrich(
            toolName: "read_file",
            originalError: "Error: File not found",
            availableToolNames: ["glob_files"]      // one of several mapped suggestions
        )
        XCTAssertTrue(enriched.contains("glob_files"))
        XCTAssertFalse(enriched.contains("list_directory"),
                       "a tool absent from this request must never be suggested")
        XCTAssertFalse(enriched.contains("codebase_map"))
    }

    // MARK: - Self-exclusion (anti-loop)

    /// A hint that suggests the tool that just failed would send the model straight back into the
    /// same call. `create_file`'s "File already exists" maps to `read_file`, so the clearest
    /// probe is a tool whose own name appears among its mapped suggestions.
    func testEnrich_NeverSuggestsTheToolThatJustFailed() {
        for toolName in ["read_file", "edit_code", "list_directory", "glob_files",
                         "code_search", "codebase_map", "file_overview", "create_file"] {
            for errorText in ["File not found", "old_string not found", "File already exists",
                              "does not exist", "matches"] {
                let enriched = ToolRecoveryHints.enrich(
                    toolName: toolName,
                    originalError: "Error: \(errorText)",
                    availableToolNames: allTools
                )
                guard enriched.contains("Try these available tools") else { continue }

                let suggestionLines = enriched
                    .components(separatedBy: "\n")
                    .filter { $0.hasPrefix("  - ") }
                for line in suggestionLines {
                    let suggested = line.dropFirst(4).prefix { $0 != ":" }
                    XCTAssertNotEqual(String(suggested), toolName,
                                      "\(toolName) was told to retry itself for '\(errorText)' — a loop")
                }
            }
        }
    }

    // MARK: - Bounded output

    func testEnrich_CapsSuggestionsAtThree() {
        // read_file/"File not found" maps to four tools; only three may be rendered.
        let enriched = ToolRecoveryHints.enrich(
            toolName: "read_file",
            originalError: "Error: File not found",
            availableToolNames: allTools
        )
        let suggestionCount = enriched.components(separatedBy: "\n").filter { $0.hasPrefix("  - ") }.count
        XCTAssertEqual(suggestionCount, 3, "menu-paralysis cap is 3")
    }

    // MARK: - Ordering

    /// The registry is scanned linearly and the first match wins, so rows must be ordered
    /// most-specific-first. `edit_code`'s "old_string matches" precedes "old_string not found";
    /// an error containing BOTH substrings must resolve to the earlier row.
    func testEnrich_FirstMatchingRowWins() {
        let enriched = ToolRecoveryHints.enrich(
            toolName: "edit_code",
            originalError: "Error: old_string matches 3 locations",
            availableToolNames: allTools
        )
        XCTAssertTrue(enriched.contains("read_file"))
        XCTAssertFalse(enriched.contains("code_search"),
                       "the 'matches' row maps to read_file only; a later row must not win")
    }

    // MARK: - Registry drift

    /// Every tool name in the registry must be a tool that actually exists.
    ///
    /// The suggestions are filtered against the request's available set at runtime, so a stale
    /// name fails SILENTLY — the hint simply stops firing and nobody notices the recovery path
    /// went missing. This codebase has been bitten by exactly that shape before (`read_contacts`
    /// dispatched under two names; 25 tools registered nowhere), which is why it is checked
    /// against the catalogue rather than trusted.
    func testRegistry_NamesEveryToolThatStillExists() throws {
        // Eight components: the filename, then the seven directories back to the repo root.
        // Counted rather than eyeballed — an off-by-one here does not fail, it makes the scan
        // find nothing.
        var repoRoot = URL(fileURLWithPath: #filePath)   // …/DevgenticTests/Core/Backends/TextGen/ReAct/Components/Execution/<this file>
        for _ in 0..<8 { repoRoot.deleteLastPathComponent() }

        let source = repoRoot.appendingPathComponent(
            "Devgentic/Core/Backends/TextGen/ReAct/Components/Execution/ToolRecoveryHints.swift")

        // FAILS rather than skips when the source cannot be read.
        //
        // `ToolRegistryDriftTests` shipped with an `XCTSkip` here and a path whose case did not
        // match what git tracked, so on a case-sensitive checkout the only guard against a
        // reintroduced registration list quietly disabled itself and reported success. A drift
        // test that opts out when it cannot do its job is worse than no drift test, because the
        // green tick says otherwise.
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            XCTFail("""
                Could not read ToolRecoveryHints.swift at \(source.path). This scan is the only \
                thing checking the hint registry against the tool catalogue — it must not pass \
                by skipping. Fix the path.
                """)
            return
        }

        // Hint(toolName: "x", errorSubstring: "…", suggestions: ["a", "b"])
        let hintPattern = try NSRegularExpression(
            pattern: #"Hint\(toolName:\s*"([^"]+)",\s*errorSubstring:\s*"[^"]*",\s*suggestions:\s*\[([^\]]*)\]"#)
        let matches = hintPattern.matches(in: text, range: NSRange(text.startIndex..., in: text))

        XCTAssertGreaterThan(matches.count, 10,
                             "parsed only \(matches.count) hints — the scan would pass vacuously")

        var referenced = Set<String>()
        for match in matches {
            guard let toolRange = Range(match.range(at: 1), in: text),
                  let listRange = Range(match.range(at: 2), in: text) else { continue }
            referenced.insert(String(text[toolRange]))
            for raw in text[listRange].components(separatedBy: ",") {
                let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \"\n\t"))
                if !name.isEmpty { referenced.insert(name) }
            }
        }

        let unknown = referenced.filter { NativeToolCatalog.entry(named: $0) == nil }.sorted()
        XCTAssertTrue(unknown.isEmpty, """
            ToolRecoveryHints names tools that no longer exist: \(unknown).
            Suggestions are filtered against the request's available tools at runtime, so a stale \
            name does not error — the recovery hint just silently stops firing.
            """)
    }
}
