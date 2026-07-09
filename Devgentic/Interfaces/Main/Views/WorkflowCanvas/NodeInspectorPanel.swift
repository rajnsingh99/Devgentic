//
//  NodeInspectorPanel.swift
//  Devgentic
//
//  Created by Raj Singh on 04/07/26.
//

import AppKit
import SwiftUI

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
    
    /// Presents the custom Node Inspector panel.
    func show<Content: View>(
        minSize: NSSize,
        theme: any Theme,
        onClose: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        // If a panel is already active, close it first
        close()
        
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
        
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            self?.activePanel = nil
            self?.onCloseCallback?()
            self?.onCloseCallback = nil
        })
    }
}
