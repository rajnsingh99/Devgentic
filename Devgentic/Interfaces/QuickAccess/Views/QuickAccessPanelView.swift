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

/// [M9] A keyboard action the panel routes to a pending in-panel HITL request (the content view
/// registers a handler that maps these onto the shared answer path). `confirm` = ⌘Return,
/// `cancel` = Escape.
enum QuickAccessHITLKeyAction { case cancel, confirm }

// Make the class conform to NSWindowDelegate
class QuickAccessPanelView: NSPanel, NSWindowDelegate {

    private var hostingView: NSHostingView<QuickAccessContentView>?
    private let logger = DGLogger(category: "QuickAccessPanelView")

    /// Invoked from `windowWillClose` so the owner (AppDelegate) can drop its strong
    /// reference on every close path (Escape / close button / hotkey toggle / replace).
    /// [QA revival P0]
    var onPanelWillClose: (() -> Void)?

    /// [M9] Set by the hosted content view: routes ⌘Return / Escape to a pending in-panel HITL
    /// request. Returns true if it consumed the key (a request was pending and answered).
    private var hitlKeyHandler: ((QuickAccessHITLKeyAction) -> Bool)?

    let collapsedHeight: CGFloat = 95
    let initialMinWidth: CGFloat = 500
    let defaultExpandedHeight: CGFloat = 400 // Default height when expanding for the first time

    private let baseStyleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
    
    private var frameBeforeZoom: NSRect?
    private var isProgrammaticallyResizing = false
    
    private let shouldResumeSession: Bool
    private let forceExpandVisual: Bool

    // [QA revival P1a] Shared graph threaded in from AppDelegate → QuickAccessContentView,
    // which builds its QuickAccessSessionViewModel from it. Set before super.init so
    // setupContentView can hand them to the SwiftUI root.
    private let mainAppViewModel: MainApplicationViewModel
    private let themeManager: ThemeManager

