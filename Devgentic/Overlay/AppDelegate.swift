// AppDelegate.swift
import Cocoa
import SwiftUI
import Carbon // Import Carbon for HotKeys

class AppDelegate: NSObject, NSApplicationDelegate {

    // Properties to hold references to our custom services
    var globalShortcutService: GlobalShortcutService?
    var overlayWindowManager: OverlayWindowManager?

    // Called automatically after the app finishes launching
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("App finished launching. Setting up overlay...")

        // 1. Initialize the OverlayWindowManager
        // This object will be responsible for creating and managing the floating panel.
        overlayWindowManager = OverlayWindowManager()

        // 2. Initialize and setup the GlobalShortcutService
        // Pass the overlayWindowManager as the handler that will be notified when the shortcut is pressed.
        // The force unwrap (!) is generally safe here because we just created overlayWindowManager on the line above.
        // In more complex scenarios, you might use optional chaining or guard statements.
        globalShortcutService = GlobalShortcutService(handler: overlayWindowManager!)

        // 3. Register the global hotkey (e.g., Option+Space)
        // This tells the system to start listening for the shortcut.
        globalShortcutService?.register()

        // --- Optional Configuration ---

        // Optional: Hide the Dock icon if you want Devgentic to run primarily as a menu bar/overlay app.
        // This makes the app behave more like a background utility. Accessing the main window
        // would typically require a menu bar item or another way to trigger it.
        // Uncomment the line below to enable this:
        // NSApp.setActivationPolicy(.accessory)

        // Optional: Prevent the main application window (defined in DevgenticApp.swift)
        // from opening automatically when the app starts. Useful if the overlay
        // is the primary way users interact initially.
        // Uncomment the block below to enable this:
        /*
        if let window = NSApplication.shared.windows.first(where: {
            // Attempt to identify the main window by its SwiftUI content view type
            ($0.contentViewController as? NSHostingController<MainApplicationView>) != nil
        }) {
            print("Closing initial main application window.")
            window.close()
        }
        */
        // --- End Optional Configuration ---

        UserDefaults.standard.set(false, forKey: SettingsKeys.isOnboardingComplete)
        print("Overlay setup complete.")
    }

    // Called automatically just before the app terminates
    func applicationWillTerminate(_ notification: Notification) {
        // Clean up: Unregister the hotkey to release it for other applications.
        print("App will terminate. Unregistering hotkey...")
        globalShortcutService?.unregister()
    }

    // Optional: Handle reopening the app (e.g., clicking the Dock icon)
    // This is mainly relevant if the app's activation policy is `.regular` (shows in Dock)
    // and the main window might have been closed by the user.
    // Uncomment the function below to enable this behavior:
    /*
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        print("Application reopen requested. Has visible windows: \(flag)")
        if !flag {
            // If there are no visible windows, try to find and show the main one.
            if let window = NSApplication.shared.windows.first(where: {
                ($0.contentViewController as? NSHostingController<MainApplicationView>) != nil
            }) {
                print("Found existing main window. Making key and ordering front.")
                window.makeKeyAndOrderFront(nil)
            } else {
                // If the main window instance doesn't exist anymore (less common with SwiftUI's WindowGroup),
                // you might need logic here to create a new one. This depends heavily on your app's structure.
                // For a standard WindowGroup, often just activating the app is enough,
                // or you might need to manually manage window creation/presentation.
                print("Main window not found. App activation might reopen it, or manual creation needed.")
                // Consider NSApp.activate(ignoringOtherApps: true) or specific window creation logic.
            }
        }
        return true // Return true to indicate the app handled the reopen request.
    }
    */
}
