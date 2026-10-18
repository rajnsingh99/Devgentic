// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackgroundTasksPanelView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// The floating panel that hosts `BackgroundTasksListView`, the persistent list of everything this conversation has run.
/// A sibling of the Code Viewer panel, not a tab in it; the trailing-slot panels are mutually exclusive and share the
/// `TrailingSidePanel` chrome.
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
