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
//  Both panels occupy the same trailing slot, so they are MUTUALLY EXCLUSIVE — enforced by the
//  `didSet` pair on `ChatHistoryViewModel`, not by whoever remembers to close the other one.
//

import SwiftUI

struct BackgroundTasksPanelView: View {

    let conversationID: UUID?

    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel
    @Environment(\.appTheme) private var theme
    @AppStorage(AppSettings.chatFontSizeKey) private var chatFontSize: Double = 15.0
    @AppStorage("codeViewerPanelWidth") private var panelWidth: Double = 520
    @State private var isExpanded = false

    private var effectiveWidth: Double {
        isExpanded ? max(panelWidth * 1.5, 780) : panelWidth
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            if let conversationID {
                BackgroundTasksListView(conversationID: conversationID,
                                        focusTaskID: chatHistoryViewModel.backgroundTasksFocusTaskID)
            } else {
                // Says WHY rather than showing an empty list: tasks are conversation-scoped, so
                // with no conversation open there is nothing this panel could be listing.
                Text("Open a conversation to see the commands it has run.")
                    .font(.system(size: chatFontSize - 2))
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(20)
            }
        }
        .frame(width: effectiveWidth)
        .background(theme.primaryBackground)
        .overlay(Rectangle().frame(width: 1).foregroundStyle(theme.secondaryText.opacity(0.15)), alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
        .transition(.move(edge: .trailing))
    }

    private var titleBar: some View {
        HStack(spacing: 10) {
            Text("Background tasks")
                .font(.system(size: chatFontSize - 1, weight: .medium))
                .foregroundStyle(theme.primaryText)
            Spacer()

            if chatHistoryViewModel.hasCodeViewerTabs {
                Button {
                    chatHistoryViewModel.reopenCodeViewer()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Code (\(chatHistoryViewModel.codeViewerTabs.count))")
                            .font(.system(size: chatFontSize - 3, weight: .medium))
                    }
                    .foregroundStyle(theme.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(theme.accentColor.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Switch to Code Viewer")
            }

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Restore width" : "Expand width")

            Button {
                chatHistoryViewModel.hideBackgroundTasks()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
