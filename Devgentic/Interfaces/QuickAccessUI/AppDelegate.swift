//
//  AppDelegate.swift
//  Devgentic
//
//  Created by Raj Singh on 07/05/25.
//

// AppDelegate.swift
import SwiftUI // For @main if DevgenticApp uses it, or AppKit for traditional AppDelegate
import os
import HotKey // Assuming HotKey is used as per the provided AppDelegate content

// Assuming ConversationStore and SettingsKeys are defined elsewhere
// For AgentManager functionality, ensure SettingsKeys includes:
// agentBaseURL, defaultAgentModel, agentPID, venvPythonPath, isOnboardingComplete, selectedBackend

class AppDelegate: NSObject, NSApplicationDelegate {
    
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic", category: "AppDelegate")
    
    // Make AgentManager accessible
    private(set) var agentManager: AgentManager? // Changed to private(set)
    
    // Static shared instance of AppDelegate to access its properties like agentManager
    static var shared: AppDelegate {
        return NSApplication.shared.delegate as! AppDelegate
    }

    // Properties from the provided AppDelegate
    var contentWindow: QuickAccessPanelView? // Assuming QuickAccessPanelView is a custom NSPanel or NSWindow subclass
    var hotKey: HotKey?
    private var isTogglingWindow = false
    private let sessionTimeoutDuration: TimeInterval = 1800 // 30 minutes in seconds


    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.logger.info("Application did finish launching.")
        // Initialize AgentManager
        agentManager = AgentManager()
        Self.logger.info("AgentManager initialized in AppDelegate.")
        
        if UserDefaults.standard.bool(forKey: SettingsKeys.isOnboardingComplete) {
            Self.logger.info("Onboarding is complete. Attempting to start agent if not already running via AgentManager.")
            agentManager?.startAgentIfNeeded()
        } else {
            Self.logger.info("Onboarding not yet complete. Agent will not be started automatically by AppDelegate.")
        }
        
        // Setup from the provided AppDelegate
        setupHotkey()
        setupNotificationObserver()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.logger.info("Application will terminate. Stopping agent via AgentManager.")
        agentManager?.stopAgent(reason: "Application shutting down")
        
        // Cleanup from the provided AppDelegate
        NotificationCenter.default.removeObserver(
            self,
            name: SettingsKeys.showQuickAccessPanelNotification, // Make sure this key is defined
            object: nil
        )
        hotKey = nil // Deinit of HotKey should handle unregistering
        Self.logger.info("AppDelegate cleaned up hotkey and observers.")
    }

    // --- Methods from the provided AppDelegate ---
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
        // Ensure SettingsKeys.showQuickAccessPanelNotification is correctly defined
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowQuickAccessPanelNotification(_:)),
            name: SettingsKeys.showQuickAccessPanelNotification,
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
        let lastCloseTime = defaults.double(forKey: SettingsKeys.quickAccessLastCloseTime) // Ensure key is defined
        let currentTime = Date().timeIntervalSince1970
        let elapsedTime = currentTime - lastCloseTime
        var shouldResumeSession = false

        if forceExpand {
             Self.logger.info("AppDelegate: Forcing expansion due to transfer request.")
             if lastCloseTime > 0 && elapsedTime > sessionTimeoutDuration {
                 Self.logger.info("AppDelegate: Session timed out during transfer. Starting new conversation session.")
                 // _ = ConversationStore.shared.startNewQuickAccessConversationSession() // Ensure ConversationStore is accessible
                 defaults.removeObject(forKey: SettingsKeys.quickAccessLastCloseTime)
                 defaults.removeObject(forKey: SettingsKeys.quickAccessWasExpandedOnClose) // Ensure key is defined
                 shouldResumeSession = false
             } else {
                 shouldResumeSession = true
             }
        } else if lastCloseTime > 0 && elapsedTime <= sessionTimeoutDuration {
            shouldResumeSession = true
            Self.logger.info("AppDelegate: Quick Access session is within timeout. Resuming.")
        } else if lastCloseTime > 0 {
            Self.logger.info("AppDelegate: Quick Access session timed out. Starting new.")
            // _ = ConversationStore.shared.startNewQuickAccessConversationSession()
            defaults.removeObject(forKey: SettingsKeys.quickAccessLastCloseTime)
            defaults.removeObject(forKey: SettingsKeys.quickAccessWasExpandedOnClose)
            shouldResumeSession = false
        } else {
            Self.logger.info("AppDelegate: No last close time found. Starting fresh.")
            // _ = ConversationStore.shared.getOrCreateQuickAccessConversation() // Ensure ConversationStore is accessible
             shouldResumeSession = false
        }

        Self.logger.debug("AppDelegate: Creating new QuickAccessPanelView instance. ShouldResumeSession: \(shouldResumeSession), ForceExpandVisual: \(forceExpand)")
        // Ensure QuickAccessPanelView and its initializer are correctly defined
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
        // This might not be called for AppDelegate in typical app lifecycle,
        // cleanup is usually done in applicationWillTerminate.
        Self.logger.info("AppDelegate deinit.")
    }
}
