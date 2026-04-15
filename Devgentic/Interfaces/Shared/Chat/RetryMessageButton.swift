//
//  RetryMessageButton.swift
//  Devgentic
//
//  P1: Retry button for failed agent messages.
//

import SwiftUI

struct RetryMessageButton: View {
    let action: () -> Void
    @Environment(\.appTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(.caption, weight: .semibold))
                Text("Retry")
                    .font(.system(.caption, weight: .medium))
            }
            .foregroundColor(theme.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.accentColor.opacity(isHovering ? 0.15 : 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(theme.accentColor.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
        }
        .accessibilityLabel("Retry generating response")
    }
}
