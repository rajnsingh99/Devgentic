// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackgroundTaskCard.swift
//  Devgentic
//
//  The timeline row for a `batch_command(background:)` task: what ran, how long it has been
//  running, and what it has written.
//
//  ── Why this exists ─────────────────────────────────────────────────────────────────────
//
//  Device test, 2026-09-21. The model started a build and said:
//
//      "I will now periodically check the status of this background job (bg_1) and notify you
//       immediately when it finishes."
//
//  …then emitted `final_answer`. The turn ended, the ReAct loop terminated, and nothing polled —
//  nothing could. The user was told a watch was in place that structurally could not exist, and
//  had no way to tell otherwise: the tool card showed the launch line and froze.
//
//  So this row is not a convenience. It is the thing that makes the promise unnecessary. With the
//  output visible here, the user is never blind regardless of what the model does, and the model
//  polling becomes an optimisation rather than the only path to knowing what happened.
//
//  ⚠️ Renders `data.outputTail` — a BOUNDED tail carried in the timeline — not the log file. The
//  full log is at `data.logPath` and is deliberately not loaded here: it is 375 KB for a real
//  build, and `ToolExecutionData` already documents what putting that much text through the
//  message blob costs. "Open full log" is the escape hatch for the whole thing.
//

import SwiftUI
import AppKit

struct BackgroundTaskCard: View {

    let data: BackgroundTaskData
    /// nil when the timeline was rendered without one — see `AgentTimelineView.conversationID`.
    /// Without it this card cannot ask the registry for live output and falls back to the row's
    /// own tail, which is correct rather than degraded: that tail is finalised at completion.
    var conversationID: UUID? = nil

    @Environment(\.appTheme) private var theme
    /// ⚠️ OPTIONAL, matching `ActionDetailView` and `CodeBlockView`: a timeline can be rendered
    /// without a chat view model in the environment (workflow per-node views, previews), and those
    /// contexts should simply show no "open" affordance rather than crash.
    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel: ChatHistoryViewModel?
    @AppStorage(AppSettings.chatFontSizeKey) private var chatFontSize: Double = 15.0
    @State private var isHoveringCard = false

    /// Drives the elapsed readout while the task runs. Stopped for a finished task so a
    /// conversation full of old tasks is not re-rendering once a second forever.
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Live output, held only while this card is watching and its task is still RUNNING.
    ///
    /// ⚠️ EXISTS BECAUSE THE OBSERVER NO LONGER POLLS. `data.outputTail` is written by
    /// `BackgroundTaskObserver`, which is now event-driven: it fires at launch and at completion,
    /// not once a second. A card left open during a build would otherwise sit on the launch-time
    /// tail — empty — until the task ended.
    ///
    /// This is the "someone is actually looking" refresh that replaced the 1 Hz whole-file read.
    /// `refreshTail` drains only the bytes written since the last call, and this stops entirely the
    /// moment the card is collapsed or the task finishes.
    @State private var liveTail: String?
    @State private var liveCharacters = 0

    /// Retained lifecycle invariant: indicates whether the task has active or completed output.
    private var isDisclosable: Bool {
        data.logCharacterCount > 0 || data.status == .running
    }

    var body: some View {
        compactRow
            .padding(.horizontal, 2)
            .padding(.vertical, 1.5)
            .onHover { isHoveringCard = $0 }
            .onReceive(tick) { instant in
                // Only a running task needs a clock.
                if data.status == .running { now = instant }
                refreshLiveTail()
            }
            .onAppear {
                _ = isDisclosable
                refreshLiveTail()      // immediately, rather than a blank second first
            }
    }

    // MARK: - Compact Row

    private var compactRow: some View {
        HStack(spacing: 6) {
            statusIcon

            if let name = data.name, !name.isEmpty {
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.primaryText)

                Text(data.taskID)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.accentColor)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(theme.accentColor.opacity(0.12)))

