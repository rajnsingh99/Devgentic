// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GitChangesPanelView.swift
//  Devgentic
//
//  The floating panel that hosts `GitChangesListView` — the open Code project's uncommitted changes.
//
//  ⚠️ A SIBLING of the Code Viewer and Background Tasks panels, not a Code Viewer tab: a diff list
//  carries none of `CodeViewerTab`'s editor state and would inherit all of it as dead weight. The
//  three share one trailing slot and are mutually exclusive via the `didSet`s on
//  `ChatHistoryViewModel`. The chrome is `TrailingSidePanel`, shared with Background Tasks.
//

import SwiftUI

struct GitChangesPanelView: View {

    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel
    @Environment(GitChangesStore.self) private var store
    @Environment(\.appTheme) private var theme
    @AppStorage(AppSettings.chatFontSizeKey) private var chatFontSize: Double = 14.0

    var body: some View {
        TrailingSidePanel(
            title: String(localized: "Changes"),
            presentation: chatHistoryViewModel.gitChangesPresentation,
            onToggleSplit: chatHistoryViewModel.toggleGitChangesSplit,
            onToggleExpansion: chatHistoryViewModel.toggleGitChangesExpansion,
            onClose: chatHistoryViewModel.hideGitChanges,
            titleAccessory: { branchAccessory },
            extraControls: { refreshButton },
            content: { GitChangesListView() }
        )
        .background(refreshShortcut)
        // Opening the panel is a refresh trigger (§6.2 #1): what it shows must be current.
        .task { store.requestRefresh(reason: "panel opened") }
    }

    // MARK: - Title accessory

    private var branchLabel: String? {
        guard let branch = store.snapshot?.branch else { return nil }
        if let head = branch.head { return head }
        if let oid = branch.oid { return String(localized: "detached at \(String(oid.prefix(7)))") }
        return nil
    }

    @ViewBuilder
    private var branchAccessory: some View {
        if let branchLabel {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .semibold))
                Text(branchLabel)
                    .font(.system(size: chatFontSize - 3, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let branch = store.snapshot?.branch, let ahead = branch.ahead, let behind = branch.behind,
                   ahead + behind > 0 {
                    Text(verbatim: "↑\(ahead) ↓\(behind)")
                        .font(.system(size: chatFontSize - 4, design: .monospaced))
                        .foregroundStyle(theme.tertiaryText)
                        .help(String(localized: "\(ahead) commits ahead, \(behind) behind \(branch.upstream ?? "upstream")"))
                }
            }
            .foregroundStyle(theme.secondaryText)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(localized: "Branch \(branchLabel)"))
        }
    }

    // MARK: - Controls

    private var refreshButton: some View {
        PanelHeaderIconButton(
            action: { Task { await store.refreshNow() } },
            icon: "arrow.clockwise",
            helpText: store.isRefreshing
                ? String(localized: "Refreshing…")
                : String(localized: "Refresh"),
            foregroundColor: theme.secondaryText,
            hoverBackground: theme.secondaryText.opacity(0.15),
            isActive: false
        )
        .disabled(store.isRefreshing)
    }

    /// ⌘R refreshes (⌘W close comes from `TrailingSidePanel`). Label-less — see that type's note.
    private var refreshShortcut: some View {
        Button { Task { await store.refreshNow() } } label: { EmptyView() }
            .keyboardShortcut("r", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }
}
