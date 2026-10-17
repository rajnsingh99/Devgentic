// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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

    /// How late a run may start and still count as on time. Past this it is MISSED: skipped and
    /// recorded, never run late (owner decision 2026-09-27, Timeout inventory D-22). Covers timer
    /// coalescing and launch/wake latency, not a closed app or a sleeping Mac.
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
        // ⚠️⚠️ GUARDED HERE RATHER THAN AT THE CALL SITE, because the call site is the app's launch
        // and the test host RUNS THE APP'S LAUNCH. An armed timer outlives the test that provoked
        // it: a suite taking minutes gives a cron task its next occurrence and fires it mid-run.
        guard TestHost.permits("arm scheduled-task timers", logger: logger) else { return }

        // Cancel all existing timers
        for id in timers.keys {
            cancelTimer(for: id)
        }

        // ⚠️ A task whose stored time has already passed is DECIDED first (run if within the grace,
        // else recorded as missed). Arming it straight away recomputed `nextRunAt` from now and
        // erased the passed slot, so a cron run missed while the app was quit left no trace (D-22).
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

    /// Re-decides every task when the Mac wakes, the clock is changed or the time zone changes.
    ///
    /// ⚠️ D-22: the timer used to be the only trigger, and a timer is armed as an interval. A Mac
    /// asleep through 9:00 ran the job late; a clock or time-zone change left the old instant armed.
    /// Cron follows the Mac's CURRENT local time, so a time-zone change re-derives the next run;
    /// a one-shot is an absolute instant and keeps it.
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
        // ⚠️ Replaces any armed timer. `fireTask` used to arm a second one after `updateTask` had
        // already armed the first, orphaning a live DispatchSource that fired the task again.
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
        // ⚠️ WALL deadline: an uptime deadline stops counting while the Mac sleeps, so a 9:00 job
        // fired at 11:00 after a two-hour sleep (D-22). Waking past the slot now fires at once and
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
        // ⚠️⚠️ THE MOST EXPENSIVE UNGUARDED LINE IN THE LAUNCH PATH. This fires overdue tasks, and
        // firing one is a REAL agent turn against the user's REAL API key — money, on every
        // `test-without-building` run. It is reached twice: `DevgenticApp` at launch, and again on
        // `didBecomeActive`, which a test host also triggers.
        //
        // ⚠️ AND IT COMPOUNDS, which is what makes it more than a one-off. `/tmp/devgentic-testhost.store`
        // PERSISTS BETWEEN RUNS, so a task any test writes is still there next time, overdue, and
        // fires then — a test that scheduled something once keeps spending money afterwards.
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

    /// A task left `.running` by a previous process was interrupted — Devgentic quit, crashed or was
    /// killed mid-run. It is marked Cancelled and NOT run again: it may already have done its side
    /// effects (owner decision 2026-09-27; the same rule as "never auto-retry a timed-out tool").
    ///
    /// ⚠️ Once per process, and never for a task this process is running: `loadAllTasks` is also
    /// called by the sidebar, while a run may be live.
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

        // ⚠️ Post-run bookkeeping is applied to the task AS IT IS NOW, and only to the run's own
        // fields. Writing back the copy taken at the start reverted anything the user changed
        // during the run — the prompt, the schedule, a pause, a disable (D-22).
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
        // ⚠️ The run's REAL outcome. This was `.completed` for everything — a timeout, an error
        // card, a missing conversation (Timeout inventory D-13). A recurring task still returns to
        // `.pending` below; its summary and notification carry the outcome.
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
