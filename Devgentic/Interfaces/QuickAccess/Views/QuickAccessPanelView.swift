//
//  QuickAccessPanelView.swift
//  Devgentic
//
//  Created by Raj Singh on 07/05/25.
//

import AppKit
import SwiftUI
import os

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
    private let logger = DGLogger(category: "QuickAccessPanelView")

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
        self.forceExpandVisual = forceExpandVisual
        logger.info("Initializing QuickAccessPanelView. ShouldResumeSession: \(shouldResumeSession), ForceExpandVisual: \(forceExpandVisual)")
        
        // --- FIX: Call a static helper function to determine initial state ---
        // This avoids calling an instance method before super.init()
        let shouldOpenExpanded = QuickAccessPanelView.determineInitialExpandedState(
            shouldResumeSession: shouldResumeSession,
            forceExpandVisual: forceExpandVisual
        )
        // -------------------------------------------------------------------
        
        logger.debug("Determined final initial state: shouldOpenExpanded=\(shouldOpenExpanded)")

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
        }
        
        setupWindow()
        setupContentView(initialIsExpanded: shouldOpenExpanded)
        
        self.delegate = self
        logger.info("QuickAccessPanelView initialized and delegate set.")
    }

    /// Determines if the panel should open in an expanded state.
    /// This is a static function so it can be called safely from within `init` before `super.init`.
    private static func determineInitialExpandedState(shouldResumeSession: Bool, forceExpandVisual: Bool) -> Bool {
        let logger = DGLogger(category: "QuickAccessPanelView.Init")
        
        let defaults = UserDefaults.standard
        let wasExpandedOnClose = defaults.bool(forKey: GlobalConstants.quickAccessWasExpandedOnClose)
        
        // TODO: Re-enable with SwiftData ChatPersistenceStore when QuickAccess is enhanced
        func qaConversationHasMessages() -> Bool {
            if let qaIdString = defaults.string(forKey: GlobalConstants.quickAccessOverlayConversationId),
               let qaId = UUID(uuidString: qaIdString),
               let conversation = ChatPersistenceStore.shared.getConversation(withId: qaId) {
                return !conversation.messages.isEmpty
            }
            return false
        }

        if forceExpandVisual {
            logger.debug("ForceExpandVisual is true. Checking conversation content...")
            return qaConversationHasMessages()
        } else if shouldResumeSession && wasExpandedOnClose {
            logger.debug("Session resumable and was expanded. Checking conversation content...")
            return qaConversationHasMessages()
        } else {
            logger.debug("Session not resumable, wasn't expanded, or not forcing expand. Opening collapsed.")
            return false
        }
    }

    // TODO: Re-enable with SwiftData ChatPersistenceStore when QuickAccess is enhanced
    private func getOrCreateQuickAccessConversation() -> ConversationSD? {
        let defaults = UserDefaults.standard
        let persistenceService = ChatPersistenceStore.shared
        let quickAccessKey = GlobalConstants.quickAccessOverlayConversationId

        if let qaIdString = defaults.string(forKey: quickAccessKey),
           let qaId = UUID(uuidString: qaIdString),
           let found = persistenceService.getConversation(withId: qaId) {
            return found
        }

        logger.info("No valid Quick Access conversation found. Creating a new one.")
        let newConversation = Conversation(id: UUID(), messages: [], timestamp: Date(), userDefinedTitle: "Quick Access Chat", isPinned: false)
        persistenceService.addConversation(from: newConversation)
        defaults.set(newConversation.id.uuidString, forKey: quickAccessKey)
        return persistenceService.getConversation(withId: newConversation.id)
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

    // setupContentView remains the same
    private func setupContentView(initialIsExpanded: Bool) {
        logger.debug("Setting up ContentView with initialIsExpanded: \(initialIsExpanded)")
        let swiftUIContentView = QuickAccessContentView(
            dismiss: { [weak self] in self?.closePanel() },
            onResize: { [weak self] newHeight in self?.resizePanelProgrammatically(newHeight: newHeight) },
            onToggleZoom: { [weak self] in self?.toggleZoomState() },
            isExpanded: initialIsExpanded
        )

        let hostingView = NSHostingView(rootView: swiftUIContentView)
        self.hostingView = hostingView
        self.contentView = hostingView
        
        self.setContentSize(self.frame.size)
        
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
    
    // calculateInitialFrame remains the same
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
        } else {
            width = minWidth
            height = collapsedHeight
        }

        if defaults.object(forKey: UserDefaultsKeys.quickAccessPanelX) != nil {
             return NSRect(x: savedX, y: savedY, width: width, height: height)
        } else {
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
            } else {
                targetWidth = max(currentFrame.width, initialMinWidth)
                heightToSet = max(newHeight, defaultExpandedHeight)
                targetX = screen.visibleFrame.origin.x + (screen.visibleFrame.width - targetWidth) / 2
                targetY = currentFrame.origin.y + (currentFrame.height - heightToSet)
            }
            if !styleMask.contains(.resizable) { styleMask.insert(.resizable) }
        } else { // Collapsing
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
            self.animator().setFrame(finalFrame, display: true)
        }, completionHandler: { [weak self] in
             self?.isProgrammaticallyResizing = false
             if newHeight > self?.collapsedHeight ?? 0 && defaults.object(forKey: UserDefaultsKeys.quickAccessPanelWidth) == nil {
                 self?.saveFrameToUserDefaults(frame: finalFrame)
             }
        })
    }
    
    // ensureFrameIsOnScreen remains the same
    private func ensureFrameIsOnScreen(frame: NSRect, screen: NSScreen) -> NSRect {
        var adjustedFrame = frame
        
        adjustedFrame.size.width = max(adjustedFrame.width, initialMinWidth)
        if adjustedFrame.maxX > screen.visibleFrame.maxX {
            adjustedFrame.origin.x = screen.visibleFrame.maxX - adjustedFrame.width
        }
        if adjustedFrame.minX < screen.visibleFrame.minX {
            adjustedFrame.origin.x = screen.visibleFrame.minX
        }
        
        adjustedFrame.size.height = max(adjustedFrame.height, collapsedHeight)
        if adjustedFrame.maxY > screen.visibleFrame.maxY {
            adjustedFrame.origin.y = screen.visibleFrame.maxY - adjustedFrame.height
        }
        if adjustedFrame.minY < screen.visibleFrame.minY {
            adjustedFrame.origin.y = screen.visibleFrame.minY
        }

        return adjustedFrame
    }

    // NSWindowDelegate Methods remain the same
    func windowDidResize(_ notification: Notification) {
        if !isProgrammaticallyResizing && self.frame.height > collapsedHeight && frameBeforeZoom == nil {
            saveFrameToUserDefaults(frame: self.frame)
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
         if self.frame.height > collapsedHeight && frameBeforeZoom == nil {
             saveFrameToUserDefaults(frame: self.frame)
         }
    }
    
    func windowDidMove(_ notification: Notification) {
        if self.frame.height > collapsedHeight && frameBeforeZoom == nil {
             saveFrameToUserDefaults(frame: self.frame)
        }
    }
    
    func windowWillClose(_ notification: Notification) {
        let defaults = UserDefaults.standard
        let wasExpanded = self.frame.height > self.collapsedHeight && self.frameBeforeZoom == nil
        
        defaults.set(Date().timeIntervalSince1970, forKey: GlobalConstants.quickAccessLastCloseTime)
        defaults.set(wasExpanded, forKey: GlobalConstants.quickAccessWasExpandedOnClose)
        
        if wasExpanded {
            saveFrameToUserDefaults(frame: self.frame)
        }
    }

    // saveFrameToUserDefaults remains the same
    private func saveFrameToUserDefaults(frame: NSRect) {
        guard frameBeforeZoom == nil else { return }
        let defaults = UserDefaults.standard
        defaults.set(frame.origin.x, forKey: UserDefaultsKeys.quickAccessPanelX)
        defaults.set(frame.origin.y, forKey: UserDefaultsKeys.quickAccessPanelY)
        
        if frame.height > collapsedHeight {
            defaults.set(frame.size.width, forKey: UserDefaultsKeys.quickAccessPanelWidth)
            defaults.set(frame.size.height, forKey: UserDefaultsKeys.quickAccessPanelHeight)
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
                self.animator().setFrame(previousFrame, display: true)
                self.frameBeforeZoom = nil
                if !self.styleMask.contains(.resizable) && previousFrame.height > self.collapsedHeight {
                     self.styleMask.insert(.resizable)
                }
            } else {
                self.frameBeforeZoom = self.frame
                self.animator().setFrame(screenVisibleFrame, display: true)
                if !self.styleMask.contains(.resizable) {
                    self.styleMask.insert(.resizable)
                }
            }
        }, completionHandler: { [weak self] in
             self?.isProgrammaticallyResizing = false
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

