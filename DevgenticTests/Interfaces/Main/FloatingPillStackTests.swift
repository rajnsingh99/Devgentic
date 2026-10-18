// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  FloatingPillStackTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class FloatingPillStackTests: XCTestCase {

    private func pills(
        _ mode: MainApplicationViewModel.InterfaceMode,
        isShowingChat: Bool = true,
        showsQuickAccess: Bool = true,
        showsGitChanges: Bool = false,
        codeViewerMinimized: Bool = true,
        backgroundPanelOpen: Bool = false,
        gitPanelOpen: Bool = false
    ) -> [FloatingPill] {
        FloatingPillStack.visible(
            interfaceMode: mode,
            isShowingChat: isShowingChat,
            showsQuickAccess: showsQuickAccess,
            showsGitChanges: showsGitChanges,
            isCodeViewerMinimized: codeViewerMinimized,
            isBackgroundTasksPanelPresented: backgroundPanelOpen,
            isGitChangesPanelPresented: gitPanelOpen
        )
    }

    // MARK: - Mode matrix

    func testChatMountsAllThreeInOrder() {
        XCTAssertEqual(pills(.chat), [.quickAccess, .backgroundTasks, .codeViewer])
    }

    /// The 102.7 regression: Code mode mounted nothing.
    func testCodeMountsBackgroundTasksAndCodeViewer() {
        XCTAssertEqual(pills(.code, showsGitChanges: false), [.backgroundTasks, .codeViewer])
    }

    /// Code mode's own pill leads, so the shared pills keep the same order in both modes.
    func testCodeMountsAllThreeWithGitFirst() {
        XCTAssertEqual(pills(.code, showsGitChanges: true), [.gitChanges, .backgroundTasks, .codeViewer])
    }

    /// The git pill's verdict is mode-blind; the stack's mode gate is what keeps it out of Chat.
    func testGitPillNeverMountsOutsideCode() {
        XCTAssertFalse(pills(.chat, showsGitChanges: true).contains(.gitChanges))
        XCTAssertFalse(pills(.workflow, showsGitChanges: true).contains(.gitChanges))
    }

    /// Opening the Git panel MINIMIZES the Code Viewer (slot exclusion), so `isCodeViewerMinimized`
    /// is true while it is open — the reopen pill must still stay away from the open panel.
    func testCodeViewerPillHiddenWhileGitPanelOpen() {
        XCTAssertEqual(pills(.code, showsGitChanges: false, gitPanelOpen: true), [.backgroundTasks])
    }

    func testCodeNeverMountsQuickAccessEvenWhenEligible() {
        XCTAssertFalse(pills(.code, showsQuickAccess: true).contains(.quickAccess))
    }

    /// Workflow has no pill of its own but keeps the shared two (its pre-102.7 behaviour).
    func testWorkflowMountsBackgroundTasksAndCodeViewer() {
        XCTAssertEqual(pills(.workflow), [.backgroundTasks, .codeViewer])
    }

    func testWorkflowNeverMountsQuickAccessEvenWhenEligible() {
        XCTAssertFalse(pills(.workflow, showsQuickAccess: true).contains(.quickAccess))
    }

    func testWorkflowCodeViewerPillFollowsTheSameSlotRules() {
        XCTAssertEqual(pills(.workflow, codeViewerMinimized: false), [.backgroundTasks])
        XCTAssertEqual(pills(.workflow, backgroundPanelOpen: true), [.backgroundTasks])
    }

    func testOffChatScreenMountsNothingInAnyMode() {
        for mode in [MainApplicationViewModel.InterfaceMode.chat, .code, .workflow] {
            XCTAssertEqual(pills(mode, isShowingChat: false), [], "\(mode) on a non-chat screen")
        }
    }

    // MARK: - Per-pill rules

    func testChatHonoursQuickAccessVerdict() {
        XCTAssertEqual(pills(.chat, showsQuickAccess: false), [.backgroundTasks, .codeViewer])
    }

    func testCodeViewerNeedsMinimizedViewer() {
        XCTAssertEqual(pills(.code, codeViewerMinimized: false), [.backgroundTasks])
        XCTAssertEqual(pills(.chat, codeViewerMinimized: false), [.quickAccess, .backgroundTasks])
    }

    func testCodeViewerHiddenWhileBackgroundPanelOpen() {
        XCTAssertEqual(pills(.code, backgroundPanelOpen: true), [.backgroundTasks])
        XCTAssertEqual(pills(.chat, backgroundPanelOpen: true), [.quickAccess, .backgroundTasks])
    }

    // MARK: - Wiring

    /// The matrix above only matters if the view mounts what it returns. 102.7's defect was an
    /// inline gate in the view body — so the body must iterate `visiblePills` and carry no mode
    /// gate of its own, and `visiblePills` must come from `FloatingPillStack.visible`.
    func testTheViewMountsExactlyTheStacksOutput() throws {
        let lines = try sourceFile("Devgentic/Interfaces/Main/Views/MainApplicationView.swift")
            .components(separatedBy: "\n")
        func body(after marker: String, span: Int) -> String? {
            guard let start = lines.firstIndex(where: { $0.contains(marker) }) else { return nil }
            return lines[start..<min(start + span, lines.count)]
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }
        guard let pills = body(after: "private var floatingPills", span: 22),
              let source = body(after: "private var visiblePills", span: 10) else {
            return XCTFail("floatingPills / visiblePills not found — this guard is checking nothing")
        }
        XCTAssertTrue(pills.contains("ForEach(visiblePills"), "the stack must mount the policy's output")
        XCTAssertFalse(pills.contains("isChatInterfaceActive"), "a shared inline mode gate is the 102.7 regression")
        XCTAssertFalse(pills.contains("interfaceMode"), "mode membership belongs in FloatingPillStack")
        XCTAssertTrue(source.contains("FloatingPillStack.visible("))
        // The two Git inputs must be FED, not left to a default — they have none, on purpose.
        let call = try XCTUnwrap(body(after: "private var visiblePills", span: 20))
        XCTAssertTrue(call.contains("showsGitChanges: GitChangesFloatingButton.shouldShow("))
        XCTAssertTrue(call.contains("isGitChangesPanelPresented: isGitChangesPanelMounted"),
                      "fed a constant, the reopen pill would sit on top of an open Git panel")
        XCTAssertTrue(pills.contains("case .gitChanges:"), "a pill the policy returns but the view never draws")
    }

    private func sourceFile(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard let source = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("\(path) not reachable — running outside a checkout")
        }
        return source
    }
}
