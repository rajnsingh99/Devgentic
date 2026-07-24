//
//  QuickSchedulePopoverView.swift
//  Devgentic
//
//  Compact popover for quickly scheduling a one-shot task from the ChatInputAreaView.
//

import SwiftUI

struct QuickSchedulePopoverView: View {

    let promptText: String
    let selectedProfileID: UUID?
    let currentConversationID: UUID?
    @Binding var isPresented: Bool
    var onCustomSchedule: () -> Void

    @Environment(\.appTheme) private var theme

    private struct SchedulePreset {
        let label: String
        let icon: String
        let interval: TimeInterval
        let isTomorrow9AM: Bool

        var calculatedTimeString: String {
            let now = Date()
            if isTomorrow9AM {
                return "Tomorrow, 9:00 AM"
            } else {
                let target = now.addingTimeInterval(interval)
                let formatter = DateFormatter()
                formatter.timeStyle = .short
                return formatter.string(from: target)
            }
        }
    }

    private var presets: [SchedulePreset] {
        [
            SchedulePreset(label: "In 30 min", icon: "clock", interval: 30 * 60, isTomorrow9AM: false),
            SchedulePreset(label: "In 1 hour", icon: "clock.fill", interval: 60 * 60, isTomorrow9AM: false),
            SchedulePreset(label: "In 3 hours", icon: "alarm.fill", interval: 3 * 60 * 60, isTomorrow9AM: false),
            SchedulePreset(label: "Tomorrow 9 AM", icon: "sun.horizon.fill", interval: 0, isTomorrow9AM: true)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.accentColor)

                Text("QUICK SCHEDULE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.8)
                    .foregroundColor(theme.secondaryText)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 2)

            Rectangle()
                .fill(theme.dividerColor.opacity(0.22))
                .frame(height: 1)
                .padding(.horizontal, 8)

            // Preset List
            VStack(spacing: 5) {
                ForEach(presets, id: \.label) { preset in
                    PresetRowView(
                        label: preset.label,
                        subtitle: preset.calculatedTimeString,
                        icon: preset.icon,
                        action: { scheduleWithPreset(preset) }
                    )
                }
            }
            .padding(.horizontal, 8)

            Rectangle()
                .fill(theme.dividerColor.opacity(0.22))
                .frame(height: 1)
                .padding(.horizontal, 8)

            // Custom Schedule Button
            Button {
                isPresented = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    onCustomSchedule()
                }
            } label: {
                CustomScheduleRowView()
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .padding(.vertical, 2)
        .frame(width: 260)
    }

    private func scheduleWithPreset(_ preset: SchedulePreset) {
        guard !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let fireDate: Date
        if preset.isTomorrow9AM {
            let calendar = Calendar.current
            var components = calendar.dateComponents([.year, .month, .day], from: Date())
            components.day! += 1
            components.hour = 9
            components.minute = 0
            fireDate = calendar.date(from: components) ?? Date().addingTimeInterval(24 * 3600)
        } else {
            fireDate = Date().addingTimeInterval(preset.interval)
        }

        let boundToConversation = currentConversationID != nil
        let task = ScheduledTask(
            id: UUID(),
            displayName: String(promptText.prefix(30)),
            mode: boundToConversation ? .conversationBound : .autonomous,
            promptTemplate: promptText,
            profileID: selectedProfileID,
            attachedFileURLs: [],
            cronExpression: nil,
            scheduledAt: fireDate,
            isEnabled: true,
            isPaused: false,
            status: .pending,
            lastRunAt: nil,
            nextRunAt: fireDate,
            runCount: 0,
            lastRunSummary: nil,
            linkedConversationID: currentConversationID,
            contextWindowMode: boundToConversation ? .continuous : .stateless,
            createdAt: Date()
        )

        SchedulerService.shared.createTask(task)
        isPresented = false
    }
}

// MARK: - Preset Row Component

private struct PresetRowView: View {
    let label: String
    let subtitle: String
    let icon: String
    let action: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(theme.accentColor.opacity(isHovered ? 0.25 : 0.12))
                        .frame(width: 26, height: 26)

                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                        .shadow(color: isHovered ? theme.accentColor.opacity(0.6) : .clear, radius: 3)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(theme.fontSubheadline.weight(.semibold))
                        .foregroundColor(theme.primaryText)

                    Text(subtitle)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(isHovered ? theme.accentColor : theme.tertiaryText.opacity(0.5))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovered ? theme.surfaceOverlayStrong : theme.surfaceOverlay.opacity(0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isHovered ? theme.accentColor.opacity(0.5) : Color.clear,
                        lineWidth: 1
                    )
            )
            .shadow(color: isHovered ? Color.black.opacity(0.12) : .clear, radius: 4, y: 2)
            .scaleEffect(isHovered ? 1.015 : 1.0)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { isHovered = h }
        }
    }
}

// MARK: - Custom Schedule Row Component

private struct CustomScheduleRowView: View {
    @Environment(\.appTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(theme.surfaceOverlayStrong)
                    .frame(width: 26, height: 26)

                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Custom Schedule...")
                    .font(theme.fontSubheadline.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                Text("Date, time & recurrence")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(theme.tertiaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovered ? theme.surfaceOverlayStrong : theme.surfaceOverlay.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isHovered ? theme.secondaryText.opacity(0.3) : Color.clear,
                    lineWidth: 1
                )
        )
        .shadow(color: isHovered ? Color.black.opacity(0.12) : .clear, radius: 4, y: 2)
        .scaleEffect(isHovered ? 1.015 : 1.0)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { h in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { isHovered = h }
        }
    }
}
