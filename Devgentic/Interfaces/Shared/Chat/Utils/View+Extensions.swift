//
//  View+Extensions.swift
//  Devgentic
//
//  Created by Raj Singh on 22/07/25.
//

import SwiftUI

// MARK: - Card Style Modifier

private struct CardStyleModifier: ViewModifier {
    @Environment(\.appTheme) private var theme
    var padding: CGFloat?
    var backgroundColor: Color?
    var cornerRadius: CGFloat?

    func body(content: Content) -> some View {
        content
            .padding(padding ?? theme.spacingLarge)
            .background(backgroundColor ?? theme.controlBackground)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius ?? theme.cornerRadiusLarge))
            .shadow(color: theme.primaryText.opacity(0.1), radius: 5, y: 3)
    }
}

// MARK: - Chat Bubble Style Modifier

private struct ChatBubbleStyleModifier: ViewModifier {
    @Environment(\.appTheme) private var theme
    let isCurrentUser: Bool

    func body(content: Content) -> some View {
        content
            .padding(theme.spacingMedium)
            .background(isCurrentUser ? theme.accentColor : theme.controlBackground)
            .foregroundColor(isCurrentUser ? .white : theme.primaryText)
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadiusLarge))
            .shadow(color: theme.primaryText.opacity(0.15), radius: 2, y: 1)
    }
}



// MARK: - View Extensions

extension View {
    func cardStyle(
        padding: CGFloat? = nil,
        backgroundColor: Color? = nil,
        cornerRadius: CGFloat? = nil
    ) -> some View {
        modifier(CardStyleModifier(padding: padding, backgroundColor: backgroundColor, cornerRadius: cornerRadius))
    }

    func chatBubbleStyle(isCurrentUser: Bool) -> some View {
        modifier(ChatBubbleStyleModifier(isCurrentUser: isCurrentUser))
    }
}
