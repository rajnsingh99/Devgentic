//
//  PopoverRowHighlight.swift
//  Devgentic
//
//  Hover affordance for menu-style popover rows (Quick Schedule, folder
//  selector). Mirrors the hover treatment used by toolbar icons and the
//  Whisper model rows so popover items don't feel inert. Rows keep an
//  8pt internal + 4pt external horizontal inset so text stays at the
//  same x-position as a plain 12pt-padded row.
//

import SwiftUI

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