    init(shouldResumeSession: Bool, forceExpandVisual: Bool,
         mainAppViewModel: MainApplicationViewModel, themeManager: ThemeManager) {
        self.shouldResumeSession = shouldResumeSession
        self.forceExpandVisual = forceExpandVisual
        self.mainAppViewModel = mainAppViewModel
        self.themeManager = themeManager
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

    // setupWindow remains the same
    private func setupWindow() {
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        // [drag-vs-select fix] Do NOT use isMovableByWindowBackground — it makes AppKit treat a
        // drag ANYWHERE (including over the input field) as a window move, stealing text selection.
        // The panel is instead moved by an explicit drag surface behind the content
        // (QuickAccessContentView.WindowDragArea), which sits in front of the glass but behind the
        // controls, so empty/chrome areas drag while the text field keeps its own selection.
        isMovableByWindowBackground = false
        isMovable = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // [QA revival P0] Float over the user's current app. NSPanel defaults
        // hidesOnDeactivate=true, which orderOut()s the panel the instant the user
        // clicks another app — defeating the whole quick-entry-over-your-work premise
        // (and firing a hide, not windowWillClose, so session keys never get stamped).
        // Keep it visible until an explicit dismissal (Escape / close button / hotkey).
        hidesOnDeactivate = false
        // [QA revival P0] AppDelegate keeps a strong `contentWindow` reference; NSPanel's
        // default isReleasedWhenClosed=true would double-release on close (AppKit release
        // + ARC). Matches SimplePromptWindowManager / AdvancedPromptEditor.
        isReleasedWhenClosed = false
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
            onContinueInMainWindow: { [weak self] convID in self?.continueInMainWindow(convID) },
            isExpanded: initialIsExpanded,
            // [QA revival P1e] A transfer (forceExpandVisual) must ALWAYS load the conversation
            // the main window just handed over — even if the panel's own session had timed out.
            shouldResumeSession: shouldResumeSession || forceExpandVisual,
            mainAppViewModel: mainAppViewModel,
            themeManager: themeManager,
            // [M9] Let the content view register how ⌘Return / Escape answer a pending HITL.
            onRegisterHITLKeyHandler: { [weak self] handler in self?.hitlKeyHandler = handler }
        )

        let hostingView = NSHostingView(rootView: swiftUIContentView)
        self.hostingView = hostingView
        self.contentView = hostingView

        // [H3] Pin the panel's appearance to the app theme so the Liquid Glass backdrop renders
        // in the theme's light/dark mode — otherwise a dark-theme user on a Light-Mode Mac gets
        // light glass under the (theme-token) chrome and the input text washes out. A theme with
        // no scheme preference (nil) follows the system, which is the intended behavior there.
        if let scheme = themeManager.currentTheme.colorScheme {
            self.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        } else {
            self.appearance = nil
        }

        self.setContentSize(self.frame.size)
        
        if UserDefaults.standard.object(forKey: UserDefaultsKeys.quickAccessPanelX) == nil {
            logger.debug("No saved position found; placing on the active screen.")
            // [L9] Place on the screen under the pointer (where the user is working), not always
            // NSScreen.main — on a multi-display setup the panel would otherwise pop on the wrong
            // display.
            if let screen = QuickAccessPanelView.activeScreen() {
                let screenFrame = screen.visibleFrame
                let xPosition = screenFrame.midX - self.frame.width / 2
                let yPosition = screenFrame.maxY - self.frame.height - (screenFrame.height * 0.15)
                self.setFrameOrigin(NSPoint(x: xPosition, y: yPosition))
            } else {
                self.center()
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

    /// [L9] The screen the user is currently working on — the one under the pointer — falling back
    /// to the key window's screen, then the main screen.
    static func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSApp.keyWindow?.screen
            ?? NSScreen.main
    }

    // resizePanelProgrammatically remains the same
    func resizePanelProgrammatically(newHeight: CGFloat) {
        // [L9] Operate on the panel's current screen (multi-display), not always NSScreen.main.
        guard let screen = self.screen ?? Self.activeScreen() else { return }
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

        // [QA revival P0] Let the owner drop its strong reference so the next summon
        // builds a fresh panel instead of dereferencing a closed one.
        onPanelWillClose?()
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
        // [two-panel fix] orderOut BEFORE close — a bare close() can leave a non-activating
        // floating panel on screen (so Escape/close-button/handoff appear to "not close" it, and a
        // subsequent open stacks a second panel). Matches AppDelegate.closeContentWindow.
        self.orderOut(nil)
        self.close()
    }

    // [QA revival P2e] Hand this conversation to the main window: release panel ownership (so
    // the next panel open starts fresh — mirrors the forward transfer clearing main selection),
    // post the navigate notification (observed in MainApplicationView), bring the main window
    // forward, and close the panel.
    func continueInMainWindow(_ conversationID: UUID) {
        // [C8] Only complete the handoff if there's a main window to receive it. The
        // openConversationNotification observer lives in MainApplicationView, so with the main
        // window closed the post drops the conversation — and clearing the pointer FIRST (the
        // old order) would orphan it. Activate first; bail (keeping the panel + pointer) if none.
        guard AppDelegate.shared?.activateMainWindow() == true else {
            logger.warning("Continue-in-main-window aborted — no main window to receive the handoff; keeping the panel conversation intact.")
            return
        }
        NotificationCenter.default.post(
            name: GlobalConstants.openConversationNotification,
            object: nil,
            userInfo: ["conversationID": conversationID.uuidString]
        )
        UserDefaults.standard.removeObject(forKey: GlobalConstants.quickAccessOverlayConversationId)
        closePanel()
    }

    // Window Behavior Overrides remain the same
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }

    // [QA revival P0] Escape dismisses the panel. In collapsed mode there is no visible
    // close button, and with hidesOnDeactivate=false a click outside no longer hides it,
    // so Escape is the primary keyboard dismissal (matches Spotlight-style entry panels).
    override func cancelOperation(_ sender: Any?) {
        // [M9] If a HITL request is pending in the panel, Escape answers it (deny/cancel) rather
        // than dismissing the panel and leaving the run parked invisibly (only the menu-bar badge
        // would hint at it). Falls through to close only when nothing is pending.
        if hitlKeyHandler?(.cancel) == true { return }
        closePanel()
    }

    // [QA revival P0] The panel is a .nonactivatingPanel and AppDelegate intentionally
    // does not NSApp.activate on show, so the app's main-menu key equivalents are not
    // dispatched while the app is inactive. Route the standard editing commands to the
    // panel's first responder so Cut/Copy/Paste/Select-All/Undo/Redo work in the field.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.modifierFlags.contains(.command) {
            // [M9] ⌘Return confirms a pending in-panel HITL (approve tool / approve plan) without
            // colliding with the input field's plain-Return submit.
            if event.charactersIgnoringModifiers == "\r", hitlKeyHandler?(.confirm) == true {
                return true
            }
            // [L8] ⌘W closes the panel and ⌘Q quits the app. The app is inactive (non-activating
            // panel), so these standard menu key-equivalents don't dispatch on their own — without
            // this, they silently do nothing while the panel is key.
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "w": closePanel(); return true
            case "q": NSApp.terminate(nil); return true
            default: break
            }
            let selector: Selector?
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "x": selector = #selector(NSText.cut(_:))
            case "c": selector = #selector(NSText.copy(_:))
            case "v": selector = #selector(NSText.paste(_:))
            case "a": selector = #selector(NSResponder.selectAll(_:))
            case "z": selector = event.modifierFlags.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
            default: selector = nil
            }
            if let selector, NSApp.sendAction(selector, to: nil, from: self) {
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

