//
//  View+Extensions.swift
//  Devgentic
//
//  Created by Raj Singh on 22/07/25.
//

import SwiftUI

extension View {
    func cardStyle(
        padding: CGFloat = UITheme.Spacing.large,
        backgroundColor: Color = UITheme.Colors.controlBackground,
        cornerRadius: CGFloat = UITheme.CornerRadius.large
    ) -> some View {
        self
            .padding(padding)
            .background(backgroundColor)
            .cornerRadius(cornerRadius)
            .shadow(color: .black.opacity(0.1), radius: 5, y: 3)
    }
    
    func chatBubbleStyle(isCurrentUser: Bool) -> some View {
        self
            .padding(UITheme.Spacing.medium)
            .background(isCurrentUser ? UITheme.Colors.accent : UITheme.Colors.controlBackground)
            .foregroundColor(isCurrentUser ? .white : UITheme.Colors.primaryText)
            .cornerRadius(UITheme.CornerRadius.large)
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
    }
}
