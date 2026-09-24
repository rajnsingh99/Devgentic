// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackgroundTasksListView.swift
//  Devgentic
//
//  Every command this conversation has run, in one place — the persistent list the timeline card
//  cannot be, because a card is pinned to the turn that produced it and a build you started six
//  turns ago is scrolled away.
//
//  ⚠️ DELIBERATELY NOT a `CodeViewerTab`. That type is a SOURCE-EDITOR tab: `editedCode`,
//  `lastSavedBuffer`, `lastSavedDisk`, `preWriteDisk`, dirty tracking and save-drift guards, with
//  five test suites around its subtleties (phantom-dirty state, rejected writes, baselines). A
//  task list has none of those and would carry every one of them as dead weight, while making a
//  fragile type polymorphic to do it. This view owns its own state and reads the registry directly;
//  where it is PRESENTED — a Code Viewer tab, its own panel, a sheet — is a separate decision that
//  does not change a line of it.
//

import SwiftUI
import AppKit

struct BackgroundTasksListView: View {

    let conversationID: UUID
    /// A task to reveal on open — set when the panel was opened from that task's card. Expanding
    /// and scrolling to it is the difference between "the panel opened" and "the panel answered
    /// the question I clicked on".
    var focusTaskID: String? = nil

    @Environment(\.appTheme) private var theme
    @AppStorage(AppSettings.chatFontSizeKey) private var chatFontSize: Double = 15.0

    @State private var tasks: [BackgroundProcessRegistry.Snapshot] = []
    @State private var expanded: Set<String> = []
    @State private var isFinishedExpanded: Bool = true
    @State private var now = Date()

    /// Full log text, by task id, for the rows that are currently EXPANDED.
    ///
    /// ⚠️ This cache is the whole reason the read moved out of `output(_:)`. That function is a
    /// `@ViewBuilder`, so `String(contentsOf:)` sitting in it ran on EVERY body evaluation — once
    /// per tick, per re-render, per parent redraw — re-reading an entire build log each time.
    /// Loaded when a row opens, refreshed only while that row is open AND its task is live, and
    /// dropped when it closes: a collapsed row costs nothing, which is the point.
    @State private var logs: [String: String] = [:]

    /// Refreshes while anything is live. A conversation of finished tasks stops ticking — the
    /// same rule the card follows, for the same reason: a list of history should not re-render
    /// once a second forever.
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var runningTasks: [BackgroundProcessRegistry.Snapshot] {
        tasks.filter { !$0.status.isTerminal }
    }

    private var finishedTasks: [BackgroundProcessRegistry.Snapshot] {
        tasks.filter { $0.status.isTerminal }
    }

    // MARK: - Surfaces & Contrast (matches Screenshot 2 reference)

    private var cardBackground: Color {
        theme.isDark ? Color(white: 0.16) : theme.secondaryBackground
    }

    private var cardBorderColor: Color {
        theme.isDark ? Color.white.opacity(0.08) : theme.dividerColor.opacity(0.35)
    }

    private var commandBoxBackground: Color {
        theme.isDark ? Color(white: 0.08) : Color(white: 0.95)
    }

    private var outputBoxBackground: Color {
        theme.isDark ? Color(white: 0.125) : Color(white: 0.92)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if tasks.isEmpty {
                empty
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            // Section 1: Running tasks
                            if !runningTasks.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Running")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(theme.secondaryText.opacity(0.7))
                                        .padding(.horizontal, 14)
                                        .padding(.top, 10)

                                    VStack(spacing: 8) {
                                        ForEach(runningTasks, id: \.id) { task in
                                            runningCard(task).id(task.id)
                                        }
                                    }
                                    .padding(.horizontal, 10)
                                }
                            }

                            // Section 2: Finished tasks
                            if !finishedTasks.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Button {
                                            withAnimation(.easeInOut(duration: 0.18)) {
                                                isFinishedExpanded.toggle()
                                            }
                                        } label: {
                                            HStack(spacing: 5) {
                                                Text("Finished \(finishedTasks.count)")
                                                    .font(.system(size: 11, weight: .medium))
                                                    .foregroundStyle(theme.secondaryText.opacity(0.85))
                                                Image(systemName: isFinishedExpanded ? "chevron.down" : "chevron.right")
                                                    .font(.system(size: 9, weight: .semibold))
                                                    .foregroundStyle(theme.secondaryText.opacity(0.7))
                                            }
                                        }
                                        .buttonStyle(.plain)

