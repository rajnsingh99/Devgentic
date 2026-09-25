// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CursorModifiers.swift
//  Devgentic
//
//  Unified pointing hand cursor (NSCursor.pointingHand) and interactive hit-testing helpers.
//

import SwiftUI
import AppKit

// MARK: - Pointing Hand Cursor Modifier

/// Sets the macOS pointing hand cursor (NSCursor.pointingHand) on hover while safely guarding
/// against cursor stack leaks upon unmount or rapid view dismissal.
public struct PointingHandCursorModifier: ViewModifier {
    var isEnabled: Bool = true
    @State private var hasPushedCursor: Bool = false

    public init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }

    public func body(content: Content) -> some View {
        if isEnabled {
            content
                .onHover { inside in
                    if inside {
                        if !hasPushedCursor {
                            NSCursor.pointingHand.push()
                            hasPushedCursor = true
                        }
                    } else {
                        if hasPushedCursor {
                            NSCursor.pop()
                            hasPushedCursor = false
                        }
                    }
                }
                .onDisappear {
                    if hasPushedCursor {
                        NSCursor.pop()
                        hasPushedCursor = false
                    }
                }
        } else {
            content
        }
    }
}

extension View {
    /// Changes the mouse cursor to a pointing hand on hover (ideal for clickable buttons, segmented pickers, and list items).
    /// Safely cleans up the cursor stack if the view is dismissed while hovered.
    public func pointingHandCursor(enabled: Bool = true) -> some View {
        self.modifier(PointingHandCursorModifier(isEnabled: enabled))
    }
}
