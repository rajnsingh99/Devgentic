// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  NodeInspectorPanel.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import AppKit
import SwiftUI
import os

private let logger = DGLogger(category: "NodeInspectorPanel")

/// Environment key to allow hosted views to trigger panel dismissal
struct NodeInspectorCloseKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var closeNodeInspector: () -> Void {
        get { self[NodeInspectorCloseKey.self] }
        set { self[NodeInspectorCloseKey.self] = newValue }
    }
}

/// A custom NSPanel that serves as a borderless, resizable, floating inspector panel for workflow nodes.
class NodeInspectorPanel: NSPanel, NSWindowDelegate {

    /// Called when the window system closes this panel rather than the manager, such as the app-wide ⌘W.
    /// Not fired by `NodeInspectorPanelManager.close()`, which uses `orderOut(_:)` and posts no `windowWillClose`.
    var onSystemClose: (() -> Void)?


    init(contentView: NSView, minSize: NSSize) {
        
        let widthKey = "nodeInspectorPanelWidth"
        let heightKey = "nodeInspectorPanelHeight"
        
        let savedWidth = UserDefaults.standard.double(forKey: widthKey)
        let savedHeight = UserDefaults.standard.double(forKey: heightKey)
        
        let initialWidth = savedWidth > 0 ? CGFloat(savedWidth) : minSize.width
        let initialHeight = savedHeight > 0 ? CGFloat(savedHeight) : minSize.height
        
        let targetSize = NSSize(
            width: max(initialWidth, minSize.width),
            height: max(initialHeight, minSize.height)
        )
        
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: targetSize.width, height: targetSize.height),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: true
        )
        
        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isMovableByWindowBackground = true
        self.hasShadow = true
        self.backgroundColor = .clear
        self.isOpaque = false
        self.delegate = self

        // Why: the AppKit default (true) would over-release a window the manager still references
        // Left false: the app-wide ⌘W calls `NSWindow.close()` on this key window behind the manager's back.
        self.isReleasedWhenClosed = false

        self.contentView = contentView
        
        // Center the panel relative to the active main window
        if let mainWindow = NSApp.mainWindow {
            let mainFrame = mainWindow.frame
            let x = mainFrame.origin.x + (mainFrame.width - targetSize.width) / 2
            let y = mainFrame.origin.y + (mainFrame.height - targetSize.height) / 2
            self.setFrame(NSRect(x: x, y: y, width: targetSize.width, height: targetSize.height), display: true)
        } else {
            self.center()
        }
    }
    
    override var canBecomeKey: Bool {
        return true
    }
    
    override var canBecomeMain: Bool {
        return false
    }
    
    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Repairs the manager's `activePanel` after a system close so later `close()` calls and re-selecting the same node work.
        onSystemClose?()
    }

    func windowDidResize(_ notification: Notification) {
        let widthKey = "nodeInspectorPanelWidth"
        let heightKey = "nodeInspectorPanelHeight"
        
        UserDefaults.standard.set(self.frame.size.width, forKey: widthKey)
        UserDefaults.standard.set(self.frame.size.height, forKey: heightKey)
    }
}

/// Global manager to coordinate the display of the NodeInspectorPanel.
class NodeInspectorPanelManager {
    static let shared = NodeInspectorPanelManager()
    
    private var activePanel: NodeInspectorPanel?
    private var onCloseCallback: (() -> Void)?

    // Why: the two can disagree: ⌘W closes the window before the manager hears about it
    /// Whether a panel is on screen right now.
    /// Teardown paths ask this instead of inferring presence from `canvasState.targetConfigNode`.
    var isPresented: Bool { activePanel != nil }


    /// Presents the custom Node Inspector panel.
    func show<Content: View>(
        minSize: NSSize,
        theme: any Theme,
        onClose: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        // Why: every panel's `onClose` clears `targetConfigNode`, which would close the replacement 0.15 s later
        // `firingCallback: false` is required when replacing a panel.
        if activePanel != nil {
            logger.info("[WF_CANVAS] Node inspector panel SUPERSEDED by a new one — dismissing the previous panel without firing its onClose. CONSEQUENCE: the replacement stays open; firing it here would nil `targetConfigNode` and close the panel that just opened.")
        }
        close(firingCallback: false)

        self.onCloseCallback = onClose
        
        // Wrap the provided content in our styled borderless window overlay
        let wrappedView = content()
            .environment(\.closeNodeInspector, { [weak self] in
                self?.close()
            })
            .environment(\.appTheme, theme)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [theme.dividerColor, theme.dividerColor.opacity(0.3)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1.5
                    )
            )
        
        let hostingView = NSHostingView(rootView: wrappedView)
        
        let panel = NodeInspectorPanel(contentView: hostingView, minSize: minSize)
        panel.minSize = minSize
        
        self.activePanel = panel

        // Repairs the manager's state when the window system closes this panel.
        // Identity-checked (`===`) so a superseded panel's delayed close cannot clear its replacement.
        panel.onSystemClose = { [weak self, weak panel] in
            guard let self, let panel, self.activePanel === panel else { return }
            logger.notice("[WF_CANVAS] Node inspector panel was closed by the window system (⌘W maps to `NSApp.keyWindow?.close()` app-wide) rather than by the manager. CONSEQUENCE: the manager's reference and the canvas's `targetConfigNode` are cleared here so the next inspector can open; any fields the panel buffered are discarded — but NOT the same as Cancel: the Profile inspector's node name and per-node orchestration settings are written through as they are changed, and only Cancel restores them (register INS-2), so this route KEEPS them.")
            self.activePanel = nil
            let callback = self.onCloseCallback
            self.onCloseCallback = nil
            callback?()
        }

        // Fade in animation
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 1.0
        }
    }
    
    // Why: deferring the state clear lets a late completion nil the replacement panel, leaving it undismissable
    /// Dismisses the active panel, clearing shared state synchronously; only the fade and `orderOut` are deferred.
    /// firingCallback: pass `false` when the panel is being replaced rather than dismissed.
    func close(firingCallback: Bool = true) {
        guard let closing = activePanel else { return }

        // Claim the state before yielding to the animation. A second `close()` arriving during the
        // fade now no-ops on the already-nil `activePanel`, which is the idempotence we want.
        activePanel = nil
        let callback = onCloseCallback
        onCloseCallback = nil

        // `firingCallback: false` means the caller owns clearing `targetConfigNode` and logs its own reason.

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            closing.animator().alphaValue = 0
        }, completionHandler: {
            closing.orderOut(nil)
            if firingCallback { callback?() }
        })
    }
}
