// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ToolRegistryDriftTests.swift
//  DevgenticTests
//
//  Two registries used to decide independently what a tool IS: a `switch` in
//  `AgentConnect.resolveNativeTool` (it RUNS) and a list of `registerNative(…)` calls in
//  `LocalToolManager` (it is OFFERED). 63 tools were constructed identically in both, and nothing
//  checked they agreed. The failure modes were asymmetric — a missing registration is silent
//  because the tool still works, a missing dispatch case is loud — so the drift ran one way for a
//  long time: 11 unreachable tools, 25 dispatchable tools in no picker, one struct dispatched
//  under two names, and a split whose destructive half was selectable while its harmless half was
//  not.
//
//  `NativeToolCatalog` (2026-07-31) made that structurally impossible: one list, both consumers
//  derived. So these tests changed job. They no longer reconcile two lists — they assert the
//  catalogue is still the ONLY source, and that both projections come from it. The bug they guard
//  against is not drift any more; it is someone reintroducing a second list.
//

import XCTest
@testable import devgentic

final class ToolRegistryDriftTests: XCTestCase {

    /// ⚠️⚠️ THE CATALOGUE'S DUPLICATE GUARD WAS UNTESTED, and found by mutation on 2026-09-23
    /// while withdrawing `command_status`: adding a second entry for an existing tool passed every
    /// suite, including this one.
    ///
    /// `byName` detects it and calls `assertionFailure` — which this build configuration compiles
    /// OUT, exactly as that code's own comment warns ("`assert` is compiled OUT of release builds,
    /// so a duplicate name would silently drop a tool in exactly the builds users run"). The
    /// `logger.error` fires and nothing fails.
    ///
    /// The consequence it describes is real: the map collapses, THE LATER ENTRY WINS, and the
    /// earlier tool becomes unreachable while still appearing in the source as if it were offered.
    func testNoTwoCatalogueEntriesShareAName() {
        let names = NativeToolCatalog.entries.map(\.name)
        let duplicates = Dictionary(grouping: names, by: { $0 })
            .filter { $0.value.count > 1 }
            .keys
            .sorted()
        XCTAssertTrue(duplicates.isEmpty,
                      "duplicate catalogue name(s) \(duplicates) — the byName map collapses and the "
                      + "LATER entry wins, so the earlier tool is unreachable while still reading "
                      + "as offered in the source. assertionFailure does not catch this here.")
        XCTAssertEqual(Set(names).count, names.count,
                       "entry count and unique-name count disagree")
    }

    /// Tools constructed directly by `AgentConnect` rather than from the catalogue, each built
    /// with run-scoped data a startup catalogue could not supply: `ask_user` and `final_answer`
    /// drive the ReAct loop itself, `get_conversation_history` carries the run's chat history,
    /// `load_skill` its skill manifests, and the memory tools (`remember`, `forget`, `recall`) a Code profile's project
    /// folder. Deliberately outside the catalogue — they are control-plane, not user-selectable.
    ///
    /// `get_conversation_history` was missing from this list until 2026-07-31: its
    /// `var name: String { … }` is computed, so it was invisible to the `let name = "…"` greps
    /// used to enumerate tools. Prefer the compiler over a regex when you need a complete list.
    ///
    /// ⚠️ DERIVED from `NativeToolCatalog.injectedTools` since 2026-09-20, not restated. This was
    /// the only declaration of these five anywhere, and because it lived in a test, production
    /// could not price them — all five cost 0 in the fit gauge. Moving the list into the
    /// catalogue and reading it here removes a duplicate rather than adding one.
    private static let injectedOutsideCatalog: Set<String> = NativeToolCatalog.injectedToolNames

    // MARK: - The catalogue is the only source

