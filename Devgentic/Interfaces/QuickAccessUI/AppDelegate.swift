import Cocoa
import SwiftUI
import Carbon // Keep if GlobalShortcutService uses it

// This AppDelegate sets up the application to run as a menu bar extra.
// It manages the NSStatusItem, integrates the existing OverlayWindowManager,
// and the GlobalShortcutService.
class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: Properties

    // The Status Bar Item object
    private var statusItem: NSStatusItem?

    // The manager for the overlay panel window
    // Kept from the original AppDelegate
    var overlayWindowManager: OverlayWindowManager?

    // The service for managing global keyboard shortcuts
    // Kept from the original AppDelegate
    var globalShortcutService: GlobalShortcutService?


    // MARK: - NSApplicationDelegate Methods

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        print("Application finished launching. Setting up status item, overlay manager, and shortcut service.")

        // 1. Initialize the Overlay Window Manager
        // This object will be responsible for creating and managing the floating panel.
        overlayWindowManager = OverlayWindowManager()
        // Setup observer for the explicit close button notification (if OverlayWindowManager has this method)
        overlayWindowManager?.setupCloseNotificationObserver()


        // 2. Initialize and setup the GlobalShortcutService
        // Pass the overlayWindowManager as the handler that will be notified when the shortcut is pressed.
        // Ensure OverlayWindowManager conforms to the handler protocol expected by GlobalShortcutService.
        if let manager = overlayWindowManager {
            // Assuming GlobalShortcutService initializer takes a handler argument
            globalShortcutService = GlobalShortcutService(handler: manager)
            // Register the global hotkey (e.g., Option+Space)
            globalShortcutService?.register()
            print("Global shortcut service initialized and shortcut registered.")
        } else {
            print("Error: OverlayWindowManager failed to initialize. Cannot set up shortcut service.")
        }


        // 3. Set up the Status Bar Item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            // Set an icon for the status bar item (replace "YourIconName" or use SFSymbol)
            button.image = NSImage(systemSymbolName: "bubble.middle.bottom.fill", accessibilityDescription: "DevGentic Overlay") // Example SFSymbol
             // Set the action to be called when the status item button is clicked
            button.action = #selector(statusBarButtonClicked(_:))
            button.target = self // Action is defined in this AppDelegate
            print("Status bar item created and configured.")
        } else {
            print("Error: Could not create status bar button.")
            // Consider quitting or logging a fatal error if the status item is essential
            // NSApp.terminate(nil)
        }

        // Note: The optional configurations from your original AppDelegate
        // (like hiding Dock icon or closing main window) are now handled differently:
        // - Hiding Dock icon: Done via LSUIElement=true in Info.plist (as per previous instructions).
        // - Closing main window: Achieved by removing the WindowGroup from the SwiftUI App struct.

        // The UserDefaults line seems unrelated to the overlay/status item setup, keep if needed elsewhere.
        // UserDefaults.standard.set(false, forKey: SettingsKeys.isOnboardingComplete)

        print("AppDelegate setup complete.")
    }

    // MARK: - Actions

    /// Called when the status bar item's button is clicked.
    @objc func statusBarButtonClicked(_ sender: AnyObject?) {
        print("Status bar button clicked.")
        // Toggle the overlay window using the manager
        // This provides an alternative way to show/hide besides the shortcut.
        overlayWindowManager?.toggleOverlayWindow()
    }

    // Note: If GlobalShortcutService calls a handler method directly on the object
    // passed to its initializer (i.e., overlayWindowManager), then AppDelegate
    // doesn't need to conform to GlobalShortcutHandler itself. Ensure OverlayWindowManager
    // has the necessary `handleShortcutActivation` method (or similar).


    func applicationWillTerminate(_ aNotification: Notification) {
        // Clean up resources
        print("Application will terminate. Unregistering shortcut.")
        // Unregister the global hotkey
        globalShortcutService?.unregister()
    }

}
