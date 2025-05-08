//
//  QuickAccessPanelView.swift
//  Devgentic
//
//  Created by Raj Singh on 07/05/25.
//

import AppKit
import SwiftUI
import os // Import for logging

// UserDefaults Keys for saving the frame (Keep existing ones)
private enum UserDefaultsKeys {
    static let quickAccessPanelX = "quickAccessPanelLastX"
    static let quickAccessPanelY = "quickAccessPanelLastY"
    static let quickAccessPanelWidth = "quickAccessPanelLastWidth"
    static let quickAccessPanelHeight = "quickAccessPanelLastHeight"
}

// Make the class conform to NSWindowDelegate
class QuickAccessPanelView: NSPanel, NSWindowDelegate {

    private var hostingView: NSHostingView<QuickAccessContentView>?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.Devgentic", category: "QuickAccessPanelView")

    let collapsedHeight: CGFloat = 95
    let initialMinWidth: CGFloat = 500
    let defaultExpandedHeight: CGFloat = 400 // Default height when expanding for the first time

    private let baseStyleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
    
    private var frameBeforeZoom: NSRect?
    private var isProgrammaticallyResizing = false
    
    private let shouldResumeSession: Bool
    private let forceExpandVisual: Bool
    
    init(shouldResumeSession: Bool, forceExpandVisual: Bool) {
        self.shouldResumeSession = shouldResumeSession
        self.forceExpandVisual = forceExpandVisual // Store the flag
        logger.info("Initializing QuickAccessPanelView. ShouldResumeSession: \(shouldResumeSession), ForceExpandVisual: \(forceExpandVisual)")
        
        // Determine initial state *before* calling super.init
        let defaults = UserDefaults.standard
        let wasExpandedOnClose = defaults.bool(forKey: SettingsKeys.quickAccessWasExpandedOnClose)
        var shouldOpenExpanded = false // Default to collapsed

        // --- REFINED LOGIC for initial expanded state ---
        if forceExpandVisual {
             logger.debug("ForceExpandVisual is true. Checking conversation content...")
             let qaConversation = ConversationStore.shared.getOrCreateQuickAccessConversation()
             if !qaConversation.messages.isEmpty {
                 shouldOpenExpanded = true
                 logger.debug("Force expanding: Conversation has messages.")
             } else {
                 logger.debug("Force expanding requested, but conversation is empty. Opening collapsed.")
             }
        } else if shouldResumeSession && wasExpandedOnClose {
            // Normal resume logic: Check content only if resuming an expanded session
            logger.debug("Session resumable and was expanded. Checking conversation content...")
            let qaConversation = ConversationStore.shared.getOrCreateQuickAccessConversation()
            if !qaConversation.messages.isEmpty {
                shouldOpenExpanded = true
                logger.debug("Resuming expanded: Conversation has messages.")
            } else {
                logger.debug("Resuming expanded requested, but conversation is empty. Opening collapsed.")
            }
        } else {
             // Session timed out, wasn't expanded, first open, or not forcing expand. Open collapsed.
             logger.debug("Session not resumable, wasn't expanded, or not forcing expand. Opening collapsed.")
        }
        // --- END REFINED LOGIC ---
        
        logger.debug("Determined final initial state: shouldOpenExpanded=\(shouldOpenExpanded)")

        // Calculate initial frame based on whether it should open expanded
        let initialFrame = QuickAccessPanelView.calculateInitialFrame(
            shouldOpenExpanded: shouldOpenExpanded,
            collapsedHeight: collapsedHeight,
            defaultExpandedHeight: defaultExpandedHeight,
            minWidth: initialMinWidth
        )

        super.init(
            contentRect: initialFrame,
            styleMask: baseStyleMask,
            backing: .buffered,
            defer: true
        )
        
        if shouldOpenExpanded && !styleMask.contains(.resizable) {
             styleMask.insert(.resizable)
             logger.debug("Setting initial styleMask to include resizable.")
        }
        
        setupWindow()
        setupContentView(initialIsExpanded: shouldOpenExpanded)
        
        self.delegate = self
        logger.info("QuickAccessPanelView initialized and delegate set.")
    }

