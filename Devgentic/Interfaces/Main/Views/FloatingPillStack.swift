// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  FloatingPillStack.swift
//  Devgentic
//
//  Which floating pills the top-trailing stack MOUNTS, per interface mode.
//

import Foundation

/// One pill in `MainApplicationView.floatingPills`.
enum FloatingPill: Hashable {
    case quickAccess
    case gitChanges
    case backgroundTasks
    case codeViewer
}

/// The per-mode membership of the floating pill stack, as a pure function the view iterates.
///
/// ⚠️ Exists because of a regression. Build 102.7 introduced the QuickAccess pill with a
/// Chat-only gate (`isChatInterfaceActive`) and wrapped the Background Tasks and Code Viewer
/// pills in the SAME gate — so both vanished from Code mode, where background tasks are mostly
/// started (`run_command`). Nothing failed: QuickAccess's own tests only cover QuickAccess's own
/// rule, and stack membership lived inline in a view body. Each pill now has its own mode rule,
/// and `MainApplicationView` mounts exactly what this returns, so the tests on it test the stack.
///
/// | Pill             | Chat | Code | Workflow |
/// |------------------|------|------|----------|
/// | QuickAccess/Orb  |  ✅  |  —   |    —     |
/// | Git changes      |  —   |  ✅  |    —     |
/// | Background Tasks |  ✅  |  ✅  |    ✅    |
/// | Code Viewer      |  ✅  |  ✅  |    ✅    |
///
/// Workflow has no mode-specific pill, but keeps the shared two — as it did before 102.7. Both
/// panels mount mode-blind in `MainApplicationView`, so each pill has a panel to open there.
///
/// MEMBERSHIP, not visibility: a mounted pill still applies its own rule (Background Tasks hides
/// itself with no tasks; QuickAccess's `shouldShow` is folded into `showsQuickAccess`).
enum FloatingPillStack {

    /// The pills to mount, in display order (top to bottom). Mode-specific pills come FIRST so
    /// the shared pills keep the same relative order in every mode.
    ///
    /// - Parameters:
    ///   - isShowingChat: `router.isShowingChat` — false on Settings / profile / library screens,
    ///     where no pill belongs.
    ///   - showsQuickAccess: QuickAccess's own `shouldShow` verdict (already Chat-gated there).
    ///   - showsGitChanges: `GitChangesFloatingButton.shouldShow`'s verdict. Mode-blind — the mode
    ///     gate is applied HERE, so it cannot leak into Chat.
    ///   - isGitChangesPanelPresented: opening the Git panel MINIMIZES the Code Viewer (slot
    ///     exclusion), which turns `isCodeViewerMinimized` true — without this input the viewer's
    ///     reopen pill would appear on top of the Git panel.
    static func visible(
        interfaceMode: MainApplicationViewModel.InterfaceMode,
        isShowingChat: Bool,
        showsQuickAccess: Bool,
        showsGitChanges: Bool,
        isCodeViewerMinimized: Bool,
        isBackgroundTasksPanelPresented: Bool,
        isGitChangesPanelPresented: Bool
    ) -> [FloatingPill] {
        guard isShowingChat else { return [] }

        var pills: [FloatingPill] = []
        switch interfaceMode {
        case .chat:
            if showsQuickAccess { pills.append(.quickAccess) }
        case .code:
            if showsGitChanges { pills.append(.gitChanges) }
        case .workflow:
            break
        }

        // Shared by every mode.
        pills.append(.backgroundTasks)
        if isCodeViewerMinimized && !isBackgroundTasksPanelPresented && !isGitChangesPanelPresented {
            pills.append(.codeViewer)
        }
        return pills
    }
}
