// Services/OverlayWindowManager.swift
import Cocoa
import SwiftUI
import Combine // Needed for observing ViewModel changes

// MARK: - Overlay Window Manager

// This class is responsible for creating, configuring, showing, hiding,
// and managing the lifecycle of the floating overlay panel (NSPanel).
// It dynamically sizes the panel based on its SwiftUI content and matches
// the corner radius of the SwiftUI view.
// It also acts as the handler for the global shortcut activation.
class OverlayWindowManager: NSObject, GlobalShortcutHandler, NSWindowDelegate {

    // MARK: Properties

    private var overlayPanel: NSPanel?
    private var quickAccessViewModel: QuickAccessViewModel?
    private var hostingController: NSHostingController<QuickAccessOverlayView>?
    private var cancellables = Set<AnyCancellable>() // Local cancellables for this class

    // MARK: Panel Creation

    /// Creates the NSPanel and its SwiftUI content if it doesn't exist yet.
    /// Configures the panel for dynamic sizing and matching corner radius.
    private func createPanelIfNeeded() {
        // Ensure this runs on the main thread, though it usually does from UI events.
        assert(Thread.isMainThread, "UI Creation must be on the main thread")

        guard overlayPanel == nil else { return }

        print("Creating overlay panel and its content...")

        // 1. Create the ViewModel
        let viewModel = QuickAccessViewModel()
        // Register observer for window resign key (calls viewModel.resetState)
        // Note: With hidesOnDeactivate=false, reset might need different trigger if panel stays visible.
        // Ensure the observer in registerDismissalObserver is commented out/disabled in QuickAccessViewModel.swift
        self.quickAccessViewModel = viewModel

        // 2. Create the SwiftUI View
        let swiftUIView = QuickAccessOverlayView(viewModel: viewModel)

        // 3. Create the NSHostingController
        let hostVC = NSHostingController(rootView: swiftUIView)
        self.hostingController = hostVC

        // 4. Determine Initial Size from SwiftUI View
        // Get the initial size required by the SwiftUI content.
        // The .frame modifier in SwiftUI should influence this now.
        let initialContentSize = hostVC.view.fittingSize
        let initialContentRect = NSRect(origin: .zero, size: initialContentSize)
        print("Initial SwiftUI fittingSize: \(initialContentSize)")

        // 5. Create the NSPanel
        let panel = NSPanel(
            contentRect: initialContentRect,
            // .utilityWindow keeps its utility panel behavior.
            // .titled is included (though hidden) to potentially help with key status/event handling.
            styleMask: [.utilityWindow, .titled],
            backing: .buffered,
            defer: false)

        // --- Configure Panel Appearance & Behavior ---
        panel.level = .mainMenu // Keep high level for floating over other apps
        // *** CORRECTED Collection Behavior ***
        // Removed .moveToActiveSpace as it conflicts with .canJoinAllSpaces.
        // .canJoinAllSpaces allows the panel to exist on any space the user drags it to.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isFloatingPanel = true // It is fundamentally a floating panel
        panel.hidesOnDeactivate = false // Keep false to allow visibility when app inactive
        panel.isMovableByWindowBackground = true // Ensure dragging is enabled
        panel.hasShadow = true

        // --- Transparency and Corner Radius ---
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 16.0 // Match SwiftUI view's corner radius
        panel.contentView?.layer?.masksToBounds = true

        // --- Hide Title Bar ---
        // Still hide the title bar visually even though .titled is in the styleMask
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        // --- Set SwiftUI Content via Hosting Controller ---
        panel.contentViewController = hostVC
        print("Set panel's contentViewController to the NSHostingController.")

        // --- Set Delegate ---
        panel.delegate = self

        // Store the created panel
        self.overlayPanel = panel

        // --- Observe ViewModel for Size Changes ---
        // This remains important for resizing the *panel* based on SwiftUI content changes.
        viewModel.$isExpanded
            .sink { [weak self, weak panel, weak hostVC] _ in
                DispatchQueue.main.async {
                    guard let self = self, let panel = panel, let hostVC = hostVC else { return }
                    // Recalculate fittingSize after SwiftUI layout potentially changes
                    let newSize = hostVC.view.fittingSize
                    print("ViewModel expansion changed. New fittingSize: \(newSize)")

                    NSAnimationContext.runAnimationGroup({ context in
                        context.duration = 0.25
                        context.allowsImplicitAnimation = true
                        let currentFrame = panel.frame
                        // Keep top-left stationary during resize
                        let newFrame = NSRect(origin: currentFrame.origin, size: newSize)

                        // Check if panel is visible before trying to resize/animate
                        if panel.isVisible {
                            panel.setFrame(newFrame, display: true, animate: true)
                        } else {
                             // If not visible, just update the frame size internally
                             panel.setFrame(newFrame, display: false)
                        }
                        // Optional: Reposition if needed after resize
                        // self.positionPanel(panel)

                    }, completionHandler: nil)
                }
            }
            .store(in: &viewModel.cancellables) // Assumes cancellables is accessible

        print("Overlay panel created successfully. Initial size: \(initialContentSize). Corner radius applied. Auto-resizing enabled. Level: \(panel.level.rawValue). HidesOnDeactivate: \(panel.hidesOnDeactivate)")
    }


