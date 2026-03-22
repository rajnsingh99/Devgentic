//
//  SidebarAnimations.swift
//  Devgentic
//
//  Shared animation utilities and reusable components for the sidebar.
//

import SwiftUI

// MARK: - Scale Button Style
/// A button style that provides a subtle press-down scale effect.
struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Pulse Animation Modifier
/// Applies a repeating glow-pulse shadow effect, ideal for CTA buttons.
struct PulseAnimationModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .shadow(
                color: Color.accentColor.opacity(isPulsing ? 0.3 : 0.0),
                radius: isPulsing ? 12 : 4, x: 0, y: 0
            )
            .onAppear {
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
    }
}

// MARK: - Streaming Pulse Indicator
/// An animated pulsing dot indicating an active streaming conversation.
struct StreamingPulseIndicator: View {
    @State private var isPulsing = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        Circle()
            .fill(theme.streamingIndicator)
            .frame(width: 8, height: 8)
            .scaleEffect(isPulsing ? 1.3 : 0.8)
            .opacity(isPulsing ? 1.0 : 0.5)
            .shadow(color: theme.streamingIndicator.opacity(isPulsing ? 0.4 : 0.0), radius: 4)
            .animation(
                .easeInOut(duration: 0.8)
                .repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}

// MARK: - Hover Action Button
/// A small icon button that reveals on hover, used for inline row actions.
struct HoverActionButton: View {
    let icon: String
    var tint: Color = .secondary
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isHovering ? tint : theme.tertiaryText)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHovering ? theme.surfaceOverlay : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
