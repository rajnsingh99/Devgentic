// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ScheduledTaskRowView.swift
//  Devgentic
//
//  A row view for displaying a scheduled task in the sidebar panel.
//

import SwiftUI

struct ScheduledTaskRowView: View {

    let task: ScheduledTask
    let onToggleEnabled: () -> Void
    let onDelete: () -> Void
    let onRunNow: () -> Void
    let onPauseResume: () -> Void
    let onResetThread: () -> Void
    let onTap: () -> Void
    var isSelected: Bool = false

    @State private var isHovering = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Title + Status
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                Text(task.displayName)
                    .font(theme.fontFootnote.weight(.medium))
                    .foregroundColor(task.isEnabled ? theme.primaryText : theme.secondaryText)
                    .lineLimit(1)

                Spacer()

                if task.isEnabled {
                    Text(task.scheduleDescription)
                        .font(theme.fontCaption2.weight(.medium))
                        .foregroundColor(theme.secondaryText.opacity(0.7))
                        .lineLimit(1)
                }
            }

            // Subtitle: next run or last run info
            HStack(spacing: 4) {
                if task.status == .running {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.6)
                }

                if let nextRun = task.nextRunAt, task.isEnabled && !task.isPaused {
                    Text("Next: \(nextRun.timeAgoDisplay())")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText.opacity(0.6))
                } else if let lastRun = task.lastRunAt {
                    Text("Last: \(lastRun.timeAgoDisplay())")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText.opacity(0.6))
                }

                if task.runCount > 0 {
                    Text("· Run \(task.runCount)")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText.opacity(0.5))
                }

                Spacer()

                if !task.isEnabled {
                    Text("Disabled")
                        .font(theme.fontCodeCaption.weight(.medium))
                        .foregroundColor(theme.secondaryText.opacity(0.5))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(theme.secondaryText.opacity(0.1))
                        .clipShape(Capsule())
                } else if task.isPaused {
                    Text("Paused")
                        .font(theme.fontCodeCaption.weight(.medium))
                        .foregroundColor(theme.warningColor.opacity(0.9))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(theme.warningColor.opacity(0.1))
                        .clipShape(Capsule())
                }
            }

            // Last run summary
            if let summary = task.lastRunSummary, !summary.isEmpty {
                Text(summary)
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .sidebarRowBackground(isSelected: isSelected, isHovering: isHovering)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
        .contextMenu {
            Button { onRunNow() } label: {
                Label("Run Now", systemImage: "play.fill")
            }

            Divider()

            Button { onPauseResume() } label: {
                Label(task.isPaused ? "Resume" : "Pause", systemImage: task.isPaused ? "play.circle" : "pause.circle")
            }

            Button { onToggleEnabled() } label: {
                Label(task.isEnabled ? "Disable" : "Enable", systemImage: task.isEnabled ? "xmark.circle" : "checkmark.circle")
            }

            if task.mode == .autonomous && task.linkedConversationID != nil {
                Button { onResetThread() } label: {
                    Label("Reset Thread", systemImage: "arrow.counterclockwise")
                }
            }

            Divider()

            Button(role: .destructive) { onDelete() } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var statusColor: Color {
        if !task.isEnabled { return theme.secondaryText.opacity(0.4) }
        switch task.status {
        case .pending: return theme.accentColor
        case .running: return theme.warningColor
        case .completed: return theme.successColor
        case .failed: return theme.errorColor
        case .paused: return theme.secondaryText
        }
    }
}
