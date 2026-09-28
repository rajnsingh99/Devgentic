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
    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel
    @AppStorage(AppSettings.chatFontSizeKey) private var chatFontSize: Double = 14.0

    /// Live tasks AND the conversation's saved history — see `BackgroundTaskHistory`. Keyed by
    /// `id` (the run's log path), never by `taskID`, which repeats across launches.
    @State private var tasks: [BackgroundTaskListItem] = []
    @State private var expanded: Set<String> = []
    /// The focus already revealed — so a row the user then collapses is not re-opened every time
    /// the list's membership changes.
    @State private var revealedFocus: String?
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

    private var runningTasks: [BackgroundTaskListItem] {
        tasks.filter(\.isRunning)
    }

    private var finishedTasks: [BackgroundTaskListItem] {
        tasks.filter { !$0.isRunning }
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
                                            // Hides finished rows — live AND saved. Deletes no
                                            // card and no log; see `BackgroundTaskHistory.markCleared`.
                                            BackgroundProcessRegistry.shared.clearFinished(conversationID: conversationID)
                                            BackgroundTaskHistory.markCleared(conversationID)
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
                                        .transition(.opacity)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onAppear { reveal(in: proxy) }
                    .onChange(of: focusTaskID) { reveal(in: proxy) }
                    // The saved history arrives AFTER the panel appears, so the focused row may
                    // only exist from the second load on.
                    .onChange(of: tasks.map(\.id)) { reveal(in: proxy) }
                }
            }
        }
        .background(Color.clear)
        .task(id: conversationID) {
            reload()
            await chatHistoryViewModel.refreshSavedBackgroundTasks(for: conversationID)
            reload()
        }
        .onReceive(tick) { instant in
            guard tasks.contains(where: \.isRunning) else { return }
            now = instant
            reload()
            // Only rows someone has actually opened, and only while their task is still writing.
            // A finished task's log cannot change, and a collapsed one is not being read.
            for task in tasks where task.isRunning && expanded.contains(task.id) {
                loadLog(task.id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .backgroundTaskChanged)) { note in
            // Only this conversation's tasks — a run in another conversation must not redraw here.
            guard note.userInfo?[BackgroundTaskNotificationKey.conversationID] as? UUID == conversationID
            else { return }
            reload()
            // A task just changed state — if its row is open, its final output is on disk now.
            // The note carries the REGISTRY id; only a live row can match it.
            if let taskID = note.userInfo?[BackgroundTaskNotificationKey.taskID] as? String,
               let item = tasks.first(where: { $0.isLive && $0.taskID == taskID }),
               expanded.contains(item.id) {
                loadLog(item.id)
            }
        }
    }

    private func reload() {
        tasks = chatHistoryViewModel.backgroundTaskItems(for: conversationID)
    }

    /// Pulls one task's FULL log into the cache.
    ///
    /// Deliberately the whole file rather than the registry's bounded tail: this view is where
    /// someone comes to actually read a build log, and 200 lines is not that. The bound that makes
    /// this affordable is WHEN it runs — on open, and then only while open — not how much it reads.
    ///
    /// A row from an earlier launch reads its log FILE directly — the registry never heard of it.
    /// Once retention has swept that file (7 days), the output tail saved on the card is what is
    /// left, and the text says so rather than showing "No output." for a command that printed.
    private func loadLog(_ itemID: String) {
        guard let item = tasks.first(where: { $0.id == itemID }) else { return }
        logs[itemID] = Self.logText(for: item, conversationID: conversationID)
    }

    static func logText(for item: BackgroundTaskListItem, conversationID: UUID,
                        registry: BackgroundProcessRegistry = .shared) -> String {
        if item.isLive {
            return registry.readLog(conversationID: conversationID, taskID: item.taskID)?.text ?? ""
        }
        if let data = try? Data(contentsOf: item.logURL) {
            return String(decoding: data, as: UTF8.self)
        }
        guard !item.savedTail.isEmpty else { return "" }
        return String(localized: "[The full log was removed after 7 days. The end of its output, saved with the conversation:]")
            + "\n" + item.savedTail
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
        guard let focusTaskID, focusTaskID != revealedFocus,
              tasks.contains(where: { $0.id == focusTaskID }) else { return }
        revealedFocus = focusTaskID
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
    private func runningCard(_ task: BackgroundTaskListItem) -> some View {
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
                BackgroundProcessRegistry.shared.stop(conversationID: conversationID, taskID: task.taskID)
                reload()
            }
            .disabled(!task.isLive)
            Divider()
            Button("Copy Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(task.command, forType: .string)
            }
            Button("Reveal Log in Finder") {
                NSWorkspace.shared.selectFile(task.logURL.path, inFileViewerRootedAtPath: "")
            }
            .disabled(!FileManager.default.fileExists(atPath: task.logURL.path))
        }
    }

    // MARK: - Finished Card (Screenshot 2 Reference)

    @ViewBuilder
    private func finishedCard(_ task: BackgroundTaskListItem) -> some View {
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
            .disabled(!FileManager.default.fileExists(atPath: task.logURL.path))
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
    private func output(_ task: BackgroundTaskListItem) -> some View {
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

    private func runningSubtitle(_ task: BackgroundTaskListItem) -> String {
        let seconds = Int(task.elapsed(now: now).rounded())
        let elapsed = seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
        return "Bash   \(elapsed)"
    }

    private func finishedSubtitle(_ task: BackgroundTaskListItem) -> String {
        Self.finishedSubtitle(task, now: now)
    }

    static func finishedSubtitle(_ task: BackgroundTaskListItem, now: Date) -> String {
        let seconds = Int(task.elapsed(now: now).rounded())
        let elapsed = seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
        let day = task.startedAt.formatted(date: .abbreviated, time: .shortened)
        switch task.status {
        case .exited:
            let code = task.exitCode ?? 0
            return code == 0 ? "Bash  Completed · \(day)" : "Bash  Exit \(code) · \(elapsed) · \(day)"
        case .timedOut:
            return "Bash  Timed out · \(elapsed) · \(day)"
        case .stopped:
            return "Bash  Stopped · \(elapsed) · \(day)"
        case .interrupted:
            // No duration: nobody knows when it died (see `BackgroundTaskObserver.reconcile`).
            return "Bash  Ended when the app quit · \(day)"
        case .running:
            return "Bash  \(elapsed)"
        }
    }
}
