// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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

    /// In Code interface mode, Profiles and Scheduler tabs must be hidden.
    /// In Chat and Workflow interface modes, all sidebar tabs must remain visible.
    func testSidebarTabVisibilityPerInterfaceMode() {
        // In Code mode, Profiles and Scheduler must be hidden
        XCTAssertFalse(SidebarTab.backendProfiles.isVisible(in: .code))
        XCTAssertFalse(SidebarTab.scheduler.isVisible(in: .code))
        XCTAssertTrue(SidebarTab.conversations.isVisible(in: .code))
        XCTAssertTrue(SidebarTab.explorer.isVisible(in: .code))
        XCTAssertTrue(SidebarTab.promptLibrary.isVisible(in: .code))
        XCTAssertTrue(SidebarTab.tools.isVisible(in: .code))
        XCTAssertTrue(SidebarTab.skills.isVisible(in: .code))
        XCTAssertTrue(SidebarTab.settings.isVisible(in: .code))

        // In Chat and Workflow modes, all tabs must be visible
        for mode in [MainApplicationViewModel.InterfaceMode.chat, .workflow] {
            XCTAssertTrue(SidebarTab.backendProfiles.isVisible(in: mode))
            XCTAssertTrue(SidebarTab.scheduler.isVisible(in: mode))
            XCTAssertTrue(SidebarTab.conversations.isVisible(in: mode))
            XCTAssertTrue(SidebarTab.explorer.isVisible(in: mode))
            XCTAssertTrue(SidebarTab.skills.isVisible(in: mode))
        }
    }

    // MARK: - Route

    /// The optional profile is the whole dual-mode contract: reachable with no profile chosen
    /// (browse the library, import, create), and only per-skill LINKING writes to one.
    func testSkillLibraryRouteCarriesAnOptionalProfile() {
        let browsing = MainViewDestination.skillLibrary(profileID: nil)
        let scoped = MainViewDestination.skillLibrary(profileID: UUID())

        XCTAssertNotEqual(browsing, scoped)
        XCTAssertEqual(browsing, .skillLibrary(profileID: nil))
        XCTAssertEqual(browsing.displayName, "Skills")
        XCTAssertEqual(scoped.displayName, "Skills")
    }

    /// ⚠️ The sidebar row that NAMES a skill must be able to open it. It used to navigate to the
    /// bare list and discard the skill, so the only way to inspect one was to find it a second time.
    /// ⚠️ REWRITTEN for the route split. Naming a skill used to be an optional field on the library
    /// route, which made one destination mean two screens — `(profile, nil)` the link surface,
    /// `(nil, id)` a detail, `(profile, id)` undefined — in a router whose push/replace decision
    /// keys on destination identity. Editing a skill is its own screen, so it is its own case.
    func testTheRouteCanNameASkillToOpen() {
        let plain = MainViewDestination.skillLibrary(profileID: nil)
        let opening = MainViewDestination.skillDetail(skillID: "skill_1")

        XCTAssertNotEqual(plain, opening,
                          "the id must be part of the route's identity, or navigating to it twice is a no-op")
        XCTAssertEqual(opening, .skillDetail(skillID: "skill_1"))
    }

    /// The library's folder list lives in the sidebar pane, so navigating there with the pane
    /// hidden (⌘B) would leave no way to import, create or delete a skill. Asserted on the source for
    /// the same reason as above — the post happens inside `navigate(to:)` with no observable seam.
    func testNavigatingToTheSkillLibraryRequestsTheSidebar() throws {
        let source = try Self.read("Devgentic/Interfaces/Main/MainViewRouter.swift")
        guard let range = source.range(of: "if destination.isSkillsSurface {") else {
            return XCTFail("no `.requestSidebarVisible` post for the skills surface — entering it with ⌘B pressed would strand the user with no skill list")
        }
        let after = source[range.upperBound...].prefix(200)
        XCTAssertTrue(after.contains("requestSidebarVisible"),
                      "the skills-surface branch must post .requestSidebarVisible, as .toolLibrary does — and it must cover the DETAIL too, or arriving there with the pane hidden leaves no way back to the library")
    }

    /// Verifies that when the skills sidebar is empty, it prompts the user to import skills.
    func testSkillNavigationPaneEmptyStatePresentsImportSkill() throws {
        let source = try Self.read("Devgentic/Interfaces/Main/Views/Skills/SkillNavigationPane.swift")
        guard let emptyStateRange = source.range(of: "private var emptyState: some View {") else {
            return XCTFail("emptyState not found in SkillNavigationPane.swift")
        }
        let block = source[emptyStateRange.lowerBound...].prefix(400)
        XCTAssertTrue(block.contains("buttonTitle: \"Import Skill\""), "Empty state button must offer Import Skill rather than New Skill")
        XCTAssertTrue(block.contains("showingImport = true"), "Empty state action must trigger import sheet")
    }

    /// Verifies that SkillDetailView wires a preview toggle and renders via WorkflowMarkdownView.
    func testSkillDetailViewWiredWithMarkdownPreview() throws {
        let source = try Self.read("Devgentic/Interfaces/Main/Views/Skills/SkillDetailView.swift")
        XCTAssertTrue(source.contains("isPreviewMode"), "SkillDetailView must track preview state")
        XCTAssertTrue(source.contains("isPreviewEnabled"), "SkillDetailView must guard preview mode based on content")
        XCTAssertTrue(source.contains("WorkflowMarkdownView(text: draft.body)"), "SkillDetailView must use WorkflowMarkdownView for rendering")
        XCTAssertTrue(source.contains("skills.instructions.preview"), "SkillDetailView must include preview button identifier")
    }

    /// Verifies that ActivityBarView filters its visible tabs and reacts to interface mode changes.
    func testActivityBarFiltersTabsForCodeMode() throws {
        let source = try Self.read("Devgentic/Interfaces/Main/Views/Sidebar/ActivityBar.swift")
        XCTAssertTrue(source.contains("visibleTopTabs"), "ActivityBarView must filter tabs for current interface mode")
        XCTAssertTrue(source.contains("isVisible(in:"), "ActivityBarView must use isVisible(in:) to filter visible tabs")
        XCTAssertTrue(source.contains("ensureValidSelectedTab"), "ActivityBarView must revalidate selected tab when mode changes")
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

// MARK: - Stack hygiene on the skills surface

/// ⚠️⚠️ THE GUARD THAT ONLY EVER COVERED CLICKING THE SAME ROW TWICE.
///
/// `navigate(to:)` replaced only when the destination was IDENTICAL. `openSkillID` is part of a
/// destination's identity — it must be, or routing to a second skill would be a no-op — so skill A
/// then B then C were three different destinations and pushed three stack entries. Back then walked
/// the user A←B←C through screens they experienced as one. The comment above that guard read as
/// though it covered exactly this case; it did not.
@MainActor
final class SkillRouteStackHygieneTests: XCTestCase {

    /// **Mutation check:** restore `guard destination != activeDestination` and this goes red.
    func testWalkingSkillToSkillDoesNotStackAnEntryEachTime() {
        let router = MainViewRouter()
        router.navigate(to: .skillLibrary(profileID: nil))
        let afterList = router.navigationStack.count

        router.navigate(to: .skillDetail(skillID: "skill_a"))
        let afterFirstDetail = router.navigationStack.count

        router.navigate(to: .skillDetail(skillID: "skill_b"))
        router.navigate(to: .skillDetail(skillID: "skill_c"))

        XCTAssertEqual(router.navigationStack.count, afterFirstDetail,
                       "detail → detail is one screen whose contents changed — it must REPLACE, not stack an entry per click")
        XCTAssertGreaterThan(afterFirstDetail, afterList,
                            "…while list → detail must still PUSH, or Back cannot mean 'back to the list'")
    }

    /// ⚠️ THE ASYMMETRY IS THE POINT. A blanket same-case rule would collapse the descent too, and
    /// Back would pop straight past the library to whatever preceded it.
    func testBackFromASkillReturnsToTheLibraryRatherThanSkippingIt() {
        let router = MainViewRouter()
        router.navigate(to: .skillLibrary(profileID: nil))
        router.navigate(to: .skillDetail(skillID: "skill_a"))
        router.navigate(to: .skillDetail(skillID: "skill_b"))

        router.goBack()

        guard case .skillLibrary = router.activeDestination else {
            return XCTFail("Back from a skill detail must land on the LIBRARY, not on the previous skill — got \(router.activeDestination)")
        }
    }

    /// The control: an unrelated destination still pushes. A lateral rule that returned true too
    /// often would silently stop the stack growing anywhere.
    func testLeavingTheSkillsSurfaceStillPushes() {
        let router = MainViewRouter()
        router.navigate(to: .skillDetail(skillID: "skill_a"))
        let before = router.navigationStack.count
        router.navigate(to: .downloadManager)
        XCTAssertGreaterThan(router.navigationStack.count, before,
                            "moving to a different surface is a descent and must be reversible")
    }

    /// Verifies the full round-trip navigation from an Agent Profile to Manage Skills,
    /// into a Skill Detail, and backing out step-by-step to the Agent Profile.
    func testNavigationFlowFromAgentProfileToLibraryToDetailAndBack() {
        let router = MainViewRouter()
        let agentID = UUID()

        // 1. Arrive at Agent Profile
        router.navigate(to: .profileDetail(profileID: agentID))
        XCTAssertEqual(router.activeDestination, .profileDetail(profileID: agentID))

        // 2. Click "Manage Skills" -> opens Skill Library pinned to agentID
        router.navigate(to: .skillLibrary(profileID: agentID))
        XCTAssertEqual(router.activeDestination, .skillLibrary(profileID: agentID))

        // 3. Click into a Skill Detail
        router.navigate(to: .skillDetail(skillID: "capstone-build-coach"))
        XCTAssertEqual(router.activeDestination, .skillDetail(skillID: "capstone-build-coach"))

        // 4. First Back: pops Skill Detail, lands on Skill Library with agentID preserved
        router.goBack()
        guard case .skillLibrary(let returnedProfileID) = router.activeDestination else {
            return XCTFail("First back must return to Skill Library — got \(router.activeDestination)")
        }
        XCTAssertEqual(returnedProfileID, agentID, "Profile ID must be preserved when returning to library")

        // 5. Second Back: pops Skill Library, lands on Agent Profile
        router.goBack()
        guard case .profileDetail(let returnedAgentID) = router.activeDestination else {
            return XCTFail("Second back must return to Profile Detail — got \(router.activeDestination)")
        }
        XCTAssertEqual(returnedAgentID, agentID, "Agent ID must be preserved when returning to profile")
    }
}

// MARK: - The test host must not write real user data

/// ⚠️⚠️ THIS WAS FOUND BY A TEST RUN CHANGING THE DEVELOPER'S OWN SAVED SIDEBAR TAB.
///
/// `announceArrival` writes `SidebarTab.storageKey` so that arriving at a skills screen selects the
/// Skills pane. The test host IS the app, so every test that called `navigate(to: .skillLibrary…)`
/// wrote that key in the REAL user defaults — and the next host launch then BOOTED into the Skills
/// screen, whose live views hold `SkillSD` objects. Any test that swapped `SkillStore`'s container
/// left those views dereferencing models destroyed by `ModelContext.reset`, which killed the host
/// mid-suite and reported as an unrelated crash.
///
/// A per-test override is not enough here, precisely because the write happens somewhere no test
/// explicitly calls — so the guard keys on `TestHost.isRunning` itself.
@MainActor
final class SkillRouterTestHostSideEffectTests: XCTestCase {

    /// **Mutation check:** delete the `guard !TestHost.isRunning` and this goes red — the assertion
    /// runs IN the test host, so it observes the real write.
    func testNavigatingDoesNotWriteTheRealSidebarTabFromTheTestHost() {
        let key = SidebarTab.storageKey
        let before = UserDefaults.standard.string(forKey: key)

        MainViewRouter().navigate(to: .skillLibrary(profileID: nil))

        XCTAssertEqual(UserDefaults.standard.string(forKey: key), before,
                       "a test run must not change which sidebar tab the user sees — the test host is the real app, and this key is real user data")
    }

    /// The same for the detail, which shares the side effect through `isSkillsSurface`.
    func testNavigatingToASkillDetailDoesNotWriteTheRealSidebarTabEither() {
        let key = SidebarTab.storageKey
        let before = UserDefaults.standard.string(forKey: key)

        MainViewRouter().navigate(to: .skillDetail(skillID: "skill_whatever"))

        XCTAssertEqual(UserDefaults.standard.string(forKey: key), before)
    }

    /// The control: the gate must not disable the PANE request as well. Refusing the tab write is
    /// right; refusing to reveal the sidebar would make the guard a silent feature-killer that no
    /// test would notice, because the pane is invisible to assertions.
    func testTheSidebarRevealIsStillRequested() throws {
        let source = try Self.read("Devgentic/Interfaces/Main/MainViewRouter.swift")
        let gate = try XCTUnwrap(source.range(of: "guard !TestHost.isRunning else { return }"))
        let post = try XCTUnwrap(source.range(of: "NotificationCenter.default.post(name: .requestSidebarVisible"))
        XCTAssertTrue(post.lowerBound < gate.lowerBound,
                      "the pane request must happen BEFORE the test-host gate — gating it too would hide the sidebar for real users on every arrival")
    }

    private static func read(_ relativePath: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("Could not locate \(relativePath) from \(#filePath).")
    }
}
