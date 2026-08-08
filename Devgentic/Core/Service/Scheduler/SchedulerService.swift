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

private let logger = DGLogger(category: "SchedulerService")

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

    /// True once `loadAllTasks()` has populated `scheduledTasks` from the store.
    ///
    /// ⚠️ Distinct from "the container is configured": the container can be set while the array is
    /// still empty, and every scheduling decision reads the ARRAY. Without this, an early
    /// `evaluateAndFireDueTasks()` looks like "nothing is due" rather than "nothing is loaded yet".
    private(set) var hasLoadedTasks = false

    /// Set when an evaluation was requested before the tasks were loaded, so the bootstrap can
    /// replay it instead of the request being lost (G52).
    private var pendingEvaluationAfterLoad = false

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
            logger.error(
                "[SCHEDULER] loadAllTasks called before the ModelContainer was configured. "
                + "CONSEQUENCE: no scheduled task is loaded, armed or caught up this launch — every "
                + "recurring and one-shot task is inert until the next launch."
            )
            return
        }

        do {
            let descriptor = FetchDescriptor<ScheduledTaskModel>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            let models = try context.fetch(descriptor)
            scheduledTasks = models.map { $0.toStruct() }
            hasLoadedTasks = true
            logger.info("Loaded \(self.scheduledTasks.count) scheduled task(s).")

            // ⚠️ Replay an evaluation that arrived too early. `didBecomeActive` fires during a cold
            // launch and can beat this method; without the replay that request was dropped and an
            // overdue task silently never ran (G52).
            if pendingEvaluationAfterLoad {
                pendingEvaluationAfterLoad = false
                logger.info("[SCHEDULER] Replaying the catch-up evaluation that arrived before load.")
                evaluateAndFireDueTasks()
            }
        } catch {
            logger.error(
                "[SCHEDULER] Failed to load scheduled tasks: \(error.localizedDescription). "
                + "CONSEQUENCE: `scheduledTasks` stays empty, so nothing is armed or caught up — "
                + "every task is inert this launch. The stored rows are untouched."
            )
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

    /// Stops a task whose backend profile no longer exists, instead of letting it fail on every fire.
    ///
    /// ⚠️ Register A30. Deleting a profile cascades only to its own workflow layout, so a task bound
    /// to that profile kept its dangling `profileID`. This guard marked the run `.failed` and
    /// returned — and then the timer fired again on the next schedule, and the next, indefinitely.
    /// A nightly task failed every night with "Backend profile not found." and nothing ever stopped
    /// it or said why in terms the user could act on.
    ///
    /// ⚠️ Disabled, **not deleted**. A scheduled task is user-authored work — its prompt, its cron,
    /// its conversation binding. Deleting it as a side effect of deleting a profile is data loss the
    /// user never asked for. Disabling is recoverable: repoint it at another profile and switch it
    /// back on.
    ///
    /// ⚠️ Reached by more than deletion — a store that fails to read, or a profile removed by any
    /// other route, lands here too. That is deliberate: whatever the cause, a task that cannot
    /// resolve its profile cannot run, and retrying on a schedule will not change that.
    private func disableTaskWithMissingProfile(_ task: ScheduledTask) {
        let profileDescription = task.profileID.map(\.uuidString) ?? "none set"
        logger.error(
            "[SCHEDULER] Task '\(task.displayName)' (\(task.id)) references backend profile "
            + "\(profileDescription), which is not in the store. CONSEQUENCE: the task is being "
            + "DISABLED rather than left to fail on every fire; its prompt and schedule are kept so "
            + "the user can repoint it at another profile and re-enable it."
        )

        var updated = task
        updated.isEnabled = false
        updated.isPaused = false
        updated.status = .failed
        updated.lastRunSummary = String(
            localized: "Stopped: the backend profile this task used was deleted. Choose another profile and re-enable.")
        updated.nextRunAt = nil
        updateTask(updated)

        // Cancel any armed timer so the disabled task cannot fire from an in-flight schedule.
        cancelTimer(for: task.id)
    }

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

    /// Fires anything already overdue — the catch-up path for tasks whose moment passed while the
    /// app was closed or in the background.
    ///
    /// ⚠️ THIS IS THE ONLY WAY AN OVERDUE ONE-SHOT TASK EVER RUNS. `scheduleTimer` arms a timer only
    /// for a FUTURE date: a cron task gets its next future occurrence (the missed one is skipped),
    /// and a `scheduledAt` in the past falls through to "no valid schedule" and gets no timer at all.
    ///
    /// ⚠️ ORDERING (G52). It is called from `didBecomeActive`, which fires during a cold launch —
    /// potentially BEFORE the bootstrap `Task` has run `loadAllTasks()`. When that happened this
    /// method iterated an EMPTY `scheduledTasks`, did nothing, and said nothing: a task due at 3pm
    /// with the app opened at 4pm was silently skipped, recovering only if the user happened to
    /// switch away and back. The bootstrap now calls this itself after loading, and an early call
    /// records that it must be replayed rather than being lost.
    func evaluateAndFireDueTasks() {
        guard hasLoadedTasks else {
            pendingEvaluationAfterLoad = true
            logger.warning(
                "[SCHEDULER] evaluateAndFireDueTasks called BEFORE tasks were loaded — the store "
                + "bootstrap has not finished. CONSEQUENCE: nothing is evaluated right now, so an "
                + "overdue task would have been silently skipped; the evaluation is queued and runs "
                + "as soon as loadAllTasks() completes."
            )
            return
        }

        let now = Date()
        var fired = 0
        for task in scheduledTasks where task.isEnabled && !task.isPaused {
            if let nextRun = task.nextRunAt, nextRun <= now, !runningTaskIDs.contains(task.id) {
                fired += 1
                Task { @MainActor in
                    await self.fireTask(task)
                }
            }
        }
        if fired > 0 {
            logger.info("[SCHEDULER] Catch-up: fired \(fired) overdue task(s) out of \(self.scheduledTasks.count).")
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
            disableTaskWithMissingProfile(task)
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
