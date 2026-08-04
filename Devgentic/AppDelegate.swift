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

    /// [QA revival P1a] The shared object graph, injected from DevgenticApp once the app is
    /// up (AppDelegate and the panel live outside the SwiftUI environment). Weak — both are
    /// owned for the app's lifetime by DevgenticApp's @State.
    weak var quickAccessMainViewModel: MainApplicationViewModel?
    weak var quickAccessThemeManager: ThemeManager?

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

    /// Everything that needs `await` before quitting. Runs while the run loop is alive
    /// (from `applicationShouldTerminate`), so MainActor-bound services are reachable.
    private static func performAsyncTeardown() async {
        // Stop any live Whisper capture (composer dictation or Jarvis listening) so the
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

        // Mark this session cleanly exited (§12.1) — async teardown already ran via
        // applicationShouldTerminate. Crashes and force-quits never get here; the next
        // launch reads the stale `false` and knows.
        CrashDiagnosticsCollector.markCleanExit()
    }

    /// [QA revival P1d] (Re)register the global hotkey from QuickAccessConfigManager. Called at
    /// launch and whenever the settings pane changes the shortcut or enable flag. Assigning
    /// `hotKey` replaces any prior Carbon registration; nil unregisters (when disabled).
    func applyHotkeyConfig() {
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
