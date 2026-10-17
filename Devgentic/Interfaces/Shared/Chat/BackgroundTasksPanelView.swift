// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackgroundTasksPanelView.swift
//  Devgentic
//
//  The floating panel that hosts `BackgroundTasksListView` — the persistent list of everything
//  this conversation has run.
//
//  ⚠️ A SIBLING of the Code Viewer panel, not a tab inside it. `CodeViewerTab` is a source-editor
//  tab — `editedCode`, `lastSavedBuffer`, `lastSavedDisk`, `preWriteDisk`, dirty tracking and
//  save-drift guards, with five test suites around its subtleties. A task list has none of those
//  and would carry all of them as dead weight, while making a fragile type polymorphic to do it.
//
//  The panels in the trailing slot are MUTUALLY EXCLUSIVE — enforced by the `didSet`s on
//  `ChatHistoryViewModel`, not by whoever remembers to close the other one. The chrome (card,
//  divider, width rules, title-bar controls) is `TrailingSidePanel`, shared with Git Changes.
//

import SwiftUI

struct BackgroundTasksPanelView: View {

    let conversationID: UUID?

    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel
    @Environment(\.appTheme) private var theme
    @AppStorage(AppSettings.chatFontSizeKey) private var chatFontSize: Double = 14.0

    var body: some View {
        TrailingSidePanel(
            title: String(localized: "Background tasks"),
            presentation: chatHistoryViewModel.backgroundTasksPresentation,
            onToggleSplit: chatHistoryViewModel.toggleBackgroundTasksSplit,
            onToggleExpansion: chatHistoryViewModel.toggleBackgroundTasksExpansion,
            onClose: chatHistoryViewModel.hideBackgroundTasks
        ) {
            if let conversationID {
                BackgroundTasksListView(
                    conversationID: conversationID,
                    focusTaskID: chatHistoryViewModel.backgroundTasksFocusTaskID
                )
            } else {
                Text(String(localized: "Open a conversation to see the commands it has run."))
                    .font(.system(size: chatFontSize - 2))
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(20)
            }
        }
    }
}
