//
//  RetryMessageButton.swift
//  Devgentic
//
//  P1: Retry button for failed agent messages.
//

import SwiftUI

struct RetryMessageButton: View {
    let action: () -> Void
    /// Why the retry is unavailable, or nil when it may run. Defaulted so existing call sites are
    /// unaffected. Surfaced as a tooltip — a dead control with no explanation reads as a bug.
    var refusal: RunAdmissionPolicy.Refusal? = nil
    @Environment(\.appTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        Button(action: { if refusal == nil { action() } }) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(.caption, weight: .semibold))
                Text("Retry")
                    .font(.system(.caption, weight: .medium))
            }
            .foregroundColor(refusal == nil ? theme.accentColor : theme.tertiaryText)
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
        .disabled(refusal != nil)
        .help(refusal?.userFacingReason ?? "Generate a new response")
        .onHover { hovering in
            guard refusal == nil else { return }
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
        }
        .accessibilityLabel("Retry generating response")
    }
}
