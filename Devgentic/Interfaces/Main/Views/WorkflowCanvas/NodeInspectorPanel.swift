//
//  NodeInspectorPanel.swift
//  Devgentic
//
//  Created by Raj Singh on 04/07/26.
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

    /// Called when the WINDOW SYSTEM closes this panel rather than the manager doing it — today
    /// that means the app-wide ⌘W (DevgenticApp.swift:681), which reaches this window because it
    /// can become key (WF-CU9).
    ///
    /// ⚠️ NOT fired by `NodeInspectorPanelManager.close()`, which uses `orderOut(_:)`, and
    /// `orderOut` does not post `windowWillClose`. So there is no recursion and no double-dismiss.
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

        // ⚠️ The app rebinds ⌘W app-wide to `NSApp.keyWindow?.close()` (DevgenticApp.swift:681),
        // and this panel CAN be key (`canBecomeKey` below returns true) and is made key on show.
        // `NSWindow.close()` is programmatic — the missing `.closable` mask does NOT stop it — so
        // that path can take this window down behind the manager's back. With the AppKit default
        // (`true`) and a strong `activePanel` reference held by the manager, that is an
        // over-release of a still-referenced window. Left false, the worst case is a stale
        // `activePanel`, which `windowWillClose` below now repairs anyway (WF-CU9).
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
        // WF-CU9. Without this the manager's `activePanel` would stay pointing at a closed window:
        // every later `close()` would no-op on a dead reference while `targetConfigNode` still said
        // "open", and because `WorkflowNode` is `Hashable` the value-compared `onChange` would not
        // re-fire on re-selecting the SAME node — that node's inspector would refuse to reopen.
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

    /// Whether a panel is on screen RIGHT NOW.
    ///
    /// ⚠️ Teardown paths must ask THIS rather than infer presence from
    /// `canvasState.targetConfigNode`. The two can disagree — ⌘W closes the window without the
    /// manager hearing about it until `windowWillClose` lands — and a teardown log that guesses
    /// wrong is worse than no log (WF-CU9).
    var isPresented: Bool { activePanel != nil }


    /// Presents the custom Node Inspector panel.
    func show<Content: View>(
        minSize: NSSize,
        theme: any Theme,
        onClose: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        // ⚠️ `firingCallback: false` is NOT optional. Every panel's `onClose` is the same closure —
        // `{ canvasState.targetConfigNode = nil }` — so letting the superseded panel fire it would
        // nil the target 0.15 s AFTER the replacement opened, and the resulting `onChange(nil)`
        // would close the brand-new panel. The synchronous-capture fix and this flag only work as
        // a pair.
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

        // WF-CU9: repair the manager's state when the WINDOW SYSTEM closes this panel rather than
        // us — the app-wide ⌘W reaches it because the panel can become key.
        // ⚠️ Identity-checked (`===`): a superseded panel's delayed close must not clear the
        // reference to its REPLACEMENT.
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
    
    /// Dismisses the active panel.
    ///
    /// ⚠️ Shared state is cleared SYNCHRONOUSLY; only the fade and the `orderOut` are deferred.
    /// Deferring the state clear meant opening a second inspector produced an UNDISMISSABLE window:
    /// `show()` closed panel A, stored panel B in `activePanel`, and 0.15 s later A's completion
    /// handler ran and nil'd the reference to B. From then on B's Cancel, its Save-dismiss and the
    /// `targetConfigNode` observer all hit the `guard let panel = activePanel else { return }` and
    /// no-oped, while B — borderless, `.floating`, `.canJoinAllSpaces`, with no close control and
    /// no `.closable` mask for ⌘W — followed the user across every Space until they quit the app.
    /// Repeating the pattern stacked more of them.
    ///
    /// - Parameter firingCallback: pass `false` when the panel is being REPLACED rather than
    ///   dismissed. See `show()` for why this is load-bearing rather than tidiness.
    func close(firingCallback: Bool = true) {
        guard let closing = activePanel else { return }

        // Claim the state before yielding to the animation. A second `close()` arriving during the
        // fade now no-ops on the already-nil `activePanel`, which is the idempotence we want.
        activePanel = nil
        let callback = onCloseCallback
        onCloseCallback = nil

        // ⚠️ `firingCallback: false` now means only "the CALLER owns clearing `targetConfigNode`".
        // Superseding (`show`) and host teardown (`WorkflowCanvasView.dismissInspectorForTeardown`)
        // both need that, and each logs its own reason at its own call site — a single message here
        // could only ever describe one of them (WF-CU9).

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
