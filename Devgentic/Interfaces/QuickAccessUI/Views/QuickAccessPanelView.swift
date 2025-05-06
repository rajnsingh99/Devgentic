//
//  QuickAccessPanelView.swift
//  Devgentic
//
//  Created by Raj Singh on 07/05/25.

import AppKit
import SwiftUI

class QuickAccessPanelView: NSPanel {

    private var hostingView: NSHostingView<QuickAccessContentView>?

    let collapsedHeight: CGFloat = 95
    let initialMinWidth: CGFloat = 500

    private let baseStyleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
    
    // Stores the panel's frame before zooming to full screen
    private var frameBeforeZoom: NSRect?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: initialMinWidth, height: collapsedHeight),
            styleMask: baseStyleMask,
            backing: .buffered,
            defer: true
        )
        setupWindow()
        setupContentView()
    }

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
    }

    private func setupContentView() {
        // Pass the toggleZoom function as a closure to ContentView
        let swiftUIContentView = QuickAccessContentView(
            dismiss: {
                self.closePanel()
            },
            onResize: { newHeight in // For expand/collapse of ContentView
                self.resizePanelProgrammatically(newHeight: newHeight)
            },
            onToggleZoom: { // For full screen zoom/unzoom of the panel
                self.toggleZoomState()
            }
        )

        let hostingView = NSHostingView(rootView: swiftUIContentView)
        self.hostingView = hostingView
        self.contentView = hostingView

        let panelContentSize = NSSize(width: initialMinWidth, height: collapsedHeight)
        self.setContentSize(panelContentSize)
        
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let xPosition = screenFrame.origin.x + (screenFrame.width - initialMinWidth) / 2
            let yPosition = screenFrame.maxY - panelContentSize.height - (screenFrame.height * 0.15)
            self.setFrameOrigin(NSPoint(x: xPosition, y: yPosition))
        } else {
            self.center()
        }
    }
    
    // Handles programmatic resize for ContentView's expand/collapse
    func resizePanelProgrammatically(newHeight: CGFloat) {
        guard let screen = NSScreen.main else { return }
        let currentFrame = self.frame
        var currentWidth: CGFloat = currentFrame.width
        if currentWidth < initialMinWidth {
            currentWidth = initialMinWidth
        }

        // If we are programmatically resizing (e.g. collapsing), we are no longer "zoomed" to full screen.
        // Clear the frameBeforeZoom so next zoom captures the new current state.
        if newHeight <= collapsedHeight { // Assuming this means it's collapsing fully
            frameBeforeZoom = nil
        }

        let newYPosition = currentFrame.origin.y + (currentFrame.height - newHeight)
        var newFrame = NSRect(
            x: currentFrame.origin.x,
            y: newYPosition,
            width: currentWidth,
            height: newHeight
        )
        newFrame.origin.x = screen.visibleFrame.origin.x + (screen.visibleFrame.width - currentWidth) / 2

        if newFrame.maxY > screen.visibleFrame.maxY {
             newFrame.origin.y = screen.visibleFrame.maxY - newHeight
        }
        if newFrame.minY < screen.visibleFrame.minY {
            newFrame.origin.y = screen.visibleFrame.minY
        }

        if newHeight > collapsedHeight {
            if !styleMask.contains(.resizable) { styleMask.insert(.resizable) }
        } else {
            if styleMask.contains(.resizable) { styleMask.remove(.resizable) }
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().setFrame(newFrame, display: true)
        }, completionHandler: nil)
    }

    // NEW: Toggles the panel between full screen and its previous size
    public func toggleZoomState() {
        guard let screen = self.screen ?? NSScreen.main else { return } // Use panel's current screen or main
        let screenVisibleFrame = screen.visibleFrame

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3 // Adjust animation duration as needed
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            if let previousFrame = self.frameBeforeZoom {
                // Currently zoomed, so restore to previousFrame
                self.animator().setFrame(previousFrame, display: true)
                self.frameBeforeZoom = nil // Clear stored frame
                // Ensure it's resizable if it was (likely, as zoom is for expanded state)
                if !self.styleMask.contains(.resizable) && self.frame.height > self.collapsedHeight {
                     self.styleMask.insert(.resizable)
                }
            } else {
                // Not currently zoomed, so zoom to full screen
                self.frameBeforeZoom = self.frame // Store current frame
                self.animator().setFrame(screenVisibleFrame, display: true)
                // Ensure it's resizable when zoomed
                if !self.styleMask.contains(.resizable) {
                    self.styleMask.insert(.resizable)
                }
            }
        }, completionHandler: nil)
    }

    func closePanel() {
        // When closing, reset any stored zoom state
        frameBeforeZoom = nil
        self.close()
    }

    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }
}
