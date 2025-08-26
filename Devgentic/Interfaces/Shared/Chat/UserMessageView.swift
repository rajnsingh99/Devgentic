//
//  UserMessageView.swift
//  Devgentic
//
//  Created by Raj Singh on 20/08/25.
//

import SwiftUI
import AppKit

struct UserMessageView: View {
    let text: String
    private let lineLimitCollapsed = 10
    @State private var isExpanded = false
    @State private var isTruncatable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isTruncatable {
                HStack {
                    Spacer()
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isExpanded.toggle()
                        }
                    }) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white.opacity(0.7))
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                            .padding(6)
                            .background(Color.black.opacity(0.25))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Collapse" : "Expand")
                }
            }

            Text(text)
                .font(UITheme.Fonts.body)
                .lineLimit(isExpanded ? nil : lineLimitCollapsed)
                .background(
                    GeometryReader { geometry in
                        Color.clear.onAppear {
                            determineTruncation(availableWidth: geometry.size.width)
                        }
                    }
                )
                .fixedSize(horizontal: false, vertical: true)
        }
        .clipped()
    }
    
    private func determineTruncation(availableWidth: CGFloat) {
        let fullTextView = Text(text)
            .font(UITheme.Fonts.body)
            .frame(width: availableWidth, alignment: .leading)
        
        let truncatedTextView = Text(text)
            .font(UITheme.Fonts.body)
            .lineLimit(lineLimitCollapsed)
            .frame(width: availableWidth, alignment: .leading)
            
        let fullSize = NSHostingView(rootView: fullTextView).fittingSize
        let truncatedSize = NSHostingView(rootView: truncatedTextView).fittingSize
        
        if fullSize.height > truncatedSize.height + 2 {
            self.isTruncatable = true
        }
    }
}

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

struct UserBubbleModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .foregroundColor(.white)
            .background(
                UserBubbleShape()
                    .fill(UITheme.Colors.accent)
            )
    }
}

extension View {
    func userBubbleStyle() -> some View {
        self.modifier(UserBubbleModifier())
    }
}

