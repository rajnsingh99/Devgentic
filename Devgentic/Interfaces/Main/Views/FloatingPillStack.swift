// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  FloatingPillStack.swift
//  Devgentic
//
//  Created by Raj Singh.
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
/// Membership, not visibility: a mounted pill still applies its own rule (Background Tasks hides with no tasks).
/// Chat adds QuickAccess/Orb and Code adds Git changes; Background Tasks and Code Viewer appear in every mode.
enum FloatingPillStack {

    // Why: opening the Git panel minimizes the Code Viewer;
    // `isGitChangesPanelPresented` keeps the viewer's reopen pill from appearing on top of it.
    /// The pills to mount, in display order (top to bottom); mode-specific pills come first.
    /// - Parameter isShowingChat: false on Settings / profile / library screens, where no pill belongs.
    /// - Parameter showsGitChanges: mode-blind; the mode gate is applied here so it cannot leak into Chat.
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
