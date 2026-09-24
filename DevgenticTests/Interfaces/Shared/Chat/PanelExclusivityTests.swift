// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  PanelExclusivityTests.swift
//  DevgenticTests
//
//  The Code Viewer and the Background Tasks list occupy the SAME trailing slot. If both are marked
//  visible they overlap, and whichever has the higher zIndex silently wins — a defect that looks
//  like "the panel didn't open" rather than like two panels fighting.
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

    /// The Code Viewer keeps its own rule: visible AND has tabs.
    func testTheCodeViewerStillRequiresTabs() {
        let vm = makeViewModel()
        vm.isCodeViewerVisible = true
        XCTAssertFalse(vm.isCodeViewerPanelPresented,
                       "the Code Viewer presented with no tabs — its gate was weakened")
    }
}