    /// The old dispatch `switch` must not come back. A `case "x": return wrapTool(…)` in
    /// `AgentConnect` would be a second tool list — exactly the shape that produced every tool
    /// bug in the 2026-07-31 audit.
    func testNoDispatchSwitchHasBeenReintroduced() throws {
        let source = try Self.read("Devgentic/Core/Backends/TextGen/AgentConnect.swift")
        Self.assertReadTheRightFile(source, containing: "func resolveNativeTool")
        let offenders = Self.matches(#"^case "[a-z0-9_]+":\s*return wrapTool\("#, in: source)

        XCTAssertTrue(offenders.isEmpty, """
            \(offenders.count) hand-written dispatch case(s) found in AgentConnect:

              \(offenders.joined(separator: "\n  "))

            Native tools are declared once, in `NativeToolCatalog.entries`. A `case` here is a \
            second list that nothing keeps in step with the catalogue.
            """)
    }

    /// Likewise the registration list. `LocalToolManager` is a projection of the catalogue now;
    /// a `registerNative(…)` call would make it an independent list again.
    func testNoSecondRegistrationListHasBeenReintroduced() throws {
        // ⚠️ Lowercase `utils` — that is the path git tracks. This read `Utils` until 2026-07-31
        // and only worked because the author's volume is case-insensitive APFS; on a
        // case-sensitive checkout it threw `XCTSkip` and this guard — the ONLY thing standing
        // between the codebase and a reintroduced registration list — silently checked nothing.
        let source = try Self.read("Devgentic/Interfaces/Main/Views/Tooling/Local/utils/LocalToolManager.swift")
        Self.assertReadTheRightFile(source, containing: "final class LocalToolManager")
        let offenders = Self.matches(#"registerNative\("#, in: source)

        XCTAssertTrue(offenders.isEmpty, """
            \(offenders.count) `registerNative(…)` call(s) found. The Tool Library is built from \
            `NativeToolCatalog.libraryTools`; registering a tool by hand reintroduces the second \
            list this architecture removed.
            """)
    }

    // MARK: - Both projections derive from it

    /// The Tool Library shows exactly the entries marked `.library` — no more, no fewer.
    @MainActor
    func testLibraryIsExactlyTheCatalogLibraryEntries() {
        let registered = Set(LocalToolManager.shared.availableTools().map(\.name))
        let expected = Set(NativeToolCatalog.libraryTools.map(\.name))

        XCTAssertEqual(registered, expected,
            "the Tool Library and the catalogue's `.library` entries have diverged — "
            + "missing: \(expected.subtracting(registered).sorted()), "
            + "unexpected: \(registered.subtracting(expected).sorted())")
    }

    /// Every catalogue entry resolves to a runnable tool. This is what `resolveNativeTool` does,
    /// so a lookup that returns nil for a declared tool means the catalogue can offer something
    /// the executor cannot run.
    func testEveryCatalogEntryResolves() {
        for entry in NativeToolCatalog.entries {
            XCTAssertNotNil(NativeToolCatalog.entry(named: entry.name),
                            "\(entry.name) is in `entries` but not resolvable by name")
            let tool = entry.agentTool(conversationID: UUID(), requiresConfirmation: false)
            XCTAssertEqual(tool.name, entry.name, "entry \(entry.name) built a tool named \(tool.name)")
        }
    }

    /// `byName` is built by folding `entries` into a dictionary, so two entries sharing a name
    /// would silently drop one — the `read_contacts` bug (one struct, two names) in a new form.
    /// The production code asserts this, but `assert` is compiled out of release builds.
    func testCatalogNamesAreUnique() {
        XCTAssertEqual(NativeToolCatalog.byName.count, NativeToolCatalog.entries.count,
            "duplicate tool name(s) in NativeToolCatalog — \(NativeToolCatalog.entries.count) "
            + "entries collapsed to \(NativeToolCatalog.byName.count) unique names")
    }

    /// Every entry declares a category. Required by `DevgenticTool` since 2026-07-31, but the
    /// requirement is only as good as the values: an empty string would group tools under a blank
    /// heading in the Library and nothing else would complain.
    func testEveryEntryDeclaresANonEmptyCategory() {
        let blank = NativeToolCatalog.entries.filter { $0.category.trimmingCharacters(in: .whitespaces).isEmpty }
        XCTAssertTrue(blank.isEmpty, "tools with a blank category: \(blank.map(\.name).sorted())")
    }

    /// Control-plane tools are built by `AgentConnect` with run-scoped data, so they must NOT be
    /// in the catalogue — an entry for one would be constructible without the data it needs.
    func testInjectedToolsAreNotInTheCatalog() {
        let leaked = Self.injectedOutsideCatalog.filter { NativeToolCatalog.entry(named: $0) != nil }
        XCTAssertTrue(leaked.isEmpty, """
            \(leaked.sorted()) are in the catalogue but are injected by `AgentConnect` with \
            run-scoped data (chat history, skill manifests, a project folder). A catalogue entry \
            cannot supply that, so it would build a differently-configured tool.
            """)
    }

    // MARK: - Non-vacuity

    /// A test that reads an empty catalogue satisfies every assertion above while checking
    /// nothing — the failure mode that made the original source guard worth so little. The floor
    /// is far below the real count (73 as of 2026-09-15) so ordinary tool removals do not trip it.
    func testTheCatalogIsNotEmpty() {
        XCTAssertGreaterThan(NativeToolCatalog.entries.count, 40,
            "only \(NativeToolCatalog.entries.count) catalogue entries — the assertions above are "
            + "passing vacuously")
        XCTAssertNotNil(NativeToolCatalog.entry(named: "read_file"), "a known tool is missing")
    }


    /// A source-scanning guard that reads the WRONG file passes every assertion while checking
    /// nothing — the vacuous pass this file exists to avoid. `read` throws `XCTSkip` when a path
    /// is unreachable, which is right for a packaged bundle but indistinguishable from a typo, so
    /// each scan also proves it got the file it meant.
    private static func assertReadTheRightFile(_ source: String, containing anchor: String,
                                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(source.contains(anchor),
                      "scanned a file that does not contain '\(anchor)' — wrong path, so the "
                      + "assertions below are checking nothing",
                      file: file, line: line)
    }

    // MARK: - Source access

    private static func read(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Local
            .deletingLastPathComponent()   // Tooling
            .deletingLastPathComponent()   // Views
            .deletingLastPathComponent()   // Main
            .deletingLastPathComponent()   // Interfaces
            .deletingLastPathComponent()   // DevgenticTests
            .deletingLastPathComponent()   // repo root
        let url = repoRoot.appendingPathComponent(relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("\(relativePath) not reachable — running outside a checkout")
        }
        return text
    }

    /// Non-comment lines matching `pattern`. Comments are skipped so the notes explaining what
    /// was removed — and this file's own prose — cannot be read as live code.
    private static func matches(_ pattern: String, in source: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return source.components(separatedBy: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { return nil }
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            return regex.firstMatch(in: trimmed, range: range) != nil ? trimmed : nil
        }
    }
}
