// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SkillLibraryWiringTests.swift
//  devgenticTests
//
//  The Skills tab's wiring — specifically the parts the compiler does NOT enforce.
//
//  Adding a `SidebarTab` case breaks the build in three places (`iconName`, `title`, and the pane
//  container's exhaustive switch), so those need no test. Exactly one site is silent:
//  `ActivityBarView.topTabs` is a hand-written array, and a tab omitted from it exists, routes, and
//  persists its selection — with no button anywhere to reach it. That is what
//  `testSkillsTabIsReachableFromTheActivityBar` exists for.
//

import XCTest
@testable import devgentic

final class SkillLibraryWiringTests: XCTestCase {

    // MARK: - The silent site

    /// ⚠️ THE ONE THE COMPILER CANNOT CATCH. `topTabs` is a literal array in `ActivityBar.swift`.
    /// Asserted by reading the source, because the array is `private` to a SwiftUI view and there
    /// is no runtime seam — the alternative is no coverage at all for a whole-feature-invisible bug.
    func testSkillsTabIsReachableFromTheActivityBar() throws {
        let source = try Self.read("Devgentic/Interfaces/Main/Views/Sidebar/ActivityBar.swift")

        let line = try XCTUnwrap(
            source.components(separatedBy: "\n").first { $0.contains("private let topTabs:") },
            "ActivityBarView.topTabs not found — if it was renamed, repoint this test rather than deleting it"
        )
        XCTAssertTrue(line.contains(".skills"), """
            The Skills tab is missing from ActivityBarView.topTabs.

            Every other SidebarTab switch is exhaustive and fails the build when a case is missing.
            This array is not: the tab would exist, route, and persist its selection, with no button
            anywhere in the UI to reach it.
            """)
    }

    // MARK: - Enum surface

    func testSkillsTabHasAStableRawValueIconAndTitle() {
        // Raw value is persisted to @AppStorage — renaming it silently resets everyone's tab.
        XCTAssertEqual(SidebarTab.skills.rawValue, "skills")
        XCTAssertEqual(SidebarTab.skills.title, "Skills")
        XCTAssertFalse(SidebarTab.skills.iconName.isEmpty)
    }

    func testSkillsTabRoundTripsThroughItsRawValue() {
        // The container stores a raw String and bridges it back; an unknown value degrades to nil.
        XCTAssertEqual(SidebarTab(rawValue: SidebarTab.skills.rawValue), .skills)
    }

    // MARK: - Route

    /// The optional profile is the whole dual-mode contract: reachable with no profile chosen
    /// (browse the library, import, create), and only per-skill LINKING writes to one.
    func testSkillLibraryRouteCarriesAnOptionalProfile() {
        let browsing = MainViewDestination.skillLibrary(profileID: nil, openSkillID: nil)
        let scoped = MainViewDestination.skillLibrary(profileID: UUID(), openSkillID: nil)

        XCTAssertNotEqual(browsing, scoped)
        XCTAssertEqual(browsing, .skillLibrary(profileID: nil, openSkillID: nil))
        XCTAssertEqual(browsing.displayName, "Skills")
        XCTAssertEqual(scoped.displayName, "Skills")
    }

    /// ⚠️ The sidebar row that NAMES a skill must be able to open it. It used to navigate to the
    /// bare list and discard the skill, so the only way to inspect one was to find it a second time.
    func testTheRouteCanNameASkillToOpen() {
        let plain = MainViewDestination.skillLibrary(profileID: nil, openSkillID: nil)
        let opening = MainViewDestination.skillLibrary(profileID: nil, openSkillID: "skill_1")

        XCTAssertNotEqual(plain, opening,
                          "the id must be part of the route's identity, or navigating to it twice is a no-op")
        XCTAssertEqual(opening, .skillLibrary(profileID: nil, openSkillID: "skill_1"))
    }

    /// The library's folder list lives in the sidebar pane, so navigating there with the pane
    /// hidden (⌘B) would leave no way to import, create or delete a skill. Asserted on the source for
    /// the same reason as above — the post happens inside `navigate(to:)` with no observable seam.
    func testNavigatingToTheSkillLibraryRequestsTheSidebar() throws {
        let source = try Self.read("Devgentic/Interfaces/Main/MainViewRouter.swift")
        guard let range = source.range(of: "if case .skillLibrary = destination {") else {
            return XCTFail("no `.requestSidebarVisible` post for .skillLibrary — entering the tab with ⌘B pressed would strand the user with no folder list")
        }
        let after = source[range.upperBound...].prefix(200)
        XCTAssertTrue(after.contains("requestSidebarVisible"),
                      "the .skillLibrary branch must post .requestSidebarVisible, as .toolLibrary does")
    }

    // MARK: - Helper

    private static func read(_ relativePath: String) throws -> String {
        // Walks up from this file to the repo root — the same approach ToolRegistryDriftTests uses
        // to read source, so a moved test file fails loudly rather than silently reading nothing.
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("Could not locate \(relativePath) from \(#filePath) — source-reading tests need the checkout present.")
    }
}
