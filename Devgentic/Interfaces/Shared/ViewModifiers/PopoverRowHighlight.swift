// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  PopoverRowHighlight.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// Hover affordance for menu-style popover rows (Quick Schedule, folder selector), like the toolbar icons' hover.
/// Rows keep an 8pt internal plus 4pt external horizontal inset so text aligns with a plain 12pt-padded row.
private struct PopoverRowHighlight: ViewModifier {
    @Environment(\.appTheme) private var theme
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? theme.surfaceOverlay : Color.clear)
            )
            .padding(.horizontal, 4)
            .onHover { hover in
                withAnimation(.easeInOut(duration: 0.1)) { isHovering = hover }
            }
    }
}

extension View {
    /// Adds the standard hover highlight for a row inside a menu-style popover.
    func popoverRowHighlight() -> some View {
        modifier(PopoverRowHighlight())
    }
}
