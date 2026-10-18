// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AppDelegate.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import os
import HotKey
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    
    private static let logger = DGLogger(category: "AppDelegate")
    
    /// The real AppDelegate instance, captured at launch; nil only before `applicationDidFinishLaunching`.
    /// Under `@NSApplicationDelegateAdaptor`, `NSApplication.shared.delegate` is SwiftUI's wrapper, so casting it traps.
    static private(set) var shared: AppDelegate!

    var contentWindow: QuickAccessPanelView?
    var hotKey: HotKey?
    /// Orb's global shortcut. Separate registration from QuickAccess's: push-to-talk needs
    /// BOTH Carbon edges, and the two features must be independently enable-able.
    var orbHotKey: HotKey?

    /// [QA revival P1a] The shared object graph, injected from DevgenticApp once the app is
    /// up (AppDelegate and the panel live outside the SwiftUI environment). Weak — both are
    /// owned for the app's lifetime by DevgenticApp's @State.
    weak var quickAccessMainViewModel: MainApplicationViewModel?
    weak var quickAccessThemeManager: ThemeManager?

    /// The profile editor's unsaved state, consulted by `applicationShouldTerminate`.
    /// Weak: DevgenticApp's `@State` owns it. Nil until `configureTerminationGuard` runs; a nil guard fails open on quit
    /// and logs it.
    weak var profileService: BackendProfileService?

    /// Owner of the main Workflow interface's canvas states, injected alongside `profileService`.
    /// A second, independent source of unsaved canvas work: two `WorkflowEditGuard` instances exist because both canvases
    /// can be mounted at once.
    weak var workflowCanvasOwner: MainApplicationViewModel?

    /// True when the QuickAccess panel is the key window, i.e. the user is looking at it.
    /// The panel is non-activating, so it can be key while `NSApp.isActive` is false; a merely visible background panel is
    /// not key.
    @MainActor var isQuickAccessPanelKey: Bool { contentWindow?.isKeyWindow ?? false }

    /// [QA revival P2d] Menu-bar status item — click toggles the panel; it badges with the
    /// global pending-HITL count so a run parked while the main window is closed is visible.
    private var statusItem: NSStatusItem?
    private var pendingBadgeObserver: ObservationStream?
    private var isTogglingWindow = false
    /// A summon that arrived before the shared graph was injected: holds the requested `forceExpand`, replayed after
    /// injection.
    /// nil when nothing is pending.
    private var pendingShowForceExpand: Bool?
    /// [QA revival P1d] Read from QuickAccessConfigManager (default 60 s —
    /// `QuickAccessConfigManager.sessionTimeoutSeconds`) instead of hardcoded.
    private var sessionTimeoutDuration: TimeInterval {
        TimeInterval(QuickAccessConfigManager.shared.sessionTimeoutSeconds)
    }


    func applicationDidFinishLaunching(_ notification: Notification) {
        // [QA revival P1a] Capture the real instance for AppDelegate.shared (NSApp.delegate
        // is SwiftUI's wrapper under the adaptor). Runs before any view's .task.
        Self.shared = self

        // Ensure modern overlay scrollers with hidden tracks across the app
        ScrollerCustomizer.install()

        // Whether this launch got SWIFT_DETERMINISTIC_HASHING (Info.plist LSEnvironment / the
        // scheme). Without it every MLX prompt re-renders its tool list in a new order each turn.
        DeterministicHashing.logLaunchStatus()

        // Captured before any trace begins this session, so orphan reconciliation never touches a trace of the current process.
        let launchInstant = Date()

        // Consumes the clean-exit sentinel first: false means the previous session crashed or was force-killed.
        // Feeds the reconciliation reason below, then registers for MetricKit diagnostics.
        let previousExitWasClean = CrashDiagnosticsCollector.consumeLaunchSentinel()
        CrashDiagnosticsCollector.shared.start()
        if !previousExitWasClean {
            Self.logger.error("Previous session did not exit cleanly (crash or force-quit). MetricKit diagnostics, if any, arrive shortly; .ips reports are folded into diagnostic bundles.")
        }

        // Points MCPClientService at the app's tool store and HITL brokers; must run before anything can connect a server.
        // Otherwise a refreshed tool list has nowhere to land and sampling/elicitation are refused.
        MCPHostBridge.installAppImplementations()

        // Set this delegate so UNUserNotificationCenter can deliver notifications
        // both when the app is in the foreground AND in the background.
        UNUserNotificationCenter.current().delegate = self
        Self.logger.info("UNUserNotificationCenter delegate set.")
        applyHotkeyConfig()
        applyOrbHotkeyConfig()
        setupStatusItem()
        setupNotificationObserver()

        // Cleans up leftover QuickAccess screen-capture temp files from earlier sessions; pure file I/O, so off the main thread.
        Task.detached(priority: .utility) {
            QuickAccessScreenCaptureService.sweepOrphanedCaptureFiles()
        }

        // 30-day observability purge + orphan reconciliation. Runs in a detached
        // background task so startup isn't delayed by the SQLite work on large archives.
        Task.detached(priority: .background) {
            guard let store = TraceStore.shared else { return }
            let cutoff = launchInstant.addingTimeInterval(-30 * 24 * 3600)

            // Purges aged traces; spans, events and configs cascade through the foreign key.
            do {
                try store.purgeOlderThan(cutoff)
            } catch {
                Self.logger.error("Trace purge failed: \(error.localizedDescription)")
            }
            if let purged = try? store.purgeLogEntriesOlderThan(cutoff), purged > 0 {
                Self.logger.info("Purged \(purged) log entries older than 30 days.")
            }

            // Stamps traces left `running` by a previous session as `.interrupted`, so they do not skew reliability stats.
            // The clean-exit sentinel separates a crash or force-quit from a normal quit mid-run.
            let orphanReason = previousExitWasClean
                ? "App quit during run (interrupted)"
                : "App crashed or was force-quit during run"
            if let reconciled = try? store.reconcileOrphanedTraces(
                before: launchInstant,
                reason: orphanReason
            ), reconciled > 0 {
                Self.logger.info("Reconciled \(reconciled) orphaned running trace(s) to .interrupted (\(orphanReason)).")
            }

            // [HITL/C2] Same retention + orphan-reconcile for the durable HITL audit: prune aged rows,
            // then stamp any request still pending from a previous session as `interrupted`.
            if let purgedHITL = try? store.purgeHITLAuditOlderThan(cutoff), purgedHITL > 0 {
                Self.logger.info("Purged \(purgedHITL) HITL audit record(s) older than 30 days.")
            }
            if let reconciledHITL = try? store.reconcileOrphanedHITL(
                before: launchInstant,
                reason: orphanReason
            ), reconciledHITL > 0 {
                Self.logger.info("Reconciled \(reconciledHITL) interrupted HITL audit record(s) (\(orphanReason)).")
            }

            // Persisted MetricKit payloads follow the same 30-day retention as traces.
            CrashDiagnosticsCollector.purgeDiagnostics(olderThan: cutoff)
        }
    }

    /// Allow banners / sounds to appear even while the app is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }

    /// Handle user tapping a notification (e.g., to open the relevant conversation).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let conversationIDString = userInfo["conversationID"] as? String {
            Self.logger.info("Notification tapped with conversationID: \(conversationIDString)")
            // Post an internal notification so the UI can navigate to the conversation.
            NotificationCenter.default.post(
                name: GlobalConstants.openConversationNotification,
                object: nil,
                userInfo: ["conversationID": conversationIDString]
            )
        }
        completionHandler()
    }

    // Why: Do not block the main thread on semaphores here: the teardown Tasks inherit MainActor and would never start.
    /// Async teardown with the run loop alive: `.terminateLater` keeps the main actor processing, then `reply` resumes
    /// quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Before any teardown: once `.terminateLater` is returned the app is going away, so this is the last chance to rescue
        // unsaved work.
        if case .cancel = handleUnsavedProfileEditsBeforeQuit() {
            Self.logger.info("[PROFILE] Quit CANCELLED by the user at the unsaved-changes prompt. "
                             + "CONSEQUENCE: the app stays open with the editor untouched.")
            return .terminateCancel
        }

        // Second, independent gate: a run in flight can only finish or be frozen, unlike a dirty canvas.
        // Sequenced after the canvas gate because the two alerts describe unrelated risks and remedies.
        if case .cancel = handleInFlightWorkflowRunsBeforeQuit() {
            Self.logger.info("[WF_RUN] Quit CANCELLED by the user at the in-flight-run prompt. "
                             + "CONSEQUENCE: the app stays open; every in-flight run keeps running.")
            return .terminateCancel
        }

        Self.logger.info("Application requested to terminate — running async teardown.")

        Task { @MainActor in
            // A real bound on quit teardown: `DeadlineRace` returns at the limit and names the step still running.
            // A task group cannot return before a hung step does, so one stuck step would hang quit silently.
            let tracker = QuitTeardownTracker()
            let started = Date()
            let outcome = try? await DeadlineRace.run(limit: Self.quitTeardownLimit, stopGrace: 0.2) {
                await Self.performAsyncTeardown(tracker)
            }
            if case .timedOut? = outcome {
                Self.logger.error("[QUIT] Teardown passed its \(Int(Self.quitTeardownLimit))s limit while '\(tracker.step)' was still running (\(String(format: "%.1f", Date().timeIntervalSince(started)))s). CONSEQUENCE: quitting anyway — steps after it did not run; MCP child processes are force-killed next.")
            } else {
                Self.logger.info("[QUIT] Teardown finished in \(String(format: "%.1f", Date().timeIntervalSince(started)))s.")
            }

            // Whatever the watchdog cut short, no MCP child may outlive us: ShellProcess's SIGTERM-to-SIGKILL escalation cannot
            // fire this late.
            MCPClientService.shared.killAllChildProcessesNow()

            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Quit-time unsaved-changes guard (register A29)

    /// Arms the quit-time guard. Separate from `configureQuickAccess` because it has nothing to do
    /// with the panel — until this runs, `applicationShouldTerminate` cannot see the editor.
    func configureTerminationGuard(
        profileService: BackendProfileService,
        mainAppViewModel: MainApplicationViewModel
    ) {
        self.profileService = profileService
        self.workflowCanvasOwner = mainAppViewModel
        Self.logger.info("[PROFILE] AppDelegate: quit-time unsaved-changes guard armed (profile editor + workflow canvases).")
    }

    enum QuitDecision { case proceed, cancel }

    // Why: `NSAlert.runModal()` is fine here: this is an AppKit delegate callback, not a SwiftUI update pass.
    /// Offers Save / Discard / Cancel when the profile editor holds unsaved work, and reports whether quitting may continue.
    /// Uses `hasUnsavedEditorChanges`, not `editBuffer?.isDirty`: a workflow canvas keeps its dirt in `WorkflowCanvasState`.
    @MainActor
    private func handleUnsavedProfileEditsBeforeQuit() -> QuitDecision {
        guard let profileService else {
            Self.logger.notice(
                "[PROFILE] Quit is NOT gated on unsaved editor changes: the profile service was "
                + "never injected into AppDelegate. CONSEQUENCE: if an editor is open with unsaved "
                + "work, it is being discarded silently — the failure this guard exists to prevent."
            )
            return .proceed
        }
        // Flush first: a floating prompt editor writes back only on an explicit commit, a third source of unsaved work
        // that neither the buffer nor the canvas reports and that Cmd-Q has no teardown to commit.
        profileService.flushPendingEditorText()

        // The main Workflow interface's canvases are a separate source of dirt; both can be dirty at once.
        // Read every cached canvas, not just the on-screen one.
        if workflowCanvasOwner == nil {
            Self.logger.notice(
                "[WF_CANVAS] Quit is NOT gated on unsaved workflow-canvas edits: the main view model "
                + "was never injected into AppDelegate. CONSEQUENCE: unsaved graph work in the "
                + "Workflow interface is being discarded silently."
            )
        }
        let dirtyWorkflowIDs = workflowCanvasOwner?.unsavedWorkflowCanvasProfileIDs ?? []

        // Skill drafts are a fourth source of unsaved work; they live in `SkillDraftStore` for the app run,
        // so quit is the only exit that loses them and the only place skills are gated.
        let dirtySkillIDs = SkillDraftStore.shared.skillIDsWithUnsavedEdits

        guard profileService.hasUnsavedEditorChanges
                || !dirtyWorkflowIDs.isEmpty
                || !dirtySkillIDs.isEmpty else { return .proceed }

        if !dirtySkillIDs.isEmpty {
            Self.logger.notice(
                "[SKILL_EDIT] Quit is gated on \(dirtySkillIDs.count) skill draft(s) with unsaved "
                + "instructions: \(dirtySkillIDs.joined(separator: ", ")). CONSEQUENCE: quitting "
                + "discards them — a draft is deliberately never persisted, because a half-typed "
                + "instruction surviving a crash would look like a saved version, and versions are "
                + "append-only and reach every linked profile."
            )
        }

        let bufferDirty = profileService.editBuffer?.isDirty == true
        let canvasDirty = profileService.canvasEditGuard.hasUnsavedChanges
        Self.logger.notice(
            "[PROFILE] Quit requested with unsaved changes (buffer dirty: \(bufferDirty), "
            + "editor canvas dirty: \(canvasDirty), workflow canvases dirty: \(dirtyWorkflowIDs.count)) "
            + "for '\(profileService.editBuffer?.draft.displayName ?? "no open profile")'. "
            + "CONSEQUENCE: prompting before teardown; quit is blocked until the user answers."
        )

        let alert = NSAlert()
        alert.messageText = String(localized: "You have unsaved changes")
        // Name the workflow canvas when that is what is dirty: 'profile edits' sends the user looking for an editor they never
        // opened.
        alert.informativeText = dirtyWorkflowIDs.isEmpty
            ? String(localized: "Your profile edits haven't been saved yet. Quitting now discards them.")
            : String(localized: "Your workflow canvas has unsaved changes. Quitting now discards them.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Save and Quit"))
        alert.addButton(withTitle: String(localized: "Discard and Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveOpenProfileEdits(on: profileService)

        case .alertSecondButtonReturn:
            Self.logger.notice(
                "[PROFILE] User chose DISCARD at the quit prompt. CONSEQUENCE: the unsaved edits to "
                + "'\(profileService.editBuffer?.draft.displayName ?? "the open profile")' are gone; "
                + "the persisted profile is unchanged."
            )
            return .proceed

        default:
            return .cancel
        }
    }

    // MARK: - [WF-LC2] Quit-time in-flight-workflow-run guard

    // Why: `forceFinalizeActiveRuns` runs only on the affirmative branch: `didFinalize` is permanent, so an early freeze
    // strands a run.
    /// Warns when workflow runs are still executing, and freezes each on proceed.
    /// Per-node output exists only in the live `WorkflowExecutionState` until `finalize()` runs, so quitting would lose it.
    @MainActor
    private func handleInFlightWorkflowRunsBeforeQuit() -> QuitDecision {
        let count = WorkflowRunTicket.activeRunCount
        guard count > 0 else { return .proceed }

        Self.logger.notice(
            "[WF_RUN] Quit requested with \(count) workflow run(s) still in flight. "
            + "CONSEQUENCE: prompting before teardown; quit is blocked until the user answers."
        )

        let alert = NSAlert()
        alert.messageText = count == 1
            ? String(localized: "A workflow is still running")
            : String(localized: "\(count) workflows are still running")
        // Name what is running (a bare count cannot identify a QuickAccess or Orb run); caps at 4 names, then falls back to
        // the count.
        let names = WorkflowRunTicket.activeRunNames
        let namesLine = names.count <= 4
            ? names.map { "• \($0)" }.joined(separator: "\n")
            : nil
        // Matches `settleInFlightWork`: only nodes still `.running` are relabelled Cancelled; completed nodes keep their result.
        let consequence = String(localized: "Completed steps keep their real result. Any step still in progress is marked Cancelled.")
        alert.informativeText = namesLine.map { "\($0)\n\n\(consequence)" } ?? consequence
        alert.alertStyle = .warning
        // Cancel first, so the safe option is the Return-key default, as in the other destructive quit-time alerts.
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Quit Anyway"))

        switch alert.runModal() {
        case .alertSecondButtonReturn:
            WorkflowRunTicket.forceFinalizeActiveRuns(reason: "Quit during run")
            return .proceed

        default:
            return .cancel
        }
    }

    /// Persists whatever is dirty, and refuses to quit if any part of it fails.
    /// Quitting after a failed save would destroy work the user asked to keep; a failure cancels the quit and says why.
    @MainActor
    private func saveOpenProfileEdits(on profileService: BackendProfileService) -> QuitDecision {
        // Main Workflow interface canvases FIRST — this drains every cached dirty canvas, including
        // ones for workflows the user has since switched away from, which no on-screen hook covers.
        var drainedProfileIDs: Set<UUID> = []
        // Tracked separately from `drainedProfileIDs`: this answers 'was this id persisted, or refused?', which the
        // skip-check's log text needs.
        var refusedProfileIDs: Set<UUID> = []
        // Distinct from 'the drain covered nothing': a nil owner means the drain never ran (quit fails open before injection),
        // so the fallback warning below must not assert data loss.
        let drainDidRun = workflowCanvasOwner != nil
        if let workflowCanvasOwner {
            let drain = workflowCanvasOwner.persistDirtyWorkflowCanvases(profileService: profileService)
            // A refused profile counts as handled by the drain like a persisted one; leaving it out
            // would fire a redundant `saveHook()` and wrongly log 'layout persisted'.
            drainedProfileIDs = Set(drain.persisted).union(drain.refused.map(\.id))
            refusedProfileIDs = Set(drain.refused.map(\.id))
            if !drain.failed.isEmpty {
                Self.logger.error(
                    "[WF_CANVAS] Quit-time save FAILED for \(drain.failed.count) workflow canvas(es): "
                    + "\(drain.failed.map(\.uuidString).joined(separator: ", ")). CONSEQUENCE: quit is "
                    + "CANCELLED rather than discarding graph work the user asked to keep."
                )
                if !drain.refused.isEmpty {
                    // `refused` is dropped by this early return on purpose: the failed canvas is where the actionable escape lives.
                    // The log line keeps the read-only-canvas prompt from surprising the user on the next quit attempt.
                    Self.logger.notice(
                        "[WF_CANVAS] \(drain.refused.count) additional workflow canvas(es) are also "
                        + "refused by design (not shown in this alert — the transient failure above "
                        + "takes priority): \(drain.refused.map(\.id.uuidString).joined(separator: ", ")). "
                        + "CONSEQUENCE: the read-only-canvas prompt will appear on a SUBSEQUENT quit "
                        + "attempt, once the failure above is resolved or discarded."
                    )
                }
                presentQuitSaveFailure(String(
                    localized: "A workflow canvas couldn't be saved automatically. Save it from the canvas, then quit."))
                return .cancel
            }
            // Checked after `failed`, never merged: a refused canvas can never be saved by retrying, so it needs an honest choice.
            // If both are dirty, the `failed` branch above already returned, which is correct.
            if !drain.refused.isEmpty {
                if case .cancel = presentReadOnlyCanvasQuitChoice(drain.refused, profileService: profileService) {
                    Self.logger.info(
                        "[WF_CANVAS] Quit CANCELLED by the user at the read-only-canvas prompt "
                        + "(\(drain.refused.count) canvas(es)). CONSEQUENCE: the app stays open; "
                        + "the canvas(es) remain dirty and read-only, unchanged."
                    )
                    return .cancel
                }
                Self.logger.notice(
                    "[WF_CANVAS] User chose Quit Anyway at the read-only-canvas prompt "
                    + "(\(drain.refused.count) canvas(es)). CONSEQUENCE: quit proceeds; the in-memory "
                    + "edits to \(drain.refused.map(\.id.uuidString).joined(separator: ", ")) are lost, "
                    + "but the on-disk layout is byte-intact — nothing was written or could be."
                )
            }
        }

        if profileService.canvasEditGuard.hasUnsavedChanges {
            // Both this `saveHook` and the drain write `WorkflowLayoutSD` with no compare-and-swap; a divergence would lose a graph.
            // Key off profile identity, not the guard's dirty flag, which reads stale-true after a successful drain.
            if let registeredID = profileService.canvasEditGuard.registeredProfileID,
               drainedProfileIDs.contains(registeredID) {
                // The two ids in this set need different log text: a persisted one was written, a refused one was not.
                if refusedProfileIDs.contains(registeredID) {
                    Self.logger.info(
                        "[WF_CANVAS] Quit-time save: the on-screen canvas (workflow \(registeredID)) "
                        + "was already handled by the cached-canvas drain as a by-design REFUSAL, so "
                        + "its saveHook is SKIPPED. CONSEQUENCE: none beyond what the read-only-canvas "
                        + "prompt already reported — nothing was written by either path; the edits "
                        + "remain unsaved, exactly as that prompt said."
                    )
                } else {
                    Self.logger.info(
                        "[WF_CANVAS] Quit-time save: the on-screen canvas (workflow \(registeredID)) was "
                        + "already persisted by the cached-canvas drain, so its saveHook is SKIPPED. "
                        + "CONSEQUENCE: none — both resolve to the same shared WorkflowCanvasState, and "
                        + "skipping avoids a second write to the same layout row."
                    )
                }
            } else {
                guard let saveHook = profileService.canvasEditGuard.saveHook else {
                    Self.logger.error(
                        "[PROFILE] Quit-time save requested but the workflow canvas registered NO save "
                        + "hook. CONSEQUENCE: the canvas layout cannot be persisted from here; quit is "
                        + "cancelled so the user can save it from the canvas itself."
                    )
                    presentQuitSaveFailure(String(
                        localized: "The workflow canvas couldn't be saved automatically. Save it from the canvas, then quit."))
                    return .cancel
                }
                // Reaching here means the on-screen canvas holds state the view model does not know about; log it, do not save silently.
                // Only when the drain ran: with a nil `workflowCanvasOwner` this hook is the only thing saving the canvas.
                if drainDidRun, let registeredID = profileService.canvasEditGuard.registeredProfileID {
                    Self.logger.error(
                        "[WF_CANVAS] Quit-time save: the on-screen canvas for workflow \(registeredID) "
                        + "was NOT covered by the cached-canvas drain, so it holds a state the view "
                        + "model does not own. CONSEQUENCE: its saveHook is running as a fallback and "
                        + "will overwrite that workflow's layout row with this canvas's graph; if "
                        + "another surface was editing the same workflow, its edits are being lost. "
                        + "Mount sites must inject MainApplicationViewModel.workflowCanvasState(for:)."
                    )
                }
                saveHook()
                Self.logger.info("[PROFILE] Quit-time save: workflow canvas layout persisted.")
            }
        }

        if let buffer = profileService.editBuffer, buffer.isDirty {
            do {
                try profileService.saveProfile(buffer.draft)
                buffer.markSaved()
                Self.logger.info(
                    "[PROFILE] Quit-time save: profile '\(buffer.draft.displayName)' "
                    + "(\(buffer.draft.id)) persisted; proceeding with quit."
                )
            } catch {
                // Reachable in ordinary use: `ProfileValidator` rejects e.g. an over-length name, and the agent editor's pre-flight
                // lives in the view.
                Self.logger.error(
                    "[PROFILE] Quit-time save FAILED for '\(buffer.draft.displayName)' "
                    + "(\(buffer.draft.id)): \(error.localizedDescription). CONSEQUENCE: quit is "
                    + "CANCELLED rather than discarding the edits the user asked to keep."
                )
                presentQuitSaveFailure(error.localizedDescription)
                return .cancel
            }
        }

        return .proceed
    }

    @MainActor
    private func presentQuitSaveFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Couldn't save your changes")
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    /// Asks about dirty canvases refused by design (newer-version or unreadable stored layout): Cancel or Quit Anyway.
    /// No unit-test seam: it drives a real `NSAlert.runModal()`; the decision vocabulary it consumes is tested separately.
    /// Cancel is the Return-key default and added first; 'Quit Anyway' discards unrecoverable in-memory edits.
    @MainActor
    private func presentReadOnlyCanvasQuitChoice(
        _ refused: [(id: UUID, outcome: WorkflowLayoutSaveOutcome)],
        profileService: BackendProfileService
    ) -> QuitDecision {
        // Falls back rather than force-unwrapping: `quitTimeRefusalReason` is nil only for a case already filtered out.
        // Entries are named, so two canvases refused for the same reason stay distinguishable.
        let lines = refused.map { entry -> String in
            let name = profileService.profiles.first(where: { $0.id == entry.id })?.displayName
                ?? entry.id.uuidString
            let reason = entry.outcome.quitTimeRefusalReason
                ?? String(localized: "This workflow's layout can't be saved on this build.")
            return "\(name): \(reason)"
        }

        let alert = NSAlert()
        alert.messageText = refused.count == 1
            ? String(localized: "A workflow canvas can't be saved")
            : String(localized: "\(refused.count) workflow canvases can't be saved")
        // Each reason on its own line — matches the multi-run naming this session's WF-LC2 alert
        // added for the identical "don't leave the user guessing which one" reason.
        alert.informativeText = lines.joined(separator: "\n\n")
            + "\n\n"
            + String(localized: "Your on-disk layout is unchanged either way — only the edits you made this session are at risk. Quitting now discards them.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Quit Anyway"))

        switch alert.runModal() {
        case .alertSecondButtonReturn:
            return .proceed
        default:
            return .cancel
        }
    }

    /// Everything that needs `await` before quitting. Runs while the run loop is alive
    /// (from `applicationShouldTerminate`), so MainActor-bound services are reachable.
    /// The whole quit teardown's hard limit. At it, the app quits whatever is still running.
    static let quitTeardownLimit: TimeInterval = 5

    /// Saving workflow history is the one step where waiting protects data, so it gets its own
    /// share of the limit rather than being able to consume all of it.
    static let quitPersistLimit: TimeInterval = 3

    // Why: Order is load-bearing: killing shell tasks after the MCP disconnect left builds and dev servers running after a hang
    // there.
    /// Quit teardown in a fixed order: shell tasks first (fast, cannot hang), then the capped workflow-history save,
    /// then everything else best effort inside the limit.
    private static func performAsyncTeardown(_ tracker: QuitTeardownTracker) async {
        tracker.step = "terminate background tasks"
        // Likewise for the children a conversation started (`batch_command(background:)`), which would outlive the app.
        // Synchronous, sleeping once for `quitGrace` between SIGTERM and SIGKILL; async could let the limit fire first.
        BackgroundProcessRegistry.shared.terminateAll()

        tracker.step = "save workflow history"
        // First, before the observability flush so its logs ship: await any in-flight workflow-run persist.
        // `finalize()` is fire-and-forget, so exiting mid-write strands the `.running` stub; capped at `quitPersistLimit`.
        if case .timedOut? = try? await DeadlineRace.run(limit: quitPersistLimit, stopGrace: 0, work: {
            await WorkflowRunTicket.drainPendingPersists()
        }) {
            Self.logger.error("[QUIT] Saving workflow history passed its \(Int(quitPersistLimit))s share. CONSEQUENCE: the most recent workflow run record may not be saved; quitting continues.")
        }

        tracker.step = "stop speech recognition"
        // Stops any live Whisper capture so the HAL client closes cleanly: a running AVAudioEngine at process death can wedge
        // coreaudiod into refusing this app's audio IO (`_StartIO error 35`). No-op when nothing is recording.
        _ = await WhisperRecognitionService.shared.stopStreaming()

        tracker.step = "disconnect MCP servers"
        // Disconnect MCP sessions so child processes (npx/uvx/etc.) don't get
        // re-parented to launchd as orphans (SIGTERM, escalating to SIGKILL).
        await MCPClientService.shared.disconnectAll()

        tracker.step = "flush logs and traces"
        // Flush observability buffers to SQLite (Gap #13): up to 5s of logs and 1s of
        // span events are otherwise lost on quit.
        await LogRecorder.shared.prepareForTermination()
        await TraceRecorder.shared.prepareForTermination()

        tracker.step = "unload models"
        // Unload local models cleanly (App RAM + Ollama VRAM).
        let stats = await MLXService.shared.unloadModel()
        Self.logger.info("Termination MLX cleanup stats: \(stats)")
        // Only the Ollama models THIS app used (U10): the server may be serving other apps.
        await LocalInferenceCoordinator.shared.unloadOllamaModelsWeUsed()
        tracker.step = "done"
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.logger.info("Application will terminate.")

        // Last graceful chance: the panel-scoped Orb duplex engine may still be live, and an AVAudioEngine at process death
        // wedges coreaudiod (`_StartIO error 35`) and leaves the mic dead across relaunches. Crashes cannot be covered.
        OrbDuplexAudio.shared.release(reason: "application terminating")

        // Flush the composer drafts NOW — writes are coalesced half a second behind typing, and
        // the last keystrokes before Quit would otherwise be lost.
        MainActor.assumeIsolated { ComposerDraftStore.shared.writeNow() }

        // Marks this session cleanly exited; crashes and force-quits never get here, so the next launch reads the stale `false`.
        CrashDiagnosticsCollector.markCleanExit()
    }

    /// [QA revival P1d] (Re)register the global hotkey from QuickAccessConfigManager. Called at
    /// launch and whenever the settings pane changes the shortcut or enable flag. Assigning
    /// `hotKey` replaces any prior Carbon registration; nil unregisters (when disabled).
    func applyHotkeyConfig() {
        // A Carbon hotkey is registered system-wide for the life of the process, so a test host would steal the combo
        // from the developer's running copy and read their real `UserDefaults`.
        guard TestHost.permits("register the system-wide QuickAccess hotkey", logger: Self.logger) else { return }

        let config = QuickAccessConfigManager.shared
        hotKey = nil

        // The enable flag governs the whole feature: reflect it on the menu-bar item and close any open panel immediately.
        statusItem?.isVisible = config.isEnabled

        guard config.isEnabled else {
            Self.logger.info("QuickAccess disabled — hotkey unregistered and menu-bar item hidden.")
            if contentWindow != nil { closeContentWindow() }
            return
        }

        // Probes registration before the package registers, since the HotKey package swallows the OSStatus.
        // Combos the system consumes upstream (e.g. Cmd-Space) are blocked at record time by `HotkeyValidator`.
        let canRegister = HotkeyRegistrationProbe.canRegister(
            carbonKeyCode: config.carbonKeyCode, carbonModifiers: config.carbonModifiers
        )

        let hk = HotKey(carbonKeyCode: config.carbonKeyCode, carbonModifiers: config.carbonModifiers)
        hk.keyDownHandler = { [weak self] in
            DispatchQueue.main.async { self?.toggleContentWindow() }
        }
        hotKey = hk

        if canRegister {
            Self.logger.info("QuickAccess hotkey registered: \(config.shortcutDescription)")
        } else {
            Self.logger.warning("QuickAccess hotkey \(config.shortcutDescription) could not be registered — it may be held by another app. The shortcut will not fire until changed.")
        }
    }

    /// (Re)registers Orb's global shortcut from `OrbConfigManager`; called at launch and when the shortcut, mode or enable
    /// flag changes.
    /// Registered only in `.holdShortcut` mode: the other modes already hold the microphone open.
    @MainActor
    func applyOrbHotkeyConfig() {
        // The Orb hotkey opens the microphone and is registered system-wide from the developer's real defaults,
        // so a keystroke during a test run could start capturing audio.
        guard TestHost.permits("register the system-wide Orb push-to-talk hotkey (it opens the microphone)", logger: Self.logger) else { return }

        let config = OrbConfigManager.shared
        orbHotKey = nil

        // The enable flag governs the WHOLE feature: close an open panel so turning Orb off
        // takes effect immediately rather than leaving a live microphone floating over every Space.
        if !config.isEnabled, OrbPanelController.shared.isOpen {
            OrbPanelController.shared.close(reason: "Orb disabled in Settings")
        }

        guard config.isEnabled, config.activationMode == .holdShortcut else {
            Self.logger.info("[ORB] Global shortcut not registered (enabled: \(config.isEnabled), mode: \(config.activationMode.rawValue)). CONSEQUENCE: in this mode the orb is reached from the composer button or an already-open panel.")
            return
        }

        // Probe BEFORE the package registers: the soffes/HotKey package swallows
        // RegisterEventHotKey's OSStatus, so it cannot tell us when the OS refuses.
        let canRegister = HotkeyRegistrationProbe.canRegister(
            carbonKeyCode: config.carbonKeyCode, carbonModifiers: config.carbonModifiers
        )
        let hk = HotKey(carbonKeyCode: config.carbonKeyCode, carbonModifiers: config.carbonModifiers)
        hk.keyDownHandler = { [weak self] in
            DispatchQueue.main.async { self?.orbPushToTalkDown() }
        }
        hk.keyUpHandler = { [weak self] in
            DispatchQueue.main.async { self?.orbPushToTalkUp() }
        }
        orbHotKey = hk

        if canRegister {
            Self.logger.info("[ORB] Push-to-talk shortcut registered: \(config.shortcutDescription)")
        } else {
            Self.logger.warning("[ORB] Push-to-talk shortcut \(config.shortcutDescription) could not be registered — another app likely holds it. CONSEQUENCE: the shortcut will never fire and, in hold-to-talk mode, the composer button is the only way in until the combo is changed.")
        }
    }

    @MainActor private func orbPushToTalkDown() {
        guard let mainVM = quickAccessMainViewModel else {
            Self.logger.warning("[ORB] Push-to-talk pressed before the shared view model was injected. CONSEQUENCE: this press does nothing; the shortcut works once the main window has finished mounting.")
            return
        }
        // Opening the panel on first press is the point of the shortcut: Orb was otherwise
        // reachable only from a composer button that exists in chat interface mode alone.
        if !OrbPanelController.shared.isOpen {
            OrbPanelController.shared.show(mainVM: mainVM)
        }
        OrbPanelController.shared.beginPushToTalk()
    }

    @MainActor private func orbPushToTalkUp() {
        OrbPanelController.shared.endPushToTalk()
    }

    /// Pause/resume BOTH global shortcuts while a settings recorder is armed, so pressing a
    /// current combo to re-record it reaches the recorder instead of firing the feature.
    @MainActor
    func setOrbHotkeyPaused(_ paused: Bool) {
        orbHotKey?.isPaused = paused
    }

    /// [M3] Pause/resume the live global hotkey while the settings recorder is armed, so pressing
    /// the CURRENT combo to re-record it is captured by the recorder instead of summoning the
    /// panel over Settings. No-op if no hotkey is registered.
    func setHotkeyPaused(_ paused: Bool) {
        hotKey?.isPaused = paused
    }
    
    private func setupNotificationObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowQuickAccessPanelNotification(_:)),
            name: GlobalConstants.showQuickAccessPanelNotification,
            object: nil
        )
        Self.logger.info("Added observer for showQuickAccessPanelNotification.")
    }
    
    @objc private func handleShowQuickAccessPanelNotification(_ notification: Notification) {
         Self.logger.info("Received showQuickAccessPanelNotification.")
         let forceExpand = notification.userInfo?["forceExpand"] as? Bool ?? false
         Self.logger.debug("Notification userInfo forceExpand flag: \(forceExpand)")
         
         DispatchQueue.main.async {
             self.showContentWindow(forceExpand: forceExpand)
         }
     }
    
    func toggleContentWindow() {
        guard !isTogglingWindow else {
            Self.logger.debug("Window toggle already in progress. Ignoring.")
            return
        }
        isTogglingWindow = true
        Self.logger.debug("Attempting to toggle window...")

        if let window = contentWindow, window.isVisible {
            Self.logger.info("Window exists and is visible. Closing it.")
            closeContentWindow()
        } else {
            Self.logger.info("Window does not exist or is not visible. Showing/Creating it.")
            showContentWindow(forceExpand: false)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.isTogglingWindow = false
            Self.logger.debug("Window toggle operation complete. Flag reset.")
        }
    }
    
    /// [QA revival P1a] Called from DevgenticApp once the shared graph exists, so the
    /// AppKit-created panel can stream through the real backend pipeline.
    func configureQuickAccess(mainAppViewModel: MainApplicationViewModel, themeManager: ThemeManager) {
        self.quickAccessMainViewModel = mainAppViewModel
        self.quickAccessThemeManager = themeManager
        Self.logger.info("AppDelegate: QuickAccess shared graph injected.")

        // [L2] Replay a summon that arrived before injection (see pendingShowForceExpand).
        if let forceExpand = pendingShowForceExpand {
            pendingShowForceExpand = nil
            Self.logger.info("AppDelegate: replaying deferred QuickAccess summon.")
            showContentWindow(forceExpand: forceExpand)
        }
        // Live-badges the status item with the global pending-HITL count; the track/onChange closures are `@MainActor`,
        // so reading `InteractionCenter.pending` inside them is safe.
        Task { @MainActor [weak self] in
            self?.pendingBadgeObserver = ObservationStream(
                track: { [weak self] in _ = self?.quickAccessMainViewModel?.interactionCenter.pending.count },
                onChange: { [weak self] in self?.refreshStatusItemBadge() }
            )
        }
    }

    // MARK: - Menu-bar status item [QA revival P2d]

    private func setupStatusItem() {
        // The status item would appear in the developer's real menu bar for the life of the test host and be summonable.
        guard TestHost.permits("install the menu-bar status item", logger: Self.logger) else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // [M10] AppKit NSStrings need explicit String(localized:) — they aren't auto-extracted.
            button.image = NSImage(systemSymbolName: "bolt.horizontal.circle", accessibilityDescription: String(localized: "Quick Access"))
            button.imagePosition = .imageLeading
            button.font = .systemFont(ofSize: 11, weight: .semibold)
            button.action = #selector(statusItemClicked)
            button.target = self
            button.toolTip = String(localized: "Devgentic Quick Access")
        }
        // [M2] Present the item only when the feature is enabled (applyHotkeyConfig keeps this in
        // sync on later toggles).
        item.isVisible = QuickAccessConfigManager.shared.isEnabled
        statusItem = item
    }

    @objc private func statusItemClicked() {
        toggleContentWindow()
    }

    /// Reflect the global pending-HITL count on the status item (called from the @MainActor
    /// ObservationStream onChange).
    @MainActor
    private func refreshStatusItemBadge() {
        guard let button = statusItem?.button else { return }
        let count = quickAccessMainViewModel?.interactionCenter.pending.count ?? 0
        if count > 0 {
            // [M10] Localized + automatic grammar agreement ("1 request" / "2 requests").
            button.image = NSImage(systemSymbolName: "exclamationmark.bubble.fill",
                                   accessibilityDescription: String(localized: "^[\(count) request](inflect: true) awaiting input"))
            button.title = " \(count)"
            button.contentTintColor = .systemOrange
        } else {
            button.image = NSImage(systemSymbolName: "bolt.horizontal.circle", accessibilityDescription: String(localized: "Quick Access"))
            button.title = ""
            button.contentTintColor = nil
        }
    }

    func showContentWindow(forceExpand: Bool = false) {
        Self.logger.info("AppDelegate: showContentWindow called. ForceExpand: \(forceExpand)")

        // Honors the enable flag at the single choke point every summon path funnels through (hotkey, status item, transfer
        // notification).
        guard QuickAccessConfigManager.shared.isEnabled else {
            Self.logger.info("AppDelegate: QuickAccess is disabled — ignoring show request.")
            return
        }

        // The panel cannot function without the shared graph, which is injected at launch; a summon that beats it is remembered
        // and replayed from `configureQuickAccess` instead of dropped.
        guard let mainVM = quickAccessMainViewModel, let quickAccessTheme = quickAccessThemeManager else {
            Self.logger.error("AppDelegate: QuickAccess graph not injected yet — deferring show until it is.")
            pendingShowForceExpand = forceExpand
            return
        }

        // Snapshot session state before closing any existing panel: closing fires `windowWillClose`, which stamps the close time
        // and would force a spurious resume on every re-show.
        let defaults = UserDefaults.standard
        let lastCloseTime = defaults.double(forKey: GlobalConstants.quickAccessLastCloseTime)
        let currentTime = Date().timeIntervalSince1970
        let elapsedTime = currentTime - lastCloseTime

        // Sweep every existing QuickAccess panel, not just `contentWindow`, and `orderOut` before `close`:
        // a bare `close()` can leave a non-activating panel on screen.
        let existingPanels = NSApp.windows.compactMap { $0 as? QuickAccessPanelView }
        if !existingPanels.isEmpty {
            Self.logger.warning("AppDelegate: closing \(existingPanels.count) existing QuickAccess panel(s) before creating a new one.")
            for old in existingPanels {
                old.orderOut(nil)
                old.close()
            }
        } else {
            Self.logger.debug("AppDelegate: No existing QuickAccess panel found. Proceeding to create new.")
        }
        self.contentWindow = nil

        var shouldResumeSession = false

        if forceExpand {
             Self.logger.info("AppDelegate: Forcing expansion due to transfer request.")
             if lastCloseTime > 0 && elapsedTime > sessionTimeoutDuration {
                 Self.logger.info("AppDelegate: Session timed out during transfer. Starting new conversation session.")
                 // Conversation rotation itself happens in QuickAccessSessionViewModel.prepareSession(resume:).
                 defaults.removeObject(forKey: GlobalConstants.quickAccessLastCloseTime)
                 defaults.removeObject(forKey: GlobalConstants.quickAccessWasExpandedOnClose)
                 shouldResumeSession = false
             } else {
                 shouldResumeSession = true
             }
        } else if lastCloseTime > 0 && elapsedTime <= sessionTimeoutDuration {
            shouldResumeSession = true
            Self.logger.info("AppDelegate: Quick Access session is within timeout. Resuming.")
        } else if lastCloseTime > 0 {
            Self.logger.info("AppDelegate: Quick Access session timed out. Starting new.")
            // Conversation rotation itself happens in QuickAccessSessionViewModel.prepareSession(resume:).
            defaults.removeObject(forKey: GlobalConstants.quickAccessLastCloseTime)
            defaults.removeObject(forKey: GlobalConstants.quickAccessWasExpandedOnClose)
            shouldResumeSession = false
        } else {
            Self.logger.info("AppDelegate: No last close time found. Starting fresh.")
             shouldResumeSession = false
        }

        Self.logger.debug("AppDelegate: Creating new QuickAccessPanelView instance. ShouldResumeSession: \(shouldResumeSession), ForceExpandVisual: \(forceExpand)")
        let panel = QuickAccessPanelView(
            shouldResumeSession: shouldResumeSession,
            forceExpandVisual: forceExpand,
            mainAppViewModel: mainVM,
            themeManager: quickAccessTheme
        )
        contentWindow = panel

        // Drops our strong reference on any close path so a later hotkey never dereferences a closed panel; identity-guarded.
        panel.onPanelWillClose = { [weak self, weak panel] in
            if self?.contentWindow === panel {
                self?.contentWindow = nil
            }
        }

        Self.logger.debug("AppDelegate: Ordering new panel front.")
        panel.makeKeyAndOrderFront(nil)

        // Do not `NSApp.activate`: the panel is non-activating, and activating raises the main window over the user's work.
        // `makeKeyAndOrderFront` on a `canBecomeKey` panel takes focus without activating.
        Self.logger.info("AppDelegate: New Quick Access Panel shown.")
    }
    
    private func closeContentWindow() {
        if let window = contentWindow {
            Self.logger.info("Closing Quick Access Panel.")
            window.orderOut(nil)
            window.close()
            self.contentWindow = nil
            Self.logger.debug("Content window reference set to nil.")
        } else {
            Self.logger.warning("closeContentWindow called but contentWindow reference was already nil.")
        }
    }

    // Brings the main SwiftUI window forward for the panel's reverse hand-off; the main scene is an id-less `WindowGroup`,
    // so scan `NSApp.windows`, skipping panels and the titled auxiliary windows.
    func mainAppWindow() -> NSWindow? {
        NSApp.windows.first { win in
            guard !(win is NSPanel), win.canBecomeMain else { return false }
            let title = win.title
            if title.hasPrefix("System Instructions:") { return false }
            if title == "File Viewer" || title == "Observability Trends" { return false }
            return true
        }
    }

    /// Brings the main window forward. Returns false when there is no main window to activate
    /// (e.g. it was closed while the app kept running via the hotkey/status item) — [C8] callers
    /// use this to avoid a handoff that would drop into the void.
    @discardableResult
    func activateMainWindow() -> Bool {
        guard let window = mainAppWindow() else { return false }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    deinit {
        Self.logger.info("AppDelegate deinit.")
    }
}

/// Which quit-teardown step is running, so a teardown cut off by its limit can say where it stuck.
/// Lock-protected: teardown writes it off the main actor while the quit task reads it.
final class QuitTeardownTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var current = "starting"
    var step: String {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
}
