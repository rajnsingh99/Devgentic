// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  PanelExclusivityTests.swift
//  DevgenticTests
//
//  The Code Viewer, the Background Tasks list and the Git Changes panel occupy the SAME trailing
//  slot. If two are marked visible they overlap, and whichever has the higher zIndex silently
//  wins — a defect that looks like "the panel didn't open" rather than like two panels fighting.
//
//  ⚠️ Enforced by a `didSet` pair on the view model, NOT at the mount site. `isCodeViewerVisible`
//  is assigned true from four separate places; a rule spread across call sites is a rule the fifth
//  one misses.
//

import XCTest
@testable import devgentic

@MainActor
final class PanelExclusivityTests: XCTestCase {

    private func makeViewModel() -> ChatHistoryViewModel {
        ChatHistoryViewModel(persistenceService: ChatPersistenceStore.shared,
                             activeStreamManager: ActiveStreamManager(
                                persistenceService: ChatPersistenceStore.shared,
                                fileProcessorService: FileProcessorService()),
                             ownsCodeViewer: true)
    }

    func testOpeningTheTaskListClosesTheCodeViewer() {
        let vm = makeViewModel()
        vm.isCodeViewerVisible = true

        vm.showBackgroundTasks()

        XCTAssertTrue(vm.isBackgroundTasksVisible)
        XCTAssertFalse(vm.isCodeViewerVisible, "both panels would render into the same slot")
    }

    func testOpeningTheCodeViewerClosesTheTaskList() {
        let vm = makeViewModel()
        vm.showBackgroundTasks()

        vm.isCodeViewerVisible = true

        XCTAssertTrue(vm.isCodeViewerVisible)
        XCTAssertFalse(vm.isBackgroundTasksVisible)
    }

    /// ⚠️ The `if` inside each `didSet` is what stops them ping-ponging: assigning one true sets
    /// the other false, whose own `didSet` then sees false and stops. Without the guard this pair
    /// recurses. A test that merely set a flag would not notice — this asserts the value SETTLES.
    func testTheExclusionSettlesRatherThanRecursing() {
        let vm = makeViewModel()

        vm.isCodeViewerVisible = true
        vm.showBackgroundTasks()
        vm.isCodeViewerVisible = true
        vm.showBackgroundTasks()

        XCTAssertTrue(vm.isBackgroundTasksVisible)
        XCTAssertFalse(vm.isCodeViewerVisible)
    }

    /// Closing one must NOT open the other. The `didSet` fires on every write, including false.
    func testClosingOneLeavesTheOtherClosed() {
        let vm = makeViewModel()
        vm.showBackgroundTasks()

        vm.hideBackgroundTasks()

        XCTAssertFalse(vm.isBackgroundTasksVisible)
        XCTAssertFalse(vm.isCodeViewerVisible, "closing the task list opened the Code Viewer")
    }

    /// ⚠️ Unlike the Code Viewer, this panel is NOT gated on having content. An empty list that
    /// says "nothing has run yet" is a useful answer; a panel that refuses to open because no task
    /// exists yet reads as broken.
    func testTheTaskPanelPresentsWithoutAnyTasks() {
        let vm = makeViewModel()
        vm.showBackgroundTasks()
        XCTAssertTrue(vm.isBackgroundTasksPanelPresented)
    }

    // MARK: - Opening from a card

    /// The card is pinned to the turn that produced it; the panel is where the whole history
    /// lives. Opening WITHOUT focus would land the user at the top of a list of twenty and make
    /// the click useless.
    func testOpeningFromACardCarriesTheFocusedTask() {
        let vm = makeViewModel()
        vm.showBackgroundTasks(focus: "bg_3")

        XCTAssertTrue(vm.isBackgroundTasksVisible)
        XCTAssertEqual(vm.backgroundTasksFocusTaskID, "bg_3")
    }

    /// ⚠️ Cleared on close. A stale focus would silently re-expand an unrelated task the next time
    /// the panel is opened from a toolbar or a menu, and the user would have no idea why.
    func testClosingClearsTheFocus() {
        let vm = makeViewModel()
        vm.showBackgroundTasks(focus: "bg_3")

        vm.hideBackgroundTasks()

        XCTAssertNil(vm.backgroundTasksFocusTaskID)
    }

    /// Opening from somewhere with no particular task must not inherit the last card's focus.
    func testOpeningWithoutAFocusDoesNotInheritTheLastOne() {
        let vm = makeViewModel()
        vm.showBackgroundTasks(focus: "bg_3")
        vm.hideBackgroundTasks()

        vm.showBackgroundTasks()

        XCTAssertTrue(vm.isBackgroundTasksVisible)
        XCTAssertNil(vm.backgroundTasksFocusTaskID)
    }

    /// Opening from a card must still close the Code Viewer — the focus variant is the path a user
    /// will actually take, so the exclusion has to hold on it and not just on the bare opener.
    func testOpeningFromACardStillClosesTheCodeViewer() {
        let vm = makeViewModel()
        vm.isCodeViewerVisible = true

        vm.showBackgroundTasks(focus: "bg_1")

        XCTAssertFalse(vm.isCodeViewerVisible)
    }

    // MARK: - Three-way exclusion (Git Changes joined the slot)

    private enum Panel: CaseIterable { case codeViewer, backgroundTasks, gitChanges }