                                        Spacer()

                                        Button {
                                            BackgroundProcessRegistry.shared.clearFinished(conversationID: conversationID)
                                            reload()
                                        } label: {
                                            Image(systemName: "trash")
                                                .font(.system(size: 11))
                                                .foregroundStyle(theme.secondaryText.opacity(0.7))
                                                .frame(width: 20, height: 20)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Clear finished tasks")
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.top, runningTasks.isEmpty ? 10 : 4)

                                    if isFinishedExpanded {
                                        VStack(spacing: 7) {
                                            ForEach(finishedTasks, id: \.id) { task in
                                                finishedCard(task).id(task.id)
                                            }
                                        }
                                        .padding(.horizontal, 10)
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onAppear { reveal(in: proxy) }
                    .onChange(of: focusTaskID) { reveal(in: proxy) }
                }
            }
        }
        .background(theme.primaryBackground)
        .onAppear(perform: reload)
        .onChange(of: conversationID) { reload() }
        .onReceive(tick) { instant in
            guard tasks.contains(where: { !$0.status.isTerminal }) else { return }
            now = instant
            reload()
            // Only rows someone has actually opened, and only while their task is still writing.
            // A finished task's log cannot change, and a collapsed one is not being read.
            for task in tasks where !task.status.isTerminal && expanded.contains(task.id) {
                loadLog(task.id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .backgroundTaskChanged)) { note in
            // Only this conversation's tasks — a run in another conversation must not redraw here.
            guard note.userInfo?[BackgroundTaskNotificationKey.conversationID] as? UUID == conversationID
            else { return }
            reload()
            // A task just changed state — if its row is open, its final output is on disk now.
            if let taskID = note.userInfo?[BackgroundTaskNotificationKey.taskID] as? String,
               expanded.contains(taskID) {
                loadLog(taskID)
            }
        }
    }

    private func reload() {
        tasks = BackgroundProcessRegistry.shared.snapshots(conversationID: conversationID)
    }

    /// Pulls one task's FULL log into the cache.
    ///
    /// Deliberately the whole file rather than the registry's bounded tail: this view is where
    /// someone comes to actually read a build log, and 200 lines is not that. The bound that makes
    /// this affordable is WHEN it runs — on open, and then only while open — not how much it reads.
    private func loadLog(_ taskID: String) {
        logs[taskID] = BackgroundProcessRegistry.shared
            .readLog(conversationID: conversationID, taskID: taskID)?.text ?? ""
    }

    /// Opens or closes a row, loading its log on the way in and releasing it on the way out.
    private func toggle(_ taskID: String) {
        if expanded.contains(taskID) {
            expanded.remove(taskID)
            logs.removeValue(forKey: taskID)      // a closed row must not retain a log
        } else {
            expanded.insert(taskID)
            loadLog(taskID)
        }
    }

    /// Expands and scrolls to the focused task, when there is one.
    ///
    /// ⚠️ Only ADDS to `expanded`. Replacing the set would collapse whatever the user had already
    /// opened every time they clicked a different card — the panel is persistent, so its state is
    /// theirs, not the caller's to reset.
    private func reveal(in proxy: ScrollViewProxy) {
        guard let focusTaskID, tasks.contains(where: { $0.id == focusTaskID }) else { return }
        expanded.insert(focusTaskID)
        loadLog(focusTaskID)          // expanded without going through `toggle`
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(focusTaskID, anchor: .top) }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text("Nothing has been run in this conversation yet.")
                .font(.system(size: chatFontSize - 2))
                .foregroundStyle(theme.secondaryText)
            // Says what produces a row, so an empty list is not mistaken for a broken one.
            Text("Commands the agent runs appear here while they run and after they finish.")
                .font(.system(size: chatFontSize - 4))
                .foregroundStyle(theme.secondaryText.opacity(0.8))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    // MARK: - Running Card (Screenshot 2 Reference)

    @ViewBuilder
    private func runningCard(_ task: BackgroundProcessRegistry.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                toggle(task.id)
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            let title = (task.name?.isEmpty == false) ? task.name! : task.command
                            Text(title)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(theme.primaryText)
                                .lineLimit(1)

                            if expanded.contains(task.id) {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(theme.secondaryText.opacity(0.7))
                            }
                        }

                        Text(runningSubtitle(task))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryText.opacity(0.75))
                    }

                    Spacer(minLength: 8)

                    // Subtle terminal/window glyph matching reference
                    Image(systemName: "rectangle")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(expanded.contains(task.id) ? theme.primaryText : theme.secondaryText.opacity(0.6))
                        .frame(width: 22, height: 22)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded.contains(task.id) {
                VStack(alignment: .leading, spacing: 8) {
                    commandBox(task.command)
                    output(task)
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(cardBorderColor, lineWidth: 1)
        )
        .contextMenu {
            Button("Stop Task") {
                BackgroundProcessRegistry.shared.stop(conversationID: conversationID, taskID: task.id)
                reload()
            }
            Divider()
            Button("Copy Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(task.command, forType: .string)
            }
            Button("Reveal Log in Finder") {
                NSWorkspace.shared.selectFile(task.logURL.path, inFileViewerRootedAtPath: "")
            }
        }
    }

    // MARK: - Finished Card (Screenshot 2 Reference)

    @ViewBuilder
    private func finishedCard(_ task: BackgroundProcessRegistry.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                toggle(task.id)
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            let title = (task.name?.isEmpty == false) ? task.name! : task.command
                            Text(title)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(theme.primaryText)
                                .lineLimit(1)

                            Image(systemName: expanded.contains(task.id) ? "chevron.down" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(theme.secondaryText.opacity(expanded.contains(task.id) ? 0.8 : 0.4))
                        }

                        Text(finishedSubtitle(task))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryText.opacity(0.75))
                    }

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded.contains(task.id) {
                VStack(alignment: .leading, spacing: 8) {
                    commandBox(task.command)
                    output(task)
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(cardBorderColor, lineWidth: 1)
        )
        .contextMenu {
            Button("Copy Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(task.command, forType: .string)
            }
            Button("Copy Output") {
                let text = logs[task.id] ?? ""
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            Divider()
            Button("Reveal Log in Finder") {
                NSWorkspace.shared.selectFile(task.logURL.path, inFileViewerRootedAtPath: "")
            }
        }
    }

    // MARK: - Command Box

    @ViewBuilder
    private func commandBox(_ command: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Text("$")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.cyan.opacity(0.8))
            Text(command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.primaryText.opacity(0.92))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(commandBoxBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
        .textSelection(.enabled)
    }

    // MARK: - Output Viewer

    @ViewBuilder
    private func output(_ task: BackgroundProcessRegistry.Snapshot) -> some View {
        // ⚠️ CACHE ONLY — never `readLog` here. This is a `@ViewBuilder`; anything in it runs on
        // every body evaluation. See `logs`.
        let text = logs[task.id] ?? ""
        ScrollView {
            Text(text.isEmpty ? "No output." : text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(text.isEmpty ? theme.secondaryText.opacity(0.6) : theme.primaryText.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 220)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(outputBoxBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(0.04), lineWidth: 1)
        )
    }

    // MARK: - Subtitle Formatting

    private func runningSubtitle(_ task: BackgroundProcessRegistry.Snapshot) -> String {
        let seconds = Int(task.elapsed(now: now).rounded())
        let elapsed = seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
        return "Bash   \(elapsed)"
    }

    private func finishedSubtitle(_ task: BackgroundProcessRegistry.Snapshot) -> String {
        let seconds = Int(task.elapsed(now: now).rounded())
        let elapsed = seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
        switch task.status {
        case .exited(let code):
            if code == 0 {
                return "Bash  Completed"
            } else {
                return "Bash  Exit \(code) · \(elapsed)"
            }
        case .timedOut:
            return "Bash  Timed out · \(elapsed)"
        case .stopped:
            return "Bash  Stopped · \(elapsed)"
        case .running:
            return "Bash  \(elapsed)"
        }
    }
}
