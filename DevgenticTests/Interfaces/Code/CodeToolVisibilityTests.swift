//
//  CodeToolVisibilityTests.swift
//  DevgenticTests
//
//  "Who sees this tool?" used to be answered in three places: `NativeToolCatalog` (does it exist),
//  `LocalToolManager` (is it in the Library), and a `Set` literal in `CodeToolPreset` (is it
//  hidden for Code). The third listed five names with the reason for each in a comment above the
//  list rather than beside the tool, so the fact that `edit_code` is hidden *because*
//  `edit_code_single`/`edit_code_batch` replaced it was not discoverable from either tool.
//
//  As of 2026-07-31 the catalogue answers all three. These tests pin the derivation — including a
//  parity check against the exact set the hand-written literal produced, because a refactor that
//  quietly changes which tools a Code profile sees is worse than the duplication it removed.
//

import XCTest
@testable import devgentic

final class CodeToolVisibilityTests: XCTestCase {

    /// The five tools the preset supersedes, as the removed `Set` literal spelled them. Pinned
    /// verbatim: this is the one assertion that would catch the derivation silently changing what
    /// a Code profile sees.
    private static let supersededByPreset: Set<String> = [
        "edit_code", "code_search", "create_file", "write_file", "execute_shell",
    ]

    func testHiddenSetStillMatchesTheHandWrittenLiteral() {
        let expected = Set(CodeToolPreset.defaultTools.map(\.name)).union(Self.supersededByPreset)
        XCTAssertEqual(CodeToolPreset.hiddenToolNames, expected, """
            the derived hidden set no longer matches what the old literal produced — \
            missing: \(expected.subtracting(CodeToolPreset.hiddenToolNames).sorted()), \
            unexpected: \(CodeToolPreset.hiddenToolNames.subtracting(expected).sorted())
            """)
    }

    /// The superseded group comes from the catalogue now, so the catalogue must actually carry it.
    func testCatalogCarriesTheSupersededGroup() {
        XCTAssertEqual(NativeToolCatalog.hiddenFromCodeLibrary, Self.supersededByPreset)
    }

    /// Each superseded tool names its replacement. A blank reason would let the group survive
    /// while losing the thing that made moving it worthwhile.
    func testEverySupersededToolNamesItsReplacement() {
        for name in Self.supersededByPreset {
            guard let entry = NativeToolCatalog.entry(named: name) else {
                return XCTFail("\(name) is not in the catalogue")
            }
            guard case .libraryExceptCode(let supersededBy) = entry.visibility else {
                return XCTFail("\(name) should be .libraryExceptCode, got \(entry.visibility)")
            }
            XCTAssertFalse(supersededBy.trimmingCharacters(in: .whitespaces).isEmpty,
                           "\(name) is hidden for Code profiles without saying what replaces it")
        }
    }

    /// Superseded tools are still ordinary Library tools for Chat and Workflow profiles — being
    /// superseded is a fact about the Code interface, not about the tool.
    @MainActor
    func testSupersededToolsRemainInTheLibraryForOtherProfiles() {
        let registered = Set(LocalToolManager.shared.availableTools().map(\.name))
        for name in Self.supersededByPreset {
            XCTAssertTrue(registered.contains(name),
                          "\(name) must stay in the Library — only CODE profiles hide it")
        }
    }

    /// The intent-splits are absent from the Library entirely, which is what makes hiding their
    /// originals coherent: a Code profile sees exactly one shape per intent.
    @MainActor
    func testCodeOnlySplitsAreNotInTheLibrary() {
        let registered = Set(LocalToolManager.shared.availableTools().map(\.name))
        let codeOnly = Set(NativeToolCatalog.codeOnlyTools.map(\.name))

        XCTAssertFalse(codeOnly.isEmpty, "no .codeOnly entries — the split tools lost their marking")
        XCTAssertTrue(codeOnly.isDisjoint(with: registered),
                      "code-only tools leaked into the Library: \(codeOnly.intersection(registered).sorted())")
    }

    /// A Code profile must end up with one shape per intent: the preset's narrow tools, and none
    /// of the broad originals they replaced.
    func testCodeProfileSeesNoSupersededOriginal() {
        let presetNames = Set(CodeToolPreset.defaultTools.map(\.name))
        XCTAssertTrue(presetNames.isDisjoint(with: Self.supersededByPreset),
                      "the preset itself supplies a tool it also supersedes")
        for name in Self.supersededByPreset {
            XCTAssertTrue(CodeToolPreset.hiddenToolNames.contains(name), "\(name) is not hidden for Code")
        }
    }
}