    // MARK: - GlobalShortcutHandler Conformance

    /// Called by `GlobalShortcutService` when the hotkey is pressed.
    func handleShortcutActivation() {
        print("Shortcut activated! Toggling overlay window.")
        toggleOverlayWindow()
    }

    // MARK: - Window Management

    /// Shows or hides the overlay panel, ensuring correct size and position.
    func toggleOverlayWindow() {
        createPanelIfNeeded() // Ensure panel and content exist
        guard let panel = overlayPanel, let hostVC = hostingController else {
            print("Error: Panel or hostingController is nil, cannot toggle.")
            return
        }

        if panel.isVisible {
            panel.orderOut(nil)
            print("Overlay panel ordered out (hidden).")
        } else {
            print("Showing overlay panel...")

            // Update size and position BEFORE showing
            let currentSize = hostVC.view.fittingSize
            panel.setContentSize(currentSize) // Set panel size based on current SwiftUI content need
            positionPanel(panel) // Position the correctly sized panel

            // Ensure panel becomes key and app activates
            // This is crucial for receiving keyboard/mouse events.
            panel.makeKeyAndOrderFront(nil)
            // Activate app to help ensure panel gets focus initially
            NSApp.activate(ignoringOtherApps: true)
            print("Overlay panel shown and made key. Size: \(currentSize)")
        }
    }

    /// Calculates and sets the position of the panel, centered on the active screen.
    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else {
            print("Error: Could not determine target screen.")
            return
        }
        let screenFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        let targetX = screenFrame.origin.x + (screenFrame.size.width - panelSize.width) / 2
        let targetY = screenFrame.origin.y + (screenFrame.size.height - panelSize.height) * 0.6 // Adjust vertical position
        let adjustedOrigin = NSPoint(x: targetX, y: targetY)
        panel.setFrameOrigin(adjustedOrigin)
        print("Panel positioned on screen \(screen.localizedName ?? "Unknown") at (\(adjustedOrigin.x), \(adjustedOrigin.y))")
    }

    // MARK: - NSWindowDelegate Methods

    /// Called automatically just before the panel closes (e.g., user closes it, or app terminates).
    /// Note: This might NOT be called if only hiding due to deactivation when hidesOnDeactivate=true.
    func windowWillClose(_ notification: Notification) {
        if let closingPanel = notification.object as? NSPanel, closingPanel == self.overlayPanel {
            print("Overlay panel is closing (windowWillClose). Resetting ViewModel state.")
            // Ensure resetStateWithoutAnimation exists in QuickAccessViewModel
            self.quickAccessViewModel?.resetStateWithoutAnimation()
        }
    }

    // Optional: Handle resign key if specific behavior needed when panel loses focus but stays visible
    // func windowDidResignKey(_ notification: Notification) {
    //     if let panel = notification.object as? NSPanel, panel == self.overlayPanel {
    //         print("Overlay panel resigned key status.")
    //         // If hidesOnDeactivate is false, the panel remains visible here.
    //         // Resetting state should NOT happen here if we want panel to persist when inactive.
    //     }
    // }


    // MARK: - Notification Handling (for explicit close button)

    /// Call this method during app initialization to listen for the custom close notification.
    func setupCloseNotificationObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCloseNotification),
            name: Notification.Name("CloseQuickAccessOverlay"),
            object: nil
        )
        print("Close notification observer set up.")
    }

    /// Responds to the custom "CloseQuickAccessOverlay" notification.
    @objc private func handleCloseNotification() {
        print("Received explicit close notification. Ordering panel out.")
        overlayPanel?.orderOut(nil)
        // Reset state should happen via windowWillClose
    }

    // MARK: - Deinitialization

    deinit {
        NotificationCenter.default.removeObserver(self, name: Notification.Name("CloseQuickAccessOverlay"), object: nil)
        cancellables.forEach { $0.cancel() }
        print("OverlayWindowManager deinit. Removed observers and cancelled subscriptions.")
    }
}

// MARK: - Helper in QuickAccessViewModel (Reminder)

// Ensure this function exists in QuickAccessViewModel.swift
/*
 extension QuickAccessViewModel {
     func resetStateWithoutAnimation() {
         userInput = ""
         isProcessing = false
         results = nil
         errorMessage = nil
         isExpanded = false // Reset directly without withAnimation
         print("QuickAccessViewModel state reset (without animation). isExpanded: \(isExpanded)")
     }
 }
*/

// Ensure the observer in QuickAccessViewModel -> registerDismissalObserver() is disabled
/*
 func registerDismissalObserver() {
     // COMMENT OUT or REMOVE the NotificationCenter observer for didResignKeyNotification
     print("registerDismissalObserver: DidResignKeyNotification observer is currently DISABLED.")
 }
*/
