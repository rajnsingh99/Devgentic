// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackgroundTasksFloatingButton.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// A floating pill that opens the Background Tasks panel from anywhere in the conversation.
/// Mounted at the app-window level beside `CodeViewerFloatingButton`, since the panel is not in the tree while closed.
struct BackgroundTasksFloatingButton: View {

    /// Read from `ChatHistoryViewModel.viewerOwningConversationID` by the caller, so the pill and
    /// the panel it opens can never disagree about which conversation they mean.
    let conversationID: UUID?

    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel
    @Environment(\.appTheme) private var theme

    @State private var tasks: [BackgroundTaskListItem] = []
    @State private var isHovering = false

    private var runningCount: Int { tasks.filter(\.isRunning).count }

    /// Hidden when the panel is already open and when this conversation has never run anything.
    /// Stays visible once every task has finished, since the list is history.
    private var isVisible: Bool {
        Self.shouldShow(hasConversation: conversationID != nil,
                        taskCount: tasks.count,
                        panelIsOpen: chatHistoryViewModel.isBackgroundTasksVisible
                            || chatHistoryViewModel.isCodeViewerPanelPresented
                            || chatHistoryViewModel.isGitChangesPanelPresented)
    }

    // Why: a `private var` in a `View` is untestable without rendering, and a transcribed predicate stays green when broken
    /// The visibility rule, kept out of the view body so tests exercise the same expression.
    static func shouldShow(hasConversation: Bool, taskCount: Int, panelIsOpen: Bool) -> Bool {
        hasConversation && taskCount > 0 && !panelIsOpen
    }

    var body: some View {
        Group {
            if isVisible { pill } else { EmptyView() }
        }
        // Saved cards are fetched on appear and on every conversation switch, so the pill reflects history.
        .task(id: conversationID) {
            reload()
            guard let conversationID else { return }
            await chatHistoryViewModel.refreshSavedBackgroundTasks(for: conversationID)
            reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .backgroundTaskChanged)) { note in
            // Only this conversation's tasks — a run elsewhere must not light this up.
            guard note.userInfo?[BackgroundTaskNotificationKey.conversationID] as? UUID == conversationID
            else { return }
            reload()
        }
    }

    private var pill: some View {
        Button {
            chatHistoryViewModel.showBackgroundTasks()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: runningCount > 0 ? "play.circle" : "terminal")
                    .font(.system(size: 12, weight: .semibold))   // Fixed size: pill affordance
                    .foregroundColor(theme.accentColor)

                HStack(spacing: 3) {
                    Text("\(tasks.count)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))  // Fixed size: count badge
                        .foregroundColor(theme.accentColor)

                    // A running task is the one state worth interrupting for. Everything else is
                    // history, and history does not need to pulse.
                    if runningCount > 0 { LivePulseDot(color: .orange) }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(theme.accentColor.opacity(0.15))
                .clipShape(Capsule())
                .contentTransition(.numericText())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(theme.secondaryBackground)
                    .shadow(color: .black.opacity(0.18), radius: isHovering ? 7 : 4, y: 2)
            )
            .overlay(Capsule().strokeBorder(theme.dividerColor.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(helpText)
        .accessibilityLabel(helpText)
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private var helpText: String {
        runningCount > 0
            ? String(localized: "Background tasks — \(runningCount) running of \(tasks.count)")
            : String(localized: "Background tasks — \(tasks.count) finished")
    }

    private func reload() {
        guard let conversationID else { return tasks = [] }
        tasks = chatHistoryViewModel.backgroundTaskItems(for: conversationID)
    }
}
