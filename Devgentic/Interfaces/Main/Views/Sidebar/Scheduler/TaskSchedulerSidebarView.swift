// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  TaskSchedulerSidebarView.swift
//  Devgentic
//
//  Sidebar panel for managing all scheduled tasks.
//  Follows the PromptLibrarySidebarView pattern with header, search, filter chips, and grouped list.
//

import SwiftUI
import os

private let logger = DGLogger(category: "TaskSchedulerSidebarView")

struct TaskSchedulerSidebarView: View {

    @State private var viewModel = SchedulerViewModel()
    @Environment(MainApplicationViewModel.self) var mainViewModel
    @Environment(MainViewRouter.self) private var router
    @Environment(\.appTheme) private var theme

    @State private var showingDeleteAlert = false
    @State private var taskToDelete: ScheduledTask?

    @State private var isConversationBoundExpanded = true
    @State private var isAutonomousExpanded = true

    @State private var focusedTaskID: UUID? = nil
    @FocusState private var isListFocused: Bool
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            SidebarHeaderView(
                title: "Scheduler",
                buttonTitle: "New Task",
                systemImage: "plus",
                shortcut: "⌘N",
                onAction: { router.navigateToNewTask() }
            )
            .keyboardShortcut("n", modifiers: [.command])
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Search
            SidebarSearchBarView("Search tasks...", text: $viewModel.searchText)
                .focused($isSearchFocused)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            // Filter chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SchedulerFilter.allCases) { filter in
                        CategoryChip(
                            title: filter.localizedTitle,
                            isSelected: viewModel.selectedFilter == filter,
                            action: { viewModel.selectedFilter = filter }
                        )
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.bottom, 10)

            // Content
            if viewModel.filteredTasks.isEmpty {
                SidebarEmptyStateView(
                    title: "No Scheduled Tasks",
                    subtitle: "Schedule tasks to run automatically at specific times",
                    buttonTitle: "Create Task",
                    systemImage: "clock.badge",
                    onAction: { router.navigateToNewTask() }
                )
            } else {
                taskList
            }
        }
        .alert("Delete Task?", isPresented: $showingDeleteAlert, presenting: taskToDelete) { task in
            Button("Delete", role: .destructive) {
                viewModel.deleteTask(taskID: task.id)
                if focusedTaskID == task.id {
                    focusedTaskID = nil
                }
            }
        } message: { task in
            Text("Are you sure you want to delete \"\(task.displayName)\"? This cannot be undone.")
        }
        .onAppear {
            SchedulerService.shared.loadAllTasks()
            if focusedTaskID == nil {
                focusedTaskID = viewModel.filteredTasks.first?.id
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newScheduledTask)) { _ in
            router.navigateToNewTask()
        }
        .onChange(of: viewModel.filteredTasks.map(\.id)) { _, newIDs in
            if let id = focusedTaskID, !newIDs.contains(id) {
                focusedTaskID = newIDs.first
            }
        }
    }

    // MARK: - Task List

    private var taskList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Conversation-Bound Section
                    if !viewModel.conversationBoundTasks.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            SidebarGroupHeaderView(
                                title: "Conversation-Bound",
                                count: viewModel.conversationBoundTasks.count,
                                isExpanded: $isConversationBoundExpanded
                            )

                            if isConversationBoundExpanded {
                                VStack(spacing: 2) {
                                    ForEach(viewModel.conversationBoundTasks) { task in
                                        taskRow(for: task)
                                            .id(task.id)
                                    }
                                }
                                .padding(.leading, 12)
                            }
                        }
                    }

                    // Autonomous Section
                    if !viewModel.autonomousTasks.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            SidebarGroupHeaderView(
                                title: "Autonomous Tasks",
                                count: viewModel.autonomousTasks.count,
                                isExpanded: $isAutonomousExpanded
                            )

                            if isAutonomousExpanded {
                                VStack(spacing: 2) {
                                    ForEach(viewModel.autonomousTasks) { task in
                                        taskRow(for: task)
                                            .id(task.id)
                                    }
                                }
                                .padding(.leading, 12)
                            }
                        }
                    }

                    // Mixed: if only one mode, show flat
                    if viewModel.conversationBoundTasks.isEmpty && viewModel.autonomousTasks.isEmpty {
                        ForEach(viewModel.filteredTasks) { task in
                            taskRow(for: task)
                                .id(task.id)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 20)
            }
            .focusable()
            .focused($isListFocused)
            .focusEffectDisabled()
            .onMoveCommand { direction in
                moveFocus(direction, in: viewModel.filteredTasks)
                if let id = focusedTaskID {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            .onKeyPress(.return) {
                if let id = focusedTaskID,
                   let task = viewModel.filteredTasks.first(where: { $0.id == id }) {
                    openTask(task)
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.delete) {
                if let id = focusedTaskID,
                   let task = viewModel.filteredTasks.first(where: { $0.id == id }) {
                    taskToDelete = task
                    showingDeleteAlert = true
                    return .handled
                }
                return .ignored
            }
            .onKeyPress("r") {
                if let id = focusedTaskID {
                    viewModel.runNow(taskID: id)
                    return .handled
                }
                return .ignored
            }
            .onKeyPress("p") {
                if let id = focusedTaskID,
                   let task = viewModel.filteredTasks.first(where: { $0.id == id }) {
                    if task.isPaused {
                        viewModel.resumeTask(taskID: id)
                    } else {
                        viewModel.pauseTask(taskID: id)
                    }
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.space) {
                if let id = focusedTaskID,
                   let task = viewModel.filteredTasks.first(where: { $0.id == id }) {
                    if task.isPaused {
                        viewModel.resumeTask(taskID: id)
                    } else {
                        viewModel.pauseTask(taskID: id)
                    }
                    return .handled
                }
                return .ignored
            }
            .onKeyPress { press in
                if press.key == "f" && press.modifiers.contains(.command) {
                    isSearchFocused = true
                    return .handled
                }
                return .ignored
            }
        }
    }

    private func moveFocus(_ direction: MoveCommandDirection, in tasks: [ScheduledTask]) {
        guard !tasks.isEmpty else { return }
        guard let currentID = focusedTaskID,
              let currentIndex = tasks.firstIndex(where: { $0.id == currentID }) else {
            focusedTaskID = tasks.first?.id
            return
        }

        switch direction {
        case .down:
            let nextIndex = min(currentIndex + 1, tasks.count - 1)
            focusedTaskID = tasks[nextIndex].id
        case .up:
            let prevIndex = max(currentIndex - 1, 0)
            focusedTaskID = tasks[prevIndex].id
        default:
            break
        }
    }

    private func openTask(_ task: ScheduledTask) {
        if let convID = task.linkedConversationID {
            mainViewModel.selectedConversationID = convID
            if !router.isShowingChat {
                router.returnToChat()
            }
        } else {
            router.navigateToTask(task.id)
        }
    }

    @ViewBuilder
    private func taskRow(for task: ScheduledTask) -> some View {
        ScheduledTaskRowView(
            task: task,
            onToggleEnabled: { viewModel.toggleEnabled(taskID: task.id) },
            onDelete: {
                taskToDelete = task
                showingDeleteAlert = true
            },
            onRunNow: { viewModel.runNow(taskID: task.id) },
            onPauseResume: {
                if task.isPaused {
                    viewModel.resumeTask(taskID: task.id)
                } else {
                    viewModel.pauseTask(taskID: task.id)
                }
            },
            onResetThread: { viewModel.resetThread(taskID: task.id) },
            onTap: {
                focusedTaskID = task.id
                openTask(task)
            },
            isSelected: focusedTaskID == task.id
        )
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.95)),
            removal: .opacity.combined(with: .scale(scale: 0.95))
        ))
    }
}

// MARK: - ScheduledTask Identifiable conformance for sheet(item:)

extension ScheduledTask: @retroactive Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
