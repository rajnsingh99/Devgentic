// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  JarvisPanelController.swift
//  Devgentic
//
//  [Jarvis MVP] Jarvis lives in a borderless floating NSPanel, not a full-screen
//  overlay: the chat interface underneath stays visible and usable, and the orb can
//  be dragged anywhere on screen. Mirrors the QuickAccessPanelView pattern (floating
//  level, non-activating, transparent, isReleasedWhenClosed = false).
//
//  The panel has two sizes: the profile picker (first run / explicit switch) and the
//  compact orb. The hosted view reports which one it wants; this controller animates
//  the frame.
//

import AppKit
import SwiftUI

/// Which presentation the panel is showing, and therefore how big it is.
///
/// Was a Bool (picker vs orb) until Phase 3 needed a third size for the approval banner. An enum
/// rather than another flag because the next presentation will not be the last one either.
enum JarvisPanelMode: Equatable {
    case picker
    case orb
    case approval

    var size: NSSize {
        switch self {
        case .picker:   return NSSize(width: 460, height: 560)
        case .orb:      return NSSize(width: 300, height: 220)
        // Tall enough to show a tool's arguments, which the user MUST be able to read before
        // approving — the whole safety argument for not accepting a spoken "yes".
        case .approval: return NSSize(width: 380, height: 400)
        }
    }
}

// MARK: - Panel

/// Borderless transparent panel hosting the Jarvis orb.
final class JarvisPanel: NSPanel {

    /// Escape closes Jarvis once the panel has focus (a click gives it key status).
    /// Orb mode has no close button by design — the ask was a single config bubble —
    /// so the reliable exits are the orb's right-click menu and the composer toggle.
    var onCancel: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        // Safe here (unlike the QuickAccess panel, which had to avoid it because it
        // stole text selection): Jarvis hosts no text field, so a drag anywhere on the
        // panel should move it. Buttons still consume their own clicks.
        isMovableByWindowBackground = true
        isMovable = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // Stay put when the user clicks another app — Jarvis is meant to float over work.
        hidesOnDeactivate = false
        // The controller keeps a strong reference; AppKit's default would double-release.
        isReleasedWhenClosed = false
        // Jarvis draws its own dark hologram chrome regardless of app theme.
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

// MARK: - Controller

@MainActor
final class JarvisPanelController {

    static let shared = JarvisPanelController()

    /// Compact orb: the steady-state presentation.
    static let orbSize = JarvisPanelMode.orb.size
    /// Profile picker: first run, or an explicit switch from the config bubble.
    static let pickerSize = JarvisPanelMode.picker.size

    /// Session state, not a preference — deliberately NOT in AppSettings (see its Jarvis note).
    /// Internal rather than private so `JarvisConfigManager.resetAll()` can clear a panel that a
    /// crash or a disconnected display stranded off-screen: the panel is borderless with no
    /// titlebar, so there is otherwise no in-app way to get it back.
    /// `nonisolated`: JarvisConfigManager is main-thread-confined but NOT @MainActor (it is read
    /// from AppDelegate's nonisolated lifecycle code), and it needs these to clear a stranded
    /// panel position. A plain `static let` on a @MainActor type inherits that isolation.
    nonisolated static let originXKey = "jarvisPanelOriginX"
    nonisolated static let originYKey = "jarvisPanelOriginY"

    private var panel: JarvisPanel?
    /// ⚠️ Readable so the settings pane can reach a RUNNING session. Several settings are read
    /// once — at panel open, or when a run parks — and a change made while the orb is open was
    /// simply invisible to it. Writes stay private: only this controller owns the lifetime.
    private(set) var session: JarvisSessionController?
    private let logger = DGLogger(category: "JarvisPanel")

    var isOpen: Bool { panel != nil }

    private init() {}

    // MARK: Presentation

    func toggle(mainVM: MainApplicationViewModel) {
        if isOpen { close(reason: "shortcut or composer toggle") } else { show(mainVM: mainVM) }
    }

    func show(mainVM: MainApplicationViewModel) {
        guard panel == nil else {
            panel?.orderFrontRegardless()
            return
        }

        let controller = JarvisSessionController()
        controller.attach(mainVM: mainVM)
        // Wake word heard → make sure the orb is actually on screen to react to.
        controller.onRequestAttention = { [weak self] in self?.bringToAttention() }
        session = controller

        // begin() BEFORE building the view: it resolves the remembered profile and
        // settles the stage, so the panel is created at the right size and the picker
        // never flashes for a frame on a remembered-profile launch.
        controller.begin()

        let startsInPicker = controller.stage == .selectingProfile
        let size = startsInPicker ? Self.pickerSize : Self.orbSize
        let panel = JarvisPanel(contentRect: NSRect(origin: .zero, size: size))
        panel.onCancel = { [weak self] in self?.close(reason: "Escape key") }

        let root = JarvisFloatingView(
            controller: controller,
            onModeChange: { [weak self] mode in self?.resize(to: mode) },
            onClose: { [weak self] in self?.close(reason: "orb close button") }
        )
        panel.contentView = NSHostingView(rootView: root)
        panel.setFrameOrigin(restoredOrigin(for: size))
        self.panel = panel

        // orderFrontRegardless, NOT makeKeyAndOrderFront: the orb must not steal
        // keyboard focus from the chat composer behind it. (Clicking the panel still
        // makes it key, which is when Esc-to-close becomes available.)
        panel.orderFrontRegardless()
        logger.info("[JARVIS_PANEL] Panel OPENED (picker: \(startsInPicker)). CONSEQUENCE: a session controller now exists and the listening loop starts once a profile is chosen.")
    }

