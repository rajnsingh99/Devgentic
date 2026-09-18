// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AppDelegate.swift
//  Devgentic
//
//  Created by Raj Singh on 07/05/25.
//

import SwiftUI
import os
import HotKey
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    
    private static let logger = DGLogger(category: "AppDelegate")
    
    /// The real AppDelegate instance, captured at launch. Under
    /// @NSApplicationDelegateAdaptor, `NSApplication.shared.delegate` is SwiftUI's
    /// forwarding wrapper (`SwiftUI.AppDelegate`), NOT our class — the old
    /// `as! AppDelegate` cast always trapped. Nil only before applicationDidFinishLaunching.
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
    ///
    /// ⚠️ Register A29: ⌘Q ran straight into async teardown, so a profile editor holding a
    /// 2,000-character unsaved system prompt was destroyed with no prompt and — contrary to the
    /// project logging standard — no log line either, leaving the loss invisible in a support
    /// bundle. Weak, for the same reason as the QuickAccess graph above: DevgenticApp's `@State`
    /// owns it for the app's lifetime.
    ///
    /// ⚠️ Nil until `configureTerminationGuard` runs, and a nil guard means quit is NOT gated. That
    /// is deliberate — failing open on quit is right, and the window between launch and injection
    /// is before the user can have opened an editor — but it is logged so a quit that skipped the
    /// check is distinguishable from one that ran and found nothing.
    weak var profileService: BackendProfileService?

    /// Owner of the MAIN Workflow interface's canvas states, injected alongside `profileService`.
    ///
    /// ⚠️ A SECOND, INDEPENDENT source of unsaved canvas work, and the reason `profileService`
    /// alone was not enough. There are two `WorkflowEditGuard` instances by design — the profile
    /// editor's canvas and the main Workflow interface's canvas can be mounted AT THE SAME TIME
    /// (`chatArea` stays alive under a non-chat destination, opacity-toggled), so one shared guard
    /// would let whichever registered last clear the other's hooks and dirty flag. The bug was that
    /// quit consulted only the first: an afternoon of graph work in the main interface was
    /// discarded by ⌘Q with no prompt and no log line, while the identical work done inside the
    /// profile editor was rescued.
    weak var workflowCanvasOwner: MainApplicationViewModel?

    /// [C6] True when the QuickAccess panel is the KEY window — i.e. the user is actively
    /// looking at it. Because the panel is non-activating it can be key while `NSApp.isActive`
    /// is false, so notification suppression must consult this in addition to app-active.
    /// (Deliberately keyWindow, not just isVisible: a panel left open in the background while
    /// the user works in another app is not key, so completions there still notify.)
    @MainActor var isQuickAccessPanelKey: Bool { contentWindow?.isKeyWindow ?? false }

    /// [QA revival P2d] Menu-bar status item — click toggles the panel; it badges with the
    /// global pending-HITL count so a run parked while the main window is closed is visible.
    private var statusItem: NSStatusItem?
    private var pendingBadgeObserver: ObservationStream?
    private var isTogglingWindow = false
    /// [L2] A summon that arrived before the shared graph was injected (hotkey is registered in
    /// applicationDidFinishLaunching, before DevgenticApp's `.task` runs configureQuickAccess).
    /// Holds the requested `forceExpand`; replayed once injection completes so the press isn't a
    /// silent no-op. nil = nothing pending.
    private var pendingShowForceExpand: Bool?
    /// [QA revival P1d] Read from QuickAccessConfigManager (default 30 min) instead of hardcoded.
    private var sessionTimeoutDuration: TimeInterval {
        TimeInterval(QuickAccessConfigManager.shared.sessionTimeoutSeconds)
    }


    func applicationDidFinishLaunching(_ notification: Notification) {
        // [QA revival P1a] Capture the real instance for AppDelegate.shared (NSApp.delegate
        // is SwiftUI's wrapper under the adaptor). Runs before any view's .task.
        Self.shared = self

        // Captured before any trace can begin this session, so the orphan reconciliation
        // below can never touch a trace created by the current process (it only reconciles
        // traces that started earlier).
        let launchInstant = Date()

        // Crash detection (§12.1): consume the clean-exit sentinel BEFORE anything else —
        // false means the previous session crashed or was force-killed (it never reached
        // applicationWillTerminate). Feeds the reconciliation reason below. Then register
        // for MetricKit diagnostics; payloads for a prior crash arrive shortly after.
        let previousExitWasClean = CrashDiagnosticsCollector.consumeLaunchSentinel()
        CrashDiagnosticsCollector.shared.start()
        if !previousExitWasClean {
            Self.logger.error("Previous session did not exit cleanly (crash or force-quit). MetricKit diagnostics, if any, arrive shortly; .ips reports are folded into diagnostic bundles.")
        }

        // Seed the per-family Response Synthesis toggles from the legacy single
        // toggle exactly once. Must run before any agent run can resolve its
        // synthesis opt-in. Idempotent and cheap (a guarded UserDefaults read).
        SynthesisOptIn.migrateLegacyToggleIfNeeded()

        // Point MCPClientService at the app's tool store and HITL brokers. MUST run before
        // anything can connect a server: the launch sweep lives in the SwiftUI scene's
        // startup task, and the Add-server form's Test Connection is user-driven — both are
        // strictly later than this. Without it a connect still succeeds, but its refreshed
        // tool list has nowhere to land and sampling/elicitation are refused.
        MCPHostBridge.installAppImplementations()

        // Set this delegate so UNUserNotificationCenter can deliver notifications
        // both when the app is in the foreground AND in the background.
        UNUserNotificationCenter.current().delegate = self
        Self.logger.info("UNUserNotificationCenter delegate set.")
        applyHotkeyConfig()
        applyOrbHotkeyConfig()
        setupStatusItem()
        setupNotificationObserver()

        // [H1] Clean up leftover QuickAccess screen-capture temp files from prior sessions (sent
        // captures whose bytes are already persisted, or any orphaned by a crash mid-flow). Pure
        // file I/O, nothing UI — run off-main so it never delays launch.
        Task.detached(priority: .utility) {
            QuickAccessScreenCaptureService.sweepOrphanedCaptureFiles()
        }

        // 30-day observability purge + orphan reconciliation. Runs in a detached
        // background task so startup isn't delayed by the SQLite work on large archives.
        Task.detached(priority: .background) {
            guard let store = TraceStore.shared else { return }
            let cutoff = launchInstant.addingTimeInterval(-30 * 24 * 3600)

            // Purge aged traces (+ cascaded spans/events/configs via FK). Previously only
            // log_entries was purged here despite the comment's cascade claim, so
            // traces.sqlite grew without bound (Gap #5).
            do {
                try store.purgeOlderThan(cutoff)
            } catch {
                Self.logger.error("Trace purge failed: \(error.localizedDescription)")
            }
            if let purged = try? store.purgeLogEntriesOlderThan(cutoff), purged > 0 {
                Self.logger.info("Purged \(purged) log entries older than 30 days.")
            }

            // Stamp traces left `running` by a previous session (graceful quit or crash
            // before endTrace ran) as `.interrupted`, so they stop lingering forever and
            // skewing reliability stats (Gap #13). The clean-exit sentinel distinguishes
            // crash/force-quit from a normal quit mid-run (§12.1).
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

    /// Async teardown with the run loop ALIVE. The previous approach — spawning `Task`s
    /// in `applicationWillTerminate` and blocking the main thread on semaphores — could
    /// never work: the tasks inherit MainActor, the semaphore wait blocks the main thread,
    /// so the tasks never start, every wait burned its full timeout, and the process
    /// exited with NO flush/disconnect having run (audit finding #1). `.terminateLater`
    /// keeps the main actor processing while we tear down, then `reply` resumes quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // ⚠️ Before ANY teardown (register A29). Once `.terminateLater` is returned the app is
        // going away, so this is the last point at which unsaved editor work can be rescued.
        if case .cancel = handleUnsavedProfileEditsBeforeQuit() {
            Self.logger.info("[PROFILE] Quit CANCELLED by the user at the unsaved-changes prompt. "
                             + "CONSEQUENCE: the app stays open with the editor untouched.")
            return .terminateCancel
        }

        // [WF-LC2] Second, independent gate — a run in flight is a different kind of at-risk work
        // than a dirty canvas (it has no Save button of its own; the only way to keep it is to let
        // it finish, or to freeze it here). Sequenced AFTER the canvas gate rather than merged with
        // it: the two alerts describe unrelated risks with unrelated remedies, and this repo has no
        // precedent for combining two dirty-source categories' button sets into one alert.
        if case .cancel = handleInFlightWorkflowRunsBeforeQuit() {
            Self.logger.info("[WF_RUN] Quit CANCELLED by the user at the in-flight-run prompt. "
                             + "CONSEQUENCE: the app stays open; every in-flight run keeps running.")
            return .terminateCancel
        }

        Self.logger.info("Application requested to terminate — running async teardown.")

        // Synchronous, cheap teardown first: kill shell child processes.
        ShellSessionManager.shared.cleanup()

        Task { @MainActor in
            // Race teardown against a watchdog so a hung MCP disconnect or DB write can
            // never block quit for more than ~3s.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await Self.performAsyncTeardown() }
                group.addTask { try? await Task.sleep(for: .seconds(3)) }
                await group.next()
                group.cancelAll()
            }

            // Whatever the watchdog cut short, no MCP child may outlive us. ShellProcess's
            // SIGTERM→SIGKILL escalation is a 2s `asyncAfter` that cannot fire this late,
            // so a server ignoring SIGTERM would be re-parented to launchd as an orphan.
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

    /// Offers Save / Discard / Cancel when the profile editor holds unsaved work, and reports
    /// whether quitting may continue.
    ///
    /// ⚠️ `NSAlert.runModal()` is correct HERE and wrong in `onDisappear`: this is an AppKit
    /// delegate callback on the main thread, not a SwiftUI update pass, so it is not spinning a
    /// nested modal loop inside a view update.
    ///
    /// ⚠️ Uses `hasUnsavedEditorChanges`, never `editBuffer?.isDirty` — a workflow canvas keeps its
    /// dirt in `WorkflowCanvasState`, so the buffer check alone reports "clean" for a canvas full
    /// of unsaved nodes.
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
        // ⚠️ Flush FIRST. A floating prompt editor keeps typing in its own `@State` and writes back
        // only on an explicit commit, so it is a third source of unsaved work that neither the
        // buffer nor the canvas reports. Navigation commits it on teardown (register A27); ⌘Q has
        // no teardown, so without this a 2,000-character system prompt typed into the Expand window
        // is discarded here silently — the exact loss this guard exists to prevent.
        profileService.flushPendingEditorText()

        // The MAIN Workflow interface's canvases are a separate source of dirt from the profile
        // editor's — different guard, different owner, and BOTH can be dirty at once. Read every
        // cached canvas, not just the one on screen: switching workflows leaves the previous one's
        // unsaved graph in the cache, invisible to the on-screen guard.
        if workflowCanvasOwner == nil {
            Self.logger.notice(
                "[WF_CANVAS] Quit is NOT gated on unsaved workflow-canvas edits: the main view model "
                + "was never injected into AppDelegate. CONSEQUENCE: unsaved graph work in the "
                + "Workflow interface is being discarded silently."
            )
        }
        let dirtyWorkflowIDs = workflowCanvasOwner?.unsavedWorkflowCanvasProfileIDs ?? []

        // ⚠️ SKILL DRAFTS ARE A FOURTH SOURCE OF UNSAVED WORK, and quit is the ONLY exit that can
        // lose them. A skill draft lives in `SkillDraftStore` for the life of the app run, so every
        // navigation exit — sidebar, tab switch, palette, ⌘[ — is lossless by construction and needs
        // no prompt. Memory going away is the one case that is not, which is why this is the single
        // place skills are gated rather than seven.
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
        // Name the workflow canvas explicitly when that is what is dirty — "profile edits" sent the
        // user looking for an editor they never opened, and the wrong mental model at a
        // Discard-and-Quit prompt is how work gets thrown away on purpose.
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

    /// Warns when one or more workflow runs are still executing, and freezes each on proceed.
    ///
    /// ⚠️ Per-node output exists ONLY in the live `WorkflowExecutionState` until `finalize()` runs,
    /// and until this guard, nothing ever called it at quit — the process just exited, and the
    /// persisted row stayed the empty `.running` stub `WorkflowRunBootstrap.begin` wrote
    /// (`nodeResults: []`), which the next launch's orphan-reconcile relabels "Cancelled —
    /// Interrupted" with every already-completed node's output gone. Register row WF-LC2.
    ///
    /// ⚠️ READ-ONLY until "Quit Anyway": `WorkflowRunTicket.forceFinalizeActiveRuns` is called from
    /// EXACTLY ONE place, the affirmative branch below, never speculatively — `didFinalize` is a
    /// permanent guard, so freezing before the user has committed would strand a run that goes on
    /// to finish normally seconds later (the user pressed Cancel here, or never saw this at all)
    /// with no way for its own real completion to ever be persisted.
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
        // Name what's running — a bare count leaves a QuickAccess or Orb run, which has no
        // visible window of its own, impossible to identify from this alert alone. Caps at 4 names
        // (a wall of titles stops being scannable) and falls back to the count above that.
        let names = WorkflowRunTicket.activeRunNames
        let namesLine = names.count <= 4
            ? names.map { "• \($0)" }.joined(separator: "\n")
            : nil
        // Matches settleInFlightWork (WorkflowExecutionState.swift): only nodes still `.running`
        // are touched (relabelled Cancelled, never discarded); anything already completed keeps
        // its real result untouched.
        let consequence = String(localized: "Completed steps keep their real result. Any step still in progress is marked Cancelled.")
        alert.informativeText = namesLine.map { "\($0)\n\n\(consequence)" } ?? consequence
        alert.alertStyle = .warning
        // ⚠️ Cancel FIRST — every other destructive quit-time alert in this app puts the safe
        // option on the Return-key/prominent-styling default (`handleUnsavedProfileEditsBeforeQuit`
        // above puts "Save and Quit" first; `DevgenticApp.swift`'s reset alert puts "Cancel" first
        // and gates its destructive action on `.alertSecondButtonReturn`). Adversarial review of
        // this exact alert caught it defaulting Return to "Quit Anyway" — fixed to match.
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

    /// Persists whatever is dirty, and REFUSES to quit if any part of it fails.
    ///
    /// ⚠️ Quitting after a failed save would be the worst outcome available: the user explicitly
    /// asked to keep the work, and it would be destroyed anyway with only a toast that no longer
    /// has a window to appear in. A failure here cancels the quit and says why.
    @MainActor
    private func saveOpenProfileEdits(on profileService: BackendProfileService) -> QuitDecision {
        // Main Workflow interface canvases FIRST — this drains every cached dirty canvas, including
        // ones for workflows the user has since switched away from, which no on-screen hook covers.
        var drainedProfileIDs: Set<UUID> = []
        // [WF-PE2] Tracked separately from `drainedProfileIDs`, which only answers "does the WF-PE1
        // skip-check apply?" — this answers the DIFFERENT question the skip-check's own LOG TEXT
        // needs: "was this specific id persisted, or refused?" Conflating the two produced a real
        // bug, caught by adversarial review: the skip-check logged "already persisted... skipping
        // avoids a second write" for a canvas that was never written at all.
        var refusedProfileIDs: Set<UUID> = []
        // ⚠️ Distinct from "the drain covered nothing": a nil owner means the drain never RAN (it is
        // injected by `configureTerminationGuard`, and quit fails open before that). The fallback
        // warning below must not fire in that case — it would assert data loss that is not happening.
        let drainDidRun = workflowCanvasOwner != nil
        if let workflowCanvasOwner {
            let drain = workflowCanvasOwner.persistDirtyWorkflowCanvases(profileService: profileService)
            // [WF-PE2] A REFUSED profile belongs in "already handled by the drain" exactly like a
            // persisted one — its outcome is just as final, only without a write. Leaving it out
            // would make the WF-PE1 skip-check below treat it as un-covered and fire a REDUNDANT
            // `saveHook()` for the on-screen canvas: a second refusal (harmless in itself — refusal
            // is a pure read, nothing to corrupt) that would then wrongly log "layout persisted" for
            // a canvas that was refused, and wrongly fire the "held a state the drain doesn't own"
            // WF-PE1 violation warning for what is actually the SAME canvas the drain already
            // resolved. Caught by adversarial review of this exact fix, not by the register.
            drainedProfileIDs = Set(drain.persisted).union(drain.refused.map(\.id))
            refusedProfileIDs = Set(drain.refused.map(\.id))
            if !drain.failed.isEmpty {
                Self.logger.error(
                    "[WF_CANVAS] Quit-time save FAILED for \(drain.failed.count) workflow canvas(es): "
                    + "\(drain.failed.map(\.uuidString).joined(separator: ", ")). CONSEQUENCE: quit is "
                    + "CANCELLED rather than discarding graph work the user asked to keep."
                )
                if !drain.refused.isEmpty {
                    // [WF-PE2] `refused` is silently dropped by this early return — real, but
                    // deliberately not escalated into changing this alert's decision (the failed
                    // canvas is where the one actionable escape lives, so this branch still owns
                    // the choice). A log line is enough to keep the read-only-canvas prompt from
                    // surprising the user on the VERY NEXT quit attempt once they fix the failure.
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
            // [WF-PE2] Checked AFTER `failed`, never merged with it: a REFUSED canvas can never be
            // saved by retrying, so it needs an honest choice, not the "save it from the canvas"
            // framing above — which is a false promise for exactly this case (the register's own
            // filed defect). If BOTH a failed and a refused canvas are dirty at once, the `failed`
            // branch above already returned — correct, since that is where the one actionable
            // escape (fix the transient problem, retry) actually lives.
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
            // ⚠️ WF-PE1. The drain above and this `saveHook` both write `WorkflowLayoutSD`, and the
            // store has no compare-and-swap — so if they ever hold DIFFERENT graphs for one profile,
            // this second write silently destroys the first. Both mount sites now share a single
            // `WorkflowCanvasState` per profile (`MainApplicationViewModel.workflowCanvasState(for:)`),
            // which makes the two writes identical; skipping the redundant one keeps that true by
            // construction instead of by assumption, and turns any future divergence into a log line
            // here rather than a graph the user loses at quit.
            //
            // The dirty flag is the guard's own MIRROR of the canvas state and is not cleared by the
            // drain's `markSaved()`, so it reads stale-true after a successful drain — expected, and
            // exactly why the decision keys off the profile identity rather than the flag.
            if let registeredID = profileService.canvasEditGuard.registeredProfileID,
               drainedProfileIDs.contains(registeredID) {
                // [WF-PE2] The two ids in this set mean different things and need different text —
                // a persisted one really was written (the original claim, still true for it); a
                // refused one was NOT, and the earlier "already persisted" wording was flatly false
                // for it — caught by adversarial review as a self-contradicting log trail against
                // the read-only-canvas prompt's own "nothing was written" line two log calls above.
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
                // Reaching here means the on-screen canvas is NOT one the drain covered — i.e. it is
                // holding a state the view model does not know about. That is the WF-PE1 shape and
                // should be impossible now; say so rather than writing silently.
                //
                // ⚠️ Only when the drain actually ran. With a nil `workflowCanvasOwner` this hook is
                // the ONLY thing saving the canvas, which is correct, not a conflict.
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
                // ⚠️ Reachable in ordinary use: `ProfileValidator` rejects e.g. an over-length name,
                // and the agent editor's own "system instructions are required" pre-flight lives in
                // the VIEW (register A35), so a save routed from here never ran it.
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

    /// ⚠️ NO UNIT-TEST SEAM — reviewed, not tested, same as `handleInFlightWorkflowRunsBeforeQuit`
    /// (WF-LC2) and `handleUnsavedProfileEditsBeforeQuit` above it. Reaching this means driving a
    /// real `NSAlert.runModal()`, which cannot be headless. The DECISION vocabulary this alert
    /// consumes — `WorkflowLayoutSaveOutcome.isRefusedByDesign`/`.quitTimeRefusalReason` — IS
    /// tested, exhaustively, in `BlobWriteRefusalTests.swift`'s WF-PE2 section; what is untested is
    /// only this function's own alert construction, button-to-branch mapping, and the caller-side
    /// bucketing loop in `MainApplicationViewModel.persistDirtyWorkflowCanvases` (also VM-construction-
    /// blocked, per the same established constraint WF-LC2/WF-PE7 already disclose).
    ///
    /// [WF-PE2] One or more dirty canvases are refused BY DESIGN — their stored layout is either
    /// from a newer app version or unreadable, so `WorkflowLayoutStore.save` will refuse identically
    /// on every attempt. Unlike `presentQuitSaveFailure`, this asks a real question: the canvas
    /// genuinely cannot be saved, so the honest choice is Cancel (stay open, keep the in-memory
    /// edits, unsaved) or Quit Anyway (lose them — the on-disk layout was never at risk either way).
    ///
    /// ⚠️ The wording per case is intentionally SIMILAR to, but not byte-identical with, what
    /// `WorkflowCanvasView.saveLayout` shows IN-CANVAS — exactly matching for `.refusedNewerVersion`
    /// (both read from the same `quitTimeRefusalReason`/banner text), but the unreadable case here
    /// is deliberately SHORTER: the in-canvas overlay's node/edge/annotation counts are evidence for
    /// a repair decision that belongs on the canvas, not a quit-time choice with only two options.
    /// (An earlier draft of this comment overclaimed exact-wording parity for both cases — corrected
    /// after adversarial review checked it against the actual overlay text and found it did not
    /// match for the unreadable case.)
    ///
    /// ⚠️ Cancel is the Return-key DEFAULT and is added first — "Quit Anyway" here is exactly as
    /// destructive as "Discard and Quit" in the sibling alert above (permanently discards real,
    /// unrecoverable in-memory edits), so it gets the same treatment the already-shipped WF-LC2
    /// in-flight-run prompt established after adversarial review caught the inverse ordering as a
    /// real UX-safety defect: the destructive option must never be the accidental-Return default.
    @MainActor
    private func presentReadOnlyCanvasQuitChoice(
        _ refused: [(id: UUID, outcome: WorkflowLayoutSaveOutcome)],
        profileService: BackendProfileService
    ) -> QuitDecision {
        // Falls back rather than force-unwrapping: `quitTimeRefusalReason` is nil only for a case
        // `isRefusedByDesign` would have excluded, which the caller already filtered on before this
        // was ever invoked — reachable only if that invariant is ever broken, and a generic line in
        // the alert is a far smaller failure than crashing the whole quit sequence over it.
        //
        // ⚠️ NAMED, not just listed — caught by adversarial review: two canvases refused for the
        // SAME reason (e.g. both `.refusedUnreadable`) produce byte-identical reason text with
        // nothing to tell them apart, which the doc comment below used to (wrongly) claim already
        // matched WF-LC2's per-item naming. It did not, until this line existed.
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
    private static func performAsyncTeardown() async {
        // [WF-PE7] First, and before the observability flush below so its log lines ship: await
        // any in-flight workflow-run persist. `WorkflowRunTicket.finalize()` is deliberately
        // fire-and-forget for the UI, which made quit the one moment it lost data — exiting
        // inside the encode+write window stranded the `.running` stub, and the next launch
        // relabelled a COMPLETED run "Interrupted" with zero node results. The 3s quit watchdog
        // wrapping this method still bounds a hung write.
        await WorkflowRunTicket.drainPendingPersists()

        // Stop any live Whisper capture (composer dictation or Orb listening) so the
        // HAL client closes cleanly. An AVAudioEngine still running at process death can
        // wedge coreaudiod into refusing this app's audio IO (`_StartIO error 35`) until
        // the daemon restarts — observed 2026-07-18 as "mic silently dead in-app while
        // other apps record fine". No-op when nothing is recording.
        _ = await WhisperRecognitionService.shared.stopStreaming()

        // Disconnect MCP sessions so child processes (npx/uvx/etc.) don't get
        // re-parented to launchd as orphans (SIGTERM, escalating to SIGKILL).
        await MCPClientService.shared.disconnectAll()

        // Flush observability buffers to SQLite (Gap #13): up to 5s of logs and 1s of
        // span events are otherwise lost on quit.
        await LogRecorder.shared.prepareForTermination()
        await TraceRecorder.shared.prepareForTermination()

        // Unload local models cleanly (App RAM + Ollama VRAM).
        let stats = await MLXService.shared.unloadModel()
        Self.logger.info("Termination MLX cleanup stats: \(stats)")
        await OllamaService.shared.unloadModel()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.logger.info("Application will terminate.")

        // ⚠️ LAST GRACEFUL CHANCE. The Orb duplex engine is panel-scoped, so it can still be
        // live here; an AVAudioEngine that reaches process death wedges coreaudiod into
        // `_StartIO error 35` — an app-wide dead microphone that survives relaunch and needs an
        // admin `killall coreaudiod`. Crashes and force-quits cannot be covered; Repair Audio in
        // Settings is the remedy for those.
        OrbDuplexAudio.shared.release(reason: "application terminating")

        // Mark this session cleanly exited (§12.1) — async teardown already ran via
        // applicationShouldTerminate. Crashes and force-quits never get here; the next
        // launch reads the stale `false` and knows.
        CrashDiagnosticsCollector.markCleanExit()
    }

    /// [QA revival P1d] (Re)register the global hotkey from QuickAccessConfigManager. Called at
    /// launch and whenever the settings pane changes the shortcut or enable flag. Assigning
    /// `hotKey` replaces any prior Carbon registration; nil unregisters (when disabled).
    func applyHotkeyConfig() {
        // ⚠️⚠️ A CARBON HOTKEY IS REGISTERED SYSTEM-WIDE, WITH THE OS, FOR THE LIFE OF THE PROCESS —
        // it is not scoped to this app's windows. A test host that registers ⌥Space STEALS the combo
        // from the developer's own running copy of Devgentic, and the config it reads is the
        // developer's REAL `UserDefaults` (the store redirect does not cover `UserDefaults.standard`),
        // where QuickAccess is enabled by default.
        guard TestHost.permits("register the system-wide QuickAccess hotkey", logger: Self.logger) else { return }

        let config = QuickAccessConfigManager.shared
        hotKey = nil

        // [M2] The enable flag governs the WHOLE feature, not just the hotkey: reflect it on the
        // menu-bar item and close any open panel so disabling takes effect immediately (previously
        // the status item still summoned the panel and an open one stayed open).
        statusItem?.isVisible = config.isEnabled

        guard config.isEnabled else {
            Self.logger.info("QuickAccess disabled — hotkey unregistered and menu-bar item hidden.")
            if contentWindow != nil { closeContentWindow() }
            return
        }

        // [M1] Probe registration BEFORE the package registers (the soffes/HotKey package
        // swallows RegisterEventHotKey's OSStatus, so it can't tell us if the OS refused). Log the
        // truth instead of unconditionally claiming success. Combos the system consumes upstream
        // (e.g. ⌘Space) still register here — those are blocked at record time by HotkeyValidator.
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

    /// (Re)register Orb's global shortcut from OrbConfigManager. Called at launch and
    /// whenever the settings pane changes the shortcut, the activation mode, or the enable flag.
    ///
    /// ⚠️ Registered ONLY in `.holdShortcut` mode. In the continuously-listening modes the
    /// microphone is already open and a shortcut would be a second, redundant way in — and
    /// holding a Carbon registration the user cannot see is exactly the kind of invisible state
    /// that makes a shortcut conflict impossible to diagnose.
    @MainActor
    func applyOrbHotkeyConfig() {
        // ⚠️⚠️ WORSE THAN THE QUICKACCESS ONE, because ⌥J OPENS THE MICROPHONE. Registered
        // system-wide from the developer's real defaults, where Orb push-to-talk is the default
        // activation mode — so a keystroke during a test run could start capturing audio from a
        // process that is about to be killed.
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
        // [QA revival P2d] Live-badge the status item with the global pending-HITL count. The
        // track/onChange closures are @MainActor (ObservationStream), so InteractionCenter's
        // main-actor-isolated `pending` is read safely inside them. ObservationStream.init is
        // itself @MainActor, so create it on the main actor.
        Task { @MainActor [weak self] in
            self?.pendingBadgeObserver = ObservationStream(
                track: { [weak self] in _ = self?.quickAccessMainViewModel?.interactionCenter.pending.count },
                onChange: { [weak self] in self?.refreshStatusItemBadge() }
            )
        }
    }

    // MARK: - Menu-bar status item [QA revival P2d]

    private func setupStatusItem() {
        // ⚠️ A VISIBLE ARTEFACT OF A TEST RUN. The item appears in the developer's real menu bar for
        // the life of the host process and is summonable — clicking it drives a view model inside a
        // process that exits when the suite finishes.
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

        // [M2] Honor the enable flag at the single choke point every summon path funnels through
        // (hotkey → toggleContentWindow → showContentWindow; status-item click; the transfer
        // notification → showContentWindow). When disabled, no entry point can open the panel.
        guard QuickAccessConfigManager.shared.isEnabled else {
            Self.logger.info("AppDelegate: QuickAccess is disabled — ignoring show request.")
            return
        }

        // [QA revival P1a] The panel cannot function without the shared graph. It is injected at
        // launch (DevgenticApp .task). [L2] If a summon (early hotkey / status click) beats that
        // injection, remember it and replay from configureQuickAccess instead of dropping it.
        guard let mainVM = quickAccessMainViewModel, let quickAccessTheme = quickAccessThemeManager else {
            Self.logger.error("AppDelegate: QuickAccess graph not injected yet — deferring show until it is.")
            pendingShowForceExpand = forceExpand
            return
        }

        // [QA revival P0] Snapshot session state BEFORE closing any existing panel:
        // closing fires windowWillClose, which stamps quickAccessLastCloseTime = now,
        // making elapsedTime ≈ 0 and forcing a spurious "resume" on every re-show.
        let defaults = UserDefaults.standard
        let lastCloseTime = defaults.double(forKey: GlobalConstants.quickAccessLastCloseTime)
        let currentTime = Date().timeIntervalSince1970
        let elapsedTime = currentTime - lastCloseTime

        // [two-panel fix] Sweep EVERY existing QuickAccess panel, not just the one tracked in
        // `contentWindow`, and orderOut BEFORE close. A bare `close()` can leave a non-activating
        // floating panel on screen (closeContentWindow already does orderOut+close for this
        // reason), and only one reference is tracked — so a leftover/untracked panel would let a
        // fresh open stack a second panel on top ("two versions visible"). This guarantees at most
        // one panel after any open.
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

        // [QA revival P0] Drop our strong reference on ANY close path (Escape / close
        // button / hotkey toggle / programmatic replace) so a later Option+Space never
        // dereferences a closed panel. Identity-guarded against a newer panel.
        panel.onPanelWillClose = { [weak self, weak panel] in
            if self?.contentWindow === panel {
                self?.contentWindow = nil
            }
        }

        Self.logger.debug("AppDelegate: Ordering new panel front.")
        panel.makeKeyAndOrderFront(nil)

        // [QA revival P0] Do NOT NSApp.activate here. The panel is a .nonactivatingPanel;
        // activating a regular Dock app raises the main window over whatever the user was
        // doing — the opposite of quick-entry UX — and destroys the frontmost-app info a
        // future screenshot feature needs. makeKeyAndOrderFront on a canBecomeKey panel
        // takes keyboard focus without activating the app.
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

    // [QA revival P2e] Bring the main SwiftUI window forward for the panel's reverse-handoff.
    // The main scene is an id-less WindowGroup (no openWindow(id:) target), so scan
    // NSApp.windows: skip panels (QuickAccess / Report / Node inspectors, all NSPanel) and the
    // titled aux windows (prompt editors "System Instructions:…", File Viewer, Trends).
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