                Text(data.command)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(data.taskID)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.accentColor)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(theme.accentColor.opacity(0.12)))

                Text(data.command)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(theme.primaryText.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Text("(\(subtitle))")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.tertiaryText)
                .lineLimit(1)

            Spacer(minLength: 6)

            // Right-aligned actions
            HStack(spacing: 6) {
                // Inline Stop action for actively running tasks
                if data.status == .running, let conversationID {
                    Button {
                        BackgroundProcessRegistry.shared.stop(conversationID: conversationID, taskID: data.taskID)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 8))
                            Text(String(localized: "Stop"))
                                .font(.system(size: 9.5, weight: .medium))
                        }
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.orange.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Stop background task"))
                }

                // Explicit affordance: View in Background Tasks panel
                if canOpenPanel {
                    Button {
                        openInPanel()
                    } label: {
                        HStack(spacing: 3) {
                            Text(String(localized: "View in tasks"))
                                .font(.system(size: 9.5, weight: .medium))
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 8.5))
                        }
                        .foregroundStyle(theme.accentColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(theme.accentColor.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Open in Background Tasks panel"))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 28)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.surfaceOverlay.opacity(isHoveringCard ? 0.45 : 0.2))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isHoveringCard ? theme.surfaceOverlayStrong : theme.dividerColor.opacity(0.6), lineWidth: 1)
        )
    }

    private var statusIcon: some View {
        Group {
            if data.status == .running {
                ProgressView().controlSize(.mini).frame(width: 13, height: 13)
            } else {
                Image(systemName: iconName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 13, height: 13)
            }
        }
    }

    /// ⚠️ `exited` is NOT rendered as success. A non-zero exit is the command's own verdict, and
    /// reporting it with a tick is the same false statement the registry's log wording had to be
    /// corrected for: "it ran" and "it worked" are different facts.
    private var iconName: String {
        switch data.status {
        case .running:     return "circle.dotted"
        case .exited:      return data.exitCode == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        case .timedOut:    return "clock.badge.exclamationmark.fill"
        case .stopped:     return "stop.circle.fill"
        case .interrupted: return "bolt.horizontal.circle.fill"
        }
    }

    private var statusColor: Color {
        switch data.status {
        case .running:     return theme.accentColor
        case .exited:      return data.exitCode == 0 ? theme.successColor : theme.errorColor
        case .timedOut:    return .orange
        case .stopped:     return theme.secondaryText
        case .interrupted: return .orange
        }
    }

    private var subtitle: String {
        let elapsed = Self.duration(data.finishedAt?.timeIntervalSince(data.startedAt)
                                    ?? now.timeIntervalSince(data.startedAt))
        switch data.status {
        case .running:     return "running · \(elapsed)"
        case .exited:      return "finished in \(elapsed) · exit \(data.exitCode.map(String.init) ?? "?")"
        case .timedOut:    return "killed at timeout (\(elapsed))"
        case .stopped:     return "stopped after \(elapsed)"
        // Deliberately explicit rather than "unknown": quit KILLS every background task, so a task
        // last seen running did not survive the restart, and saying so beats a shrug.
        case .interrupted: return "ended when the app restarted"
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        return "\(total / 60)m \(total % 60)s"
    }

    // MARK: - Opening the panel

    private var canOpenPanel: Bool { chatHistoryViewModel != nil }

    /// Opens the persistent task list focused on THIS task.
    ///
    /// The card is pinned to the turn that produced it, so a build started six turns ago is
    /// scrolled away; the panel is where the whole run history lives. Focusing rather than just
    /// opening is what makes the click answer the question that prompted it.
    private func openInPanel() {
        guard let chatHistoryViewModel else { return }
        chatHistoryViewModel.showBackgroundTasks(focus: data.taskID)
    }

    /// Pulls the registry's in-memory tail while this card is watching; releases it otherwise.
    ///
    /// Cheap by construction — `refreshTail` reads only what the task has written since last time.
    /// The guard is the design: collapsed, finished, or without a conversation, this does nothing
    /// at all and no file is touched.
    private func refreshLiveTail() {
        guard data.status == .running, let conversationID else {
            // Fall back to the row's tail, which the observer finalises when the task ends.
            if liveTail != nil { liveTail = nil }
            return
        }
        guard let snapshot = BackgroundProcessRegistry.shared
            .refreshTail(conversationID: conversationID, taskID: data.taskID) else { return }

        // The same wire-format bound `BackgroundTaskObserver` applies, so an expanded card and a
        // finalised row show the same amount of text rather than visibly jumping at completion.
        let bounded = snapshot.tail.count > BackgroundTaskData.maxOutputTail
            ? String(snapshot.tail.suffix(BackgroundTaskData.maxOutputTail))
            : snapshot.tail
        if bounded != liveTail { liveTail = bounded }
        liveCharacters = snapshot.logCharacterCount
    }
}

/// Semantic alias for `BackgroundTaskCard` reflecting its compact timeline row presentation.
typealias CompactBackgroundTaskRow = BackgroundTaskCard
