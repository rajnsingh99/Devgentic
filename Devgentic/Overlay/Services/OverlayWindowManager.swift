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
        viewModel.registerDismissalObserver()
        self.quickAccessViewModel = viewModel

        // 2. Create the SwiftUI View instance, injecting the ViewModel.
        let swiftUIView = QuickAccessOverlayView(viewModel: viewModel)

        // 3. Create the NSHostingController to embed the SwiftUI view within AppKit.
        let hostVC = NSHostingController(rootView: swiftUIView)
        self.hostingController = hostVC // Keep reference

        // 4. Define the panel's initial size and position.
        // Let's try 800 width this time for a clear difference if it works.
        let desiredSize = NSSize(width: 500, height: 450)
        let contentRect = NSRect(origin: .zero, size: desiredSize)

        // *** ADDED: Set preferredContentSize on hosting controller ***
        // This tells the hosting controller the ideal size for its SwiftUI content.
        hostVC.preferredContentSize = desiredSize
        print("Set hosting controller preferredContentSize to: \(desiredSize)")

        // 5. Create the NSPanel instance.
        // Keep .titled for focus, removed .hudWindow during visibility fix.
        let panel = NSPanel(
            contentRect: contentRect, // Use the rect derived from desiredSize
            styleMask: [.titled, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        // --- Configure Panel Properties ---
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isMovableByWindowBackground = true // Still allow moving by background
        panel.hasShadow = true
        panel.backgroundColor = .clear // Keep panel clear
        panel.isOpaque = false          // Keep panel non-opaque

        // Hide the (now enabled) title bar for focus fix
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        // --- Set the SwiftUI content ---
        // Assign the NSHostingController as the panel's main content view controller.
        panel.contentViewController = hostVC

        // Set hosting view frame explicitly (can sometimes help)
        // Use contentView.bounds which represents the drawable area inside the window frame.
        if let contentView = panel.contentView {
             hostVC.view.frame = contentView.bounds
             print("Set hosting controller view frame to contentView bounds: \(contentView.bounds)")
        } else {
             print("Warning: Panel contentView is nil when trying to set hosting controller frame.")
             hostVC.view.frame = panel.frame // Fallback
        }
        // Ensure the hosting view autoresizes with the window/contentView
        hostVC.view.autoresizingMask = [.width, .height]


        // --- Set Delegate ---
        panel.delegate = self

        // Store the created panel.
        self.overlayPanel = panel

        print("Overlay panel created successfully with SwiftUI content. Initial size: \(contentRect.size). Title bar hidden. Style mask adjusted.")
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
        createPanelIfNeeded()
        guard let panel = overlayPanel else {
            print("Error: Panel is nil, cannot toggle.")
            return
        }

        if panel.isVisible && panel.isKeyWindow {
            panel.orderOut(nil)
            print("Overlay panel ordered out (hidden).")
        } else {
            print("Showing overlay panel...")
            centerPanel(panel)
            // Make key and activate app to ensure focus can be received
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            print("Overlay panel shown and made key.")
            // Focus logic is handled in SwiftUI's onAppear
        }
    }

    /// Calculates and sets the position of the panel, positioning it near the mouse cursor.
    private func centerPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else {
            print("Error: Could not get screen containing mouse.")
            return
        }
        let mouseLocation = NSEvent.mouseLocation
        let screenFrame = screen.frame
        let panelSize = panel.frame.size
        var targetX = mouseLocation.x - panelSize.width / 2
        var targetY = mouseLocation.y - panelSize.height / 2
        targetX = max(screenFrame.minX, min(targetX, screenFrame.maxX - panelSize.width))
        targetY = max(screenFrame.minY, min(targetY, screenFrame.maxY - panelSize.height))
        let adjustedOrigin = NSPoint(x: targetX, y: targetY)
        panel.setFrameOrigin(adjustedOrigin)
        print("Panel positioned near mouse on screen \(screen.localizedName ?? "Unknown") at (\(adjustedOrigin.x), \(adjustedOrigin.y))")
    }

    // MARK: - NSWindowDelegate Methods

    /// Called automatically by AppKit just before the panel closes or hides.
    func windowWillClose(_ notification: Notification) {
        if let closingPanel = notification.object as? NSPanel, closingPanel == self.overlayPanel {
            print("Overlay panel is closing. Resetting ViewModel state.")
            self.quickAccessViewModel?.resetState()
        } else {
            print("A different window is closing.")
        }
    }

    // MARK: - Notification Handling

    /// Call this method during initialization to listen for the close notification.
    func setupCloseNotificationObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCloseNotification),
            name: Notification.Name("CloseQuickAccessOverlay"),
            object: nil
        )
        print("Close notification observer set up.")
    }

    /// Responds to the close notification.
    @objc private func handleCloseNotification() {
        print("Received close notification. Ordering panel out.")
        overlayPanel?.orderOut(nil)
    }

    // Deinitializer to remove observer
    deinit {
        NotificationCenter.default.removeObserver(self, name: Notification.Name("CloseQuickAccessOverlay"), object: nil)
        print("OverlayWindowManager deinit. Removed close notification observer.")
    }
}