    func close(reason: String = "unspecified") {
        // ⚠️ A close on an already-closed panel is a no-op in every line below, but it used to log
        // one anyway — so a device log could show two CLOSED lines around a single OPEN, which
        // reads as a lifecycle bug and sends the reader looking for a second presentation that
        // never happened. `toggle`, Escape, the orb button and `applyJarvisHotkeyConfig` can all
        // reach here, and only the last one checks `isOpen` first.
        guard panel != nil || session != nil else {
            logger.debug("[JARVIS_PANEL] Close (\(reason)) with no panel open — nothing to do. CONSEQUENCE: none; this is a duplicate or late close, not a second teardown.")
            return
        }
        session?.teardown()
        session = nil
        if let panel {
            persistOrigin(panel.frame.origin)
            panel.orderOut(nil)
            panel.close()
        }
        panel = nil
        logger.info("[JARVIS_PANEL] Panel CLOSED (\(reason)). CONSEQUENCE: the session is torn down — voice loop stopped, run cancelled, audio engine released.")
    }

    /// Push-to-talk edges from the global shortcut. Forwarded rather than exposing `session`,
    /// which stays private so the config manager remains the only channel into a running orb.
    func beginPushToTalk() { session?.beginPushToTalk() }
    func endPushToTalk() { session?.endPushToTalk() }

    // MARK: Geometry

    /// Resize between orb and picker, keeping the panel's visual center fixed so it
    /// doesn't appear to jump when the picker collapses to the orb.
    private func resize(to mode: JarvisPanelMode) {
        guard let panel else { return }
        let target = mode.size
        guard panel.frame.size != target else { return }
        logger.info("[JARVIS_PANEL] Resizing to \(String(describing: mode)) (\(Int(target.width))×\(Int(target.height))).")

        let current = panel.frame
        var origin = NSPoint(
            x: current.midX - target.width / 2,
            y: current.midY - target.height / 2
        )
        if let screen = panel.screen ?? Self.activeScreen() {
            origin = Self.clamped(origin: origin, size: target, on: screen)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(NSRect(origin: origin, size: target), display: true)
        }
    }

    /// Wake-word response: raise the panel, and recenter it only if it isn't fully
    /// visible on a screen (deliberate placement is otherwise respected).
    private func bringToAttention() {
        guard let panel else { return }
        panel.orderFrontRegardless()
        guard let screen = panel.screen ?? Self.activeScreen() else { return }
        guard !screen.visibleFrame.contains(panel.frame) else { return }

        let size = panel.frame.size
        let centered = NSPoint(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.midY - size.height / 2
        )
        logger.info("[JARVIS_PANEL] Recentering — the panel was off-screen. CONSEQUENCE: the orb moves to the default position; a saved frame from a disconnected display is the usual cause.")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(NSRect(origin: centered, size: size), display: true)
        }
    }

    private func restoredOrigin(for size: NSSize) -> NSPoint {
        let defaults = UserDefaults.standard
        guard let screen = Self.activeScreen() else { return .zero }
        guard defaults.object(forKey: Self.originXKey) != nil else {
            // First ever open: centered on the active screen.
            return NSPoint(
                x: screen.visibleFrame.midX - size.width / 2,
                y: screen.visibleFrame.midY - size.height / 2
            )
        }
        let saved = NSPoint(
            x: defaults.double(forKey: Self.originXKey),
            y: defaults.double(forKey: Self.originYKey)
        )
        // A saved spot from a display that's since been disconnected must not strand
        // the panel off-screen — there's no titlebar to drag it back with.
        return Self.clamped(origin: saved, size: size, on: screen)
    }

    private func persistOrigin(_ origin: NSPoint) {
        UserDefaults.standard.set(origin.x, forKey: Self.originXKey)
        UserDefaults.standard.set(origin.y, forKey: Self.originYKey)
    }

    private static func clamped(origin: NSPoint, size: NSSize, on screen: NSScreen) -> NSPoint {
        let visible = screen.visibleFrame
        return NSPoint(
            x: min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width)),
            y: min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        )
    }

    /// The screen under the pointer, falling back to the key window's, then main.
    private static func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSApp.keyWindow?.screen
            ?? NSScreen.main
    }
}
