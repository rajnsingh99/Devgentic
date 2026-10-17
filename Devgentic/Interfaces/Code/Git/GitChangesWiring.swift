// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GitChangesWiring.swift
//  Devgentic
//
//  Connects `GitChangesStore` to the app: which project it follows, when it refreshes, and when the
//  panel closes. A ViewModifier so `MainApplicationView.body` (already at the type-checker's budget)
//  gains one line, and the decisions are pure functions with tests.
//

import SwiftUI
import AppKit

private let logger = DGLogger(category: "GitUI")

enum GitChangesWiring {

    /// The project the store should follow. Code mode ONLY — in Chat/Workflow the store follows
    /// nothing, so no refresh trigger can run git while the feature is not on screen.
    ///
    /// Under an XCTest host it follows nothing either: the test host IS the real app, and a
    /// persisted Code project would otherwise have git run against the developer's own repository
    /// during an ordinary test run (see `TestHost.permits`).
    static func project(interfaceMode: MainApplicationViewModel.InterfaceMode,
                        projectPath: URL?, isTestHost: Bool) -> URL? {
        guard interfaceMode == .code, !isTestHost else { return nil }
        return projectPath
    }

    /// Whether the panel may be mounted. The flag alone is not enough: it lives on the shared
    /// `ChatHistoryViewModel`, which Chat and Workflow also use.
    static func shouldMountPanel(interfaceMode: MainApplicationViewModel.InterfaceMode,
                                 isPresented: Bool) -> Bool {
        interfaceMode == .code && isPresented
    }
}

struct GitChangesWiringModifier: ViewModifier {
    let store: GitChangesStore
    let chatHistoryViewModel: ChatHistoryViewModel
    let interfaceMode: MainApplicationViewModel.InterfaceMode
    let projectPath: URL?

    private var followedProject: URL? {
        GitChangesWiring.project(interfaceMode: interfaceMode, projectPath: projectPath,
                                 isTestHost: TestHost.isRunning)
    }

    func body(content: Content) -> some View {
        content
            // Project sync (§6.2 #1). `.task(id:)` fires on appear AND on every change, so a launch
            // straight into Code mode with a restored project loads without user action.
            .task(id: followedProject) {
                if interfaceMode == .code, projectPath != nil, TestHost.isRunning {
                    _ = TestHost.permits("read git status for the Code project", logger: logger)
                }
                store.setProject(followedProject)
            }
            // The panel must not survive a switch to Chat/Workflow — its flag is shared state.
            .onChange(of: interfaceMode) { _, mode in
                if mode != .code { chatHistoryViewModel.hideGitChanges() }
            }
            // Run / save activity (§6.2 #3–4). The store ignores requests while it follows nothing.
            .onReceive(NotificationCenter.default.publisher(for: WorkspaceActivity.didChange)) { note in
                let reason = note.userInfo?[WorkspaceActivity.reasonKey] as? String ?? "workspace activity"
                store.requestRefresh(reason: reason)
            }
            // External edits made while the app was in the background (§6.2 #5).
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                store.requestRefresh(reason: "app became active")
            }
    }
}
