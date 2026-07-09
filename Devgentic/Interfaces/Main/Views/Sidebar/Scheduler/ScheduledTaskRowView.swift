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
                        .font(.system(.caption2, weight: .medium))
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
                        .font(.system(.caption2))
                        .foregroundColor(theme.secondaryText.opacity(0.6))
                } else if let lastRun = task.lastRunAt {
                    Text("Last: \(lastRun.timeAgoDisplay())")
                        .font(.system(.caption2))
                        .foregroundColor(theme.secondaryText.opacity(0.6))
                }

                if task.runCount > 0 {
                    Text("· Run \(task.runCount)")
                        .font(.system(.caption2))
                        .foregroundColor(theme.secondaryText.opacity(0.5))
                }

                Spacer()

                if !task.isEnabled {
                    Text("Disabled")
                        .font(.system(size: 9, weight: .medium)) // Fixed size: intentional (badge/chip text)
                        .foregroundColor(theme.secondaryText.opacity(0.5))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(theme.secondaryText.opacity(0.1))
                        .clipShape(Capsule())
                } else if task.isPaused {
                    Text("Paused")
                        .font(.system(size: 9, weight: .medium)) // Fixed size: intentional (badge/chip text)
                        .foregroundColor(.orange.opacity(0.8))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(theme.warningColor.opacity(0.1))
                        .clipShape(Capsule())
                }
            }

            // Last run summary
            if let summary = task.lastRunSummary, !summary.isEmpty {
                Text(summary)
                    .font(.system(.caption))
                    .foregroundColor(theme.secondaryText.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering ? theme.surfaceOverlay : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
        }
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
        if !task.isEnabled { return .gray.opacity(0.4) }
        switch task.status {
        case .pending: return .blue
        case .running: return .orange
        case .completed: return .green
        case .failed: return .red
        case .paused: return .gray
        }
    }
}
