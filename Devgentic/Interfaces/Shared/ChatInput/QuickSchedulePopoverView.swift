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
    /// When invoked from inside an open chat, the preset task continues that
    /// conversation (mode = .conversationBound) instead of creating an orphan
    /// thread. When nil (welcome screen, no active chat), falls back to a
    /// stateless autonomous task.
    let currentConversationID: UUID?
    @Binding var isPresented: Bool
    var onCustomSchedule: () -> Void

    @Environment(\.appTheme) private var theme

    private let presets: [(label: String, icon: String, interval: TimeInterval)] = [
        ("In 30 min", "clock", 30 * 60),
        ("In 1 hour", "clock.fill", 60 * 60),
        ("In 3 hours", "alarm", 3 * 60 * 60),
        ("Tomorrow 9 AM", "sun.horizon", 0) // Handled specially
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Quick Schedule")
                .font(.system(.caption, weight: .bold))
                .foregroundColor(theme.primaryText)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)

            ForEach(Array(presets.enumerated()), id: \.offset) { index, preset in
                Button {
                    scheduleWithPreset(preset)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: preset.icon)
                            .font(.system(.caption))
                            .foregroundColor(theme.accentColor)
                            .frame(width: 16)
                        Text(preset.label)
                            .font(theme.fontSubheadline)
                            .foregroundColor(theme.primaryText)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popoverRowHighlight()
            }

            Divider()
                .padding(.horizontal, 8)

            Button {
                isPresented = false
                // Small delay to ensure popover dismissal doesn't conflict with sheet presentation
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    onCustomSchedule()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(.caption))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 16)
                    Text("Custom...")
                        .font(theme.fontSubheadline)
                        .foregroundColor(theme.secondaryText)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popoverRowHighlight()
        }
        .padding(.vertical, 4)
        .frame(width: 200)
    }

    private func scheduleWithPreset(_ preset: (label: String, icon: String, interval: TimeInterval)) {
        guard !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let fireDate: Date
        if preset.interval == 0 {
            // "Tomorrow 9 AM"
            let calendar = Calendar.current
            var components = calendar.dateComponents([.year, .month, .day], from: Date())
            components.day! += 1
            components.hour = 9
            components.minute = 0
            fireDate = calendar.date(from: components) ?? Date().addingTimeInterval(24 * 3600)
        } else {
            fireDate = Date().addingTimeInterval(preset.interval)
        }

        // If invoked from inside an active conversation, the preset continues
        // that thread; otherwise falls back to a stateless autonomous run.
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