    // setupWindow remains the same
    private func setupWindow() {
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        self.minSize = NSSize(width: initialMinWidth, height: collapsedHeight)
        self.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    }

    // setupContentView remains the same (accepts initialIsExpanded)
    private func setupContentView(initialIsExpanded: Bool) {
        logger.debug("Setting up ContentView with initialIsExpanded: \(initialIsExpanded)")
        let swiftUIContentView = QuickAccessContentView(
            dismiss: { [weak self] in
                self?.closePanel()
            },
            onResize: { [weak self] newHeight in
                self?.resizePanelProgrammatically(newHeight: newHeight)
            },
            onToggleZoom: { [weak self] in
                self?.toggleZoomState()
            },
            // Pass the determined initial state
            isExpanded: initialIsExpanded
        )

        let hostingView = NSHostingView(rootView: swiftUIContentView)
        self.hostingView = hostingView
        self.contentView = hostingView
        
        self.setContentSize(self.frame.size)
        
        // Centering / Positioning Logic remains the same
        if UserDefaults.standard.object(forKey: UserDefaultsKeys.quickAccessPanelX) == nil {
            logger.debug("No saved position found, centering initial panel.")
            self.center()
            if let screen = NSScreen.main {
                 let screenFrame = screen.visibleFrame
                 let yPosition = screenFrame.maxY - self.frame.height - (screenFrame.height * 0.15)
                 self.setFrameOrigin(NSPoint(x: self.frame.origin.x, y: yPosition))
            }
        } else {
            logger.debug("Restored initial panel position from UserDefaults.")
        }
    }
    
