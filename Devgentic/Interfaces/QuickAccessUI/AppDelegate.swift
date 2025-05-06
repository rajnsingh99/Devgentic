//
//  AppDelegate.swift
//  Devgentic
//
//  Created by Raj Singh on 07/05/25.

import AppKit
import HotKey // Ensure this package is added to your project

class AppDelegate: NSObject, NSApplicationDelegate {
    var contentWindow: NSWindow?
    var hotKey: HotKey?
    
    // Flag to prevent rapid toggling from creating multiple instances or re-entrant calls.
    private var isTogglingWindow = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set activation policy. .accessory means the app doesn't appear in the Dock
        // and doesn't get a main menu bar unless its window is key.
        // NSApp.setActivationPolicy(.accessory) // Keep or comment out for debugging

        setupHotkey()
    }
    
    private func setupHotkey() {
        // Configure the hotkey for Option+Space.
        hotKey = HotKey(key: .space, modifiers: [.option])
        
        // Assign a handler to be executed when the hotkey is pressed.
        hotKey?.keyDownHandler = { [weak self] in
            // Ensure UI updates are on the main thread.
            DispatchQueue.main.async {
                self?.toggleContentWindow()
            }
        }
    }
    
    // Toggles the visibility of the content window.
    func toggleContentWindow() {
        // Prevent re-entrant calls or multiple rapid toggles.
        guard !isTogglingWindow else {
            print("Window toggle operation already in progress. Ignoring this call.")
            return
        }
        isTogglingWindow = true // Set the flag

        if contentWindow?.isVisible == true {
            // If window exists and is visible, close it.
            closeContentWindow() // This method sets self.contentWindow to nil.
        } else {
            // If window is nil OR exists but is not visible, show it.
            // showContentWindow() handles closing any existing (but non-visible) window first.
            showContentWindow()
        }
        
        // Reset the flag after the operation is complete.
        // Since closeContentWindow and showContentWindow are synchronous from this method's perspective
        // regarding state changes to self.contentWindow and visibility, we can reset it here.
        // If they involved further significant async work that could affect this logic,
        // the flag reset might need to be in completion handlers of that async work.
        isTogglingWindow = false
    }
    
    func showContentWindow() {
        // If a window instance already exists (even if not visible),
        // close it first to ensure we're always working with a fresh instance
        // and to maintain the singleton pattern for our contentWindow.
        if contentWindow != nil {
             closeContentWindow() // This sets self.contentWindow to nil.
        }
        
        // At this point, self.contentWindow is guaranteed to be nil.
        
        // Create an instance of our custom ContentPanel.
        // This assumes ContentPanel is correctly set up to use a ContentView
        // that has the onResize callback, as per previous discussions.
        let panel = QuickAccessPanelView()
        
        // Store a reference to the window.
        contentWindow = panel
        
        // Make the panel key and order it to the front.
        panel.makeKeyAndOrderFront(nil)
        
        // Activate the application to ensure the panel can become key,
        // especially if activation policy is .accessory
        NSApp.activate(ignoringOtherApps: true)
    }
    
    private func closeContentWindow() {
        // Perform cleanup when closing the window.
        if let window = contentWindow {
            window.close() // Removes the window from the screen.
            self.contentWindow = nil // Release our strong reference to allow deallocation.
        }
    }

    // It's good practice to deallocate the hotkey if the AppDelegate is deinitialized,
    // though for an app delegate, it typically lives for the duration of the app.
    deinit {
        hotKey = nil // This will deallocate the HotKey object and unregister the hotkey.
    }
}
