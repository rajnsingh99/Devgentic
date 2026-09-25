// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ScrollerCustomizer.swift
//  Devgentic
//
//  Forces native macOS overlay scrollers and eliminates scroller track / path backgrounds
//  across all ScrollViews and NSScrollViews, producing a clean, modern Antigravity / Linear-style UI.
//

import AppKit
import SwiftUI

public enum ScrollerCustomizer {
    private static var isInstalled = false
    private static let lock = NSLock()

    /// Installs AppKit runtime customizations to enforce overlay scroller behavior
    /// and suppress the visible track ("path") behind the scrollbar thumb.
    public static func install() {
        lock.lock()
        defer { lock.unlock() }

        guard !isInstalled else { return }
        isInstalled = true

        swizzlePreferredScrollerStyle()
        swizzleScrollViewSetScrollerStyle()
        swizzleScrollerSetScrollerStyle()
        swizzleScrollerDrawKnobSlot()
    }

    // MARK: - Method Swizzling

    private static func swizzlePreferredScrollerStyle() {
        guard let originalMethod = class_getClassMethod(NSScroller.self, #selector(getter: NSScroller.preferredScrollerStyle)),
              let swizzledMethod = class_getClassMethod(NSScroller.self, #selector(getter: NSScroller.devgentic_preferredScrollerStyle)) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }

    private static func swizzleScrollViewSetScrollerStyle() {
        guard let originalMethod = class_getInstanceMethod(NSScrollView.self, #selector(setter: NSScrollView.scrollerStyle)),
              let swizzledMethod = class_getInstanceMethod(NSScrollView.self, #selector(NSScrollView.devgentic_setScrollerStyle(_:))) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }

    private static func swizzleScrollerSetScrollerStyle() {
        guard let originalMethod = class_getInstanceMethod(NSScroller.self, #selector(setter: NSScroller.scrollerStyle)),
              let swizzledMethod = class_getInstanceMethod(NSScroller.self, #selector(NSScroller.devgentic_setScrollerStyle(_:))) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }

    private static func swizzleScrollerDrawKnobSlot() {
        guard let originalMethod = class_getInstanceMethod(NSScroller.self, #selector(NSScroller.drawKnobSlot(in:highlight:))),
              let swizzledMethod = class_getInstanceMethod(NSScroller.self, #selector(NSScroller.devgentic_drawKnobSlot(in:highlight:))) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }
}

// MARK: - Swizzled AppKit Extensions

extension NSScroller {
    @objc class var devgentic_preferredScrollerStyle: NSScroller.Style {
        return .overlay
    }

    @objc func devgentic_setScrollerStyle(_ newStyle: NSScroller.Style) {
        // Enforce overlay style regardless of system mouse/preference setting
        self.devgentic_setScrollerStyle(.overlay)
    }

    @objc func devgentic_drawKnobSlot(in slotRect: NSRect, highlight: Bool) {
        // No-op: suppress drawing the scroller track / path so only the floating knob thumb is visible
    }
}

extension NSScrollView {
    @objc func devgentic_setScrollerStyle(_ newStyle: NSScroller.Style) {
        // Enforce overlay style regardless of system mouse/preference setting
        self.devgentic_setScrollerStyle(.overlay)
    }
}

// MARK: - SwiftUI View Modifier

public struct SeamlessScrollTrackModifier: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .onAppear {
                ScrollerCustomizer.install()
            }
    }
}

extension View {
    /// Ensures scrollbars use overlay style with transparent / hidden tracks across this view.
    public func seamlessScrollTrack() -> some View {
        self.modifier(SeamlessScrollTrackModifier())
    }
}
