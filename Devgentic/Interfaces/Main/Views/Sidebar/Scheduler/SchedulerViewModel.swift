//
//  SchedulerViewModel.swift
//  Devgentic
//
//  ViewModel for the Task Scheduler sidebar panel.
//  Observes SchedulerService and provides filtering/actions for the UI.
//

import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "SchedulerViewModel")

enum SchedulerFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case active = "Active"
    case paused = "Paused"
    case recurring = "Recurring"
    case oneShot = "One-shot"

    var id: String { rawValue }
}

@Observable @MainActor
final class SchedulerViewModel {

    var searchText: String = ""
    var selectedFilter: SchedulerFilter = .all

    init() { }

    var tasks: [ScheduledTask] {
        SchedulerService.shared.scheduledTasks
    }

    var filteredTasks: [ScheduledTask] {
        var result = tasks

        // Apply filter
        switch selectedFilter {
        case .all: break
        case .active:
            result = result.filter { $0.isEnabled && !$0.isPaused }
        case .paused:
            result = result.filter { $0.isPaused }
        case .recurring:
            result = result.filter { $0.isRecurring }
        case .oneShot:
            result = result.filter { $0.isOneShot }
        }

        // Apply search
        if !searchText.isEmpty {
            result = result.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText) ||
                $0.promptTemplate.localizedCaseInsensitiveContains(searchText)
            }
        }

        return result
    }

    var conversationBoundTasks: [ScheduledTask] {
        filteredTasks.filter { $0.mode == .conversationBound }
    }

    var autonomousTasks: [ScheduledTask] {
        filteredTasks.filter { $0.mode == .autonomous }
    }

    // MARK: - Actions

    func toggleEnabled(taskID: UUID) {
        SchedulerService.shared.toggleEnabled(taskID: taskID)
    }

    func deleteTask(taskID: UUID) {
        SchedulerService.shared.deleteTask(id: taskID)
    }

    func runNow(taskID: UUID) {
        guard let task = tasks.first(where: { $0.id == taskID }) else { return }
        Task {
            await SchedulerService.shared.fireTask(task)
        }
        logger.info("Manual run triggered for: \(task.displayName)")
    }

    func resetThread(taskID: UUID) {
        SchedulerService.shared.resetThread(taskID: taskID)
    }

    func pauseTask(taskID: UUID) {
        SchedulerService.shared.pauseTask(id: taskID)
    }

    func resumeTask(taskID: UUID) {
        SchedulerService.shared.resumeTask(id: taskID)
    }
}
