// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SchedulerService.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import SwiftData
import AppKit
import os

private let logger = DGLogger(category: "SchedulerService")

/// Central service for scheduled tasks: CRUD, timer management and task execution (fire logic for conversation-bound
/// and autonomous tasks).
@MainActor
@Observable
final class SchedulerService {

    static let shared = SchedulerService()

    private(set) var scheduledTasks: [ScheduledTask] = []

    private var timers: [UUID: DispatchSourceTimer] = [:]
    private var runningTaskIDs: Set<UUID> = []

    /// How late a run may start and still count as on time. Past this it is missed: skipped and recorded, never run late.
    /// Covers timer coalescing and launch/wake latency, not a closed app or a sleeping Mac.
    nonisolated static let missedRunGrace: TimeInterval = 5 * 60

    /// Notes to append to a task's next run summary: runs missed just before a caught-up one, and
    /// slots skipped because the previous run was still going.
    private var pendingRunNotes: [UUID: [String]] = [:]

    /// Tasks `processDue` has decided to fire whose `fireTask` has not started yet. Launch decides
    /// due tasks twice (`rescheduleAll`, then the catch-up); without this the second pass spawned a
    /// second `fireTask` that was refused only by its own "already running" guard.
    private var pendingFireIDs: Set<UUID> = []

    /// Interrupted runs are reconciled once per process — see `reconcileInterruptedRuns`.
    private var didReconcileInterruptedRuns = false

    /// Wake / clock / time-zone observers, registered once by `startObservingSystemChanges`.
    private var systemObservers: [(NotificationCenter, NSObjectProtocol)] = []

    /// Weak reference set during app bootstrap (avoids circular dependency).
    weak var mainViewModel: MainApplicationViewModel?

    /// The shared model container, injected during app init.
    private var modelContainer: ModelContainer?

    /// True once `loadAllTasks()` has populated `scheduledTasks` from the store. Distinct from the container being
    /// configured: the container can be set while the array is empty, and every scheduling decision reads the array.
    private(set) var hasLoadedTasks = false

    /// Set when an evaluation was requested before the tasks were loaded, so the bootstrap can
    /// replay it instead of the request being lost (G52).
    private var pendingEvaluationAfterLoad = false

    private var mainContext: ModelContext? {
        modelContainer?.mainContext
    }

    /// Internal, not private, so tests can build their own instance over an in-memory store instead
    /// of repointing the shared one the test host's launch configured. The app uses `shared`.
    init() {}

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
            reconcileInterruptedRuns()

            // Replays an evaluation that arrived too early: `didBecomeActive` fires during a cold launch and can beat this
            // method.
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

    /// Stops a task whose backend profile is gone, instead of letting it fail on every fire. Disabled, not deleted: a
    /// task is user-authored work, and disabling is recoverable by repointing it at another profile. Reached by any cause
    /// that leaves the profile unresolvable, since retrying on a schedule cannot change that.
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
        // Guarded here rather than at the call site, because the call site is the app's launch and the test host runs it; an
        // armed timer would outlive its test and fire mid-run.
        guard TestHost.permits("arm scheduled-task timers", logger: logger) else { return }

        // Cancel all existing timers
        for id in timers.keys {
            cancelTimer(for: id)
        }

