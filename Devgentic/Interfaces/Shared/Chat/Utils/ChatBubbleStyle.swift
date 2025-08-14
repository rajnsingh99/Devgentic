//
//  ChatBubbleStyle.swift
//  Devgentic
//
//  Created by Raj Singh on 11/08/25.
//

import SwiftUI
import AppKit

/// A custom shape that creates a "droplet" effect for the user's chat bubble.
/// It rounds all corners except for the top-right, creating a tail.
struct UserBubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cornerRadius: CGFloat = 20
        var path = Path()

        // Start just after the top-left corner radius
        path.move(to: CGPoint(x: rect.minX + cornerRadius, y: rect.minY))
        
        // Top-right corner (sharp)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))

        // Bottom-right corner
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius))
        path.addArc(
            center: CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY - cornerRadius),
            radius: cornerRadius,
            startAngle: Angle(degrees: 0),
            endAngle: Angle(degrees: 90),
            clockwise: false
        )

        // Bottom-left corner
        path.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY - cornerRadius),
            radius: cornerRadius,
            startAngle: Angle(degrees: 90),
            endAngle: Angle(degrees: 180),
            clockwise: false
        )
        
        // Top-left corner
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cornerRadius))
        path.addArc(
            center: CGPoint(x: rect.minX + cornerRadius, y: rect.minY + cornerRadius),
            radius: cornerRadius,
            startAngle: Angle(degrees: 180),
            endAngle: Angle(degrees: 270),
            clockwise: false
        )
        
        path.closeSubpath()
        return path
    }
}


/// A view modifier that applies the standard styling for a user's chat bubble,
/// including padding, text color, and the custom `UserBubbleShape` background.
struct UserBubbleModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .foregroundColor(.white) // Corrected to use a standard color
            .background(
                UserBubbleShape()
                    .fill(UITheme.Colors.accent)
            )
    }
}

extension View {
    /// Applies a custom style to a view, making it look like a user's chat bubble
    /// with a "droplet" tail.
    func userBubbleStyle() -> some View {
        self.modifier(UserBubbleModifier())
    }
}