    // calculateInitialFrame remains the same (uses shouldOpenExpanded)
    private static func calculateInitialFrame(shouldOpenExpanded: Bool, collapsedHeight: CGFloat, defaultExpandedHeight: CGFloat, minWidth: CGFloat) -> NSRect {
        let defaults = UserDefaults.standard
        let savedX = defaults.double(forKey: UserDefaultsKeys.quickAccessPanelX)
        let savedY = defaults.double(forKey: UserDefaultsKeys.quickAccessPanelY)
        var width: CGFloat
        var height: CGFloat

        if shouldOpenExpanded {
            let savedWidth = defaults.double(forKey: UserDefaultsKeys.quickAccessPanelWidth)
            let savedHeight = defaults.double(forKey: UserDefaultsKeys.quickAccessPanelHeight)
            width = max(savedWidth > 0 ? savedWidth : minWidth, minWidth)
            height = max(savedHeight > 0 ? savedHeight : defaultExpandedHeight, defaultExpandedHeight)
            os_log(.debug, log: OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "QuickAccessPanelView"), "Calculating initial frame: Should open expanded. Using W: %f, H: %f", width, height)
        } else {
            width = minWidth
            height = collapsedHeight
            os_log(.debug, log: OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "QuickAccessPanelView"), "Calculating initial frame: Should open collapsed. Using W: %f, H: %f", width, height)
        }

        if defaults.object(forKey: UserDefaultsKeys.quickAccessPanelX) != nil {
             os_log(.debug, log: OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "QuickAccessPanelView"), "Using saved position X: %f, Y: %f", savedX, savedY)
             return NSRect(x: savedX, y: savedY, width: width, height: height)
        } else {
             os_log(.debug, log: OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "QuickAccessPanelView"), "No saved position found. Initial frame at 0,0.")
             return NSRect(x: 0, y: 0, width: width, height: height)
        }
    }

    // resizePanelProgrammatically remains the same
    func resizePanelProgrammatically(newHeight: CGFloat) {
        guard let screen = NSScreen.main else { return }
        let defaults = UserDefaults.standard
        let currentFrame = self.frame
        var targetWidth: CGFloat
        var targetX = currentFrame.origin.x
        var targetY = currentFrame.origin.y
        var heightToSet: CGFloat
        
        if newHeight > collapsedHeight { // Expanding
            logger.debug("Panel expanding programmatically.")
            heightToSet = newHeight
            
            if defaults.object(forKey: UserDefaultsKeys.quickAccessPanelWidth) != nil {
                let savedWidth = defaults.double(forKey: UserDefaultsKeys.quickAccessPanelWidth)
                let savedHeight = defaults.double(forKey: UserDefaultsKeys.quickAccessPanelHeight)
                let savedX = defaults.double(forKey: UserDefaultsKeys.quickAccessPanelX)
                let savedY = defaults.double(forKey: UserDefaultsKeys.quickAccessPanelY)

                targetWidth = max(savedWidth, initialMinWidth)
                heightToSet = max(newHeight, max(savedHeight, defaultExpandedHeight))
                targetX = savedX
                targetY = savedY
                logger.info("Restoring saved frame: W:\(targetWidth), H:\(heightToSet), X:\(targetX), Y:\(targetY)")
            } else {
                logger.info("No saved frame found. Expanding to default size.")
                targetWidth = max(currentFrame.width, initialMinWidth)
                heightToSet = max(newHeight, defaultExpandedHeight)
                targetX = screen.visibleFrame.origin.x + (screen.visibleFrame.width - targetWidth) / 2
                targetY = currentFrame.origin.y + (currentFrame.height - heightToSet)
            }
            if !styleMask.contains(.resizable) { styleMask.insert(.resizable) }
        } else { // Collapsing
             logger.debug("Panel collapsing programmatically.")
             targetWidth = max(currentFrame.width, initialMinWidth)
             heightToSet = collapsedHeight
             targetX = screen.visibleFrame.origin.x + (screen.visibleFrame.width - targetWidth) / 2
             targetY = currentFrame.origin.y + (currentFrame.height - heightToSet)
             if styleMask.contains(.resizable) { styleMask.remove(.resizable) }
        }

        var finalFrame = NSRect(x: targetX, y: targetY, width: targetWidth, height: heightToSet)
        finalFrame = ensureFrameIsOnScreen(frame: finalFrame, screen: screen)

        isProgrammaticallyResizing = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().setFrame(finalFrame, display: true)
        }, completionHandler: { [weak self] in
             DispatchQueue.main.async {
                 self?.isProgrammaticallyResizing = false
             }
             if newHeight > self?.collapsedHeight ?? 0 && defaults.object(forKey: UserDefaultsKeys.quickAccessPanelWidth) == nil {
                 self?.logger.debug("Saving initial expanded frame after animation.")
                 self?.saveFrameToUserDefaults(frame: finalFrame)
             }
        })
    }
    
    // ensureFrameIsOnScreen remains the same
    private func ensureFrameIsOnScreen(frame: NSRect, screen: NSScreen) -> NSRect {
        let screenFrame = screen.visibleFrame
        var adjustedFrame = frame
        
        adjustedFrame.size.width = max(adjustedFrame.width, initialMinWidth)
        if adjustedFrame.maxX > screenFrame.maxX {
            adjustedFrame.origin.x = screenFrame.maxX - adjustedFrame.width
        }
        if adjustedFrame.minX < screenFrame.minX {
            adjustedFrame.origin.x = screenFrame.minX
        }
        
        adjustedFrame.size.height = max(adjustedFrame.height, collapsedHeight)
        if adjustedFrame.maxY > screenFrame.maxY {
            adjustedFrame.origin.y = screenFrame.maxY - adjustedFrame.height
        }
        if adjustedFrame.minY < screenFrame.minY {
            adjustedFrame.origin.y = screenFrame.minY
        }

        return adjustedFrame
    }

    // NSWindowDelegate Methods remain the same
    func windowDidResize(_ notification: Notification) {
        if !isProgrammaticallyResizing && self.frame.height > collapsedHeight && frameBeforeZoom == nil {
            logger.debug("Window resized by user (or non-programmatic). Saving frame.")
            saveFrameToUserDefaults(frame: self.frame)
        } else if isProgrammaticallyResizing {
             logger.trace("Ignoring save during programmatic resize.")
        } else if frameBeforeZoom != nil {
             logger.trace("Ignoring save while zoomed.")
        } else {
             logger.trace("Ignoring save while collapsed.")
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
         if self.frame.height > collapsedHeight && frameBeforeZoom == nil {
             logger.debug("Window finished live resize. Saving frame.")
             saveFrameToUserDefaults(frame: self.frame)
         }
    }
    
    func windowDidMove(_ notification: Notification) {
        if self.frame.height > collapsedHeight && frameBeforeZoom == nil {
             logger.trace("Window moved. Saving frame.")
             saveFrameToUserDefaults(frame: self.frame)
        }
    }
    
    func windowWillClose(_ notification: Notification) {
        logger.info("Window will close. Saving state for potential resume.")
        let defaults = UserDefaults.standard
        let currentTime = Date().timeIntervalSince1970
        let wasExpanded = self.frame.height > self.collapsedHeight && self.frameBeforeZoom == nil
        
        defaults.set(currentTime, forKey: SettingsKeys.quickAccessLastCloseTime)
        defaults.set(wasExpanded, forKey: SettingsKeys.quickAccessWasExpandedOnClose)
        
        logger.debug("Saved lastCloseTime: \(currentTime), wasExpanded: \(wasExpanded)")
        
        if wasExpanded {
            saveFrameToUserDefaults(frame: self.frame)
        }
    }

    // saveFrameToUserDefaults remains the same
    private func saveFrameToUserDefaults(frame: NSRect) {
        guard frameBeforeZoom == nil else {
             logger.warning("Attempted to save frame while zoomed. Aborting save.")
             return
        }
        let defaults = UserDefaults.standard
        defaults.set(frame.origin.x, forKey: UserDefaultsKeys.quickAccessPanelX)
        defaults.set(frame.origin.y, forKey: UserDefaultsKeys.quickAccessPanelY)
        
        if frame.height > collapsedHeight {
            defaults.set(frame.size.width, forKey: UserDefaultsKeys.quickAccessPanelWidth)
            defaults.set(frame.size.height, forKey: UserDefaultsKeys.quickAccessPanelHeight)
            logger.info("Saved panel frame (Expanded) to UserDefaults: \(String(describing: frame))")
        } else {
             logger.info("Saved panel position (Collapsed) to UserDefaults: X:\(frame.origin.x), Y:\(frame.origin.y)")
        }
    }

    // Zoom Logic remains the same
    public func toggleZoomState() {
        guard let screen = self.screen ?? NSScreen.main else { return }
        let screenVisibleFrame = screen.visibleFrame

        isProgrammaticallyResizing = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            if let previousFrame = self.frameBeforeZoom {
                logger.info("Zooming out to previous frame.")
                self.animator().setFrame(previousFrame, display: true)
                self.frameBeforeZoom = nil
                if !self.styleMask.contains(.resizable) && previousFrame.height > self.collapsedHeight {
                     self.styleMask.insert(.resizable)
                }
            } else {
                logger.info("Zooming in to full screen.")
                self.frameBeforeZoom = self.frame
                self.animator().setFrame(screenVisibleFrame, display: true)
                if !self.styleMask.contains(.resizable) {
                    self.styleMask.insert(.resizable)
                }
            }
        }, completionHandler: { [weak self] in
             DispatchQueue.main.async {
                 self?.isProgrammaticallyResizing = false
             }
        })
    }

    // Close Logic remains the same
    func closePanel() {
        frameBeforeZoom = nil
        self.close()
    }

    // Window Behavior Overrides remain the same
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }
}
