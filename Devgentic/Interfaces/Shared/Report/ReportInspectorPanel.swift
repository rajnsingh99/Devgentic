// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh

import AppKit
import SwiftUI

/// A custom NSPanel that serves as a borderless, resizable, floating inspector panel for reports.
class ReportInspectorPanel: NSPanel, NSWindowDelegate {
    let isDeveloperMode: Bool
    
    init(contentView: NSView, minSize: NSSize, isDeveloperMode: Bool) {
        self.isDeveloperMode = isDeveloperMode
        
        let widthKey = isDeveloperMode ? "reportInspectorDevWidth" : "reportInspectorUserWidth"
        let heightKey = isDeveloperMode ? "reportInspectorDevHeight" : "reportInspectorUserHeight"
        
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
    
    func windowDidResize(_ notification: Notification) {
        let widthKey = isDeveloperMode ? "reportInspectorDevWidth" : "reportInspectorUserWidth"
        let heightKey = isDeveloperMode ? "reportInspectorDevHeight" : "reportInspectorUserHeight"
        
        UserDefaults.standard.set(self.frame.size.width, forKey: widthKey)
        UserDefaults.standard.set(self.frame.size.height, forKey: heightKey)
    }
}

/// Global manager to coordinate the display of the ReportInspectorPanel.
class ReportInspectorPanelManager {
    static let shared = ReportInspectorPanelManager()
    
    private var activePanel: ReportInspectorPanel?
    
    func show(
        messageID: UUID,
        conversationID: UUID,
        traceID: String?,
        theme: any Theme,
        isDeveloperMode: Bool,
        answerPreview: String? = nil
    ) {
        // If a panel is already active, close it first
        close()

        // Pass a close handler so the SwiftUI view can dismiss the panel
        let rootView = ReportInspectorView(
            messageID: messageID,
            conversationID: conversationID,
            traceID: traceID,
            answerPreview: answerPreview,
            onClose: { [weak self] in
                self?.close()
            }
        )
        .environment(\.appTheme, theme)
        
        let hostingView = NSHostingView(rootView: rootView)
        
        // One unified report now — the old user-mode 550×550 can't hold the
        // stream + inspector split, so both modes share the same floor.
        let minSize = NSSize(width: 900, height: 600)
        
        let panel = ReportInspectorPanel(contentView: hostingView, minSize: minSize, isDeveloperMode: isDeveloperMode)
        panel.minSize = minSize
        
        self.activePanel = panel
        
        // Fade in animation
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 1.0
        }
    }
    
    func close() {
        guard let panel = activePanel else { return }
        // Release ownership SYNCHRONOUSLY, before the fade. The completion used to nil
        // `activePanel` 0.15s later — by which time `show()` had already stored the NEW
        // panel there, so the manager forgot it: the second panel's ✕ went dead (borderless
        // panels have no close button of their own) and further clicks stacked more panels.
        // The fade-out below animates the LOCAL reference and needs no manager state.
        activePanel = nil

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }
}
