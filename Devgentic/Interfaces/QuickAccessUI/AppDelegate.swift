//
//  AppDelegate.swift
//  Devgentic
//
//  Created by Raj Singh on 07/05/25.
//

import AppKit
import HotKey
import os

// Assuming ConversationStore and SettingsKeys are defined elsewhere

class AppDelegate: NSObject, NSApplicationDelegate {
    
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.Devgentic", category: "AppDelegate")
    var contentWindow: QuickAccessPanelView?
    var hotKey: HotKey?
    private var isTogglingWindow = false
    private let sessionTimeoutDuration: TimeInterval = 1800 // 30 minutes in seconds
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("Application finished launching. Setting up hotkey and observers.")
        setupHotkey()
        setupNotificationObserver()
    }
    
    private func setupHotkey() {
        hotKey = HotKey(key: .space, modifiers: [.option])
        hotKey?.keyDownHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.toggleContentWindow()
            }
        }
        if hotKey != nil { logger.info("Hotkey Option+Space registered successfully.") }
        else { logger.error("Failed to register Hotkey Option+Space.") }
    }
    
    private func setupNotificationObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowQuickAccessPanelNotification(_:)),
            name: SettingsKeys.showQuickAccessPanelNotification,
            object: nil
        )
        logger.info("Added observer for showQuickAccessPanelNotification.")
    }
    
    // --- MODIFIED: Handle notification userInfo ---
    @objc private func handleShowQuickAccessPanelNotification(_ notification: Notification) {
         logger.info("Received showQuickAccessPanelNotification.")
         // Check if the notification requests forcing the expanded state
         let forceExpand = notification.userInfo?["forceExpand"] as? Bool ?? false
         logger.debug("Notification userInfo forceExpand flag: \(forceExpand)")
         
         // Ensure this runs on the main thread as it manipulates UI
         DispatchQueue.main.async {
             // Pass the flag to showContentWindow
             self.showContentWindow(forceExpand: forceExpand)
         }
     }
    // --- END MODIFICATION ---
    
    func toggleContentWindow() {
        guard !isTogglingWindow else {
            logger.debug("Window toggle already in progress. Ignoring.")
            return
        }
        isTogglingWindow = true
        logger.debug("Attempting to toggle window...")

        if let window = contentWindow, window.isVisible {
            logger.info("Window exists and is visible. Closing it.")
            closeContentWindow()
        } else {
            logger.info("Window does not exist or is not visible. Showing/Creating it.")
            // Default toggle doesn't force expand
            showContentWindow(forceExpand: false)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.isTogglingWindow = false
            self.logger.debug("Window toggle operation complete. Flag reset.")
        }
    }
    
    // --- MODIFIED: Accepts forceExpand parameter ---
    /* @objc */ func showContentWindow(forceExpand: Bool = false) { // Default to false
        logger.info("AppDelegate: showContentWindow called. ForceExpand: \(forceExpand)")

        if let existingWindow = contentWindow {
            logger.warning("AppDelegate: Found existing window reference during showContentWindow. Closing it first.")
            existingWindow.close()
            self.contentWindow = nil
        } else {
             logger.debug("AppDelegate: No existing window reference found. Proceeding to create new.")
        }

        let currentQAIdInDefaults = UserDefaults.standard.string(forKey: SettingsKeys.quickAccessOverlayConversationId)
        logger.debug("AppDelegate: Before creating panel, QA ID in UserDefaults is: \(currentQAIdInDefaults ?? "nil")")

        // --- Check for Session Timeout ---
        let defaults = UserDefaults.standard
        let lastCloseTime = defaults.double(forKey: SettingsKeys.quickAccessLastCloseTime)
        let currentTime = Date().timeIntervalSince1970
        let elapsedTime = currentTime - lastCloseTime
        var shouldResumeSession = false

        // Determine if session should resume based on timeout *unless* forceExpand is true
        if forceExpand {
             logger.info("AppDelegate: Forcing expansion due to transfer request.")
             // We still respect the timeout for *conversation* reset, but visual state is forced
             if lastCloseTime > 0 && elapsedTime > sessionTimeoutDuration {
                 logger.info("AppDelegate: Session timed out during transfer. Starting new conversation session.")
                 _ = ConversationStore.shared.startNewQuickAccessConversationSession()
                 defaults.removeObject(forKey: SettingsKeys.quickAccessLastCloseTime)
                 defaults.removeObject(forKey: SettingsKeys.quickAccessWasExpandedOnClose)
                 shouldResumeSession = false // Don't technically resume the old session state
             } else {
                 // Within timeout or no previous time, keep existing conversation ID
                 // but ensure the panel knows to force expand visually.
                 // The panel initializer will handle the visual part based on forceExpand flag.
                 shouldResumeSession = true // Allow panel to read existing state if needed
             }
        } else if lastCloseTime > 0 && elapsedTime <= sessionTimeoutDuration {
            // Normal resume (not forced)
            shouldResumeSession = true
            logger.info("AppDelegate: Quick Access session is within timeout. Resuming.")
        } else if lastCloseTime > 0 {
            // Normal timeout (not forced)
            logger.info("AppDelegate: Quick Access session timed out. Starting new.")
            _ = ConversationStore.shared.startNewQuickAccessConversationSession()
            defaults.removeObject(forKey: SettingsKeys.quickAccessLastCloseTime)
            defaults.removeObject(forKey: SettingsKeys.quickAccessWasExpandedOnClose)
            shouldResumeSession = false
        } else {
            // First open
            logger.info("AppDelegate: No last close time found. Starting fresh.")
             _ = ConversationStore.shared.getOrCreateQuickAccessConversation()
             shouldResumeSession = false
        }
        // --- End Timeout Check ---

        logger.debug("AppDelegate: Creating new QuickAccessPanelView instance. ShouldResumeSession: \(shouldResumeSession), ForceExpandVisual: \(forceExpand)")
        // Pass both flags to the panel initializer
        let panel = QuickAccessPanelView(shouldResumeSession: shouldResumeSession, forceExpandVisual: forceExpand)
        contentWindow = panel
        
        logger.debug("AppDelegate: Ordering new panel front.")
        panel.makeKeyAndOrderFront(nil)
        
        NSApp.activate(ignoringOtherApps: true)
        logger.info("AppDelegate: New Quick Access Panel shown.")
    }
    
    private func closeContentWindow() {
        if let window = contentWindow {
            logger.info("Closing Quick Access Panel.")
            window.orderOut(nil)
            window.close() // Triggers windowWillClose
            self.contentWindow = nil
            logger.debug("Content window reference set to nil.")
        } else {
            logger.warning("closeContentWindow called but contentWindow reference was already nil.")
        }
    }

    deinit {
        logger.info("AppDelegate deinit. Removing observers and unregistering hotkey.")
        NotificationCenter.default.removeObserver(
            self,
            name: SettingsKeys.showQuickAccessPanelNotification,
            object: nil
        )
        hotKey = nil
    }
}
