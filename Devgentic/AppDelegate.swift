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
    
    static var shared: AppDelegate {
        return NSApplication.shared.delegate as! AppDelegate
    }

    var contentWindow: QuickAccessPanelView?
    var hotKey: HotKey?
    private var isTogglingWindow = false
    private let sessionTimeoutDuration: TimeInterval = 1800


    func applicationDidFinishLaunching(_ notification: Notification) {
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

        // Set this delegate so UNUserNotificationCenter can deliver notifications
        // both when the app is in the foreground AND in the background.
        UNUserNotificationCenter.current().delegate = self
        Self.logger.info("UNUserNotificationCenter delegate set.")
        setupHotkey()
        setupNotificationObserver()

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
                name: NSNotification.Name("devgentic.openConversation"),
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
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Everything that needs `await` before quitting. Runs while the run loop is alive
    /// (from `applicationShouldTerminate`), so MainActor-bound services are reachable.
    private static func performAsyncTeardown() async {
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

    private func setupHotkey() {
        hotKey = HotKey(key: .space, modifiers: [.option])
        hotKey?.keyDownHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.toggleContentWindow()
            }
        }
        if hotKey != nil { Self.logger.info("Hotkey Option+Space registered successfully.") }
        else { Self.logger.error("Failed to register Hotkey Option+Space.") }
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
    
    func showContentWindow(forceExpand: Bool = false) {
        Self.logger.info("AppDelegate: showContentWindow called. ForceExpand: \(forceExpand)")

        if let existingWindow = contentWindow {
            Self.logger.warning("AppDelegate: Found existing window reference during showContentWindow. Closing it first.")
            existingWindow.close()
            self.contentWindow = nil
        } else {
             Self.logger.debug("AppDelegate: No existing window reference found. Proceeding to create new.")
        }

        let defaults = UserDefaults.standard
        let lastCloseTime = defaults.double(forKey: GlobalConstants.quickAccessLastCloseTime)
        let currentTime = Date().timeIntervalSince1970
        let elapsedTime = currentTime - lastCloseTime
        var shouldResumeSession = false

        if forceExpand {
             Self.logger.info("AppDelegate: Forcing expansion due to transfer request.")
             if lastCloseTime > 0 && elapsedTime > sessionTimeoutDuration {
                 Self.logger.info("AppDelegate: Session timed out during transfer. Starting new conversation session.")
                 // Your logic for starting a new session would go here.
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
            // Your logic for starting a new session would go here.
            defaults.removeObject(forKey: GlobalConstants.quickAccessLastCloseTime)
            defaults.removeObject(forKey: GlobalConstants.quickAccessWasExpandedOnClose)
            shouldResumeSession = false
        } else {
            Self.logger.info("AppDelegate: No last close time found. Starting fresh.")
             shouldResumeSession = false
        }

        Self.logger.debug("AppDelegate: Creating new QuickAccessPanelView instance. ShouldResumeSession: \(shouldResumeSession), ForceExpandVisual: \(forceExpand)")
        let panel = QuickAccessPanelView(shouldResumeSession: shouldResumeSession, forceExpandVisual: forceExpand)
        contentWindow = panel
        
        Self.logger.debug("AppDelegate: Ordering new panel front.")
        panel.makeKeyAndOrderFront(nil)
        
        NSApp.activate(ignoringOtherApps: true)
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

    deinit {
        Self.logger.info("AppDelegate deinit.")
    }
}
