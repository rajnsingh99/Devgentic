//
//  TaskSchedulerSidebarView.swift
//  Devgentic
//
//  Sidebar panel for managing all scheduled tasks.
//  Follows the PromptLibrarySidebarView pattern with header, search, filter chips, and grouped list.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "TaskSchedulerSidebarView")

struct TaskSchedulerSidebarView: View {

    @StateObject private var viewModel = SchedulerViewModel()
    @EnvironmentObject var mainViewModel: MainApplicationViewModel
    @Environment(\.appTheme) private var theme

    @State private var showingCreateSheet = false
    @State private var editingTask: ScheduledTask?
    @State private var showingDeleteAlert = false
    @State private var taskToDelete: ScheduledTask?

    @State private var isConversationBoundExpanded = true
    @State private var isAutonomousExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            // Header
            SidebarHeaderView(
                title: "Scheduler",
                buttonTitle: "New Task",
                systemImage: "plus",
                onAction: { showingCreateSheet = true }
            )
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Search
            SidebarSearchBarView("Search tasks...", text: $viewModel.searchText)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            // Filter chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(SchedulerFilter.allCases) { filter in
                        FilterChip(
                            title: filter.rawValue,
                            isSelected: viewModel.selectedFilter == filter,
                            onTap: { viewModel.selectedFilter = filter }
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
                    systemImage: "clock.badge.plus",
                    onAction: { showingCreateSheet = true }
                )
            } else {
                taskList
            }
        }
        .sheet(isPresented: $showingCreateSheet) {
            CreateScheduledTaskView()
        }
        .sheet(item: $editingTask) { task in
            CreateScheduledTaskView(existingTask: task)
        }
        .alert("Delete Task?", isPresented: $showingDeleteAlert, presenting: taskToDelete) { task in
            Button("Delete", role: .destructive) {
                viewModel.deleteTask(taskID: task.id)
            }
        } message: { task in
            Text("Are you sure you want to delete \"\(task.displayName)\"? This cannot be undone.")
        }
        .onAppear {
            SchedulerService.shared.loadAllTasks()
        }
    }

    // MARK: - Task List

    private var taskList: some View {
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
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 20)
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
                if let convID = task.linkedConversationID {
                    mainViewModel.selectedConversationID = convID
                } else {
                    editingTask = task
                }
            }
        )
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.95)),
            removal: .opacity.combined(with: .scale(scale: 0.95))
        ))
    }
}

// MARK: - Filter Chip

private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let onTap: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: onTap) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText.opacity(0.7))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(isSelected ? theme.accentColor.opacity(0.12) : theme.surfaceOverlay)
                )
                .overlay(
                    Capsule()
                        .stroke(isSelected ? theme.accentColor.opacity(0.3) : Color.clear, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ScheduledTask Identifiable conformance for sheet(item:)

extension ScheduledTask: @retroactive Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