    private func open(_ panel: Panel, on vm: ChatHistoryViewModel) {
        switch panel {
        case .codeViewer: vm.isCodeViewerVisible = true
        case .backgroundTasks: vm.showBackgroundTasks()
        case .gitChanges: vm.showGitChanges()
        }
    }

    private func visible(_ vm: ChatHistoryViewModel) -> Set<Panel> {
        var result: Set<Panel> = []
        if vm.isCodeViewerVisible { result.insert(.codeViewer) }
        if vm.isBackgroundTasksVisible { result.insert(.backgroundTasks) }
        if vm.isGitChangesVisible { result.insert(.gitChanges) }
        return result
    }

    /// Every ordered pair: with `first` open, opening `second` leaves ONLY `second`. Six transitions —
    /// a `didSet` that closed one sibling but forgot the other fails exactly one of them.
    func testEveryPanelClosesEveryOtherPanel() {
        for first in Panel.allCases {
            for second in Panel.allCases where second != first {
                let vm = makeViewModel()
                open(first, on: vm)
                open(second, on: vm)
                XCTAssertEqual(visible(vm), [second], "\(first) → \(second)")
            }
        }
    }

    /// With three `didSet`s closing each other, the guards must still make every chain SETTLE.
    func testThreeWayExclusionSettles() {
        let vm = makeViewModel()
        for panel in [Panel.gitChanges, .codeViewer, .gitChanges, .backgroundTasks, .gitChanges, .codeViewer] {
            open(panel, on: vm)
            XCTAssertEqual(visible(vm), [panel])
        }
    }

    func testClosingGitChangesLeavesTheOthersClosed() {
        let vm = makeViewModel()
        vm.showGitChanges()
        vm.hideGitChanges()
        XCTAssertEqual(visible(vm), [], "closing the Git panel opened another")
    }

    /// "Working tree clean" and "not a git repository" are answers — the panel opens without content.
    func testTheGitPanelPresentsWithoutContent() {
        let vm = makeViewModel()
        vm.showGitChanges()
        XCTAssertTrue(vm.isGitChangesPanelPresented)
    }

    /// Opening the Git panel minimizes the Code Viewer rather than discarding its tabs — the same
    /// contract Background Tasks has.
    func testOpeningGitChangesDoesNotTouchCodeViewerState() {
        let vm = makeViewModel()
        vm.isCodeViewerVisible = true
        let tabsBefore = vm.codeViewerTabs.count
        vm.showGitChanges()
        XCTAssertEqual(vm.codeViewerTabs.count, tabsBefore)
    }

    // MARK: - Git Changes presentation

    func testGitPresentationDefaultsToSplit() {
        XCTAssertEqual(makeViewModel().gitChangesPresentation, .split)
    }

    /// Full-width remembers where it came from: split → full → back to split; overlay → full → overlay.
    func testGitExpansionReturnsToThePriorMode() {
        let vm = makeViewModel()
        vm.toggleGitChangesExpansion()
        XCTAssertEqual(vm.gitChangesPresentation, .full)
        vm.toggleGitChangesExpansion()
        XCTAssertEqual(vm.gitChangesPresentation, .split)

        vm.toggleGitChangesSplit()
        XCTAssertEqual(vm.gitChangesPresentation, .overlay)
        vm.toggleGitChangesExpansion()
        vm.toggleGitChangesExpansion()
        XCTAssertEqual(vm.gitChangesPresentation, .overlay)
    }

    /// The mode can be ASSIGNED (it is a settable var — a restore path would do exactly this), not
    /// only toggled. Full-width must remember an assigned mode too, not just one the split toggle
    /// recorded. (A mutant dropping the expansion toggle's own bookkeeping survived every
    /// toggle-only test, because the split toggle records the same value.)
    func testGitExpansionRemembersAnAssignedMode() {
        let vm = makeViewModel()
        vm.gitChangesPresentation = .overlay
        vm.toggleGitChangesExpansion()
        vm.toggleGitChangesExpansion()
        XCTAssertEqual(vm.gitChangesPresentation, .overlay)
    }

    /// From full-width, the split toggle goes straight to split.
    func testGitSplitFromFullGoesToSplit() {
        let vm = makeViewModel()
        vm.toggleGitChangesSplit()           // overlay
        vm.toggleGitChangesExpansion()       // full
        vm.toggleGitChangesSplit()
        XCTAssertEqual(vm.gitChangesPresentation, .split)
    }

    /// Git's presentation is its own — toggling it must not move the other panels'.
    func testGitPresentationIsIndependent() {
        let vm = makeViewModel()
        vm.toggleGitChangesExpansion()
        XCTAssertEqual(vm.codeViewerPresentation, .split)
        XCTAssertEqual(vm.backgroundTasksPresentation, .split)
    }

    func testGitFilterSurvivesCloseAndReopen() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.gitChangesFilter, .all)
        vm.showGitChanges()
        vm.gitChangesFilter = .unstaged
        vm.hideGitChanges()
        vm.showGitChanges()
        XCTAssertEqual(vm.gitChangesFilter, .unstaged)
    }

    /// The Code Viewer keeps its own rule: visible AND has tabs.
    func testTheCodeViewerStillRequiresTabs() {
        let vm = makeViewModel()
        vm.isCodeViewerVisible = true
        XCTAssertFalse(vm.isCodeViewerPanelPresented,
                       "the Code Viewer presented with no tabs — its gate was weakened")
    }
}