        // A task whose stored time has passed is decided first (run if within the grace, else recorded as missed); arming it
        // directly would recompute `nextRunAt` and erase the missed slot.
        let now = Date()
        for task in scheduledTasks where task.isEnabled && !task.isPaused {
            if let next = task.nextRunAt, next <= now {
                processDue(task, now: now)
            } else {
                scheduleTimer(for: task)
            }
        }
        logger.info("Rescheduled all active tasks.")
    }

    // MARK: - System clock changes

    /// Re-decides every task when the Mac wakes, the clock changes or the time zone changes. Cron follows the Mac's
    /// current local time, so a time-zone change re-derives the next run; a one-shot is an absolute instant and keeps it.
    func startObservingSystemChanges() {
        guard TestHost.permits("observe wake / clock / time-zone changes for scheduled tasks", logger: logger),
              systemObservers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let center = NotificationCenter.default
        let observe: (NotificationCenter, Notification.Name, String) -> Void = { nc, name, reason in
            let token = nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { SchedulerService.shared.handleSystemChange(reason: reason) }
            }
            self.systemObservers.append((nc, token))
        }
        observe(workspace, NSWorkspace.didWakeNotification, "wake")
        observe(center, .NSSystemClockDidChange, "clock change")
        observe(center, .NSSystemTimeZoneDidChange, "time-zone change")
    }

    func handleSystemChange(reason: String) {
        if reason == "time-zone change" { NSTimeZone.resetSystemTimeZone() }
        logger.info("[SCHEDULER] \(reason): re-deciding every scheduled task against the new time.")
        rescheduleAll()
    }

    func cancelTimer(for taskID: UUID) {
        timers[taskID]?.cancel()
        timers.removeValue(forKey: taskID)
    }

    private func scheduleTimer(for task: ScheduledTask) {
        // Replaces any armed timer so a second `DispatchSource` is never left armed to fire the task again.
        cancelTimer(for: task.id)
        guard task.isEnabled, !task.isPaused else { return }

        let nextDate: Date?

        if let cronStr = task.cronExpression, let cron = try? CronExpression(expression: cronStr) {
            nextDate = cron.nextFireDate(after: Date())
        } else if let scheduled = task.scheduledAt, scheduled > Date() {
            nextDate = scheduled
        } else {
            return // No valid schedule
        }

        guard let fireDate = nextDate else {
            logger.error(
                "[SCHEDULER] '\(task.displayName)' (\(task.id)) has no future run time. "
                + "CONSEQUENCE: no timer is armed and the task will not run until its schedule is edited.")
            return
        }

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
        // Uses a wall deadline: an uptime deadline stops counting during sleep. Waking past the slot fires at once and
        // `processDue` records it as missed.
        timer.schedule(wallDeadline: .now() + interval)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                guard let currentTask = self.scheduledTasks.first(where: { $0.id == taskID }) else { return }
                self.processDue(currentTask, now: Date())
            }
        }
        timer.resume()
        timers[task.id] = timer
        logger.info("Timer set for '\(task.displayName)' — fires at \(fireDate)")
    }

    // MARK: - Catch-up (App Foreground)

    /// Fires anything already overdue: the catch-up path for tasks whose moment passed while the app was closed or in the
    /// background. The only way an overdue one-shot task runs, since timers are armed only for future dates. An early
    /// call before `loadAllTasks()` is recorded and replayed.
    func evaluateAndFireDueTasks() {
        // Guarded: firing an overdue task is a real agent turn against the user's real API key, and the test host's
        // persistent store would keep re-firing tasks written by earlier tests.
        guard TestHost.permits("fire due scheduled tasks (each one is a real agent turn against the user's real API key)", logger: logger) else { return }

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
        var decided = 0
        for task in scheduledTasks where task.isEnabled && !task.isPaused {
            if let nextRun = task.nextRunAt, nextRun <= now, !runningTaskIDs.contains(task.id) {
                decided += 1
                processDue(task, now: now)
            }
        }
        if decided > 0 {
            logger.info("[SCHEDULER] Catch-up: decided \(decided) overdue task(s) out of \(self.scheduledTasks.count).")
        }
    }

    // MARK: - Due, missed, interrupted

    enum DueDecision: Equatable {
        /// The slot has not come yet (a timer fired early after a clock change).
        case notDue
        /// Run now. `missedBefore` earlier slots passed unrun and are noted in its summary.
        case fire(missedBefore: Int)
        /// Every passed slot is older than the grace: skip them all. `next` is the next future slot
        /// (nil for a one-shot, which is then over). `count` is capped at `missedCountCap`.
        case missed(count: Int, lastMissed: Date, next: Date?)
    }

    /// Counting stops here, so a minute-level cron after a month closed does not walk 40,000 slots.
    nonisolated static let missedCountCap = 1_000

    /// Decides what a task whose stored `nextRunAt` has passed should do. Pure, for tests.
    nonisolated static func dueDecision(nextRunAt: Date, cron: CronExpression?, now: Date,
                            grace: TimeInterval = missedRunGrace,
                            calendar: Calendar = .current) -> DueDecision {
        guard nextRunAt <= now else { return .notDue }
        guard let cron else {
            return now.timeIntervalSince(nextRunAt) <= grace
                ? .fire(missedBefore: 0)
                : .missed(count: 1, lastMissed: nextRunAt, next: nil)
        }
        var count = 0
        var last = nextRunAt
        var slot: Date? = nextRunAt
        while let s = slot, s <= now {
            count += 1
            last = s
            if count == missedCountCap {
                // Jump to the slots near now; everything in between is "1,000 or more".
                slot = cron.nextFireDate(after: now.addingTimeInterval(-grace), calendar: calendar)
                continue
            }
            slot = cron.nextFireDate(after: s, calendar: calendar)
        }
        if now.timeIntervalSince(last) <= grace { return .fire(missedBefore: count - 1) }
        return .missed(count: count, lastMissed: last, next: slot)
    }

    /// The one place a due task is acted on — timer, launch, activation, wake and clock changes all
    /// come here, so a slot is run, recorded as missed, or skipped as an overlap exactly once.
    func processDue(_ task: ScheduledTask, now: Date) {
        guard task.isEnabled, !task.isPaused, let nextRunAt = task.nextRunAt,
              !pendingFireIDs.contains(task.id) else { return }
        let cron = task.cronExpression.flatMap { try? CronExpression(expression: $0) }

        if runningTaskIDs.contains(task.id) {
            guard nextRunAt <= now, let cron else { return }
            // Overlap: the previous run is still going. Skipped, and said so after that run ends.
            pendingRunNotes[task.id, default: []].append(String(
                localized: "Skipped the \(Self.shortTime(nextRunAt)) run: the previous run was still going."))
            logger.warning(
                "[SCHEDULER] '\(task.displayName)' is still running at its \(nextRunAt) slot. "
                + "CONSEQUENCE: that slot is SKIPPED (no queue); noted in the run summary.")
            var updated = task
            updated.nextRunAt = cron.nextFireDate(after: now)
            persistSchedule(updated)
            return
        }

        switch Self.dueDecision(nextRunAt: nextRunAt, cron: cron, now: now) {
        case .notDue:
            scheduleTimer(for: task)
        case .fire(let missedBefore):
            if missedBefore > 0 {
                pendingRunNotes[task.id, default: []].append(String(
                    localized: "\(missedBefore) earlier run(s) were missed while Devgentic was closed or the Mac was asleep."))
                logger.info("[SCHEDULER] '\(task.displayName)': running the \(nextRunAt) slot; \(missedBefore) earlier slot(s) were missed and are NOT run.")
            }
            pendingFireIDs.insert(task.id)
            Task { @MainActor in await self.fireTask(task) }
        case .missed(let count, let lastMissed, let next):
            recordMissed(task, count: count, lastMissed: lastMissed, next: next)
        }
    }

    private func recordMissed(_ task: ScheduledTask, count: Int, lastMissed: Date, next: Date?) {
        var updated = task
        updated.status = .missed
        let reason = String(localized: "Devgentic was closed or the Mac was asleep.")
        updated.lastRunSummary = count == 1
            ? String(localized: "Missed the \(Self.shortTime(lastMissed)) run. \(reason)")
            : String(localized: "Missed \(count >= Self.missedCountCap ? "1,000+" : "\(count)") runs, the last at \(Self.shortTime(lastMissed)). \(reason)")
        if task.isRecurring {
            updated.nextRunAt = next
        } else {
            updated.isEnabled = false    // a one-shot's only run has passed
        }
        logger.warning(
            "[SCHEDULER] '\(task.displayName)' (\(task.id)) missed \(count) slot(s), last \(lastMissed). "
            + "CONSEQUENCE: skipped, NOT run late (owner policy); recorded on the task"
            + (task.isRecurring ? "; next run \(String(describing: next))." : "; the one-shot is now disabled."))
        updateTask(updated)
    }

    /// A task left `.running` by a previous process was interrupted. It is marked Cancelled and not run again, since it
    /// may already have done its side effects. Once per process, and never for a task this process is running, because
    /// `loadAllTasks` is also called by the sidebar.
    private func reconcileInterruptedRuns() {
        guard !didReconcileInterruptedRuns else { return }
        didReconcileInterruptedRuns = true
        for task in scheduledTasks where task.status == .running && !runningTaskIDs.contains(task.id) {
            var updated = task
            updated.status = .cancelled
            updated.lastRunSummary = String(localized: "Cancelled: Devgentic quit during this run.")
            if let cronStr = task.cronExpression, let cron = try? CronExpression(expression: cronStr) {
                // The interrupted slot RAN; start from the one after it, so later slots are judged
                // (run or missed) on their own.
                updated.nextRunAt = task.nextRunAt.flatMap { cron.nextFireDate(after: $0) }
                    ?? cron.nextFireDate(after: Date())
            } else {
                updated.isEnabled = false
            }
            logger.warning(
                "[SCHEDULER] '\(task.displayName)' (\(task.id)) was still marked running at launch. "
                + "CONSEQUENCE: recorded as Cancelled (interrupted by quit) and NOT re-run"
                + (task.isRecurring ? "; it waits for its next slot." : "; the one-shot is disabled."))
            updateTask(updated)
        }
    }

    /// Saves a new `nextRunAt` and re-arms, without touching anything else on the task.
    private func persistSchedule(_ task: ScheduledTask) {
        if let idx = scheduledTasks.firstIndex(where: { $0.id == task.id }) {
            scheduledTasks[idx].nextRunAt = task.nextRunAt
        }
        if let model = fetchModel(id: task.id) {
            model.nextRunAt = task.nextRunAt
            saveContext()
        }
        scheduleTimer(for: task)
    }

    private static func shortTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Execution

    func fireTask(_ task: ScheduledTask) async {
        pendingFireIDs.remove(task.id)
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
        let result = await vm.runScheduledMessage(
            prompt: resolvedPrompt,
            config: config,
            conversationID: conversationID,
            attachedFileURLs: task.attachedFileURLs,
            runLimit: task.runLimit
        )
        let summary = result.summary

        // Post-run bookkeeping is applied to the task as it is now, and only to the run's own fields, so changes the user
        // made during the run are not reverted.
        guard let current = scheduledTasks.first(where: { $0.id == task.id }) else {
            runningTaskIDs.remove(task.id)
            pendingRunNotes[task.id] = nil
            logger.info("[SCHEDULER] '\(task.displayName)' was deleted during its run; the outcome is not recorded on it.")
            return
        }
        updatedTask = current
        updatedTask.linkedConversationID = conversationID
        let notes = pendingRunNotes.removeValue(forKey: task.id) ?? []
        updatedTask.runCount = current.runCount + 1
        updatedTask.lastRunAt = Date()
        updatedTask.lastRunSummary = ([String(summary.prefix(100))] + notes).joined(separator: " ")
        // The run's real outcome (timeout, error card, missing conversation); a recurring task still returns to `.pending`
        // below, and its summary and notification carry the outcome.
        updatedTask.status = switch result.outcome {
        case .completed, .completedWithWarnings: .completed
        case .failed:    .failed
        case .timedOut:  .timedOut
        case .cancelled: .cancelled
        }

        // Compute next fire date for recurring tasks — from the CURRENT schedule.
        if let cronStr = current.cronExpression, let cron = try? CronExpression(expression: cronStr) {
            updatedTask.nextRunAt = cron.nextFireDate(after: Date())
            updatedTask.status = .pending
        } else if current.isOneShot {
            updatedTask.isEnabled = false
        }
        if current.isPaused { updatedTask.status = .paused }

        runningTaskIDs.remove(task.id)
        updateTask(updatedTask)   // re-arms the timer when still enabled and not paused

        // Fire notification
        let payload = AppNotificationPayload(
            title: result.outcome.notificationTitle,
            body: "\(task.displayName): \(summary.prefix(60))",
            conversationID: conversationID
        )
        await NotificationDispatcher.shared.dispatch(payload)

        logger.info("Task '\(task.displayName)' ran (run #\(updatedTask.runCount)) — outcome: \(String(describing: result.outcome)).")
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
            try SharedContextSave.save(context, "scheduler")
        } catch {
            logger.error("Failed to save SwiftData context: \(error.localizedDescription)")
        }
    }
}
