// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  MLXStoreSearchRoutingTests.swift
//  DevgenticTests
//
//  The MLX store's search box did nothing on the Recommended tab — the one a first run with
//  no installed models lands on — while its placeholder read "Search Hugging Face...".
//  `refreshCategoryData` serves `.recommended` entirely locally and issues no request, and
//  `filterAndSortModels` skipped the client-side filter for every non-installed tab, so a
//  keystroke there produced neither a remote answer nor a local one. A query is now routed to
//  `.all`, which does issue the request.
//

import XCTest
@testable import devgentic

// MARK: - The routing rule

final class MLXStoreSearchRoutingTests: XCTestCase {

    private typealias VM = MLXModelStoreViewModel
    private typealias Category = MLXModelStoreViewModel.StoreCategory

    /// Mutation that must turn this red: return `nil` for the `.recommended` + query case.
    func testAQueryOnRecommendedMovesToATabThatCanAnswerIt() {
        XCTAssertEqual(
            VM.searchDestination(from: .recommended, query: "qwen", autoLeftRecommended: false),
            .all,
            "Recommended is served from CuratedMLXCatalog and issues no HuggingFace request, so a query typed there must move somewhere that does — otherwise it is silently dropped."
        )
    }

    func testAnEmptyQueryLeavesRecommendedAlone() {
        XCTAssertNil(VM.searchDestination(from: .recommended, query: "", autoLeftRecommended: false))
    }

    /// Whitespace is not a query. Without this, clearing a field down to a stray space would
    /// strand the user on `.all` with nothing to show for it.
    func testWhitespaceIsNotAQuery() {
        XCTAssertNil(VM.searchDestination(from: .recommended, query: "   ", autoLeftRecommended: false))
        XCTAssertNil(VM.searchDestination(from: .recommended, query: "\n\t ", autoLeftRecommended: false))
    }

    /// Clearing the box undoes a move the user never asked for.
    func testClearingTheQueryReturnsTheUserToRecommended() {
        XCTAssertEqual(
            VM.searchDestination(from: .all, query: "", autoLeftRecommended: true),
            .recommended
        )
    }

    /// ⚠️ The return trip is guarded on the flag, not just on emptiness. A user who reached
    /// `.all` by clicking the tab must stay there when they clear the box.
    func testClearingDoesNotHijackATabTheUserPickedThemselves() {
        XCTAssertNil(VM.searchDestination(from: .all, query: "", autoLeftRecommended: false))
    }

    /// ⚠️ Guarded on `.all` as well as the flag, so a stale flag cannot bounce the user out of
    /// some third tab they navigated to while the search was still live.
    func testAStaleFlagCannotEjectTheUserFromAnUnrelatedTab() {
        for category: Category in [.vision, .toolUse, .installed] {
            XCTAssertNil(
                VM.searchDestination(from: category, query: "", autoLeftRecommended: true),
                "a stale auto-switch flag must not move the user off \(category.rawValue)"
            )
        }
    }

    /// Every other tab already answers its own query — remotely, or locally for `.installed`.
    func testEveryOtherTabHandlesItsOwnQueryInPlace() {
        for category: Category in [.all, .installed, .vision, .toolUse] {
            XCTAssertNil(
                VM.searchDestination(from: category, query: "qwen", autoLeftRecommended: false),
                "\(category.rawValue) answers its own query and must not be redirected"
            )
        }
    }

    /// The rule must be total: no input may trap the user in a switch that immediately reverses.
    func testTheRuleNeverOscillates() {
        for category in Category.allCases {
            for query in ["", "qwen"] {
                for flag in [true, false] {
                    guard let first = VM.searchDestination(from: category, query: query, autoLeftRecommended: flag) else { continue }
                    let flagAfter = (first == .all)
                    XCTAssertNil(
                        VM.searchDestination(from: first, query: query, autoLeftRecommended: flagAfter),
                        "\(category.rawValue) + \"\(query)\" routed to \(first.rawValue), which routes onward again"
                    )
                }
            }
        }
    }
}

// MARK: - The wiring
//
// ⚠️ THE RULE ABOVE IS INERT UNLESS SOMETHING CALLS IT. These read the source because the view
// model cannot be built in a test: `init` touches `MLXModelService.shared` and `refreshCategoryData`
// issues a real request to huggingface.co, and a unit test must not do that.
//
// ⚠️ A MISSING FILE FAILS HERE, it does not skip. A drift test that guards a path and then skips
// when the path moves reports success while its coverage silently disappears.

final class MLXStoreSearchWiringTests: XCTestCase {

    private static let viewModelPath =
        "Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelStoreViewModel.swift"

    /// Mutation that must turn this red: point `searchText`'s debounce back at
    /// `refreshCategoryData` directly, bypassing the routing rule.
    func testTheSearchFieldRoutesThroughTheRoutingRule() throws {
        let code = try Self.source(Self.viewModelPath)

        XCTAssertTrue(code.contains("self.applySearchChange()"), """
            The debounced search handler must call applySearchChange(). Calling refreshCategoryData \
            directly is the original defect: on .recommended that serves the curated list locally \
            and answers no query.
            """)
        XCTAssertTrue(code.contains("Self.searchDestination("),
                      "applySearchChange must consult the routing rule")
        XCTAssertTrue(code.contains("selectedCategory = destination"),
                      "the routing rule's answer must actually move the tab, or it is advice nobody takes")
    }

    /// Mutation that must turn this red: restore `|| !isRemoteSearchEnabled`.
    func testTheDeadRemoteSearchToggleDoesNotComeBack() throws {
        let code = try Self.source(Self.viewModelPath)

        XCTAssertFalse(code.contains("var isRemoteSearchEnabled"), """
            isRemoteSearchEnabled was initialised true and assigned nowhere in the repo. While it \
            existed, `filtersLocally = category == .installed || !isRemoteSearchEnabled` was \
            permanently false for .recommended, which is half of why typing there did nothing.
            """)
        XCTAssertTrue(code.contains("let filtersLocally = category == .installed"), """
            Only .installed filters client-side. Any additional disjunct here re-opens the gap \
            where a tab neither queries HuggingFace nor filters locally.
            """)
    }

    /// The placeholder promises a HuggingFace search on every tab but `.installed`; that promise
    /// is only true because a query on `.recommended` is routed away.
    func testThePlaceholderStillPromisesWhatTheRoutingNowDelivers() throws {
        let code = try Self.source(
            "Devgentic/Interfaces/Main/Views/BackendProfile/MlxLLM/MLXModelStoreView.swift")

        XCTAssertTrue(code.contains("Search Hugging Face..."), """
            If this copy changes, re-check the routing rule: the rule exists to make this exact \
            promise true on the Recommended tab.
            """)
    }

    // MARK: - Helper

    private static func source(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)   // …/DevgenticTests/Core/Service/<this>
            .deletingLastPathComponent()                 // …/Core/Service
            .deletingLastPathComponent()                 // …/Core
            .deletingLastPathComponent()                 // …/DevgenticTests
            .deletingLastPathComponent()                 // repo root
        // ⚠️ Only a repo root that is itself unreachable is a legitimate skip (running outside a
        // checkout). A missing FILE is a rename that took this coverage with it — fail loudly.
        guard FileManager.default.fileExists(atPath: repoRoot.path) else {
            throw XCTSkip("repo root not reachable from \(#filePath) — running outside a checkout")
        }
        let url = repoRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("\(relativePath) no longer exists. A drift test guards this file by path; if the code moved, repoint this test rather than letting the guard go silent.")
            return ""
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
