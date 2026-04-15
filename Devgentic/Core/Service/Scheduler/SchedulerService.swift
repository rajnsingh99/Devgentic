//
//  SchedulerService.swift
//  Devgentic
//
//  Central service for managing scheduled tasks: CRUD, timer management,
//  and task execution (fire logic for both conversation-bound and autonomous tasks).
//
//  Migrated to SwiftData on 26/03/26.
//

import Foundation
import SwiftData
import AppKit
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "SchedulerService")

@MainActor
@Observable
final class SchedulerService {

    static let shared = SchedulerService()

    private(set) var scheduledTasks: [ScheduledTask] = []

    private var timers: [UUID: DispatchSourceTimer] = [:]
    private var runningTaskIDs: Set<UUID> = []

    /// Weak reference set during app bootstrap (avoids circular dependency).
    weak var mainViewModel: MainApplicationViewModel?

    /// The shared model container, injected during app init.
    private var modelContainer: ModelContainer?

    private var mainContext: ModelContext? {
        modelContainer?.mainContext
    }

    private init() {}

    /// Call this once from the App init to inject the container.
    func configureContainer(_ container: ModelContainer) {
        self.modelContainer = container
    }

    // MARK: - Load

    func loadAllTasks() {
        guard let context = mainContext else {
            logger.error("loadAllTasks called before ModelContainer configured.")
            return
        }

        do {
            let descriptor = FetchDescriptor<ScheduledTaskModel>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            let models = try context.fetch(descriptor)
            scheduledTasks = models.map { $0.toStruct() }
            logger.info("Loaded \(self.scheduledTasks.count) scheduled task(s).")
        } catch {
            logger.error("Failed to load scheduled tasks: \(error.localizedDescription)")
        }
    }

    // MARK: - CRUD

    func createTask(_ task: ScheduledTask) {
        guard let context = mainContext else { return }

        let model = ScheduledTaskModel(id: task.id)
        model.apply(from: task)
        context.insert(model)
        saveContext()
        scheduledTasks.insert(task, at: 0)
        scheduleTimer(for: task)
        logger.info("Created scheduled task: \(task.displayName) (\(task.id.uuidString))")
    }

    func updateTask(_ task: ScheduledTask) {
        guard let model = fetchModel(id: task.id) else { return }
        model.apply(from: task)
        saveContext()

        if let idx = scheduledTasks.firstIndex(where: { $0.id == task.id }) {
            scheduledTasks[idx] = task
        }

        // Reschedule timer
        cancelTimer(for: task.id)
        if task.isEnabled && !task.isPaused {
            scheduleTimer(for: task)
        }
    }

    func deleteTask(id: UUID) {
        cancelTimer(for: id)
        if let model = fetchModel(id: id) {
            mainContext?.delete(model)
            saveContext()
        }
        scheduledTasks.removeAll { $0.id == id }
        logger.info("Deleted scheduled task: \(id.uuidString)")
    }

    // MARK: - State Changes

    func toggleEnabled(taskID: UUID) {
        guard var task = scheduledTasks.first(where: { $0.id == taskID }) else { return }
        task.isEnabled.toggle()
        if !task.isEnabled {
            task.isPaused = false
        }
        updateTask(task)
    }

    func pauseTask(id: UUID) {
        guard var task = scheduledTasks.first(where: { $0.id == id }) else { return }
        task.isPaused = true
        task.status = .paused
        updateTask(task)
    }

    func resumeTask(id: UUID) {
        guard var task = scheduledTasks.first(where: { $0.id == id }) else { return }
        task.isPaused = false
        task.status = .pending
        updateTask(task)
    }

    func resetThread(taskID: UUID) {
        guard var task = scheduledTasks.first(where: { $0.id == taskID }) else { return }
        task.linkedConversationID = nil
        task.runCount = 0
        task.lastRunAt = nil
        task.lastRunSummary = nil
        task.status = .pending
        updateTask(task)
        logger.info("Reset thread for task: \(task.displayName)")
    }

    // MARK: - Scheduling (Timers)

    func rescheduleAll() {
        // Cancel all existing timers
        for id in timers.keys {
            cancelTimer(for: id)
        }

        for task in scheduledTasks where task.isEnabled && !task.isPaused {
            scheduleTimer(for: task)
        }
        logger.info("Rescheduled all active tasks.")
    }

    func cancelTimer(for taskID: UUID) {
        timers[taskID]?.cancel()
        timers.removeValue(forKey: taskID)
    }

