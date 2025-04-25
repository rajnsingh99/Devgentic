// Services/OverlayWindowManager.swift
import Cocoa
import SwiftUI // Now needed for NSHostingController and SwiftUI Views

// MARK: - Overlay Window Manager

// This class is responsible for creating, configuring, showing, hiding,
// and managing the lifecycle of the floating overlay panel (NSPanel).
// It also acts as the handler for the global shortcut activation.
class OverlayWindowManager: NSObject, GlobalShortcutHandler, NSWindowDelegate { // Conform to necessary protocols

    // MARK: Properties

    // The floating panel window itself. Lazily created.
    private var overlayPanel: NSPanel?

    // The ViewModel for the SwiftUI view hosted in the panel.
    private var quickAccessViewModel: QuickAccessViewModel?

    // The AppKit controller that bridges the NSPanel and the SwiftUI view.
    private var hostingController: NSHostingController<QuickAccessOverlayView>?

    // MARK: Panel Creation

    /// Creates the NSPanel and its SwiftUI content if it doesn't exist yet.
    /// This is called lazily the first time the overlay needs to be shown.
    private func createPanelIfNeeded() {
        // Only create if the panel hasn't been created already.
        guard overlayPanel == nil else { return }

        print("Creating overlay panel and its content...")

        // 1. Create the ViewModel instance for the overlay's state.
        let viewModel = QuickAccessViewModel()
        self.quickAccessViewModel = viewModel

        // 2. Create the SwiftUI View instance, injecting the ViewModel.
        let swiftUIView = QuickAccessOverlayView(viewModel: viewModel)

        // 3. Create the NSHostingController to embed the SwiftUI view within AppKit.
        let hostVC = NSHostingController(rootView: swiftUIView)
        self.hostingController = hostVC

        // 4. Define the panel's initial size and position (can be adjusted).
        //    Height might need tweaking based on your QuickAccessOverlayView content.
        let contentRect = NSRect(x: 0, y: 0, width: 600, height: 180)

        // 5. Create the NSPanel instance.
        let panel = NSPanel(
            contentRect: contentRect,
            // Style Mask:
            // - .borderless: No standard window frame.
            // - .hudWindow: Provides a specific visual style often used for overlays (optional, but common).
            // - .utilityWindow: Indicates it's an auxiliary window.
            // - .nonactivatingPanel: Prevents the panel from becoming the key window *initially* when shown,
            //   allowing the previously active app to remain active until the user interacts with the panel.
            //   We will explicitly make it key later when showing.
            styleMask: [.borderless, .hudWindow, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, // Standard buffering.
            defer: false)      // Create the window graphics context immediately.

        // --- Configure Panel Properties ---
        panel.level = .floating // Keep it above most other standard windows.
        // Collection Behavior:
        // - .canJoinAllSpaces: Allows the panel to appear on all Spaces.
        // - .fullScreenAuxiliary: Allows it to appear over fullscreen apps.
        // - .ignoresCycle: Hides the panel from the Cmd+Tab application switcher.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isFloatingPanel = true // Explicitly mark as floating (often redundant with level).
        panel.hidesOnDeactivate = true // Automatically hide the panel when the user clicks outside it.
        panel.isMovableByWindowBackground = true // Allow dragging the panel by clicking its background.
        panel.hasShadow = true // Give it a standard window shadow.
        panel.backgroundColor = .clear // Make the NSPanel itself clear.
        panel.isOpaque = false // Required for transparency and visual effects in the SwiftUI view.

        // --- Set the SwiftUI content ---
        // Assign the NSHostingController as the panel's main content view controller.
        panel.contentViewController = hostVC

        // --- Set Delegate ---
        // Assign self to handle window events like closing.
        panel.delegate = self

        // Store the created panel.
        self.overlayPanel = panel
        // After creating the panel and hostingController:
        // panel.contentView?.frame = panel.contentRect(forFrameRect: panel.frame)
        // hostVC.view.frame = panel.contentView?.bounds ?? panel.frame.size
        panel.contentViewController = hostVC
        print("Overlay panel created successfully with SwiftUI content.")
    }

    // MARK: - GlobalShortcutHandler Conformance

    /// This method is called by the `GlobalShortcutService` when the registered hotkey is pressed.
    func handleShortcutActivation() {
        print("Shortcut activated! Toggling overlay window.")
        toggleOverlayWindow()
    }

    // MARK: - Window Management

    /// Shows or hides the overlay panel.
    func toggleOverlayWindow() {
        // Ensure the panel exists, creating it if necessary.
        createPanelIfNeeded()

        guard let panel = overlayPanel else {
            print("Error: Panel is nil, cannot toggle.")
            return
        }

        // Check if the panel is currently visible.
        if panel.isVisible {
            // If visible, hide it.
            panel.orderOut(nil) // `windowWillClose` delegate method will be called.
            print("Overlay panel ordered out (hidden).")
        } else {
            // If hidden, show it.
            centerPanel(panel) // Position the panel appropriately first.
            panel.makeKeyAndOrderFront(nil) // Show the panel and make it the key window.
            // IMPORTANT: Activate our application to ensure the panel can receive keyboard input immediately.
            panel.contentView?.needsLayout = true
            panel.contentView?.layoutSubtreeIfNeeded()
            NSApp.activate(ignoringOtherApps: true)

            // Note: Focusing the specific input field is now handled within
            // QuickAccessOverlayView using .onAppear and @FocusState.
            // Making the panel key (`makeKey()`) is sufficient here.

            print("Overlay panel shown and made key.")
        }
    }

    /// Calculates and sets the position of the panel, typically near the top-center of the main screen.
    private func centerPanel(_ panel: NSPanel) {
        // Get the main screen. Handle potential nil case (though unlikely for main screen).
        guard let screen = NSScreen.main else {
            print("Error: Could not get main screen.")
            return
        }
        // Use the visibleFrame to account for the menu bar and Dock.
        let screenRect = screen.visibleFrame
        let panelSize = panel.frame.size

        // Calculate position: Centered horizontally, offset from the top edge.
        let xPos = screenRect.origin.x + (screenRect.width - panelSize.width) / 2
        let yPos = screenRect.maxY - panelSize.height - 100 // 100 points down from top edge

        // Set the panel's bottom-left corner origin.
        panel.setFrameOrigin(NSPoint(x: xPos, y: yPos))
        print("Panel positioned at (\(xPos), \(yPos))")
    }

    // MARK: - NSWindowDelegate Methods

    /// Called automatically by AppKit just before the panel closes or hides.
    /// This includes when `hidesOnDeactivate` triggers or `orderOut()` is called.
    // In your OverlayWindowManager class

    func windowWillClose(_ notification: Notification) {
        // It's generally unsafe to rely on instance variables (like self.overlayPanel
        // or self.quickAccessViewModel) being valid within this delegate method
        // during a force quit scenario, as objects might be deallocated out of order.
  
        // Option 1: Do nothing (Safest during force quit)
        // If the only purpose of this check was to reset the ViewModel for a normal close,
        // and that reset isn't critical during a force quit (which it isn't),
        // simply doing nothing here is the safest approach to prevent the crash.
        print("Window is closing (Notification received).")

        // Option 2: Minimal check (Still potentially risky during force quit)
        // If you absolutely needed to know if it *was* the panel, you could try:
        /*
        if let closingPanel = notification.object as? NSPanel {
            // Even comparing closingPanel to self.overlayPanel is risky if self or self.overlayPanel is invalid.
            // Avoid accessing self.quickAccessViewModel here during force quit.
            print("A panel is closing.")
        }
        */

        // Recommendation: Remove the resetState call from here as it's unsafe and unnecessary during force quit.
        // The crash indicates accessing self.overlayPanel or self.quickAccessViewModel is happening after
        // they (or self) have become invalid during the termination process.
    }


    // Optional: Handle Escape key press specifically at the NSPanel level.
    // If you prefer handling Escape purely within SwiftUI using `.keyboardShortcut(.cancelAction)`,
    // you might not need this `cancel` implementation here. However, this can be a robust fallback.
    // To make this work, the panel needs to be key, and its view hierarchy needs to forward the event.
    // override func cancel(_ sender: Any?) { // Note: This needs to be an override if inheriting from a class that defines it.
    //                                       // Since we inherit from NSObject, it's not strictly an override here,
    //                                       // but AppKit's responder chain might call it.
    //     if overlayPanel?.isVisible == true {
    //         print("Cancel operation triggered (Escape key likely). Closing panel via cancel().")
    //         overlayPanel?.orderOut(nil)
    //     } else {
    //         // If not visible, maybe pass the event up the responder chain?
    //         // super.cancel(sender) // Requires appropriate superclass if overriding.
    //     }
    // }
}
