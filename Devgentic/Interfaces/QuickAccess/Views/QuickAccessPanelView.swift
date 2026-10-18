// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  QuickAccessPanelView.swift
//  Devgentic
//
//  Created by Raj Singh.
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
    /// [sa-5] The identity this panel's transcript registers as a speech-transport host under —
    /// shared with `QuickAccessContentView` so `windowWillClose` can deregister the same host.
    let transportHostID = UUID()
    private let logger = DGLogger(category: "QuickAccessPanelView")

    /// Invoked from `windowWillClose` so the owner (AppDelegate) can drop its strong reference on every close path.
    var onPanelWillClose: (() -> Void)?

    /// [M9] Set by the hosted content view: routes ⌘Return / Escape to a pending in-panel HITL
    /// request. Returns true if it consumed the key (a request was pending and answered).
    private var hitlKeyHandler: ((QuickAccessHITLKeyAction) -> Bool)?

    let collapsedHeight: CGFloat = 88 // floor below the full-bleed card's ~90pt natural height
    let initialMinWidth: CGFloat = 500
    let defaultExpandedHeight: CGFloat = 400 // Default height when expanding for the first time

    private let baseStyleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
    
    private var frameBeforeZoom: NSRect?
    private var isProgrammaticallyResizing = false

    /// Whether the panel is in the expanded state (top bar + transcript visible), set from the content view's explicit
    /// resize intent, not inferred from frame height, since a collapsed card can grow.
    private var isExpandedState: Bool
    
    private let shouldResumeSession: Bool
    private let forceExpandVisual: Bool

    // Shared graph threaded in from AppDelegate to QuickAccessContentView, which builds its session view model from it; set
    // before `super.init` so `setupContentView` can hand it to the SwiftUI root.
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
        self.isExpandedState = shouldOpenExpanded
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
        // Do not use `isMovableByWindowBackground`: a drag anywhere, even over the input field, would move the window and steal
        // text selection. The panel moves via the drag surface behind the content (`QuickAccessContentView.WindowDragArea`).
        isMovableByWindowBackground = false
        isMovable = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // Float over the user's current app: NSPanel's default `hidesOnDeactivate` would hide the panel when another app is
        // clicked; keep it visible until an explicit dismissal (Escape / close button / hotkey).
        hidesOnDeactivate = false
        // AppDelegate keeps a strong `contentWindow` reference, so NSPanel's default `isReleasedWhenClosed = true` would
        // double-release on close.
        isReleasedWhenClosed = false
        self.minSize = NSSize(width: initialMinWidth, height: collapsedHeight)
        self.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    }

    // setupContentView remains the same
    private func setupContentView(initialIsExpanded: Bool) {
        logger.debug("Setting up ContentView with initialIsExpanded: \(initialIsExpanded)")
        let swiftUIContentView = QuickAccessContentView(
            dismiss: { [weak self] in self?.closePanel() },
            // [Unified card] Explicit intent: the view says WHICH state it wants alongside the
            // height, so a grown collapsed card is never misread as an expand request.
            onResize: { [weak self] newHeight, expanded in
                self?.resizePanelProgrammatically(newHeight: newHeight, expanded: expanded)
            },
            onToggleZoom: { [weak self] in self?.toggleZoomState() },
            onContinueInMainWindow: { [weak self] convID in self?.continueInMainWindow(convID) },
            onOpenProfileSettings: { [weak self] profileID in self?.openProfileSettings(profileID) },
            isExpanded: initialIsExpanded,
            // [QA revival P1e] A transfer (forceExpandVisual) must ALWAYS load the conversation
            // the main window just handed over — even if the panel's own session had timed out.
            shouldResumeSession: shouldResumeSession || forceExpandVisual,
            mainAppViewModel: mainAppViewModel,
            themeManager: themeManager,
            // [M9] Let the content view register how ⌘Return / Escape answer a pending HITL.
            onRegisterHITLKeyHandler: { [weak self] handler in self?.hitlKeyHandler = handler },
            transportHostID: transportHostID
        )

        let hostingView = NSHostingView(rootView: swiftUIContentView)
        self.hostingView = hostingView
        self.contentView = hostingView

        // Pin the panel's appearance to the app theme so the Liquid Glass backdrop matches the theme's light/dark mode; a theme
        // with no scheme preference follows the system.
        if let scheme = themeManager.currentTheme.colorScheme {
            self.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        } else {
            self.appearance = nil
        }

        self.setContentSize(self.frame.size)

        // Every summon presents at the standard spot (horizontally centered, bottom edge 30% above the screen bottom) on the
        // screen under the pointer; saved X/Y is not consumed, while the expanded W/H size memory remains.
        if let screen = QuickAccessPanelView.activeScreen() {
            self.setFrameOrigin(standardOrigin(for: self.frame.size, on: screen))
        } else {
            self.center()
        }
    }

    /// [Fixed position] The panel's standard on-screen spot: horizontally centered, bottom edge
    /// at 30% of the visible screen height. Used on every summon and on expand/collapse
    /// transitions; a mid-session drag persists only until the next transition or summon.
    private func standardOrigin(for size: NSSize, on screen: NSScreen) -> NSPoint {
        let visible = screen.visibleFrame
        return NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + visible.height * 0.30
        )
    }
    
    /// Size only: the position is always stamped by `setupContentView` via `standardOrigin`; the expanded W/H size memory is
    /// kept.
    private static func calculateInitialFrame(shouldOpenExpanded: Bool, collapsedHeight: CGFloat, defaultExpandedHeight: CGFloat, minWidth: CGFloat) -> NSRect {
        let defaults = UserDefaults.standard
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

        return NSRect(x: 0, y: 0, width: width, height: height)
    }

    /// [L9] The screen the user is currently working on — the one under the pointer — falling back
    /// to the key window's screen, then the main screen.
    static func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSApp.keyWindow?.screen
            ?? NSScreen.main
    }

    /// `expanded` is the view's explicit state intent, not inferred from `newHeight > collapsedHeight`, since a tall
    /// collapsed card would otherwise jump to the saved expanded frame.
    func resizePanelProgrammatically(newHeight: CGFloat, expanded: Bool) {
        // [L9] Operate on the panel's current screen (multi-display), not always NSScreen.main.
        guard let screen = self.screen ?? Self.activeScreen() else { return }
        let defaults = UserDefaults.standard
        let currentFrame = self.frame
        var targetWidth: CGFloat
        var targetX = currentFrame.origin.x
        var targetY = currentFrame.origin.y
        var heightToSet: CGFloat

        let wasExpanded = isExpandedState
        isExpandedState = expanded

        if expanded {
            // Size memory kept (user-resized W/H); position is always the standard spot.
            if defaults.object(forKey: UserDefaultsKeys.quickAccessPanelWidth) != nil {
                let savedWidth = defaults.double(forKey: UserDefaultsKeys.quickAccessPanelWidth)
                let savedHeight = defaults.double(forKey: UserDefaultsKeys.quickAccessPanelHeight)
                targetWidth = max(savedWidth, initialMinWidth)
                heightToSet = max(newHeight, max(savedHeight, defaultExpandedHeight))
            } else {
                targetWidth = max(currentFrame.width, initialMinWidth)
                heightToSet = max(newHeight, defaultExpandedHeight)
            }
            // [Fixed position] Expand presents at the standard spot (centered, bottom at 30%).
            let origin = standardOrigin(for: NSSize(width: targetWidth, height: heightToSet), on: screen)
            targetX = origin.x
            targetY = origin.y
            if !styleMask.contains(.resizable) { styleMask.insert(.resizable) }
        } else {
            // Collapsed: height follows the input card (it grows with multi-line text / chips).
            targetWidth = max(currentFrame.width, initialMinWidth)
            heightToSet = max(newHeight, collapsedHeight)
            if wasExpanded {
                // [Fixed position] Explicit expand→collapse returns to the standard spot.
                let origin = standardOrigin(for: NSSize(width: targetWidth, height: heightToSet), on: screen)
                targetX = origin.x
                targetY = origin.y
            }
            // else: content-driven growth — origin.y unchanged = bottom edge anchored (the card
            // grows UPWARD from the 30% line) and no sideways recentering on a keystroke.
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
             if expanded && defaults.object(forKey: UserDefaultsKeys.quickAccessPanelWidth) == nil {
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

    // NSWindowDelegate Methods — [Unified card] expanded checks use the explicit state flag,
    // not frame-height inference (a grown collapsed card is taller than collapsedHeight).
    func windowDidResize(_ notification: Notification) {
        if !isProgrammaticallyResizing && isExpandedState && frameBeforeZoom == nil {
            saveFrameToUserDefaults(frame: self.frame)
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
         if isExpandedState && frameBeforeZoom == nil {
             saveFrameToUserDefaults(frame: self.frame)
         }
    }

    func windowDidMove(_ notification: Notification) {
        if isExpandedState && frameBeforeZoom == nil {
             saveFrameToUserDefaults(frame: self.frame)
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Deregister this panel's transcript as a speech-transport host on the AppKit close route too (its `.onDisappear` uses
        // the same id), so a close that does not deliver `onDisappear` cannot leave the reader speaking with no Stop on screen.
        SpeechService.shared.transportHostDidDisappear(transportHostID)
        let defaults = UserDefaults.standard
        let wasExpanded = isExpandedState && self.frameBeforeZoom == nil
        
        defaults.set(Date().timeIntervalSince1970, forKey: GlobalConstants.quickAccessLastCloseTime)
        defaults.set(wasExpanded, forKey: GlobalConstants.quickAccessWasExpandedOnClose)
        
        if wasExpanded {
            saveFrameToUserDefaults(frame: self.frame)
        }

        // Let the owner drop its strong reference so the next summon builds a fresh panel instead of dereferencing a closed
        // one.
        onPanelWillClose?()
    }

    // saveFrameToUserDefaults remains the same
    private func saveFrameToUserDefaults(frame: NSRect) {
        guard frameBeforeZoom == nil else { return }
        let defaults = UserDefaults.standard
        defaults.set(frame.origin.x, forKey: UserDefaultsKeys.quickAccessPanelX)
        defaults.set(frame.origin.y, forKey: UserDefaultsKeys.quickAccessPanelY)
        
        if isExpandedState { // [Unified card] explicit state, not height inference
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
                if !self.styleMask.contains(.resizable) && self.isExpandedState {
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
        // `orderOut` before `close`: a bare `close()` can leave a non-activating floating panel on screen and let a later open
        // stack a second one. Matches `AppDelegate.closeContentWindow`.
        self.orderOut(nil)
        self.close()
    }

    // Settings deep-link from the advisory banner: activate the main window and open the profile editor. The conversation
    // does not transfer, so a later summon resumes the panel session; the panel closes so it does not cover the settings.
    func openProfileSettings(_ profileID: UUID) {
        guard AppDelegate.shared?.activateMainWindow() == true else {
            logger.warning("Open-profile-settings aborted — no main window to receive the navigation; keeping the panel open.")
            return
        }
        NotificationCenter.default.post(
            name: GlobalConstants.openProfileSettingsNotification,
            object: nil,
            userInfo: ["profileID": profileID.uuidString]
        )
        closePanel()
    }

    func continueInMainWindow(_ conversationID: UUID) {
        // Complete the handoff only if a main window can receive it (the observer lives in MainApplicationView): activate first
        // and bail, keeping the panel and pointer, if none; clearing the pointer first would orphan the conversation.
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

    // Escape dismisses the panel: collapsed mode has no visible close button and a click outside does not hide it.
    override func cancelOperation(_ sender: Any?) {
        // If a HITL request is pending in the panel, Escape answers it (deny/cancel) rather than dismissing and leaving the run
        // parked invisibly; it falls through to close only when nothing is pending.
        if hitlKeyHandler?(.cancel) == true { return }
        closePanel()
    }

    // The panel is non-activating, so main-menu key equivalents do not dispatch while the app is inactive; route the
    // standard editing commands to the panel's first responder so Cut/Copy/Paste/Select-All/Undo/Redo work.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.modifierFlags.contains(.command) {
            // [M9] ⌘Return confirms a pending in-panel HITL (approve tool / approve plan) without
            // colliding with the input field's plain-Return submit.
            if event.charactersIgnoringModifiers == "\r", hitlKeyHandler?(.confirm) == true {
                return true
            }
            // Cmd-W closes the panel and Cmd-Q quits the app: the app is inactive, so these menu key-equivalents do not dispatch on
            // their own.
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