    private func scheduleTimer(for task: ScheduledTask) {
        guard task.isEnabled, !task.isPaused else { return }

        let nextDate: Date?

        if let cronStr = task.cronExpression, let cron = try? CronExpression(expression: cronStr) {
            nextDate = cron.nextFireDate(after: Date())
        } else if let scheduled = task.scheduledAt, scheduled > Date() {
            nextDate = scheduled
        } else {
            return // No valid schedule
        }

        guard let fireDate = nextDate else { return }

        // Update nextRunAt
        if var updated = scheduledTasks.first(where: { $0.id == task.id }) {
            updated.nextRunAt = fireDate
            if let idx = scheduledTasks.firstIndex(where: { $0.id == task.id }) {
                scheduledTasks[idx] = updated
            }
            if let model = fetchModel(id: task.id) {
                model.nextRunAt = fireDate
                saveContext()
            }
        }

        let interval = max(fireDate.timeIntervalSinceNow, 1.0)
        let taskID = task.id

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                guard let currentTask = self.scheduledTasks.first(where: { $0.id == taskID }) else { return }
                await self.fireTask(currentTask)
            }
        }
        timer.resume()
        timers[task.id] = timer
        logger.info("Timer set for '\(task.displayName)' — fires at \(fireDate)")
    }

    // MARK: - Catch-up (App Foreground)

    func evaluateAndFireDueTasks() {
        let now = Date()
        for task in scheduledTasks where task.isEnabled && !task.isPaused {
            if let nextRun = task.nextRunAt, nextRun <= now, !runningTaskIDs.contains(task.id) {
                Task { @MainActor in
                    await self.fireTask(task)
                }
            }
        }
    }

    // MARK: - Execution

    func fireTask(_ task: ScheduledTask) async {
        guard !runningTaskIDs.contains(task.id) else {
            logger.warning("Task '\(task.displayName)' is already running — skipping.")
            return
        }

        guard let vm = mainViewModel else {
            logger.error("MainApplicationViewModel not set — cannot fire task.")
            return
        }

        // Verify profile exists
        guard let profileID = task.profileID,
              let profile = (try? BackendProfileStore.shared.fetchProfiles())?.first(where: { $0.id == profileID }) else {
            logger.error("Profile not found for task '\(task.displayName)' — marking as failed.")
            updateTaskStatus(id: task.id, status: .failed, summary: "Backend profile not found.")
            return
        }

        runningTaskIDs.insert(task.id)
        updateTaskStatus(id: task.id, status: .running, summary: nil)

        // Resolve template
        let resolvedPrompt = resolveTemplate(task.promptTemplate, task: task)

        // Determine conversation ID
        var conversationID: UUID

        if task.mode == .conversationBound, let linkedID = task.linkedConversationID {
            if ChatPersistenceStore.shared.getConversation(withId: linkedID) != nil {
                conversationID = linkedID
            } else {
                logger.warning("Linked conversation orphaned for task '\(task.displayName)' — creating new.")
                conversationID = vm.createConversationForScheduledTask(
                    profileID: profile,
                    title: "[\(task.displayName)]"
                )
            }
        } else if task.mode == .autonomous, let linkedID = task.linkedConversationID {
            if task.contextWindowMode == .stateless || ChatPersistenceStore.shared.getConversation(withId: linkedID) == nil {
                conversationID = vm.createConversationForScheduledTask(
                    profileID: profile,
                    title: "[\(task.displayName)]"
                )
            } else {
                conversationID = linkedID
            }
        } else {
            conversationID = vm.createConversationForScheduledTask(
                profileID: profile,
                title: "[\(task.displayName)]"
            )
        }

        // Update linked conversation
        var updatedTask = task
        updatedTask.linkedConversationID = conversationID

        // Send the message
        let config = BackendRequestConfig(profile: profile)
        let summary = await vm.sendScheduledMessage(
            prompt: resolvedPrompt,
            config: config,
            conversationID: conversationID,
            attachedFileURLs: task.attachedFileURLs
        )

        // Post-execution updates
        updatedTask.runCount = task.runCount + 1
        updatedTask.lastRunAt = Date()
        updatedTask.lastRunSummary = String(summary.prefix(100))
        updatedTask.status = .completed

        // Compute next fire date for recurring tasks
        if let cronStr = task.cronExpression, let cron = try? CronExpression(expression: cronStr) {
            updatedTask.nextRunAt = cron.nextFireDate(after: Date())
            updatedTask.status = .pending
        } else if task.isOneShot {
            updatedTask.isEnabled = false
        }

        updateTask(updatedTask)
        runningTaskIDs.remove(task.id)

        // Re-schedule recurring timers
        if updatedTask.isEnabled && updatedTask.isRecurring {
            scheduleTimer(for: updatedTask)
        }

        // Fire notification
        let payload = AppNotificationPayload(
            title: "Scheduled Task Completed",
            body: "\(task.displayName): \(summary.prefix(60))",
            conversationID: conversationID
        )
        await NotificationDispatcher.shared.dispatch(payload)

        logger.info("Task '\(task.displayName)' fired successfully (run #\(updatedTask.runCount)).")
    }

    // MARK: - Helpers

    private func updateTaskStatus(id: UUID, status: TaskStatus, summary: String?) {
        if var task = scheduledTasks.first(where: { $0.id == id }) {
            task.status = status
            if let summary = summary { task.lastRunSummary = summary }
            if let idx = scheduledTasks.firstIndex(where: { $0.id == id }) {
                scheduledTasks[idx] = task
            }
            if let model = fetchModel(id: id) {
                model.status = status.rawValue
                if let summary = summary { model.lastRunSummary = summary }
                saveContext()
            }
        }
    }

    private func fetchModel(id: UUID) -> ScheduledTaskModel? {
        guard let context = mainContext else { return nil }
        let predicate = #Predicate<ScheduledTaskModel> { $0.id == id }
        var descriptor = FetchDescriptor<ScheduledTaskModel>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func saveContext() {
        guard let context = mainContext, context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            logger.error("Failed to save SwiftData context: \(error.localizedDescription)")
        }
    }
}
